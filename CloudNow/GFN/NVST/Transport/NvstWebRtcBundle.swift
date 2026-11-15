import Foundation
@preconcurrency import LiveKitWebRTC

/// The NVST ICE/DTLS/SCTP bundle, driven by libwebrtc.
///
/// NVST has no WebRTC signaling: the seat's identity arrives through RTSP (DESCRIBE's DTLS
/// fingerprint and ICE password, SETUP's ping payload), and ours goes back in ANNOUNCE. So the
/// remote description is **synthesized** from those RTSP answers, and only the answer is real.
///
/// Facts this is built to match, captured from the official client (2026-08-23):
/// - the client is the DTLS **client**: it sends the ClientHello on the bundle socket ~37 ms
///   after the first STUN Binding Request, and the handshake completes ~11 ms later;
/// - the bundle authenticates with the **`ping+1`** remote ufrag while the video socket uses the
///   raw ping payload — one shared 4-character local ufrag serves both;
/// - the seat gates media on this handshake: without it the video relay is never armed.
///
/// `libBifrost2` embeds libwebrtc itself (`net/dcsctp`, `SctpTransport`, `a=sctp-port:5000`), so
/// this is the same stack the official client uses rather than an approximation of it.
///
/// The peer connection comes from the process-wide factory the caller injects, so the seat's
/// stereo Opus track plays through that factory's audio device with no further work here. The
/// bundle never owns the factory and never tears it down.
final nonisolated class NvstWebRtcBundle: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate,
    NvstPartiallyReliableControlSending, @unchecked Sendable
{
    struct Identity: Equatable, Sendable {
        /// Port of the local host candidate, announced as `general.clientBundlePort`.
        let bundlePort: UInt16
        let localAddress: String?
        /// SHA-256 colon hex of the local DTLS certificate.
        let dtlsFingerprint: String
        /// True when libwebrtc accepted the official 4/22 ICE credentials; false means it kept its
        /// own, which Bifrost's length checks are documented to reject.
        let usesOfficialIceCredentials: Bool
    }

    enum BundleError: LocalizedError, Equatable, Sendable {
        case factoryUnavailable
        case missingRemoteFingerprint
        case missingRemoteCredentials
        case answerFailed(String)
        case localDescriptionFailed(String)
        case noHostCandidate
        case missingLocalFingerprint

        var errorDescription: String? {
            switch self {
            case .factoryUnavailable: "The NVST bundle could not create a WebRTC peer connection."
            case .missingRemoteFingerprint: "DESCRIBE did not advertise a remote DTLS fingerprint, so the bundle cannot be brought up."
            case .missingRemoteCredentials: "The NVST bundle needs the version-6 ICE credentials."
            case let .answerFailed(reason): "The NVST bundle could not create its answer: \(reason)"
            case let .localDescriptionFailed(reason): "The NVST bundle could not apply its answer: \(reason)"
            case .noHostCandidate: "The NVST bundle gathered no host candidate, so no port can be announced."
            case .missingLocalFingerprint: "The NVST bundle answer carried no local DTLS fingerprint."
            }
        }
    }

    /// The SCTP data channels the official client opens, in creation order. The seat assigns each
    /// label a **fixed** stream id and validates it: captured from `libBifrost2`'s own log,
    ///
    ///     id 0  control_channel_reliable
    ///     id 2  custom_message_on_sctp_private_reliable
    ///     id 4  custom_message_on_sctp_private_partially_reliable
    ///     id 6  control_channel_partially_reliable
    ///     id 8  control_channel_unreliable
    ///     id 10 input_channel_partially_reliable
    ///     id 12 cursor_channel
    ///     id 14 rtcp_on_sctp_private
    ///
    /// As DTLS client we are given the even ids in creation order, so creating the list in order
    /// reproduces that mapping exactly — no negotiated-id trick required.
    ///
    /// Opening `rtcp_on_sctp_private` across ids 0…14 squatted every one of those and the seat
    /// answered by resetting all streams and closing DTLS 114 ms after PLAY. Appending it to the
    /// six-channel list failed the same way for a narrower reason: it landed on id 12, which is
    /// the cursor channel's, under the wrong label.
    struct ChannelDefinition: Equatable, Sendable {
        let label: String
        /// `nil` is fully reliable; a lifetime marks partially-reliable; zero retransmits is
        /// unreliable.
        let maxPacketLifeTimeMilliseconds: Int32?
        let isUnreliable: Bool

        init(_ label: String, lifetime: Int32? = nil, unreliable: Bool = false) {
            self.label = label
            maxPacketLifeTimeMilliseconds = lifetime
            isUnreliable = unreliable
        }

        /// The SCTP stream id this definition lands on when the whole list is created in order by
        /// the DTLS client: the even ids, ascending.
        static func expectedStreamId(atIndex index: Int) -> Int { index * 2 }
    }

    static let controlChannelLabel = "control_channel_reliable"
    static let partiallyReliableControlChannelLabel = "control_channel_partially_reliable"
    static let inputChannelLabel = "input_channel_partially_reliable"

    /// `config.maxRetransmitTime = 300` for the partially-reliable channels, per the same log.
    ///
    /// Eight channels, matching the native streamer profile. The custom-message and cursor
    /// channels are never written to or read from by this client, but they have to exist: they
    /// hold the stream ids the later channels are validated against. Creating the cursor channel
    /// before the RTCP one is what puts RTCP on 14 where it belongs; without a feedback channel
    /// the seat's congestion control never hears our receiver reports and has no evidence to
    /// reduce its output when we are losing packets.
    static let officialChannels: [ChannelDefinition] = [
        ChannelDefinition(controlChannelLabel),
        ChannelDefinition("custom_message_on_sctp_private_reliable"),
        ChannelDefinition("custom_message_on_sctp_private_partially_reliable", lifetime: 300),
        ChannelDefinition(partiallyReliableControlChannelLabel, lifetime: 300),
        ChannelDefinition("control_channel_unreliable", unreliable: true),
        ChannelDefinition(inputChannelLabel, lifetime: 300),
        ChannelDefinition("cursor_channel"),
        ChannelDefinition(NvstFeedbackSender.channelLabel),
    ]

    /// Official feedback channel label. `rtcp1` is refused by the seat.
    static let feedbackChannelLabel = NvstFeedbackSender.channelLabel

    /// Stereo only: what the synthesized audio section is built for and what the injected
    /// factory's audio device plays.
    static let audioChannelCount = 2

    let handoff: NVSTVideoHandoff
    /// The process-wide peer connection factory. Borrowed, never released or reconfigured here.
    let factory: LKRTCPeerConnectionFactory
    /// The routed NIC address. libwebrtc gathers on every interface — including bridges that
    /// cannot reach the seat — and ANNOUNCE can carry only one port, so the candidate on this
    /// address is the one that must be announced.
    let preferredLocalAddress: String?
    let logger: (@Sendable (String) -> Void)?
    let lock = NSLock()
    var lastRoundTripMilliseconds = -1.0
    var statisticsRequestInFlight = false
    var didDescribeStatistics = false
    var peerConnection: LKRTCPeerConnection?
    /// Set by `close()`, so a state change the close itself causes is not reported as a failure
    /// and a statistics request cannot be issued against a closed connection.
    var isClosed = false
    var didReportConnectionFailure = false
    var createdChannels: [LKRTCDataChannel] = []
    var openFeedbackChannel: LKRTCDataChannel?
    var openControlChannel: LKRTCDataChannel?
    var openInputChannel: LKRTCDataChannel?
    var openPartiallyReliableControlChannel: LKRTCDataChannel?
    /// Guarded by `lock`: written on libwebrtc's delegate thread, read from the transport's actor.
    var trackedRemoteAudioCount = 0
    var remoteAudioTrackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return trackedRemoteAudioCount
    }

    var negotiatedInputProtocolVersion: UInt16?
    var inputMessagesSent = 0
    var inputSendFailures = 0
    var controlSendFailures = 0
    var controlMessagesSent = 0
    /// Per-command counters for the `0x313` control-channel statistics report, keyed by command
    /// code. The official client aggregates the same figures in its `ControlStatsManager`.
    var controlCommandStats: [UInt16: ControlCommandCounters] = [:]

    struct ControlCommandCounters: Equatable, Sendable {
        var messagesSent: UInt64 = 0
        var messagesFailed: UInt64 = 0
        var aggregatedBytes: UInt64 = 0
    }

    var hostCandidateContinuation: CheckedContinuation<[String], Error>?
    /// SDP lines of the UDP host candidates gathered so far.
    var hostCandidates: [String] = []
    var gatheringComplete = false
    var inboundFeedbackBytes = 0
    var feedbackSendFailures = 0
    var inboundMessagesByLabel: [String: Int] = [:]
    var loggedInboundMessages = 0
    var iceStateDescription = "new"

    // The callbacks below are plain stored properties: assign every one of them before
    // `prepare()`, from one thread. They are invoked on libwebrtc's delegate thread.

    /// Fires when a `rtcp_on_sctp_private` channel opens, so the feedback sender can start.
    var onFeedbackChannelOpen: (@Sendable () -> Void)?

    /// Fires when the seat announces its remote-input protocol version.
    var onInputProtocolNegotiated: (@Sendable (UInt16) -> Void)?

    /// Fires when `control_channel_reliable` opens. The seat starts its 10 s client-timeout the
    /// moment the association is up, so the keepalive has to begin here rather than when video
    /// arrives.
    var onControlChannelOpen: (@Sendable () -> Void)?

    /// Fires when `control_channel_partially_reliable` opens, so QoS feedback can start.
    var onPartiallyReliableControlOpen: (@Sendable () -> Void)?

    /// The seat's periodic `0x0101` statistics: game render rate and its latency estimate.
    var onSeatStats: (@Sendable (NvstSeatStats) -> Void)?
    /// Rumble from the seat (`0x010b`), one call per command with every record it carried.
    var onHapticEvents: (@Sendable ([NvstHapticEvent]) -> Void)?
    var hapticCommandCount = 0
    var hapticEventCount = 0
    var hapticChangeCount = 0
    var lastHapticSignature = ""
    /// The seat's HDR mode notification (`0x010e`): the game's HDR state as a mode word.
    var onHdrMode: (@Sendable (NvstHdrModeNotification) -> Void)?
    /// The seat's termination notification (`0x0109`): the session is over by the seat's own
    /// decision, and the reason it gives is the only account of why.
    var onSeatTermination: (@Sendable (NvstSeatTermination) -> Void)?
    /// Fires with the running count each time the seat's audio receiver lands.
    var onRemoteAudio: (@Sendable (Int) -> Void)?
    /// Fires once when the association is lost for good: ICE or DTLS failed or closed, or the
    /// seat closed the control channel. Never fires for a close this client asked for.
    var onConnectionFailure: (@Sendable (String) -> Void)?

    init(handoff: NVSTVideoHandoff,
         factory: LKRTCPeerConnectionFactory,
         preferredLocalAddress: String? = NvstRoutedIPv4.discover(),
         logger: (@Sendable (String) -> Void)? = nil)
    {
        self.handoff = handoff
        self.factory = factory
        self.preferredLocalAddress = preferredLocalAddress
        self.logger = logger
        super.init()
    }
}
