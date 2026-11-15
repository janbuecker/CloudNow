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
    /// How long `connect()` lets the RTSPS negotiation and bundle bring-up run before giving up.
    static let defaultNegotiationTimeout: Duration = .seconds(20)
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
        /// Releases a `connect()` that is still waiting on the negotiation.
        var abandonNegotiation: (@Sendable () -> Void)?
    }

    /// Events after a successful `connect()`. Finishes on `disconnect()`.
    ///
    /// Events raised while `connect()` is still waiting for the first frame — `.inputReady`,
    /// `.haptics`, `.hdrModeChanged` — are buffered and delivered to the first iteration.
    let events: AsyncStream<GFNNVSTEvent>

    private let request: GFNNVSTConnectRequest
    private let transport: NvstBifrostFreeTransport
    private let log: @Sendable (String) -> Void
    private let negotiationTimeout: Duration
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
                  negotiationTimeout: Self.defaultNegotiationTimeout,
                  firstFrameTimeout: Self.defaultFirstFrameTimeout)
    }

    init(request: GFNNVSTConnectRequest,
         peerConnectionFactory: LKRTCPeerConnectionFactory,
         frameSink: @escaping GFNNVSTFrameSink,
         log: @escaping @Sendable (String) -> Void,
         negotiationTimeout: Duration,
         firstFrameTimeout: Duration)
    {
        self.request = request
        self.log = log
        self.negotiationTimeout = negotiationTimeout
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

    deinit {
        // A transport dropped without `disconnect()` still has timers and sockets of its own.
        let transport = transport
        Task { await transport.disconnect() }
    }

    /// The decoder stamps each frame with its RTP timestamp on the 90 kHz clock; this is that
    /// timestamp back as the 32-bit wire value.
    static func rtpTimestamp(from presentationTime: CMTime) -> UInt32 {
        UInt32(truncatingIfNeeded: presentationTime.value)
    }

    /// Negotiates RTSPS, brings up the bundle, starts video and returns once the FIRST FRAME has
    /// been decoded. Throws `.firstFrameTimeout` when no frame is decoded within a bounded wait
    /// (15 s by default) of the negotiation finishing, and `.negotiationFailed` when the
    /// negotiation itself does not finish in time (20 s by default). Everything is torn down
    /// before it throws so the caller can fall back to WebRTC. Honors task cancellation
    /// (`.cancelled`).
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

        try await negotiate()
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

    /// Runs the transport's negotiation, giving up on it as soon as this transport is
    /// disconnected, the calling task is cancelled, or `negotiationTimeout` has passed.
    ///
    /// The negotiation runs in a task of its own, so cancelling the caller never cancels an RTSP
    /// request in flight; it is stopped by tearing the transport down instead, which it notices
    /// at its next step and cleans up after on its own.
    private func negotiate() async throws {
        let transport = transport
        let request = request
        let timeout = negotiationTimeout
        let outcome: Result<Void, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, any Error>, Never>) in
                let once = NvstOneShot(continuation)
                let isStillConnecting: Bool = lock.withLock {
                    guard state.phase == .connecting else { return false }
                    state.abandonNegotiation = { once.resume(.failure(CancellationError())) }
                    return true
                }
                guard isStillConnecting else {
                    once.resume(.failure(CancellationError()))
                    return
                }
                Task {
                    do {
                        try await transport.connect(request: request)
                        once.resume(.success(()))
                    } catch {
                        once.resume(.failure(error))
                    }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    once.resume(.failure(GFNNVSTError.negotiationFailed("The NVST negotiation did not finish in time.")))
                }
            }
        } onCancel: {
            Task { await self.disconnect() }
        }
        lock.withLock { state.abandonNegotiation = nil }
        try outcome.get()
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
        let (forwarding, abandonNegotiation): (Task<Void, Never>?, (@Sendable () -> Void)?) = lock.withLock {
            state.phase = .closed
            let pending = (terminalForwardingTask, state.abandonNegotiation)
            terminalForwardingTask = nil
            state.abandonNegotiation = nil
            return pending
        }
        await transport.disconnect()
        abandonNegotiation?()
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
