import CoreMedia
import CoreVideo
import Dispatch
import Foundation
@preconcurrency import LiveKitWebRTC

/// NVST transport with **no NVIDIA libraries**: the RTSP control plane, the raw-SRTP Mjolnir video
/// receiver, and VideoToolbox decode, with libwebrtc carrying only the ICE/DTLS bundle.
///
/// Pipeline, in the order the official client establishes it:
/// 1. RTSPS-over-WSS control channel to the seat's `:322` endpoint (OPTIONS → DESCRIBE → SETUP).
/// 2. The video handoff is *derived* from those answers — it never arrives through signaling —
///    including the SRTP master key, which this client generates and ANNOUNCEs itself.
/// 3. The raw-SRTP Mjolnir socket starts receiving before ANNOUNCE (Bifrost arms
///    `MjolnirVideoReceiver` first), then ANNOUNCE, then PLAY.
/// 4. Access units decode through VideoToolbox and are published as decoded `CVPixelBuffer`s.
///
/// Gamepad input, stereo game audio and the RTCP feedback plane ride the ICE/DTLS bundle's SCTP
/// data channels and Opus track, which this transport brings up through `NvstWebRtcBundle`; the
/// bare Mjolnir socket keeps carrying video and its own SRTCP reports.
///
/// One instance serves one connection: after `disconnect()` it cannot be connected again.
actor NvstBifrostFreeTransport {
    /// Decoded frames for the renderer: the buffer, its presentation time on the 90 kHz RTP
    /// clock, and whether it is a keyframe. Called on the decode queue; it must not block.
    typealias PixelBufferSink = @Sendable (CVPixelBuffer, CMTime, Bool) -> Void

    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case tornDown
    }

    let pixelBufferSink: PixelBufferSink?
    /// The process-wide factory the bundle's peer connection is created from. Borrowed.
    let peerConnectionFactory: LKRTCPeerConnectionFactory
    let logger: (@Sendable (String) -> Void)?
    private let controlTimeout: Duration
    /// The session-relative time base this actor, the video pipeline and the gamepad path all
    /// stamp with.
    nonisolated let clock = NvstSessionClock()
    /// Decoded-frame bookkeeping for the first-frame wait and the stall watchdog, off the actor.
    nonisolated let frameMonitor = NvstFrameMonitor()
    /// The gamepad state path, off the actor so input never queues behind QoS or keepalives.
    nonisolated let gamepadInput: NvstGamepadInput
    private nonisolated let terminationStream: AsyncStream<NativeNVSTTransportTermination>
    private nonisolated let terminationContinuation: AsyncStream<NativeNVSTTransportTermination>.Continuation

    var phase: Phase = .idle
    var request: GFNNVSTConnectRequest?
    var reserver: NvstLocalBundleReserver?
    var session: NvstRtspSession?
    var receiver: NvstMjolnirReceiver?
    var bundle: NvstWebRtcBundle?
    var feedbackSender: NvstFeedbackSender?
    var decoder: NvstVideoToolboxDecoder?
    /// Decode + frame acknowledgement, deliberately off this actor. See `NvstVideoPipeline`.
    var videoPipeline: NvstVideoPipeline?
    var lastHandoff: NVSTVideoHandoff?
    /// Why the bundle could not be brought up, when it could not. The negotiator carries on to
    /// ANNOUNCE and PLAY regardless, so `connect` checks this once it returns.
    var bundleFailure: String?
    private var heartbeatTask: Task<Void, Never>?
    var controlKeepAliveTask: Task<Void, Never>?
    var qosFeedbackTask: Task<Void, Never>?
    var qosSequence: UInt32 = 0
    var lastQosBytesReceived: UInt64 = 0
    var lastQosDelayMicroseconds: UInt32 = 0
    var remoteAudioTrackCount = 0
    /// The frame rate, resolution and codec this session negotiates with.
    var negotiatedFps: Int?
    var negotiatedResolution: String?
    var negotiatedCodec: String?
    /// The seat's latest `0x0101` statistics: the HUD's game frame rate comes from here.
    var latestSeatStats: NvstSeatStats?
    private var seatStatsReceived = 0
    var didActivateInput = false
    var qosReportsSent = 0
    var qosReportFailures = 0
    var rtpStatsReportsSent = 0
    var controlStatsReportsSent = 0
    var lastRtpStatsFrame: UInt64 = 0
    var controlStatsLastSentAt: Date?
    var lastIdrRequestAt: Date?
    var idrRequestsSent = 0
    var lastInvalidationAt: Date?
    var pendingInvalidationFirst: UInt32?
    var pendingInvalidationLast: UInt32?
    var invalidationFlushTask: Task<Void, Never>?
    var invalidationsSent = 0
    var inputEventsSent = 0
    var inputSequence: UInt16 = 0
    var didAnnounceClientState = false
    var hapticEventsReceived: UInt64 = 0
    var lastHdrMode: NvstHdrModeNotification?
    /// Set once the bundle comes up; owned by the shared clock so the off-actor video pipeline
    /// stamps its acks from the same origin.
    var sessionStartedAt: Date? {
        clock.startDate
    }

    /// Incremented on every bundle install and at teardown. A callback whose captured generation
    /// has moved on belongs to a replaced bundle and must not touch the current connection's state.
    var bundleGeneration: UInt64 = 0
    /// Interval cursors for `performanceSnapshot()`.
    var performanceSampler = NvstPerformanceSampler()
    /// Armed once the first frame has been shown: from then on a stream that stops, or a control
    /// connection that dies, is reported as a failure.
    private var isWatchdogArmed = false
    private var keepAliveTracker = NvstBifrostFreeWatchdog.KeepAliveTracker()
    /// One terminal report per connection: the first verdict is the one that explains the rest.
    private var didReportTermination = false

    /// Rumble from the seat, per `0x010b` command. Called on an arbitrary thread.
    var onHapticEvents: (@Sendable ([NvstHapticEvent]) -> Void)?
    /// The seat's `0x010e` HDR mode notification. Called on an arbitrary thread.
    var onHdrModeChanged: (@Sendable (NvstHdrModeNotification) -> Void)?
    /// Fires once, when the input activation chain has been sent and gamepad state is accepted.
    var onInputReady: (@Sendable () -> Void)?

    /// The sink runs on the decode queue and the handlers on arbitrary threads; set the handlers
    /// before `connect`.
    init(peerConnectionFactory: LKRTCPeerConnectionFactory,
         pixelBufferSink: PixelBufferSink? = nil,
         logger: (@Sendable (String) -> Void)? = nil,
         controlTimeout: Duration = .seconds(20))
    {
        self.peerConnectionFactory = peerConnectionFactory
        self.pixelBufferSink = pixelBufferSink
        self.logger = logger
        self.controlTimeout = controlTimeout
        gamepadInput = NvstGamepadInput(clock: clock)
        let stream = AsyncStream<NativeNVSTTransportTermination>.makeStream()
        terminationStream = stream.stream
        terminationContinuation = stream.continuation
    }

    /// Runs `action` only when `generation` is still the live bundle's. The check and the work run
    /// in one actor hop, so a teardown cannot slip between them.
    func withCurrentBundleGeneration(_ generation: UInt64,
                                     _ action: @Sendable (isolated NvstBifrostFreeTransport) -> Void)
    {
        guard bundleGeneration == generation else { return }
        action(self)
    }

    /// The frame interval the pacer is told to aim for: the **session's** frame rate, not the
    /// client display's.
    var sessionFrameTimeMicroseconds: UInt32 {
        NvstBifrostFreeProfile.sessionFrameTimeMicroseconds(fps: negotiatedFps)
    }

    func setHapticEventHandler(_ handler: (@Sendable ([NvstHapticEvent]) -> Void)?) {
        onHapticEvents = handler
    }

    func setHdrModeHandler(_ handler: (@Sendable (NvstHdrModeNotification) -> Void)?) {
        onHdrModeChanged = handler
    }

    func setInputReadyHandler(_ handler: (@Sendable () -> Void)?) {
        onInputReady = handler
    }

    // MARK: - Lifecycle

    /// Negotiates RTSPS, brings up the bundle and arms the video receiver. Returns once PLAY has
    /// been answered; ICE, DTLS, the data channels, input activation and the first frame all
    /// follow asynchronously.
    ///
    /// Throws `NativeNVSTError`, or `CancellationError` when a `disconnect()` or a task
    /// cancellation overtook the negotiation. Everything is torn down before it throws.
    func connect(request: GFNNVSTConnectRequest) async throws {
        guard phase == .idle else { throw NativeNVSTError.alreadyRunning }
        phase = .connecting
        self.request = request

        let endpoints = NvstBifrostFreeProfile.rtspsEndpoints(for: request)
        guard !endpoints.isEmpty else {
            await teardown(reason: "no control endpoint")
            throw NativeNVSTError.missingControlEndpoint(request.isResume
                ? "This session has not published an RTSPS control endpoint, so the seat has not finished handing it over to this device."
                : "This session provided no RTSPS control endpoint, so NVST cannot be negotiated.")
        }
        let profile = NvstBifrostFreeProfile.streamProfile(for: request)
        negotiatedFps = profile.fps
        negotiatedResolution = profile.resolution
        negotiatedCodec = profile.codec
        // Says exactly what will be asked for and paced to, so a "stuck at 60" report separates
        // "we asked for 60" from "the seat dropped it".
        logger?("NVST profile fps=\(profile.fps.map(String.init) ?? "nil") resolution=\(profile.resolution ?? "nil")"
            + " codec=\(profile.codec ?? "nil") pacingTargetUs=\(sessionFrameTimeMicroseconds) maxKbps=\(profile.maximumBitrateKbps.map(String.init) ?? "nil")"
            + " initKbps=\(profile.bitrateKbps.map(String.init) ?? "nil") bitDepth=\(request.bitDepth) chroma444=\(request.chroma444) hdr=\(request.hdrEnabled)")

        let reserver = NvstLocalBundleReserver(bundleProvider: { [weak self] handoff, _ in
            await self?.bringUpBundle(handoff: handoff)
        })
        self.reserver = reserver
        let negotiator = NvstRtspNegotiator(reserver: reserver, logger: logger)
        let input = NvstBifrostFreeProfile.negotiationInput(for: request, endpoints: endpoints, timeout: controlTimeout)

        let negotiated: NvstRtspSession
        do {
            negotiated = try await negotiator.negotiate(
                input,
                onVideoReady: { [weak self] handoff in
                    try await self?.startVideo(handoff: handoff)
                },
                onAnnounceReady: { [weak self] _ in
                    await self?.punchVideoSocketBeforePlay()
                }
            )
        } catch {
            let wasSuperseded = phase != .connecting || Task.isCancelled
            let bundleFailure = bundleFailure
            await teardown(reason: "negotiation failed")
            if wasSuperseded {
                throw CancellationError()
            }
            if let bundleFailure {
                throw NativeNVSTError.bundleFailed(bundleFailure)
            }
            throw NativeNVSTError.transportFailed(error.localizedDescription)
        }
        guard phase == .connecting, !Task.isCancelled else {
            // A disconnect ran while the negotiation was suspended. It could not release a
            // session that did not exist yet, so this does.
            await Self.release(negotiated, reason: "superseded")
            await teardown(reason: "superseded")
            throw CancellationError()
        }
        session = negotiated
        logger?("NVST Bifrost-free session established (steps: \(negotiated.steps.joined(separator: " → ")))")

        // The seat gates media on the bundle's DTLS handshake, and audio and input have no other
        // carrier, so a session without it is not worth keeping.
        if bundle == nil || bundleFailure != nil {
            let reason = bundleFailure ?? "The NVST bundle was never brought up."
            await teardown(reason: "bundle unavailable")
            throw NativeNVSTError.bundleFailed(reason)
        }
        if let playFailure = NvstBifrostFreeProfile.playFailure(inSteps: negotiated.steps) {
            await teardown(reason: "play failed")
            throw NativeNVSTError.transportFailed(playFailure)
        }
        phase = .connected
        startHeartbeat()
    }

    /// Idempotent. Stops every timer, closes the video socket, the bundle's peer connection and
    /// the RTSPS connection (with a TEARDOWN), and finishes `terminalEvents()`.
    func disconnect() async {
        await teardown(reason: "disconnect")
    }

    /// The seat's verdict or the transport's own failure, at most one per connection. Finishes
    /// when the transport is torn down.
    nonisolated func terminalEvents() -> AsyncStream<NativeNVSTTransportTermination> {
        terminationStream
    }

    /// Arms the stall and control-connection watchdog. Called once the first frame has been
    /// shown: before that, "no frame yet" is the first-frame wait's business.
    func armWatchdog() {
        guard phase == .connected else { return }
        isWatchdogArmed = true
    }

    // MARK: - Housekeeping

    /// One tick a second: keeps the SCTP receiver reports fed, refreshes the round-trip samples,
    /// runs the watchdog, and logs a compact counters line every few ticks.
    private func startHeartbeat() {
        guard phase == .connected else { return }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(NvstBifrostFreeWatchdog.tickSeconds))
                guard let self, !Task.isCancelled else { return }
                tick += 1
                await housekeepingTick(tick)
            }
        }
    }

    private func housekeepingTick(_ tick: Int) async {
        guard phase == .connected, let receiver else { return }
        let stats = receiver.stats
        // The feedback sender emits nothing while its media SSRC is zero, and the SSRC is only
        // known once the first video packet has arrived — after the feedback channel opened. This
        // push is what starts the receiver reports on `rtcp_on_sctp_private`.
        if let sender = feedbackSender, let ssrc = stats.boundSSRC {
            sender.updateMediaSSRC(ssrc)
            sender.updateMediaState(highestExtendedSequence: stats.highestSequence,
                                    cumulativeLost: stats.lastCumulativeLost,
                                    fractionLost: stats.lastFractionLost,
                                    interarrivalJitter: stats.lastJitter)
        }
        bundle?.refreshTransportStatistics()

        var keepAliveSummary = ""
        if let session {
            // The control connection's turnaround is the only round trip the seat reliably
            // answers; the receiver times its retransmission waits against it.
            let controlRoundTrip = await session.controlRoundTripMilliseconds()
            keepAliveSummary = await session.controlKeepAliveSummary()
            guard phase == .connected else { return }
            receiver.useRetransmissionRoundTrip(milliseconds: controlRoundTrip)
        }
        runWatchdog(keepAliveSummary: keepAliveSummary)
        if tick % Self.counterLogIntervalTicks == 0 {
            logCounters(receiver: receiver, stats: stats, keepAliveSummary: keepAliveSummary)
        }
    }

    static let counterLogIntervalTicks = 5

    private func runWatchdog(keepAliveSummary: String) {
        guard isWatchdogArmed, phase == .connected else { return }
        if NvstBifrostFreeWatchdog.isStalled(secondsSinceLastFrame: frameMonitor.secondsSinceLastFrame()) {
            reportTransportFailure(
                "No video frame was decoded for \(Int(NvstBifrostFreeWatchdog.stallTimeoutSeconds)) seconds.",
                origin: .video,
                recovery: .transientNetwork
            )
            return
        }
        guard let status = NvstBifrostFreeWatchdog.keepAliveStatus(fromSummary: keepAliveSummary) else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        if let failure = keepAliveTracker.failure(for: status, uptimeSeconds: now) {
            reportTransportFailure(failure, origin: .control, recovery: .transientNetwork)
        }
    }

    /// Separates "no packets arrive" from "packets do not authenticate" from "frames assemble but
    /// do not decode" while a session is live, without the per-second series of the source's
    /// post-mortem dump.
    private func logCounters(receiver: NvstMjolnirReceiver, stats: NvstReceiverStats, keepAliveSummary: String) {
        guard let logger else { return }
        let video = videoPipeline?.snapshot ?? NvstVideoPipeline.Counters()
        logger("NVST counters auth=\(stats.authenticatedPackets) fec=\(stats.fecPackets) dropped=\(stats.droppedPackets) rtpLoss=\(stats.finalizedLossPackets)"
            + " fecRecovered=\(stats.recoveredPackets) rtxRepaired=\(stats.retransmissionRepairedPackets) frames=\(stats.framesEmitted) keyframes=\(stats.keyframesEmitted)"
            + " recoveries=\(stats.recoveries) abandoned=\(stats.abandonedFrames) decoded=\(decoder?.decodedFrameCount ?? 0) decodeFailed=\(decoder?.failedFrameCount ?? 0)"
            + " decodeErr=\(decoder?.failureStatusSummary ?? "-") noParamSets=\(video.missingParameterSetFrames) skipped=\(video.framesSkippedForLatency)"
            + " idrOut=\(idrRequestsSent) invalidOut=\(invalidationsSent) ackOut=\(video.frameAcksSent) ackFail=\(video.frameAckFailures)"
            + " paceOut=\(video.pacingReportsSent) qosOut=\(qosReportsSent) qosFail=\(qosReportFailures) rtpStatsOut=\(rtpStatsReportsSent)"
            + " ccStatsOut=\(controlStatsReportsSent) rrOut=\(stats.receiverReportsSent) sctpRrOut=\(feedbackSender?.sentReportCount ?? 0)"
            + " frac=\(stats.lastFractionLost) lost=\(stats.lastCumulativeLost) jitter=\(stats.lastJitter)"
            + " ssrc=\(stats.boundSSRC.map { String(format: "0x%08x", $0) } ?? "-") hwDecode=\(decoder?.isHardwareAccelerated == true)"
            + " res=\(decoder?.decodedResolution ?? "-") bitstream=\(decoder?.bitstreamFormat?.summary ?? "-") output=\(decoder?.outputPixelFormatName ?? "-")")
        let input = gamepadInput.counters
        logger("NVST input ready=\(bundle?.isInputReady == true) activated=\(didActivateInput) riOut=\(inputEventsSent) padOut=\(input.sent) padFail=\(input.failed)"
            + " padRejected=\(input.rejected) padReg=\(input.registrations) haptics=\(hapticEventsReceived) audioTracks=\(remoteAudioTrackCount)")
        logger("NVST mjolnir \(receiver.inbound.summary) rcvbuf=\(receiver.receiveBufferBytes) \(receiver.fecFindings.summary)"
            + " nacks=\(receiver.nackSummary.requests)/\(receiver.nackSummary.packets)pkt rtt=\(String(format: "%.1f", receiver.roundTripMilliseconds))ms"
            + " bundleRtt=\(String(format: "%.1f", bundle?.roundTripMilliseconds ?? -1))ms ctrl[\(keepAliveSummary)]")
        if let bundle {
            logger("NVST bundle \(bundle.diagnosticSummary)")
        }
    }

    /// Stores the seat's statistics message and logs a calibration sample now and then.
    func recordSeatStats(_ stats: NvstSeatStats) {
        latestSeatStats = stats
        seatStatsReceived += 1
        if seatStatsReceived <= 3 || seatStatsReceived % 600 == 0 {
            logger?("NVST \(stats.summary) n=\(seatStatsReceived)")
        }
    }

    // MARK: - Terminal reports

    /// The transport cannot continue. Reported once; later verdicts are logged only.
    func reportTransportFailure(_ message: String,
                                origin: NativeNVSTTransportFailure.Origin,
                                recovery: NativeNVSTTransportFailure.RecoveryClassification)
    {
        guard phase == .connecting || phase == .connected else { return }
        logger?("NVST transport failure (\(origin)): \(message)")
        guard !didReportTermination else { return }
        didReportTermination = true
        terminationContinuation.yield(.transportFailed(NativeNVSTTransportFailure(
            message: message,
            origin: origin,
            recoveryClassification: recovery
        )))
    }

    /// The seat ended the session and said why. Reported as a session termination rather than a
    /// transport failure so the consumer does not try to reconnect to a seat that has already
    /// decided.
    func handleSeatTermination(_ termination: NvstSeatTermination) {
        guard phase == .connecting || phase == .connected, !didReportTermination else { return }
        didReportTermination = true
        terminationContinuation.yield(.sessionTerminated(termination.sessionTermination))
    }

    // MARK: - Teardown

    func teardown(reason: String) async {
        guard phase != .tornDown else { return }
        let wasStarted = phase != .idle
        phase = .tornDown
        // Invalidates every callback the closing bundle installed.
        bundleGeneration &+= 1
        isWatchdogArmed = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        invalidationFlushTask?.cancel()
        invalidationFlushTask = nil
        pendingInvalidationFirst = nil
        pendingInvalidationLast = nil
        controlKeepAliveTask?.cancel()
        controlKeepAliveTask = nil
        qosFeedbackTask?.cancel()
        qosFeedbackTask = nil
        gamepadInput.deactivate()
        if wasStarted {
            logger?("NVST transport tearing down (\(reason))")
        }
        if let receiver {
            logCounters(receiver: receiver, stats: receiver.stats, keepAliveSummary: "")
        }
        feedbackSender?.stop()
        feedbackSender = nil
        // The media receiver and pipeline stop before the bundle closes, so in-flight frame acks
        // and feedback packets do not fail-and-log against a closing control channel.
        receiver?.stop()
        receiver = nil
        // Stops before the decoder is invalidated: an in-flight access unit must not reach a
        // torn-down session.
        videoPipeline?.stop()
        videoPipeline = nil
        bundle?.close()
        bundle = nil
        decoder?.invalidate()
        decoder = nil
        let session = session
        self.session = nil
        let reserver = reserver
        self.reserver = nil
        terminationContinuation.finish()
        if let session {
            await Self.release(session, reason: reason)
        }
        reserver?.release()
    }

    /// How long teardown waits for the RTSPS TEARDOWN to be answered before moving on.
    static let controlReleaseGrace: Duration = .seconds(2)

    /// Stops the keepalive, sends TEARDOWN and closes the control connection, waiting at most
    /// `controlReleaseGrace`. A seat that has gone quiet would otherwise hold the caller for the
    /// whole request timeout; the release itself still runs to completion in the background.
    private static func release(_ session: NvstRtspSession, reason: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = NvstOneShot(continuation)
            Task {
                await session.release(reason)
                once.resume(())
            }
            Task {
                try? await Task.sleep(for: controlReleaseGrace)
                once.resume(())
            }
        }
    }
}
