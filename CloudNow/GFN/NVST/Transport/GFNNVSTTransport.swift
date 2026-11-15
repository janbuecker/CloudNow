import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC

/// The experimental NVST transport for GeForce NOW: RTSPS negotiation, raw-UDP SRTP video decoded
/// by VideoToolbox, and a libwebrtc peer connection carrying the SCTP data channels (control,
/// gamepad input, feedback) and stereo Opus game audio.
///
/// This is the only type the rest of the app talks to. One instance serves one connection
/// attempt: `connect()` once, then `disconnect()`.
final nonisolated class GFNNVSTTransport: @unchecked Sendable {
    /// How long `connect()` waits for the first decoded frame once negotiation has finished.
    static let defaultFirstFrameTimeout: Duration = .seconds(15)
    /// How often the first-frame wait looks.
    static let firstFramePollInterval: Duration = .milliseconds(20)

    private enum Phase {
        case idle
        case connecting
        case connected
        case closed
    }

    private struct State {
        var phase = Phase.idle
        /// A terminal report that arrived before `connect()` returned; it fails the connect
        /// instead of being delivered as an event.
        var terminalDuringConnect: NativeNVSTTransportTermination?
    }

    /// Events after a successful `connect()`. Finishes on `disconnect()`.
    ///
    /// Events raised while `connect()` is still waiting for the first frame — `.inputReady`,
    /// `.haptics`, `.hdrModeChanged` — are buffered and delivered to the first iteration.
    let events: AsyncStream<GFNNVSTEvent>

    private let request: GFNNVSTConnectRequest
    private let transport: NvstBifrostFreeTransport
    private let log: @Sendable (String) -> Void
    private let firstFrameTimeout: Duration
    private let eventContinuation: AsyncStream<GFNNVSTEvent>.Continuation
    private let lock = NSLock()
    private var state = State()
    private var terminalForwardingTask: Task<Void, Never>?

    convenience init(request: GFNNVSTConnectRequest,
                     peerConnectionFactory: LKRTCPeerConnectionFactory,
                     frameSink: @escaping GFNNVSTFrameSink,
                     log: @escaping @Sendable (String) -> Void)
    {
        self.init(request: request,
                  peerConnectionFactory: peerConnectionFactory,
                  frameSink: frameSink,
                  log: log,
                  firstFrameTimeout: Self.defaultFirstFrameTimeout)
    }

    init(request: GFNNVSTConnectRequest,
         peerConnectionFactory: LKRTCPeerConnectionFactory,
         frameSink: @escaping GFNNVSTFrameSink,
         log: @escaping @Sendable (String) -> Void,
         firstFrameTimeout: Duration)
    {
        self.request = request
        self.log = log
        self.firstFrameTimeout = firstFrameTimeout
        let stream = AsyncStream<GFNNVSTEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
        transport = NvstBifrostFreeTransport(
            peerConnectionFactory: peerConnectionFactory,
            pixelBufferSink: { pixelBuffer, presentationTime, isKeyframe in
                frameSink(pixelBuffer, Self.rtpTimestamp(from: presentationTime), isKeyframe)
            },
            logger: log
        )
    }

    /// The decoder stamps each frame with its RTP timestamp on the 90 kHz clock; this is that
    /// timestamp back as the 32-bit wire value.
    static func rtpTimestamp(from presentationTime: CMTime) -> UInt32 {
        UInt32(truncatingIfNeeded: presentationTime.value)
    }

    /// Negotiates RTSPS, brings up the bundle, starts video and returns once the FIRST FRAME has
    /// been decoded. Throws `.firstFrameTimeout` after a bounded wait (15 s by default), and tears
    /// everything down before throwing so the caller can fall back to WebRTC. Honors task
    /// cancellation (`.cancelled`).
    func connect() async throws {
        let canStart: Bool = lock.withLock {
            guard state.phase == .idle else { return false }
            state.phase = .connecting
            return true
        }
        guard canStart else {
            throw GFNNVSTError.negotiationFailed("This NVST transport has already been started; create a new one.")
        }
        do {
            try await establish()
        } catch {
            let failure = Task.isCancelled ? GFNNVSTError.cancelled : GFNNVSTError(connectFailure: error)
            log("NVST connect failed: \(failure)")
            await disconnect()
            throw failure
        }
    }

    private func establish() async throws {
        guard !NvstBifrostFreeProfile.rtspsEndpoints(for: request).isEmpty else {
            throw GFNNVSTError.noRTSPEndpoint
        }
        try Task.checkCancellation()
        await installHandlers()
        startTerminalForwarding()

        let transport = transport
        try await withTaskCancellationHandler {
            try await transport.connect(request: self.request)
        } onCancel: {
            // The negotiation does not watch for cancellation itself; tearing the transport down
            // is what makes it stop at its next step.
            Task { await transport.disconnect() }
        }
        try await waitForFirstFrame()

        let becameConnected: Bool = lock.withLock {
            guard state.phase == .connecting, state.terminalDuringConnect == nil else { return false }
            state.phase = .connected
            return true
        }
        guard becameConnected else {
            throw connectInterruption() ?? GFNNVSTError.cancelled
        }
        await transport.armWatchdog()
        log("NVST connected: first frame decoded")
    }

    /// Why the connect cannot complete, when something ended it from outside the happy path.
    private func connectInterruption() -> GFNNVSTError? {
        lock.lock()
        defer { lock.unlock() }
        if let terminal = state.terminalDuringConnect {
            return GFNNVSTError(duringConnect: terminal)
        }
        return state.phase == .connecting ? nil : .cancelled
    }

    private func waitForFirstFrame() async throws {
        let deadline = ContinuousClock.now.advanced(by: firstFrameTimeout)
        while transport.frameMonitor.decodedFrameCount == 0 {
            if let interruption = connectInterruption() {
                throw interruption
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw GFNNVSTError.firstFrameTimeout }
            try await Task.sleep(for: Self.firstFramePollInterval)
        }
    }

    private func installHandlers() async {
        let continuation = eventContinuation
        await transport.setHapticEventHandler { events in
            for event in events {
                continuation.yield(.rumble(from: event))
            }
        }
        await transport.setHdrModeHandler { notification in
            continuation.yield(.hdrModeChanged(enabled: notification.isHDR))
        }
        await transport.setInputReadyHandler {
            continuation.yield(.inputReady)
        }
    }

    /// Relays the transport's terminal report: as the reason `connect()` fails while it is still
    /// connecting, as an event afterwards.
    private func startTerminalForwarding() {
        let terminations = transport.terminalEvents()
        let task = Task { [weak self] in
            for await termination in terminations {
                self?.deliver(termination)
            }
        }
        lock.withLock { terminalForwardingTask = task }
    }

    private func deliver(_ termination: NativeNVSTTransportTermination) {
        let shouldEmit: Bool = lock.withLock {
            switch state.phase {
            case .connecting:
                if state.terminalDuringConnect == nil {
                    state.terminalDuringConnect = termination
                }
                return false
            case .connected:
                return true
            case .idle, .closed:
                return false
            }
        }
        if shouldEmit {
            eventContinuation.yield(.terminal(from: termination))
        }
    }

    /// Idempotent. Stops timers, closes sockets, the RTSPS connection and the peer connection,
    /// and finishes `events`. Returns once the teardown has completed.
    func disconnect() async {
        let forwarding: Task<Void, Never>? = lock.withLock {
            state.phase = .closed
            let task = terminalForwardingTask
            terminalForwardingTask = nil
            return task
        }
        await transport.disconnect()
        forwarding?.cancel()
        eventContinuation.finish()
    }

    /// Sends one GFN gamepad report as produced by CloudNow's `InputEncoder.encodeGamepad`: the
    /// 54-byte partially-reliable form (encoder protocol version 3) or the bare 38-byte event
    /// (protocol version 2). The report is decoded and re-encoded as an NVST gamepad command —
    /// timestamps become microseconds since NVST session start, the sequence becomes this
    /// transport's own per-pad counter, and the NVST command header is prefixed — then sent on
    /// `input_channel_partially_reliable`. Returns false when input is not ready or the packet is
    /// not a gamepad report (non-gamepad input is dropped in this version).
    /// Synchronous and callable from any thread.
    func sendGamepadReport(_ report: Data) -> Bool {
        transport.gamepadInput.send(report: report)
    }

    /// Latest statistics; cheap, callable about once per second. Rates cover the interval since
    /// the previous call.
    func statsSnapshot() async -> GFNNVSTStatsSnapshot {
        guard let snapshot = await transport.performanceSnapshot() else { return GFNNVSTStatsSnapshot() }
        return GFNNVSTStatsSnapshot(snapshot)
    }
}
