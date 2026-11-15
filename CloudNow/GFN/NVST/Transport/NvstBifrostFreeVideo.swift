import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC

// Bringing the video plane up: the Mjolnir receiver, the ICE/DTLS bundle, the decoder and the
// feedback the seat's rate controller runs on.

extension NvstBifrostFreeTransport {
    // MARK: - Video

    func startVideo(handoff: NVSTVideoHandoff) async throws {
        guard phase == .connecting else { throw CancellationError() }
        // The negotiator walks the advertised endpoints until one answers, so a later endpoint can
        // reach this point after an earlier one already armed a receiver.
        receiver?.stop()
        videoPipeline?.stop()
        decoder?.invalidate()

        let videoLogger = logger
        let decoder = NvstVideoToolboxDecoder(codec: handoff.codec)
        decoder.onDecodeFailure = { [weak self] frameIndex, message in
            videoLogger?("NVST \(message)")
            // Frame index 0 is the decoder's informational channel, not a failure.
            guard frameIndex != 0 else { return }
            // Naming the unusable frame is the recovery the seat is configured for; a bare IDR
            // request has not produced a keyframe in any run.
            Task { await self?.invalidateFrame(frameIndex) }
        }
        let sink = pixelBufferSink
        let frameMonitor = frameMonitor
        decoder.onPixelBuffer = { pixelBuffer, presentationTime, isKeyframe in
            frameMonitor.noteFrame()
            sink?(pixelBuffer, presentationTime, isKeyframe)
        }
        self.decoder = decoder
        lastHandoff = handoff

        // The negotiation already bound this socket; adopt the descriptor rather than rebinding
        // the port, which would lose the seat's NAT mapping.
        let descriptor = reserver?.takeMjolnirDescriptor() ?? -1
        let receiver = try NvstMjolnirReceiver(
            handoff: handoff,
            // SRTCP on this socket is the fallback plane; when the SCTP channel opens the seat gets
            // plain RTCP there as well. Both are harmless, and only one will be believed.
            sendsReceiverReports: true,
            existingDescriptor: descriptor
        )
        let pipeline = makeVideoPipeline(decoder: decoder, receiver: receiver)
        videoPipeline = pipeline
        receiver.onAccessUnit = { [weak pipeline] unit in pipeline?.submit(unit) }
        // Gaps are first repaired by asking the seat to retransmit (`0x0317` on the partially
        // reliable control channel); the receiver falls back to SRTCP NACK when this declines,
        // and stops waiting for repairs altogether if the seat ignores the requests.
        receiver.onRetransmissionWanted = { [weak pipeline] sequenceNumbers in
            pipeline?.requestRetransmission(of: sequenceNumbers) ?? false
        }
        receiver.onRecoveryNeeded = { [weak self, weak receiver] brokenFrameIndex in
            // Reached only for gaps too wide to repair by retransmission. A broken reference
            // chain then only recovers with a fresh keyframe.
            receiver?.requestKeyframe()
            // A PLI alone has not been seen to reach the encoder; the control channel's IDR
            // request is the path that does.
            Task { await self?.recoverBrokenReferenceChain(frameIndex: brokenFrameIndex) }
        }
        receiver.onDiagnostic = { message in videoLogger?("NVST \(message)") }
        // FEC-repair and control packets legitimately carry no picture; do not log each one (it
        // floods the log). Real losses show up in the periodic counters line instead.
        receiver.onDrop = { _ in }
        try receiver.start()
        self.receiver = receiver
        logger?("NVST Mjolnir receiver armed on port \(handoff.mjolnirUDPPort ?? handoff.clientUDPPort) for peer \(handoff.videoPeerIP):\(handoff.videoPeerPort)")
    }

