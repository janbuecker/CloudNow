import Foundation

/// What the native NVST transport reports about itself about once a second: delivered video,
/// network health and the cumulative counters behind them.
nonisolated struct NativeNVSTPerformanceSnapshot: Equatable, Sendable {
    /// False until the receiver has assembled its first frame.
    var available = false
    /// The seat's own game render rate (`0x0101`); -1 until the seat has reported one.
    var gameFramesPerSecond = -1.0
    /// Decoded frames per second over the last poll interval, not the session average: the
    /// watchdog and the HUD both want "now", and an average would mask a stall late in a session.
    var streamFramesPerSecond = 0.0
    /// Network round trip in milliseconds; -1 when no source has produced a sample yet.
    var latencyMilliseconds = -1.0
    var jitterMilliseconds = 0.0
    /// Loss over the last poll interval: lost / (received + lost), in percent.
    var packetLossPercent = 0.0
    /// Mean client-side decode cost per frame over the last poll interval; -1 when no frame was
    /// handled in it.
    var decodeMilliseconds = -1.0
    /// The slowest 1% of decodes in roughly the last 256 frames; -1 when unavailable.
    var decodeP99Milliseconds = -1.0
    var bitrateMegabitsPerSecond = 0.0
    /// What the decoder actually produced, falling back to the negotiated string until the first
    /// frame lands. A seat that ignored the requested geometry shows up here.
    var resolution = ""
    var codec = ""
    /// The frame rate the session negotiated; -1 when unknown.
    var negotiatedFramesPerSecond = -1.0
    /// Whether VideoToolbox is actually decoding in hardware.
    var decoderIsHardware = true
    /// What the bitstream declares (`10-bit 4:2:0`) and the surface the decoder emits (`xf20`).
    var bitstreamFormat = ""
    var decoderOutputFormat = ""
    /// Mean time audio spent in libwebrtc's jitter buffer over the last poll interval, ms; -1
    /// when unknown.
    var audioJitterBufferMilliseconds = -1.0

    // Cumulative counters since connect.
    var packetsReceived: UInt64 = 0
    var packetsLost: UInt64 = 0
    var packetsRecoveredByFEC: UInt64 = 0
    var retransmissionRequestsSent: UInt64 = 0
    var keyframeRequestsSent: UInt64 = 0
    var framesDecoded: UInt64 = 0
    /// Frames that never reached the screen: abandoned in reassembly, rejected by the decoder,
    /// skipped to catch up, or delivered before the first keyframe.
    var framesDropped: UInt64 = 0
    var audioPacketsReceived: UInt64 = 0
    var audioConcealedSamples: UInt64 = 0
}

nonisolated struct NativeNVSTTerminationValue: Equatable, Sendable {
    let code: Int32
    let name: String?

    init(code: Int32, name: String? = nil) {
        self.code = code
        self.name = name
    }
}

nonisolated struct NativeNVSTTerminationReason: Equatable, Sendable {
    /// The control plane's word for a `0x0109` termination whose session survives and can be
    /// resumed.
    static let sessionPause: UInt32 = NvstSeatTermination.sessionPauseResult

    let rawValue: UInt32
    let resultName: String?

    init(rawValue: UInt32, resultName: String? = nil) {
        self.rawValue = rawValue
        self.resultName = resultName
    }

    var isPause: Bool {
        rawValue == Self.sessionPause
    }
}

nonisolated struct NativeNVSTSessionTermination: Equatable, Sendable {
    let reason: NativeNVSTTerminationReason
    let extendedResult: NativeNVSTTerminationValue
    let isResumable: Bool
    let isSessionAlive: Bool
    let message: String

    /// A paused session is not an ended session: the cloud session survives and can be resumed.
    var isPause: Bool {
        reason.isPause
    }
}

nonisolated extension NvstSeatTermination {
    /// The transport's view of the seat's verdict. Only a pause leaves the session resumable and
    /// alive; every other result is the seat ending the session.
    var sessionTermination: NativeNVSTSessionTermination {
        let name = resultName
        return NativeNVSTSessionTermination(
            reason: NativeNVSTTerminationReason(rawValue: result, resultName: name),
            extendedResult: NativeNVSTTerminationValue(code: Int32(bitPattern: result), name: name),
            isResumable: isSessionPause,
            isSessionAlive: isSessionPause,
            message: isSessionPause
                ? "Native NVST stream paused by the cloud server."
                : "The cloud server ended the session: \(NvstResultCode.describe(result))"
        )
    }
}

nonisolated struct NativeNVSTTransportFailure: Equatable, Sendable {
    enum RecoveryClassification: Equatable, Sendable {
        case transientNetwork
        case permanent
    }

    /// Which plane gave up, so a caller can tell a dead bundle from a dead video socket.
    enum Origin: Equatable, Sendable {
        /// The raw-SRTP video socket or the decoder behind it.
        case video
        /// The libwebrtc ICE/DTLS/SCTP bundle.
        case bundle
        /// The RTSPS control connection.
        case control
    }

    let message: String
    let origin: Origin
    let recoveryClassification: RecoveryClassification
}

nonisolated enum NativeNVSTTransportTermination: Equatable, Sendable {
    case sessionTerminated(NativeNVSTSessionTermination)
    case transportFailed(NativeNVSTTransportFailure)
}

nonisolated enum NativeNVSTError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    /// The session advertised no RTSPS control endpoint.
    case missingControlEndpoint(String)
    /// The ICE/DTLS/SCTP bundle could not be brought up; the seat gates media on it.
    case bundleFailed(String)
    case transportFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Native NVST stream is already running."
        case .notRunning:
            "Native NVST stream is not running."
        case let .missingControlEndpoint(message), let .bundleFailed(message), let .transportFailed(message):
            message
        }
    }
}
