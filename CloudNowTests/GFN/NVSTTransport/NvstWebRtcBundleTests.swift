@testable import CloudNow
import Foundation
@preconcurrency import LiveKitWebRTC
import Testing

/// NVST has no WebRTC signaling, so the seat's half of the bundle is synthesized from RTSP answers.
/// These tests pin that synthesis and the SDP surgery around it — the parts that decide whether the
/// seat ever arms its video relay.
@Suite("NVST WebRTC bundle SDP and channels")
struct NvstWebRtcBundleTests {
    private func offerLines() -> [String] {
        NvstWebRtcBundle.synthesizedRemoteOffer(
            remoteUsernameFragment: "58d3b48a47999",
            remotePassword: "seatPassword",
            remoteFingerprint: "AA:BB:CC",
            peerIP: "203.0.113.40",
            peerPort: 5004
        ).components(separatedBy: "\r\n")
    }

    @Test("The synthesized offer carries the seat's RTSP identity")
    func synthesizedOfferCarriesSeatIdentity() {
        let lines = offerLines()
        // An SCTP media section is required or the answer has nowhere to put data channels.
        #expect(lines.contains("m=application 9 UDP/DTLS/SCTP webrtc-datachannel"))
        #expect(lines.contains("a=sctp-port:5000"))
        #expect(lines.contains("a=max-message-size:262144"))
        // An audio section is equally required: ANNOUNCE tells the seat audio rides this bundle.
        // Audio is RED (pt 63) wrapping Opus (pt 111): 63 is the wire type the seat sends.
        #expect(lines.contains("m=audio 9 UDP/TLS/RTP/SAVPF 63 111"))
        #expect(lines.contains("a=rtpmap:63 red/48000/2"))
        #expect(lines.contains("a=fmtp:63 111/111"))
        #expect(lines.contains("a=rtpmap:111 opus/48000/2"))
        #expect(lines.contains("a=fmtp:111 minptime=5;stereo=1;sprop-stereo=1;useinbandfec=1"))
        #expect(lines.contains("a=ptime:5"))
        #expect(lines.contains("a=maxptime:20"))
        // Offered sendonly by the seat, so our answer becomes recvonly.
        #expect(lines.contains("a=sendonly"))
        #expect(lines.contains("a=rtcp-mux"))
        // Both sections share one transport, so both mids are in the BUNDLE group.
        #expect(lines.contains("a=group:BUNDLE 0 1"))
        #expect(lines.contains("a=mid:0"))
        #expect(lines.contains("a=mid:1"))
        // The ICE and DTLS identity repeats per section, as a real offer does.
        #expect(lines.filter { $0 == "a=ice-ufrag:58d3b48a47999" }.count == 2)
        #expect(lines.filter { $0 == "a=ice-pwd:seatPassword" }.count == 2)
        #expect(lines.filter { $0 == "a=fingerprint:sha-256 AA:BB:CC" }.count == 2)
        // actpass on the remote side leaves us free to answer `active` and send the ClientHello.
        #expect(lines.filter { $0 == "a=setup:actpass" }.count == 2)
        // The peer address comes from SETUP's Transport header; there is no candidate exchange.
        #expect(lines.filter { $0 == "a=candidate:1 1 udp 2122260223 203.0.113.40 5004 typ host" }.count == 1)
    }