    /// Builds the decode pipeline. Decode runs off this actor: sharing the actor with QoS,
    /// keepalives and input made every frame queue behind whatever else was pending, and the wait
    /// compounded across a burst — see `NvstVideoPipeline` for the measurements.
    /// `receiver` is passed in rather than read off `self`: this runs before `self.receiver` is
    /// assigned, and a capture list evaluates eagerly, so capturing the property would bind a
    /// permanently nil weak reference and silence every keyframe request the pipeline makes.
    private func makeVideoPipeline(decoder: NvstVideoToolboxDecoder,
                                   receiver: NvstMjolnirReceiver) -> NvstVideoPipeline
    {
        // The seat paces its own frame generation to whatever vsync interval the client reports,
        // so the interval has to describe the real display.
        let displayVsyncMicroseconds = NvstBifrostFreeProfile.displayVsyncMicroseconds(
            maxRefreshRate: request?.displayMaxRefreshRate ?? 0
        )
        return NvstVideoPipeline(
            decoder: decoder,
            clock: clock,
            frameTimeMicroseconds: sessionFrameTimeMicroseconds,
            displayVsyncMicroseconds: displayVsyncMicroseconds,
            // The announce keeps the captured Adaptive baseline, and the pipeline's `0x203`
            // pacing reports are the client half of that same pacer.
            vsyncMode: .adaptive,
            logger: logger,
            mediaSink: nil,
            onKeyframeNeeded: { [weak self, weak receiver] in
                receiver?.requestKeyframe()
                Task { await self?.requestKeyframeOverControlChannel() }
            },
            onFatalDecodeError: { [weak self] message in
                Task { await self?.reportFatalDecodeError(message) }
            }
        )
    }

    // MARK: - Bundle

    /// Brings up the ICE/DTLS/SCTP bundle. The seat arms its video relay only after this DTLS
    /// handshake completes, so this is what turns the Mjolnir socket from silent to streaming.
    ///
    /// Returns nil on failure, having recorded why in `bundleFailure`: the negotiator has no way
    /// to be stopped from here, so `connect` checks once it returns and fails the connection.
    func bringUpBundle(handoff: NVSTVideoHandoff) async -> NvstBundleReservation? {
        guard phase == .connecting else { return nil }
        let logger = logger
        // A later endpoint replaces whatever an earlier attempt left behind.
        self.bundle?.close()
        self.bundle = nil
        feedbackSender?.stop()
        feedbackSender = nil
        bundleFailure = nil

        let bundle = NvstWebRtcBundle(handoff: handoff, factory: peerConnectionFactory, logger: logger)
        let sender = NvstFeedbackSender()
        sender.configure(
            channelWriter: { [weak bundle] payload in _ = bundle?.sendFeedback(payload) },
            // "ONOW" — a stable sender SSRC, as the official client uses a fixed one.
            senderSSRC: Self.feedbackSenderSSRC,
            mediaSSRC: 0
        )
        // RR values straight from the receiver on each emit, so the seat's congestion controller
        // sees real loss and jitter rather than a snapshot that only refreshes on the tick.
        sender.setReportProvider { [weak receiver] in receiver?.receiverReportBlock() }
        // Installed before `prepare()`: libwebrtc's threads are live from the moment the peer
        // connection exists, and the callbacks are plain stored properties.
        installBundleHandlers(bundle, sender: sender, logger: logger)
        let generation = bundleGeneration
        // Stored before `prepare()` as well, so a callback that somehow fired early would find the
        // bundle it belongs to rather than nothing.
        self.bundle = bundle
        feedbackSender = sender
        do {
            let identity = try await bundle.prepare()
            // A disconnect, or a newer bring-up, may have run while `prepare` was suspended.
            guard phase == .connecting, bundleGeneration == generation else {
                discardBundle(bundle, sender: sender)
                return nil
            }
            guard identity.usesOfficialIceCredentials else {
                // ANNOUNCE carries the 4/22 pair either way, so the seat's STUN usernames would
                // not match what libwebrtc actually uses.
                throw NvstWebRtcBundle.BundleError.localDescriptionFailed(
                    "libwebrtc refused the 4/22-character ICE credentials the seat requires"
                )
            }
            scheduleVideoHolePunch()
            clock.start()
            // The video receiver was armed at SETUP, before this channel existed; hand it over now
            // so frame acks can go out.
            videoPipeline?.attach(bundle: bundle)
            return NvstBundleReservation(
                bundlePort: identity.bundlePort,
                mjolnirPort: handoff.mjolnirUDPPort ?? handoff.clientUDPPort,
                localAddress: identity.localAddress,
                iceCredentials: handoff.iceCredentials.map {
                    NvstRtspIceCredentials(usernameFragment: $0.localUsernameFragment, password: $0.localPassword)
                },
                dtlsFingerprint: identity.dtlsFingerprint
            )
        } catch {
            logger?("NVST bundle bring-up failed: \(error.localizedDescription)")
            let isCurrent = phase == .connecting && bundleGeneration == generation
            discardBundle(bundle, sender: sender)
            if isCurrent {
                bundleFailure = error.localizedDescription
            }
            return nil
        }
    }

