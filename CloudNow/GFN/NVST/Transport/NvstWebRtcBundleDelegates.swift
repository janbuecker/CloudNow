import Dispatch
import Foundation
@preconcurrency import LiveKitWebRTC

// libwebrtc's peer-connection and data-channel callbacks, and what the bundle does with the seat's
// messages on them.

nonisolated extension NvstWebRtcBundle {
    // MARK: - LKRTCPeerConnectionDelegate

    func peerConnection(_: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let line = candidate.sdp
        guard Self.isUdpHostCandidate(line) else { return }
        lock.withLock { hostCandidates.append(line) }
    }

    func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        let name = Self.name(of: newState)
        lock.lock()
        iceStateDescription = name
        lock.unlock()
        logger?("NVST bundle ICE state \(name)")
        // `.disconnected` is transient by definition and cannot normally occur here at all: the
        // liveness policy that produces it is disabled in `bundleConfiguration()`.
        switch newState {
        case .failed:
            reportConnectionFailure("The NVST bundle's ICE connection failed.")
        case .closed:
            reportConnectionFailure("The NVST bundle's ICE connection closed.")
        default:
            break
        }
    }

    /// The aggregate of ICE and DTLS: this is the only callback that reports a failed DTLS
    /// handshake, which leaves ICE itself looking healthy.
    func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        logger?("NVST bundle connection state \(newState.rawValue)")
        switch newState {
        case .failed:
            reportConnectionFailure("The NVST bundle's ICE/DTLS connection failed.")
        case .closed:
            reportConnectionFailure("The NVST bundle's ICE/DTLS connection closed.")
        default:
            break
        }
    }

    func peerConnection(_: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        // The official client opens every channel itself, so nothing is expected here; a channel
        // the seat opens is adopted by label like the ones this client created.
        dataChannel.delegate = self
        logger?("NVST bundle inbound data channel '\(dataChannel.label)'")
        adopt(dataChannel)
    }

    func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}

    func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}

    func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}

    /// The seat's audio arrives as an SRTP stream muxed on the bundle port — the native stack's
    /// own socket tap shows ~200 packets a second there against a single `SETUP streamid=video/0/0`,
    /// so audio is negotiated by the bundle's SDP rather than by its own RTSP stream. The track is
    /// enabled as created and plays through the factory's audio device; nothing else is needed.
    func peerConnection(_: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams _: [LKRTCMediaStream]) {
        let kind = rtpReceiver.track?.kind ?? "nil"
        logger?("NVST bundle remote receiver kind=\(kind)")
        guard kind == "audio" else { return }
        // Under the lock: this runs on libwebrtc's delegate thread while the transport reads the
        // count from its own actor.
        let count: Int = lock.withLock {
            trackedRemoteAudioCount += 1
            return trackedRemoteAudioCount
        }
        onRemoteAudio?(count)
    }

    func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}

    func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        guard newState == .complete else { return }
        lock.withLock { gatheringComplete = true }
        finishHostCandidateWait()
    }

    func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}

    static func name(of state: LKRTCIceConnectionState) -> String {
        switch state {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        case .count: "count"
        @unknown default: "unknown(\(state.rawValue))"
        }
    }

    /// Reports the loss of the association once, and never for a close this client asked for.
    func reportConnectionFailure(_ message: String) {
        let shouldReport: Bool = lock.withLock {
            guard !isClosed, !didReportConnectionFailure else { return false }
            didReportConnectionFailure = true
            return true
        }
        guard shouldReport else { return }
        logger?("NVST bundle lost: \(message)")
        onConnectionFailure?(message)
    }

    // MARK: - LKRTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        let state = dataChannel.readyState
        logger?("NVST bundle channel '\(dataChannel.label)' id=\(dataChannel.channelId) state=\(state.rawValue)")
        adopt(dataChannel)
        // The seat answers a channel set it dislikes by resetting every stream and closing DTLS;
        // the control channel closing under us is how that — and any later loss of the
        // association — shows up first.
        guard state == .closed else { return }
        let wasControl: Bool = lock.withLock { openControlChannel === dataChannel }
        if wasControl {
            reportConnectionFailure("The seat closed the NVST control channel.")
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        let data = buffer.data
        let shouldLog: Bool = lock.withLock {
            inboundFeedbackBytes += data.count
            inboundMessagesByLabel[dataChannel.label, default: 0] += 1
            guard loggedInboundMessages < Self.maxLoggedInboundMessages else { return false }
            loggedInboundMessages += 1
            return true
        }
        // The seat announces the remote-input protocol version once, and input stays gated until
        // it arrives. Checked for every message, outside the logging budget below: a version that
        // arrived after the budget was spent would otherwise leave input dead for the session.
        noteInputProtocolVersion(in: data, label: dataChannel.label)
        // Seat statistics, rumble and the termination notice keep arriving for the whole session,
        // long past the logging budget, so they are parsed before the log gate as well.
        let (commands, trailing) = NvstControlCommand.parse(data)
        for command in commands {
            dispatchInboundCommand(command)
        }

        guard shouldLog else { return }
        logInboundMessage(data, commands: commands, trailing: trailing, label: dataChannel.label)
    }

    /// Records the seat's remote-input protocol version the first time it is seen.
    private func noteInputProtocolVersion(in data: Data, label: String) {
        guard let version = NvstRemoteInput.protocolVersion(in: data) else { return }
        let isNew: Bool = lock.withLock {
            guard negotiatedInputProtocolVersion == nil, !isClosed else { return false }
            negotiatedInputProtocolVersion = version
            return true
        }
        guard isNew else { return }
        logger?("NVST bundle input protocol version \(version) from '\(label)'")
        onInputProtocolNegotiated?(version)
    }

    /// One parsed control command, routed to whoever owns it.
    private func dispatchInboundCommand(_ command: NvstControlCommand) {
        // Ahead of everything else: a session has to hear the seat ending it, and this is the
        // only channel that says so.
        if let termination = NvstSeatTermination.parse(command) {
            logger?("NVST bundle seat terminated the session: \(termination.summary)")
            onSeatTermination?(termination)
            return
        }
        if let stats = NvstSeatStats.from(command) {
            onSeatStats?(stats)
            return
        }
        if let haptics = NvstHapticEvent.parse(command) {
            describeHapticCommand(command, events: haptics)
            if !haptics.isEmpty {
                onHapticEvents?(haptics)
            }
            return
        }
        if let hdrMode = NvstHdrModeNotification.parse(command) {
            logger?("NVST hdr-mode notification \(hdrMode.summary) payload=\(command.payload.prefix(16).map { String(format: "%02x", $0) }.joined())")
            onHdrMode?(hdrMode)
        }
    }

    /// What an inbound control message logs, once it is inside the logging budget.
    private func logInboundMessage(_ data: Data, commands: [NvstControlCommand], trailing: Data, label: String) {
        // NVST command packets start with a 16-bit code, so the leading bytes identify the command.
        let decoded = commands.map(\.summary).joined(separator: " | ")
        for command in commands where command.isTextual {
            logger?("NVST bundle inbound text \(String(format: "0x%04x", command.code.rawValue)): \(command.text(limit: 600))")
        }
        let hex = [UInt8](data.prefix(32)).map { String(format: "%02x", $0) }.joined()
        var line = "NVST bundle inbound '\(label)' bytes=\(data.count) cmds=[\(decoded)]"
        if !trailing.isEmpty {
            line += " unparsed=\(trailing.count)"
        }
        line += " hex=\(hex)"
        logger?(line)
    }

    /// Enough to characterise the control conversation without flooding the log.
    static let maxLoggedInboundMessages = 40

    /// Rumble arrives at frame rate while a game vibrates the pad, so only *changes* of motor state
    /// are logged — a held rumble refreshed every 50 ms is one line — and those stop after a
    /// budget.
    static let maxLoggedHapticChanges = 100

    func describeHapticCommand(_ command: NvstControlCommand, events: [NvstHapticEvent]) {
        let signature = events.map { "\($0.gamepadIndex):\($0.leftMotor):\($0.rightMotor)" }.joined(separator: ",")
        let (shouldLog, ordinal): (Bool, Int) = lock.withLock {
            hapticCommandCount += 1
            hapticEventCount += events.count
            let changed = signature != lastHapticSignature
            if changed {
                lastHapticSignature = signature; hapticChangeCount += 1
            }
            return (changed && hapticChangeCount <= Self.maxLoggedHapticChanges, hapticCommandCount)
        }
        guard shouldLog else { return }
        let records = events.isEmpty ? "unparsed" : events.map(\.summary).joined(separator: " | ")
        logger?("NVST haptic #\(ordinal) len=\(command.payload.count) \(records)")
    }

    /// Haptic commands seen this session, for the diagnostics summary.
    var hapticCounters: (commands: Int, events: Int) {
        lock.withLock { (hapticCommandCount, hapticEventCount) }
    }

    // MARK: - Channel adoption

    /// Files an open channel under the role its label names. Called for every state change, so
    /// each branch adopts at most once.
    func adopt(_ dataChannel: LKRTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        let label = dataChannel.label
        if label == Self.controlChannelLabel {
            adoptControl(dataChannel)
        } else if label == Self.inputChannelLabel {
            adoptInput(dataChannel)
        } else if label == Self.partiallyReliableControlChannelLabel {
            adoptPartiallyReliableControl(dataChannel)
        } else if label.lowercased().contains("rtcp") {
            // Matched on "rtcp" rather than the exact label, as the source does.
            adoptFeedback(dataChannel)
        }
    }

    private func adoptFeedback(_ dataChannel: LKRTCDataChannel) {
        let isNew: Bool = lock.withLock {
            guard openFeedbackChannel == nil, !isClosed else { return false }
            openFeedbackChannel = dataChannel
            return true
        }
        guard isNew else { return }
        logger?("NVST bundle feedback channel open")
        onFeedbackChannelOpen?()
    }

    private func adoptPartiallyReliableControl(_ dataChannel: LKRTCDataChannel) {
        let isNew: Bool = lock.withLock {
            guard openPartiallyReliableControlChannel == nil, !isClosed else { return false }
            openPartiallyReliableControlChannel = dataChannel
            return true
        }
        guard isNew else { return }
        logger?("NVST bundle partially-reliable control channel open")
        onPartiallyReliableControlOpen?()
    }

    /// The input plane. Partially reliable, because a stale gamepad state is worse than a lost one.
    private func adoptInput(_ dataChannel: LKRTCDataChannel) {
        let isNew: Bool = lock.withLock {
            guard openInputChannel == nil, !isClosed else { return false }
            openInputChannel = dataChannel
            return true
        }
        guard isNew else { return }
        logger?("NVST bundle input channel open")
    }

    /// `control_channel_reliable` is where the seat's client-timeout is measured, so its opening is
    /// what starts the keepalive.
    private func adoptControl(_ dataChannel: LKRTCDataChannel) {
        let isNew: Bool = lock.withLock {
            guard openControlChannel == nil, !isClosed else { return false }
            openControlChannel = dataChannel
            return true
        }
        guard isNew else { return }
        logger?("NVST bundle control channel open")
        onControlChannelOpen?()
    }

    // MARK: - Audio reception

    /// Inbound audio counters straight from libwebrtc, which is the only view of whether the seat
    /// is sending audio at all: the track object exists as soon as the SDP negotiates it, so its
    /// presence proves nothing on its own.
    ///
    /// Receiving a packet and decoding it are different things: a payload the decoder rejects still
    /// counts as received, so the sample and concealment counters are what say audio is actually
    /// being produced.
    struct AudioReception: Equatable, Sendable {
        var packets: UInt64 = 0
        /// The remote SSRC libwebrtc bound the audio receiver to, once a packet arrived.
        var ssrc: UInt32?
        var bytes: UInt64 = 0
        var samples: UInt64 = 0
        var concealed: UInt64 = 0
        var discarded: UInt64 = 0
        /// libwebrtc's cumulative `jitterBufferDelay` (seconds) and `jitterBufferEmittedCount`;
        /// the ratio of their deltas is the mean time audio sat in the jitter buffer.
        var jitterBufferDelaySeconds: Double = 0
        var jitterBufferEmitted: UInt64 = 0

        /// Folds one `inbound-rtp` audio entry's values into the totals.
        mutating func add(inboundAudio values: [String: NSObject]) {
            func number(_ key: String) -> UInt64 {
                (values[key] as? NSNumber)?.uint64Value ?? 0
            }
            packets += number("packetsReceived")
            bytes += number("bytesReceived")
            samples += number("totalSamplesReceived")
            concealed += number("concealedSamples")
            discarded += number("packetsDiscarded")
            jitterBufferDelaySeconds += (values["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0
            jitterBufferEmitted += number("jitterBufferEmittedCount")
            if let ssrc = values["ssrc"] as? NSNumber {
                self.ssrc = ssrc.uint32Value
            }
        }
    }

    /// Longest `audioReception()` waits for libwebrtc to answer a statistics request.
    static let statisticsTimeoutSeconds = 1.0

    func audioReception() async -> AudioReception? {
        // `close()` nils the connection and latches `isClosed`, so a closed bundle is never asked.
        let connection: LKRTCPeerConnection? = lock.withLock { isClosed ? nil : peerConnection }
        guard let connection else { return nil }
        // `statistics` answers through a callback, and a continuation that is never resumed hangs
        // its caller for good — a connection closing underneath the request must not do that, so
        // the wait is bounded.
        return await withCheckedContinuation { (continuation: CheckedContinuation<AudioReception?, Never>) in
            let once = NvstOneShot(continuation)
            connection.statistics { report in
                once.resume(Self.audioReception(in: report))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.statisticsTimeoutSeconds) {
                once.resume(nil)
            }
        }
    }

    /// The totals of every `inbound-rtp` audio entry in `report`, or nil when there is none.
    static func audioReception(in report: LKRTCStatisticsReport) -> AudioReception? {
        var reception = AudioReception()
        var sawAudio = false
        for statistics in report.statistics.values
            where statistics.type == "inbound-rtp" && (statistics.values["kind"] as? String) == "audio"
        {
            sawAudio = true
            reception.add(inboundAudio: statistics.values)
        }
        return sawAudio ? reception : nil
    }
}