    @Test("The synthesized offer is exactly the stereo, microphone-free shape")
    func synthesizedOfferShape() {
        let lines = offerLines()
        #expect(lines.first == "v=0")
        // CRLF-joined with a trailing CRLF.
        #expect(lines.last == "")
        #expect(lines.filter { $0.hasPrefix("m=") } == [
            "m=audio 9 UDP/TLS/RTP/SAVPF 63 111",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
        ])
        // No microphone section, no signaled SSRC, no surround.
        #expect(!lines.contains("a=mid:2"))
        #expect(!lines.contains("a=recvonly"))
        #expect(!lines.contains { $0.hasPrefix("a=ssrc:") })
        #expect(!lines.contains { $0.contains("multiopus") })
        // The audio candidate sits inside the audio section, ahead of the data section.
        let candidate = lines.firstIndex { $0.hasPrefix("a=candidate:") } ?? -1
        let data = lines.firstIndex(of: "m=application 9 UDP/DTLS/SCTP webrtc-datachannel") ?? -1
        #expect(candidate > 0 && candidate < data)
    }

    @Test("ICE credentials are forced to the official lengths and nothing else changes")
    func iceCredentialReplacement() {
        // libwebrtc offers no API for this and generates a 16-character ufrag, which Bifrost's
        // length checks are documented to reject.
        let answer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 63 111",
            "a=ice-ufrag:qP0zVeryLongUfrag",
            "a=ice-pwd:aVeryLongGeneratedPasswordValue",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
            "a=ice-ufrag:qP0zVeryLongUfrag",
            "a=ice-pwd:aVeryLongGeneratedPasswordValue",
            "a=fingerprint:sha-256 11:22:33",
            "a=setup:active",
        ].joined(separator: "\r\n")
        let password = String(repeating: "p", count: 22)
        let forced = NvstWebRtcBundle.replacingIceCredentials(in: answer, usernameFragment: "OyEL", password: password)
        let lines = forced.components(separatedBy: "\r\n")
        #expect(lines.filter { $0 == "a=ice-ufrag:OyEL" }.count == 2)
        #expect(lines.filter { $0 == "a=ice-pwd:\(password)" }.count == 2)
        #expect(!forced.contains("qP0zVeryLongUfrag"))
        #expect(!forced.contains("aVeryLongGeneratedPasswordValue"))
        // Nothing else may be touched: libwebrtc rejects a munged answer that changes more.
        #expect(lines.count == 9)
        #expect(lines.contains("a=fingerprint:sha-256 11:22:33"))
        #expect(lines.contains("a=setup:active"))
        #expect(lines.contains("m=application 9 UDP/DTLS/SCTP webrtc-datachannel"))
    }

    @Test("The answer's fingerprint and role are read back for ANNOUNCE")
    func fingerprintAndRole() {
        let answer = "v=0\r\na=fingerprint:sha-256 AA:BB:CC:DD\r\na=setup:active\r\n"
        #expect(NvstWebRtcBundle.fingerprint(inSdp: answer) == "AA:BB:CC:DD")
        // `active` is what makes libwebrtc send the ClientHello, matching the captured client.
        #expect(NvstWebRtcBundle.setupRole(inSdp: answer) == "active")
        #expect(NvstWebRtcBundle.fingerprint(inSdp: "v=0\r\n") == nil)
        #expect(NvstWebRtcBundle.setupRole(inSdp: "v=0\r\n") == nil)
        // A fingerprint line with no value is not a fingerprint.
        #expect(NvstWebRtcBundle.fingerprint(inSdp: "a=fingerprint:sha-256\r\n") == nil)
    }

    @Test("The host candidate supplies the announced bundle port")
    func hostCandidateParsing() {
        let candidate = "candidate:842163049 1 udp 1677729535 192.0.2.20 51628 typ host generation 0"
        let host = NvstWebRtcBundle.hostAddress(fromCandidateLine: candidate)
        #expect(host?.address == "192.0.2.20")
        #expect(host?.port == 51628)
        // The `a=` prefixed form appears in SDP rather than in a trickled candidate.
        #expect(NvstWebRtcBundle.hostAddress(fromCandidateLine: "a=" + candidate)?.port == 51628)
        #expect(NvstWebRtcBundle.hostAddress(fromCandidateLine: "candidate:1 1 udp 100") == nil)
        #expect(NvstWebRtcBundle.hostAddress(fromCandidateLine: "candidate:1 1 udp 100 192.0.2.20 notaport typ host") == nil)
    }

    @Test("Only UDP host candidates are kept for the announce")
    func udpHostCandidateFilter() {
        #expect(NvstWebRtcBundle.isUdpHostCandidate("candidate:1 1 udp 2122260223 192.0.2.20 50000 typ host generation 0"))
        #expect(NvstWebRtcBundle.isUdpHostCandidate("candidate:1 1 UDP 2122260223 192.0.2.20 50000 typ host"))
        #expect(!NvstWebRtcBundle.isUdpHostCandidate("candidate:2 1 tcp 1518280447 192.0.2.20 9 typ host tcptype active"))
        #expect(!NvstWebRtcBundle.isUdpHostCandidate("candidate:3 1 udp 1686052607 198.51.100.7 50000 typ srflx raddr 192.0.2.20 rport 50000"))
    }

    @Test("The announced candidate is the one on the routed interface")
    func routedInterfacePreference() {
        // Live failure this guards: libwebrtc gathered on several bridges plus the real interface,
        // the first candidate to arrive was a bridge's, and announcing its port armed the seat's
        // media relay on a socket that never received anything.
        let hosts: [(address: String, port: UInt16)] = [
            ("198.51.100.20", 55029),
            ("198.51.100.5", 57469),
            ("192.0.2.20", 49812),
        ]
        let chosen = NvstWebRtcBundle.preferredHost(among: hosts, matching: "192.0.2.20")
        #expect(chosen?.address == "192.0.2.20")
        #expect(chosen?.port == 49812)
        // With no routed address known, the first candidate is still better than failing.
        #expect(NvstWebRtcBundle.preferredHost(among: hosts, matching: nil)?.port == 55029)
        // A routed address that gathered no candidate falls back rather than throwing.
        #expect(NvstWebRtcBundle.preferredHost(among: hosts, matching: "203.0.113.9")?.port == 55029)
        #expect(NvstWebRtcBundle.preferredHost(among: [], matching: "192.0.2.20") == nil)
    }

    @Test("Without a routed match an IPv4 candidate is announced ahead of IPv6 and mDNS ones")
    func ipv4Preference() {
        let hosts: [(address: String, port: UInt16)] = [
            ("2001:db8::20", 50001),
            ("0f1e2d3c-aaaa-bbbb-cccc-0123456789ab.local", 50002),
            ("192.0.2.20", 50003),
        ]
        #expect(NvstWebRtcBundle.preferredHost(among: hosts, matching: nil)?.port == 50003)
        #expect(NvstWebRtcBundle.preferredHost(among: hosts, matching: "198.51.100.1")?.port == 50003)
        // An exact routed match still wins, whatever its family.
        #expect(NvstWebRtcBundle.preferredHost(among: hosts, matching: "2001:db8::20")?.port == 50001)
        // With no IPv4 candidate at all, the first one is still better than failing.
        #expect(NvstWebRtcBundle.preferredHost(among: Array(hosts.prefix(2)), matching: nil)?.port == 50001)
        #expect(NvstWebRtcBundle.isIPv4Address("203.0.113.255"))
        #expect(!NvstWebRtcBundle.isIPv4Address("203.0.113.256"))
        #expect(!NvstWebRtcBundle.isIPv4Address("203.0.113"))
        #expect(!NvstWebRtcBundle.isIPv4Address("203.0.113.1.5"))
        #expect(!NvstWebRtcBundle.isIPv4Address("::1"))
    }

    @Test("The official channel set maps labels onto the stream ids the seat reserves")
    func officialChannelTable() {
        // The seat assigns each label a fixed stream id and validates it. As DTLS client we are
        // handed the even ids in creation order, so the order of this list *is* the id mapping.
        let expected: [(label: String, id: Int)] = [
            ("control_channel_reliable", 0),
            ("custom_message_on_sctp_private_reliable", 2),
            ("custom_message_on_sctp_private_partially_reliable", 4),
            ("control_channel_partially_reliable", 6),
            ("control_channel_unreliable", 8),
            ("input_channel_partially_reliable", 10),
            ("cursor_channel", 12),
            ("rtcp_on_sctp_private", 14),
        ]
        let channels = NvstWebRtcBundle.officialChannels
        #expect(channels.map(\.label) == expected.map(\.label))
        for (index, entry) in expected.enumerated() {
            #expect(NvstWebRtcBundle.ChannelDefinition.expectedStreamId(atIndex: index) == entry.id)
        }
        #expect(Set(channels.map(\.label)).count == 8)
        // The feedback channel is last, so it lands on sid 14 where the seat expects it.
        #expect(channels.last?.label == NvstWebRtcBundle.feedbackChannelLabel)
        #expect(NvstWebRtcBundle.feedbackChannelLabel == "rtcp_on_sctp_private")
        #expect(NvstWebRtcBundle.controlChannelLabel == channels[0].label)
        #expect(NvstWebRtcBundle.partiallyReliableControlChannelLabel == channels[3].label)
        #expect(NvstWebRtcBundle.inputChannelLabel == channels[5].label)
    }

    @Test("Channel reliability matches the captured configuration")
    func officialChannelReliability() {
        // 300 ms lifetime for the partially-reliable channels, zero retransmits for the unreliable
        // one, fully reliable otherwise.
        let byLabel = Dictionary(uniqueKeysWithValues: NvstWebRtcBundle.officialChannels.map { ($0.label, $0) })
        #expect(byLabel["control_channel_partially_reliable"]?.maxPacketLifeTimeMilliseconds == 300)
        #expect(byLabel["input_channel_partially_reliable"]?.maxPacketLifeTimeMilliseconds == 300)
        #expect(byLabel["custom_message_on_sctp_private_partially_reliable"]?.maxPacketLifeTimeMilliseconds == 300)
        #expect(byLabel["control_channel_unreliable"]?.isUnreliable == true)
        #expect(byLabel["control_channel_unreliable"]?.maxPacketLifeTimeMilliseconds == nil)
        for label in ["control_channel_reliable", "custom_message_on_sctp_private_reliable", "cursor_channel", "rtcp_on_sctp_private"] {
            #expect(byLabel[label]?.maxPacketLifeTimeMilliseconds == nil)
            #expect(byLabel[label]?.isUnreliable == false)
        }
        #expect(NvstWebRtcBundle.officialChannels.filter(\.isUnreliable).count == 1)
        #expect(NvstWebRtcBundle.officialChannels.filter { $0.maxPacketLifeTimeMilliseconds != nil }.count == 3)
    }

    @Test("Every channel is ordered and negotiated in band, with the reliability its definition names")
    func channelConfigurations() {
        for definition in NvstWebRtcBundle.officialChannels {
            let configuration = NvstWebRtcBundle.channelConfiguration(for: definition)
            #expect(configuration.isOrdered)
            #expect(!configuration.isNegotiated)
            if definition.isUnreliable {
                #expect(configuration.maxRetransmits == 0)
            } else if let lifetime = definition.maxPacketLifeTimeMilliseconds {
                #expect(configuration.maxPacketLifeTime == lifetime)
            }
        }
        // A fully reliable channel leaves both limits at whatever libwebrtc defaults them to.
        let untouched = LKRTCDataChannelConfiguration()
        let reliable = NvstWebRtcBundle.channelConfiguration(for: NvstWebRtcBundle.officialChannels[0])
        #expect(reliable.maxRetransmits == untouched.maxRetransmits)
        #expect(reliable.maxPacketLifeTime == untouched.maxPacketLifeTime)
    }

    @Test("ICE liveness is disabled for a day because the seat is not an ICE agent")
    func bundleConfiguration() {
        let configuration = NvstWebRtcBundle.bundleConfiguration()
        let day = 24 * 60 * 60 * 1000
        #expect(NvstWebRtcBundle.iceLivenessTimeoutMilliseconds == day)
        #expect(configuration.iceServers.isEmpty)
        #expect(configuration.sdpSemantics == .unifiedPlan)
        #expect(configuration.bundlePolicy == .maxBundle)
        #expect(configuration.rtcpMuxPolicy == .require)
        #expect(configuration.continualGatheringPolicy == .gatherOnce)
        #expect(configuration.iceConnectionReceivingTimeout == Int32(day))
        #expect(configuration.iceUnwritableTimeout?.intValue == day)
        #expect(configuration.iceInactiveTimeout?.intValue == day)
        #expect(configuration.iceUnwritableMinChecks?.int32Value == Int32.max)
        // 5 ms Opus frames at ~200 packets a second need a deeper buffer than the default.
        #expect(configuration.audioJitterBufferMaxPackets == 200)
        #expect(configuration.audioJitterBufferFastAccelerate)
    }

    @Test("The answer media summary names each section's mid and direction")
    func mediaLineSummary() {
        let sdp = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 63 111",
            "a=mid:0",
            "a=recvonly",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
            "a=mid:1",
        ].joined(separator: "\r\n")
        let summary = NvstWebRtcBundle.mediaLineSummary(inSdp: sdp)
        #expect(summary.contains("[0 m=audio 9 UDP/TLS/RTP/SAVPF 63 111 mid=0 dir=recvonly]"))
        #expect(summary.contains("[1 m=application 9 UDP/DTLS/SCTP webrtc-datachannel mid=1 dir=-]"))
        #expect(NvstWebRtcBundle.mediaLineSummary(inSdp: "v=0\r\n").isEmpty)
    }

    @Test("The ICE round trip is read from a nominated, succeeded candidate pair")
    func candidatePairRoundTrip() {
        let succeeded: [String: NSObject] = [
            "nominated": NSNumber(value: true),
            "state": "succeeded" as NSString,
            "currentRoundTripTime": NSNumber(value: 0.0125),
        ]
        #expect(NvstWebRtcBundle.roundTripMilliseconds(inCandidatePair: succeeded) == 12.5)
        // The older key is honoured when the current one is absent.
        #expect(NvstWebRtcBundle.roundTripMilliseconds(inCandidatePair: ["roundTripTime": NSNumber(value: 0.004)]) == 4)
        // A pair that never completed a check carries no sample: optional, not zero.
        #expect(NvstWebRtcBundle.roundTripMilliseconds(inCandidatePair: ["state": "succeeded" as NSString]) == nil)
        var waiting = succeeded
        waiting["state"] = "in-progress" as NSString
        #expect(NvstWebRtcBundle.roundTripMilliseconds(inCandidatePair: waiting) == nil)
        var notNominated = succeeded
        notNominated["nominated"] = NSNumber(value: false)
        #expect(NvstWebRtcBundle.roundTripMilliseconds(inCandidatePair: notNominated) == nil)
    }

    @Test("Inbound audio statistics are summed across entries")
    func audioReceptionTotals() {
        var reception = NvstWebRtcBundle.AudioReception()
        reception.add(inboundAudio: [
            "packetsReceived": NSNumber(value: 200),
            "bytesReceived": NSNumber(value: 37600),
            "totalSamplesReceived": NSNumber(value: 48000),
            "concealedSamples": NSNumber(value: 240),
            "packetsDiscarded": NSNumber(value: 3),
            "jitterBufferDelay": NSNumber(value: 1.5),
            "jitterBufferEmittedCount": NSNumber(value: 47000),
            "ssrc": NSNumber(value: 1),
        ])
        reception.add(inboundAudio: ["packetsReceived": NSNumber(value: 10), "jitterBufferDelay": NSNumber(value: 0.5)])
        #expect(reception == NvstWebRtcBundle.AudioReception(
            packets: 210,
            ssrc: 1,
            bytes: 37600,
            samples: 48000,
            concealed: 240,
            discarded: 3,
            jitterBufferDelaySeconds: 2,
            jitterBufferEmitted: 47000
        ))
    }

    @Test("Bundle errors explain themselves")
    func bundleErrorDescriptions() {
        #expect(NvstWebRtcBundle.BundleError.missingRemoteCredentials.errorDescription?.contains("ICE credentials") == true)
        #expect(NvstWebRtcBundle.BundleError.missingRemoteFingerprint.errorDescription?.contains("fingerprint") == true)
        #expect(NvstWebRtcBundle.BundleError.answerFailed("why").errorDescription?.hasSuffix("why") == true)
        #expect(NvstWebRtcBundle.BundleError.localDescriptionFailed("why").errorDescription?.hasSuffix("why") == true)
        #expect(NvstWebRtcBundle.BundleError.noHostCandidate.errorDescription?.contains("host candidate") == true)
        #expect(NvstWebRtcBundle.BundleError.factoryUnavailable.errorDescription != nil)
        #expect(NvstWebRtcBundle.BundleError.missingLocalFingerprint.errorDescription != nil)
    }
}