    /// Closes a bundle that did not make it, and forgets it if it is still the current one.
    private func discardBundle(_ bundle: NvstWebRtcBundle, sender: NvstFeedbackSender) {
        bundle.close()
        sender.stop()
        if self.bundle === bundle {
            self.bundle = nil
            videoPipeline?.attach(bundle: nil)
        }
        if feedbackSender === sender {
            feedbackSender = nil
        }
    }

    /// "ONOW".
    static let feedbackSenderSSRC: UInt32 = 0x4F4E_4F57

    /// The bundle lost its ICE/DTLS association, or the seat closed the control channel.
    func handleBundleConnectionFailure(_ message: String) {
        reportTransportFailure(message, origin: .bundle, recovery: .transientNetwork)
    }

    /// The video punch has to be in the seat's hands before PLAY, and the official client sends
    /// them in that order (punch, then PLAY 2 ms later). The seat binds the video destination while
    /// it services PLAY and gives late punches only a short grace: with a 5 ms RTT seat a
    /// bundle-gated punch landed ~70 ms after PLAY and was accepted; with 108 and 256 ms RTT seats
    /// it landed ~340 ms after PLAY and the seat streamed nothing for the whole session — control,
    /// audio and RTSPS all fine, the Mjolnir socket dead silent (2026-09-05). Punching here,
    /// straight after the ANNOUNCE answer, puts the first burst ahead of PLAY on every path.
    func punchVideoSocketBeforePlay() async {
        beginVideoHolePunch()
        // Two punches of the 27 ms burst are out before PLAY leaves; same path, so they arrive first.
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// Late fallback for paths that never reach the ANNOUNCE-ready hook; `beginHolePunch` is
    /// idempotent, so this is a no-op on the normal path.
    func scheduleVideoHolePunch() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.beginVideoHolePunch()
        }
    }

    func beginVideoHolePunch() {
        guard phase == .connecting || phase == .connected, let receiver else { return }
        receiver.beginHolePunch()
        logger?("NVST video socket hole punch started")
    }

    func noteRemoteAudio(trackCount: Int) {
        remoteAudioTrackCount = trackCount
    }

    // MARK: - Keepalive and feedback

    /// The seat measures a 10 s client timeout on `control_channel_reliable` and ends the session
    /// with `NVST_NETERR_CLIENT_TIMED_OUT` when nothing arrives. The official client answers with
    /// command `0x200` every 3 s; the first one goes out immediately, because the seat's timer is
    /// already running by the time the association is up.
    func startControlKeepAlive() {
        guard phase != .tornDown, controlKeepAliveTask == nil else { return }
        logger?("NVST control keepalive started (\(Int(NvstControlCommand.pingBackIntervalSeconds))s)")
        controlKeepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await sendControlKeepAlive()
                try? await Task.sleep(for: .seconds(NvstControlCommand.pingBackIntervalSeconds))
            }
        }
    }

    func sendControlKeepAlive() {
        guard phase != .tornDown, let bundle else { return }
        // The official payload is a per-stream 32-bit value, and zero is what the client sends
        // before a stream object exists; the frame index is the same shape once video flows.
        let value = receiver?.feedbackCounters.framesEmitted ?? 0
        let sent = bundle.sendControl(.pingBackAck(streamValue: UInt32(truncatingIfNeeded: value)))
        if !sent {
            logger?("NVST control keepalive write failed")
        }
    }

    /// The seat runs one-way-delay rate control (`bwe.useOwdCongestionControl:1`) and asks for
    /// feedback no less often than `vqos[0].bw.txRxLag.minFeedbackTxDeltaMs:200`. Without any QoS
    /// report its controller has no evidence the path is healthy and holds the encoder far below
    /// what the link carries: 53 packets per second measured against the official client's 401 on
    /// the same title. The captured client sends command `0x207` on
    /// `control_channel_partially_reliable` at about 18 Hz.
    func startQosFeedback() {
        guard phase != .tornDown, qosFeedbackTask == nil else { return }
        logger?("NVST QoS feedback started (\(String(format: "%.0f", 1 / NvstQosReport.interval))/s)")
        qosFeedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await sendQosReport()
                await sendRtpStatsIfNeeded()
                await sendControlChannelStatsIfNeeded()
                try? await Task.sleep(for: .seconds(NvstQosReport.interval))
            }
        }
    }

    func sendQosReport() {
        guard phase != .tornDown, let bundle, let receiver else { return }
        let counters = receiver.feedbackCounters
        let bytes = UInt32(truncatingIfNeeded: counters.bytesReceived)
        let now = Date()

        qosSequence &+= 1
        // Report a link capability at least as high as the configured ceiling so the seat's rate
        // controller ramps toward it.
        let capabilityKbps = NvstBifrostFreeProfile.linkCapabilityKbps(maximumBitrateKbps: request?.maxBitrateKbps ?? 0)
        // Interarrival jitter is measured on the seat's own 90 kHz media clock; the report wants
        // microseconds.
        let jitterMicroseconds = UInt32(clamping: Int(Double(receiver.stats.lastJitter) * 1_000_000
                / Double(NvstVideoToolboxDecoder.clockRate)))
        // How far the delay sample moved since the last report — the trend an OWD controller acts
        // on, and small by construction, which is the shape the capture shows at `+24`.
        let delayTrend = jitterMicroseconds >= lastQosDelayMicroseconds
            ? jitterMicroseconds - lastQosDelayMicroseconds
            : lastQosDelayMicroseconds - jitterMicroseconds
        lastQosDelayMicroseconds = jitterMicroseconds
        // Bits carried since the previous report, not a cumulative count.
        let deltaBytes = counters.bytesReceived >= lastQosBytesReceived
            ? counters.bytesReceived - lastQosBytesReceived
            : 0
        let previousBytes = UInt32(truncatingIfNeeded: lastQosBytesReceived)
        lastQosBytesReceived = counters.bytesReceived

        let report = NvstQosReport(
            sequence: qosSequence,
            framesReceived: UInt32(truncatingIfNeeded: counters.framesEmitted),
            bytesReceived: bytes,
            linkCapabilityKbps: capabilityKbps,
            rtpTimestamp: counters.lastRtpTimestamp,
            previousBytesReceived: previousBytes,
            delayMicroseconds: jitterMicroseconds,
            delayTrendMicroseconds: delayTrend,
            intervalBits: UInt32(clamping: deltaBytes * 8),
            isWarmedUp: sessionStartedAt.map { now.timeIntervalSince($0) >= NvstQosReport.warmUpSeconds } ?? false
        )

        if bundle.sendPartiallyReliableControl(report.command) {
            qosReportsSent += 1
        } else {
            qosReportFailures += 1
            if qosReportFailures == 1 {
                logger?("NVST QoS report write failed")
            }
        }
    }

    /// The client's RTP receive statistics (`0x208`) with its NACK statistics companion
    /// (`0x20a`), sent together every `NvstRtpStatsReport.frameInterval` emitted frames — the
    /// frame-gated cadence of the official `sendRtpStats` builder. The fields carry what this
    /// pipeline actually measures; the NACK report is all zeros, exactly the payload the official
    /// client sends before its receiver exists.
    func sendRtpStatsIfNeeded() {
        guard phase != .tornDown, let bundle, let receiver else { return }
        let frame = receiver.feedbackCounters.framesEmitted
        guard frame >= lastRtpStatsFrame + NvstRtpStatsReport.frameInterval else { return }
        let stats = receiver.stats
        lastRtpStatsFrame = frame
        let frameNumber = UInt32(truncatingIfNeeded: frame)
        let report = NvstRtpStatsReport(
            frameNumber: frameNumber,
            totalReceivedPackets: stats.authenticatedPackets,
            outOfOrderPackets: UInt32(clamping: stats.outOfOrderPackets),
            dropEvents: UInt32(clamping: stats.recoveries),
            latePackets: UInt32(clamping: stats.latePackets),
            droppedPackets: UInt32(clamping: stats.droppedPackets),
            recoveredPackets: UInt32(clamping: stats.recoveredPackets),
            maxDropBurstLength: stats.maxLossBurst,
            maxWaitingQueueDepth: stats.maxReorderDepth,
            duplicatePackets: UInt32(clamping: stats.duplicatePackets),
            // This client sends no microphone audio.
            micChatSentDataBytes: 0
        )
        let nackStats = NvstRtpNackStatsReport(frameNumber: frameNumber)
        if bundle.sendPartiallyReliableControl(report.command),
           bundle.sendPartiallyReliableControl(nackStats.command)
        {
            rtpStatsReportsSent += 1
        }
    }

    /// Control-channel statistics (`0x313`) on the interval our own announce declares, sent by
    /// stream 0 only — the official client transmits no control-channel stats from any other
    /// stream. The timestamp is session-elapsed microseconds, the closest honest analog to the
    /// official library's steady-clock-epoch microseconds.
    func sendControlChannelStatsIfNeeded() {
        guard phase != .tornDown, let bundle, sessionStartedAt != nil else { return }
        let now = Date()
        if let last = controlStatsLastSentAt,
           now.timeIntervalSince(last) < NvstControlChannelStatsReport.transmitInterval
        {
            return
        }
        let counters = bundle.controlChannelStats
        let report = NvstControlChannelStatsReport(
            timestampMicroseconds: sessionElapsedMicroseconds(),
            totalMessagesSent: counters.totalSent,
            totalMessagesFailed: counters.totalFailed,
            totalBytesSent: counters.totalBytes,
            commands: counters.commands
        )
        guard bundle.sendPartiallyReliableControl(report.command) else { return }
        controlStatsLastSentAt = now
        controlStatsReportsSent += 1
    }

    /// Once the feedback channel is live the receiver reports go out on SCTP as well; the media
    /// SSRC is pushed here when it is already bound, and by the housekeeping tick otherwise.
    func adoptFeedbackSender(_ sender: NvstFeedbackSender) {
        guard let receiver else { return }
        if let ssrc = receiver.feedbackCounters.boundSSRC {
            sender.updateMediaSSRC(ssrc)
        }
    }

    // MARK: - Seat notifications

    /// Rumble from the seat. Counted here; the routing to a physical pad is the consumer's business.
    func handleHapticEvents(_ events: [NvstHapticEvent]) {
        hapticEventsReceived &+= UInt64(events.count)
        onHapticEvents?(events)
    }

    func handleHdrMode(_ notification: NvstHdrModeNotification) {
        let previous = lastHdrMode
        lastHdrMode = notification
        guard previous != notification else { return }
        logger?(String(format: "NVST hdr mode %@ -> %@ at %.3fs", previous?.summary ?? "unknown", notification.summary,
                       Double(clock.elapsedMicroseconds()) / 1_000_000))
        onHdrModeChanged?(notification)
    }

    /// Microseconds since this session started, as the remote-input timestamps are expressed.
    func sessionElapsedMicroseconds() -> UInt64 {
        clock.elapsedMicroseconds()
    }

    // MARK: - Recovery

    /// A hole the receiver saw, or a finalized RTP loss. Invalidates the damaged frame at the seat
    /// when it is known — the encoder then references only frames this client has — and asks for
    /// a keyframe either way. Measured before this (2026-09-05, 4K): rtpLoss 3 became 22 rejected
    /// frames, because nothing told the seat until the decoder had rejected the next frame, and
    /// the follow-up invalidations for the rest of the chain were held for half a second.
    func recoverBrokenReferenceChain(frameIndex: UInt32?) {
        if let frameIndex {
            invalidateFrame(frameIndex)
        }
        requestKeyframeOverControlChannel()
    }

    /// Tells the seat which frame the decoder could not use, so its encoder stops referencing it.
    ///
    /// Coalesced, not throttled: a broken reference chain rejects every following frame, and one
    /// range covers a run of them, but the range has to reach the seat while the run is happening.
    /// The first frame of a run goes out at once; the rest are folded into one range that is
    /// flushed `invalidationCoalesceInterval` later.
    func invalidateFrame(_ frameIndex: UInt32) {
        guard phase != .tornDown else { return }
        let now = Date()
        if let last = lastInvalidationAt, now.timeIntervalSince(last) < Self.invalidationCoalesceInterval {
            pendingInvalidationFirst = min(pendingInvalidationFirst ?? frameIndex, frameIndex)
            pendingInvalidationLast = max(pendingInvalidationLast ?? frameIndex, frameIndex)
            scheduleInvalidationFlush(after: Self.invalidationCoalesceInterval - now.timeIntervalSince(last))
            return
        }
        sendInvalidation(first: frameIndex, last: frameIndex, at: now)
    }

    private func scheduleInvalidationFlush(after delay: TimeInterval) {
        guard invalidationFlushTask == nil else { return }
        invalidationFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(1, Int(delay * 1000))))
            guard !Task.isCancelled else { return }
            await self?.flushPendingInvalidation()
        }
    }

    private func flushPendingInvalidation() {
        invalidationFlushTask = nil
        guard let first = pendingInvalidationFirst, let last = pendingInvalidationLast else { return }
        sendInvalidation(first: first, last: last, at: Date())
    }

    private func sendInvalidation(first: UInt32, last: UInt32, at now: Date) {
        pendingInvalidationFirst = nil
        pendingInvalidationLast = nil
        lastInvalidationAt = now
        guard let bundle else { return }
        guard bundle.sendControl(.frameInvalidationRange(first: UInt64(first), last: UInt64(last))) else {
            logger?("NVST frame invalidation write failed")
            return
        }
        invalidationsSent += 1
    }

    /// How long follow-up invalidations are gathered into one range before it goes out — a few
    /// frames at 120 fps, well under the seat's reaction time to the first one.
    static let invalidationCoalesceInterval: TimeInterval = 0.04

    /// Asks the seat's encoder for a fresh keyframe, at most a few times a second: a decode failure
    /// can repeat for every frame in a broken reference chain, and one IDR fixes the whole run of
    /// them.
    func requestKeyframeOverControlChannel() {
        guard phase != .tornDown, let bundle else { return }
        let now = Date()
        if let last = lastIdrRequestAt, now.timeIntervalSince(last) < Self.idrRequestInterval {
            return
        }
        lastIdrRequestAt = now
        guard bundle.sendControl(.idrRequest()) else {
            logger?("NVST IDR request write failed")
            return
        }
        idrRequestsSent += 1
    }

    static let idrRequestInterval: TimeInterval = 0.5

    /// The decode pipeline gave up: 30 consecutive hard failures is a stream that will not
    /// recover on its own.
    func reportFatalDecodeError(_ message: String) {
        reportTransportFailure("Native NVST could not decode video: \(message)", origin: .video, recovery: .permanent)
    }
}
