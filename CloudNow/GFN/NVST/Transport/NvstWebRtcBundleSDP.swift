import Foundation
@preconcurrency import LiveKitWebRTC

// The SDP this bundle synthesizes for a seat that is not an ICE agent, and the async bridges over
// libwebrtc's callback API.

nonisolated extension NvstWebRtcBundle {
    // MARK: - SDP

    /// The seat's side of the bundle, assembled from RTSP answers.
    ///
    /// Two media sections, both required:
    /// - `m=audio` because ANNOUNCE tells the seat audio rides this bundle, and the official
    ///   client's bundle really does receive it (1543 inbound RTP packets in the reference
    ///   capture). A data-channel-only bundle makes the seat reset every SCTP stream and close
    ///   DTLS 114 ms after PLAY, having nowhere to put the audio it was promised.
    /// - `m=application` for the eight SCTP data channels.
    ///
    /// `a=setup:actpass` leaves us free to answer `active`, which is what makes libwebrtc send the
    /// ClientHello — the role the official client takes.
    static func synthesizedRemoteOffer(remoteUsernameFragment: String,
                                       remotePassword: String,
                                       remoteFingerprint: String,
                                       peerIP: String,
                                       peerPort: UInt16) -> String
    {
        let transport = [
            "c=IN IP4 0.0.0.0",
            "a=ice-ufrag:\(remoteUsernameFragment)",
            "a=ice-pwd:\(remotePassword)",
            "a=ice-options:trickle",
            "a=fingerprint:sha-256 \(remoteFingerprint)",
            "a=setup:actpass",
        ]
        var lines = [
            "v=0",
            "o=- 0 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0 1",
            "a=msid-semantic: WMS",
            // Offered as sendonly by the seat, so our answer is recvonly.
            "m=audio 9 UDP/TLS/RTP/SAVPF \(redPayloadType) \(opusPayloadType)",
        ]
        lines += transport
        lines += [
            "a=mid:0",
            "a=rtcp-mux",
            "a=sendonly",
        ]
        lines += audioCodecLines
        lines += [
            "a=ptime:5",
            "a=maxptime:20",
            "a=candidate:1 1 udp 2122260223 \(peerIP) \(peerPort) typ host",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
        ]
        lines += transport
        lines += [
            "a=mid:1",
            "a=sctp-port:5000",
            "a=max-message-size:262144",
        ]
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// The wire carries bundle audio on payload type **63** — captured from the native stack's
    /// bundle socket (pt=63, ssrc=0x00000001, no extension, ~188 bytes at 200/s, against pt=101 for
    /// video on its own socket). libwebrtc demultiplexes on the payload type, so the offer must
    /// name it or every audio packet is discarded before it can be counted.
    ///
    /// 63 is WebRTC's own default type for **RED** (RFC 2198) wrapping Opus, and the seat uses the
    /// standard WebRTC audio offer, so RED is the format. Declaring RED payloads as plain Opus
    /// mis-frames them and yields garbage on real audio.
    static let redPayloadType = 63
    static let opusPayloadType = 111

    /// 48 kHz stereo Opus in 5 ms frames. libwebrtc decodes Opus as mono unless `stereo=1` is
    /// negotiated. Under RED, pt 63 carries generations of the pt-111 Opus payload.
    static var audioCodecLines: [String] {
        [
            "a=rtpmap:\(redPayloadType) red/48000/2",
            "a=fmtp:\(redPayloadType) \(opusPayloadType)/\(opusPayloadType)",
            "a=rtpmap:\(opusPayloadType) opus/48000/2",
            "a=fmtp:\(opusPayloadType) minptime=5;stereo=1;sprop-stereo=1;useinbandfec=1",
        ]
    }

    /// Replaces every `a=ice-ufrag:` / `a=ice-pwd:` line, leaving the rest of the SDP untouched.
    static func replacingIceCredentials(in sdp: String, usernameFragment: String, password: String) -> String {
        sdp.components(separatedBy: "\r\n").map { line in
            if line.hasPrefix("a=ice-ufrag:") {
                return "a=ice-ufrag:\(usernameFragment)"
            }
            if line.hasPrefix("a=ice-pwd:") {
                return "a=ice-pwd:\(password)"
            }
            return line
        }.joined(separator: "\r\n")
    }

    /// The fingerprint value of the first `a=fingerprint:<hash> <value>` line.
    static func fingerprint(inSdp sdp: String) -> String? {
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix("a=fingerprint:") {
            let parts = line.dropFirst("a=fingerprint:".count).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func setupRole(inSdp sdp: String) -> String? {
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix("a=setup:") {
            return String(line.dropFirst("a=setup:".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// One entry per m-line: kind, mid and direction. The answer is never transported to the
    /// seat, so this summary in the diagnostic log is the only proof of what libwebrtc actually
    /// negotiated for each section.
    static func mediaLineSummary(inSdp sdp: String) -> String {
        struct Entry {
            var media = ""
            var mid = "-"
            var direction = "-"
        }
        var entries: [Entry] = []
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                entries.append(Entry(media: line))
                continue
            }
            guard !entries.isEmpty else { continue }
            if line.hasPrefix("a=mid:") {
                entries[entries.count - 1].mid = String(line.dropFirst("a=mid:".count))
            } else if line == "a=sendonly" || line == "a=recvonly" || line == "a=sendrecv" || line == "a=inactive" {
                entries[entries.count - 1].direction = String(line.dropFirst(2))
            }
        }
        return entries.enumerated()
            .map { index, entry in "[\(index) \(entry.media) mid=\(entry.mid) dir=\(entry.direction)]" }
            .joined(separator: " ")
    }

    /// Whether a gathered candidate line is a UDP host candidate, the only kind ANNOUNCE can name.
    static func isUdpHostCandidate(_ line: String) -> Bool {
        line.contains("typ host") && line.lowercased().contains(" udp ")
    }

    /// `candidate:… udp <priority> <address> <port> typ host` → the address and port to announce.
    static func hostAddress(fromCandidateLine line: String) -> (address: String, port: UInt16)? {
        var text = line
        if text.hasPrefix("a=") {
            text.removeFirst(2)
        }
        if text.hasPrefix("candidate:") {
            text.removeFirst("candidate:".count)
        }
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count >= 6, let port = UInt16(fields[5]) else { return nil }
        return (fields[4], port)
    }

    /// The candidate on the routed interface, falling back to the first gathered one.
    static func preferredHost(among hosts: [(address: String, port: UInt16)],
                              matching preferredAddress: String?) -> (address: String, port: UInt16)?
    {
        if let preferredAddress, let match = hosts.first(where: { $0.address == preferredAddress }) {
            return match
        }
        return hosts.first
    }

    // MARK: - Async bridges

    func setRemoteDescription(_ connection: LKRTCPeerConnection, _ description: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: BundleError.answerFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func createAnswer(_ connection: LKRTCPeerConnection, constraints: LKRTCMediaConstraints) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
            connection.answer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: BundleError.answerFailed(error?.localizedDescription ?? "no answer"))
                }
            }
        }
    }

    func setLocalDescription(_ connection: LKRTCPeerConnection, _ description: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: BundleError.localDescriptionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Longest the bring-up waits for libwebrtc to report that gathering finished.
    static let hostCandidateWait: Duration = .seconds(2)

    /// Waits for gathering to finish rather than taking the first candidate: the first one to
    /// arrive is frequently a bridge interface, and announcing its port arms the seat's media relay
    /// on a socket that never receives anything.
    func waitForHostCandidates() async throws -> [String] {
        if let ready = lock.withLock({ gatheringComplete ? hostCandidates : nil }), !ready.isEmpty {
            return ready
        }
        // Gathering on a machine with many interfaces still settles in well under a second; the
        // timer only bounds a stack that never reports completion, and then hands over whatever
        // was gathered so far.
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.hostCandidateWait)
            guard !Task.isCancelled else { return }
            self?.finishHostCandidateWait()
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: BundleError.noHostCandidate)
                return
            }
            if gatheringComplete, !hostCandidates.isEmpty {
                let ready = hostCandidates
                lock.unlock()
                continuation.resume(returning: ready)
                return
            }
            hostCandidateContinuation = continuation
            lock.unlock()
        }
    }

    /// Resumes the wait with whatever has been gathered so far.
    func finishHostCandidateWait() {
        lock.lock()
        let waiting = hostCandidateContinuation
        hostCandidateContinuation = nil
        let gathered = hostCandidates
        lock.unlock()
        guard let waiting else { return }
        if gathered.isEmpty {
            waiting.resume(throwing: BundleError.noHostCandidate)
        } else {
            waiting.resume(returning: gathered)
        }
    }
}
