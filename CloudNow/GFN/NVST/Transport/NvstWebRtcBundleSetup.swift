import Foundation
@preconcurrency import LiveKitWebRTC

// Bringing the ICE/DTLS/SCTP bundle up and tearing it down, plus the feedback, control and input
// channels it opens.

nonisolated extension NvstWebRtcBundle {
    // MARK: - Bring-up

    /// ICE liveness timeouts are pushed out to a day: see `bundleConfiguration()`.
    static let iceLivenessTimeoutMilliseconds = 24 * 60 * 60 * 1000

    /// The peer-connection configuration this bundle needs. Everything is known up front, so no
    /// STUN/TURN discovery: the only candidate that matters is the host one, and the peer is a
    /// literal address from SETUP.
    static func bundleConfiguration() -> LKRTCConfiguration {
        let configuration = LKRTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherOnce
        // The seat sends 5 ms Opus frames at ~200 packets a second — twice the rate NetEq's
        // defaults are tuned for, and its own jitter-buffer settings in the seat's SDP
        // (`audio.jbConfig.initialThreshold:80`, `maxThreshold:200`) are counted in packets on that
        // same 5 ms grid. A 50-packet default buffer is only 250 ms at this rate, so it is raised to
        // match what the seat expects to be buffered.
        configuration.audioJitterBufferMaxPackets = 200
        configuration.audioJitterBufferFastAccelerate = true
        // The seat is not an ICE agent: it is Bifrost's `NattHolePunch::HandleStun`, a minimal
        // responder that answers a bare 76-byte USERNAME/MESSAGE-INTEGRITY/FINGERPRINT request and
        // ignores libwebrtc's 104-byte one (measured: 3076 answers to bare STUN, 1 to libwebrtc's).
        // So consent freshness can never be satisfied here, and libwebrtc's default 2.5 s timeouts
        // tear down a DTLS/SCTP association that is otherwise healthy — captured completing in
        // 111 ms and dying 363 ms later. Disabling the liveness policy keeps the association up;
        // the NAT mapping stays open because libwebrtc keeps sending its own checks regardless.
        let neverExpires = iceLivenessTimeoutMilliseconds
        configuration.iceConnectionReceivingTimeout = Int32(neverExpires)
        configuration.iceUnwritableTimeout = NSNumber(value: neverExpires)
        configuration.iceInactiveTimeout = NSNumber(value: neverExpires)
        configuration.iceUnwritableMinChecks = NSNumber(value: Int32.max)
        return configuration
    }

    /// Creates the peer connection, applies the synthesized remote offer, answers, and returns the
    /// identity ANNOUNCE has to carry. ICE cannot succeed until ANNOUNCE lands, so this waits only
    /// for local gathering.
    func prepare() async throws -> Identity {
        guard let credentials = handoff.iceCredentials else { throw BundleError.missingRemoteCredentials }
        guard let remoteFingerprint = credentials.remoteDTLSFingerprint, !remoteFingerprint.isEmpty else {
            throw BundleError.missingRemoteFingerprint
        }

        let configuration = Self.bundleConfiguration()
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw BundleError.factoryUnavailable
        }
        lock.withLock { peerConnection = connection }

        let offer = Self.synthesizedRemoteOffer(
            remoteUsernameFragment: credentials.remoteUsernameFragment,
            remotePassword: credentials.remotePassword,
            remoteFingerprint: remoteFingerprint,
            peerIP: handoff.videoPeerIP,
            peerPort: handoff.videoPeerPort
        )
        try await setRemoteDescription(connection, LKRTCSessionDescription(type: .offer, sdp: offer))

        // The channels have to exist before the answer, or the answer carries no SCTP section at
        // all and the bundle has nothing to negotiate.
        let created = createOfficialChannels(on: connection)
        guard created == Self.officialChannels.count else {
            // A missing channel shifts every later label onto the wrong stream id, which the seat
            // answers by resetting all streams. Better to fail here than to find out after PLAY.
            throw BundleError.answerFailed("only \(created) of \(Self.officialChannels.count) data channels could be created")
        }

        let answer = try await createAnswer(connection, constraints: constraints)
        let (forced, usesOfficialCredentials) = try await applyLocalAnswer(
            answer,
            connection: connection,
            credentials: credentials
        )

        let candidates = try await waitForHostCandidates()
        let hosts = candidates.compactMap { Self.hostAddress(fromCandidateLine: $0) }
        logger?("NVST bundle gathered host candidates: \(hosts.map { "\($0.address):\($0.port)" }.joined(separator: ", "))")
        guard let host = Self.preferredHost(among: hosts, matching: preferredLocalAddress) else {
            throw BundleError.noHostCandidate
        }
        if host.address != preferredLocalAddress {
            logger?("NVST bundle announcing \(host.address):\(host.port), which is not the routed address \(preferredLocalAddress ?? "unknown")")
        }
        return try preparedIdentity(
            connection: connection,
            fallbackSdp: forced,
            host: host,
            usesOfficialCredentials: usesOfficialCredentials
        )
    }

    /// Forces the official ICE credentials into the created answer and sets it as the local
    /// description. Bifrost length-checks ICE credentials, so this forces the official 4/22 pair
    /// libwebrtc gives no API for; if it refuses the munged answer, this falls back to libwebrtc's
    /// own credentials and says so. ANNOUNCE still carries the 4/22 pair in that case, so the
    /// caller must treat `usesOfficialIceCredentials == false` as a failed bring-up.
    private func applyLocalAnswer(
        _ answer: LKRTCSessionDescription,
        connection: LKRTCPeerConnection,
        credentials: NVSTHandoffIceCredentials
    ) async throws -> (sdp: String, usesOfficialCredentials: Bool) {
        let forced = Self.replacingIceCredentials(
            in: answer.sdp,
            usernameFragment: credentials.localUsernameFragment,
            password: credentials.localPassword
        )
        var usesOfficialCredentials = true
        do {
            try await setLocalDescription(connection, LKRTCSessionDescription(type: .answer, sdp: forced))
        } catch {
            logger?("NVST bundle rejected the official ICE credentials (\(error.localizedDescription)); keeping the generated pair")
            usesOfficialCredentials = false
            try await setLocalDescription(connection, LKRTCSessionDescription(type: .answer, sdp: answer.sdp))
        }
        return (forced, usesOfficialCredentials)
    }

    /// Reads what the answer actually negotiated — the fingerprint ANNOUNCE carries and a
    /// per-m-line summary that proves each section's direction — and packages the identity
    /// ANNOUNCE has to carry.
    func preparedIdentity(connection: LKRTCPeerConnection,
                          fallbackSdp: String,
                          host: (address: String, port: UInt16),
                          usesOfficialCredentials: Bool) throws -> Identity
    {
        let localDescription = connection.localDescription?.sdp ?? fallbackSdp
        guard let fingerprint = Self.fingerprint(inSdp: localDescription) else {
            throw BundleError.missingLocalFingerprint
        }
        logger?("NVST bundle answer media: \(Self.mediaLineSummary(inSdp: localDescription))")
        logger?("NVST bundle prepared (port=\(host.port), localAddress=\(host.address), fingerprintBytes=\(fingerprint.count), officialIce=\(usesOfficialCredentials), setup=\(Self.setupRole(inSdp: localDescription) ?? "absent"))")
        return Identity(
            bundlePort: host.port,
            localAddress: host.address,
            dtlsFingerprint: fingerprint,
            usesOfficialIceCredentials: usesOfficialCredentials
        )
    }

    // MARK: - Transport statistics

    /// Round-trip time to the seat, in milliseconds, or -1 before the first sample.
    ///
    /// This is libwebrtc's own ICE candidate-pair RTT. Media rides its own raw-SRTP socket rather
    /// than this association, but both go to the same seat, so the bundle's RTT is the honest
    /// reading of the path — when the seat answers a check at all, which it normally does not.
    var roundTripMilliseconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return lastRoundTripMilliseconds
    }

    /// Asks libwebrtc for a fresh statistics report. Returns immediately; the sample lands in
    /// `roundTripMilliseconds` when the report arrives.
    func refreshTransportStatistics() {
        lock.lock()
        let connection = isClosed ? nil : peerConnection
        let inFlight = statisticsRequestInFlight
        if connection != nil, !inFlight {
            statisticsRequestInFlight = true
        }
        lock.unlock()
        // Never hold the lock across the proxy call: the callback below takes it too.
        guard let connection, !inFlight else { return }
        connection.statistics { [weak self] report in
            guard let self else { return }
            let sample = Self.roundTripMilliseconds(in: report)
            lock.lock()
            statisticsRequestInFlight = false
            if let sample {
                lastRoundTripMilliseconds = sample
            }
            let shouldDescribe = sample == nil && !didDescribeStatistics
            if shouldDescribe {
                didDescribeStatistics = true
            }
            lock.unlock()
            // The seat is Bifrost's minimal STUN responder rather than an ICE agent, so a missing
            // RTT is a real possibility rather than a bug on our side. Say once what the report
            // actually contains, so the difference is visible instead of guessed at.
            guard shouldDescribe else { return }
            let types = Set(report.statistics.values.map(\.type)).sorted().joined(separator: ",")
            let pairs = report.statistics.values.filter { $0.type == "candidate-pair" }.count
            logger?("NVST bundle no ICE round trip yet; types=[\(types)] pairs=\(pairs)")
        }
    }

    /// The nominated candidate pair's RTT, in milliseconds. `currentRoundTripTime` is seconds and
    /// is absent until the pair has completed a check, which is why this is optional rather than 0.
    static func roundTripMilliseconds(in report: LKRTCStatisticsReport) -> Double? {
        for statistic in report.statistics.values where statistic.type == "candidate-pair" {
            if let sample = roundTripMilliseconds(inCandidatePair: statistic.values) {
                return sample
            }
        }
        return nil
    }

    /// One `candidate-pair` entry's RTT. A pair that says it is not nominated, or not succeeded,
    /// is skipped; one that says neither is taken at its word.
    static func roundTripMilliseconds(inCandidatePair values: [String: NSObject]) -> Double? {
        let nominated = values["nominated"] as? NSNumber
        let state = values["state"] as? String
        guard nominated == nil || nominated?.boolValue == true else { return nil }
        guard state == nil || state == "succeeded" else { return nil }
        let roundTrip = (values["currentRoundTripTime"] as? NSNumber) ?? (values["roundTripTime"] as? NSNumber)
        return roundTrip.map { $0.doubleValue * 1000 }
    }

    // MARK: - Teardown

    /// Idempotent. Closes every channel and the peer connection; the injected factory and its
    /// audio device are left exactly as they were.
    func close() {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        let channels = createdChannels
        let connection = peerConnection
        createdChannels = []
        openFeedbackChannel = nil
        openControlChannel = nil
        openInputChannel = nil
        openPartiallyReliableControlChannel = nil
        negotiatedInputProtocolVersion = nil
        peerConnection = nil
        let waiting = hostCandidateContinuation
        hostCandidateContinuation = nil
        lock.unlock()
        waiting?.resume(throwing: BundleError.noHostCandidate)
        guard !wasClosed else { return }
        channels.forEach { $0.close() }
        connection?.close()
    }

    // MARK: - Sends

    /// Writes one plain RTCP payload to the feedback channel. Plain, because DTLS already encrypts
    /// the SCTP association.
    func sendFeedback(_ payload: Data) -> Bool {
        lock.lock()
        let channel = openFeedbackChannel
        lock.unlock()
        guard let channel, channel.readyState == .open else {
            // A closed association still accepts writes silently at the sender, which hides the
            // real failure behind a rising report count.
            lock.withLock { feedbackSendFailures += 1 }
            return false
        }
        let sent = channel.sendData(LKRTCDataBuffer(data: payload, isBinary: true))
        if !sent {
            lock.withLock { feedbackSendFailures += 1 }
        }
        return sent
    }

    /// Writes one NVST command packet to `control_channel_reliable`.
    func sendControl(_ command: NvstControlCommand) -> Bool {
        lock.lock()
        let channel = openControlChannel
        lock.unlock()
        guard let encoded = try? command.encoded else {
            lock.withLock {
                controlSendFailures += 1
                recordControlAttempt(code: command.code.rawValue,
                                     bytes: UInt64(command.payload.count + NvstControlCommand.headerLength),
                                     sent: false)
            }
            return false
        }
        guard let channel, channel.readyState == .open else {
            lock.withLock {
                controlSendFailures += 1
                recordControlAttempt(code: command.code.rawValue, bytes: UInt64(encoded.count), sent: false)
            }
            return false
        }
        let sent = channel.sendData(LKRTCDataBuffer(data: encoded, isBinary: true))
        lock.withLock {
            if sent {
                controlMessagesSent += 1
            } else {
                controlSendFailures += 1
            }
            recordControlAttempt(code: command.code.rawValue, bytes: UInt64(encoded.count), sent: sent)
        }
        return sent
    }

    /// Call with `lock` held.
    func recordControlAttempt(code: UInt16, bytes: UInt64, sent: Bool) {
        var counters = controlCommandStats[code] ?? ControlCommandCounters()
        if sent {
            counters.messagesSent += 1
        } else {
            counters.messagesFailed += 1
        }
        counters.aggregatedBytes += bytes
        controlCommandStats[code] = counters
    }

    /// The control-channel counters as the `0x313` report wants them: totals plus one record per
    /// command, in ascending code order.
    var controlChannelStats: (totalSent: UInt32, totalFailed: UInt32, totalBytes: UInt64,
                              commands: [NvstControlChannelCommandStats])
    {
        lock.withLock {
            let commands = controlCommandStats
                .sorted { $0.key < $1.key }
                .map { NvstControlChannelCommandStats(commandCode: $0.key,
                                                      messagesSent: UInt32(clamping: $0.value.messagesSent),
                                                      messagesFailed: UInt32(clamping: $0.value.messagesFailed),
                                                      aggregatedBytes: $0.value.aggregatedBytes) }
            return (UInt32(clamping: controlMessagesSent),
                    UInt32(clamping: controlSendFailures),
                    commands.reduce(0) { $0 + $1.aggregatedBytes },
                    commands)
        }
    }

    /// Writes one already-encoded NVST command to `input_channel_partially_reliable` (SCTP
    /// stream 10), which is where the official client sends gamepad state.
    func sendInput(_ payload: Data) -> Bool {
        lock.lock()
        let channel = openInputChannel
        lock.unlock()
        guard let channel, channel.readyState == .open else {
            lock.withLock { inputSendFailures += 1 }
            return false
        }
        let sent = channel.sendData(LKRTCDataBuffer(data: payload, isBinary: true))
        lock.withLock {
            if sent {
                inputMessagesSent += 1
            } else {
                inputSendFailures += 1
            }
        }
        return sent
    }

    /// Writes to `control_channel_partially_reliable`, which is where the captured official client
    /// sends its QoS reports and frame acknowledgements (SCTP stream 6).
    func sendPartiallyReliableControl(_ command: NvstControlCommand) -> Bool {
        lock.lock()
        let channel = openPartiallyReliableControlChannel
        lock.unlock()
        guard let channel, channel.readyState == .open, let encoded = try? command.encoded else { return false }
        return channel.sendData(LKRTCDataBuffer(data: encoded, isBinary: true))
    }

    var isInputChannelOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openInputChannel?.readyState == .open
    }

    /// Input is accepted once the control channel — which carries the activation chain — is open
    /// and the seat has announced its protocol version.
    var isInputReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openControlChannel?.readyState == .open && negotiatedInputProtocolVersion != nil
    }

    var inputProtocolVersion: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return negotiatedInputProtocolVersion
    }

    var isControlChannelOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openControlChannel?.readyState == .open
    }

    var isFeedbackChannelOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openFeedbackChannel?.readyState == .open
    }

    var diagnosticSummary: String {
        lock.lock()
        defer { lock.unlock() }
        let perLabel = inboundMessagesByLabel.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "ice=\(iceStateDescription) channels=\(createdChannels.count) audioTracks=\(trackedRemoteAudioCount) feedbackOpen=\(openFeedbackChannel != nil) inboundBytes=\(inboundFeedbackBytes) inbound=[\(perLabel)] sendFailures=\(feedbackSendFailures) controlOut=\(controlMessagesSent) controlFailed=\(controlSendFailures) inputOut=\(inputMessagesSent) inputFailed=\(inputSendFailures)"
    }

    /// The data-channel configuration one definition asks for: always ordered and in-band
    /// negotiated, with the reliability the official client's log shows.
    static func channelConfiguration(for definition: ChannelDefinition) -> LKRTCDataChannelConfiguration {
        let configuration = LKRTCDataChannelConfiguration()
        configuration.isOrdered = true
        configuration.isNegotiated = false
        if definition.isUnreliable {
            configuration.maxRetransmits = 0
        } else if let lifetime = definition.maxPacketLifeTimeMilliseconds {
            configuration.maxPacketLifeTime = lifetime
        }
        return configuration
    }

    /// Creates the official channel set in order so each label lands on the stream id the seat
    /// expects, with the feedback channel last. Stops at the first refusal: skipping one would
    /// move every later label onto the wrong id.
    func createOfficialChannels(on connection: LKRTCPeerConnection) -> Int {
        var created: [LKRTCDataChannel] = []
        for definition in Self.officialChannels {
            let configuration = Self.channelConfiguration(for: definition)
            guard let channel = connection.dataChannel(forLabel: definition.label, configuration: configuration) else { break }
            channel.delegate = self
            created.append(channel)
        }
        lock.withLock { createdChannels.append(contentsOf: created) }
        logger?("NVST bundle created \(created.count) channels: " + created.map(\.label).joined(separator: ", "))
        return created.count
    }
}
