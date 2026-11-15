import CoreVideo
import Foundation

/// One RTSPS-capable endpoint advertised by CloudMatch for the session.
nonisolated struct GFNNVSTConnectionEndpoint: Equatable, Sendable {
    var usage: Int
    var ip: String?
    var port: Int
    var resourcePath: String?
    var appLevelProtocol: Int?
}

nonisolated enum GFNNVSTVideoCodec: String, Sendable { case h264, h265, av1 }

nonisolated struct GFNNVSTConnectRequest: Equatable, Sendable {
    var sessionId: String
    /// Host of the seat, used when an endpoint carries no usable address.
    var fallbackHost: String
    var endpoints: [GFNNVSTConnectionEndpoint]
    var isResume: Bool
    var width: Int
    var height: Int
    var fps: Int
    var maxBitrateKbps: Int
    var codec: GFNNVSTVideoCodec
    /// 8 or 10.
    var bitDepth: Int
    var chroma444: Bool
    var hdrEnabled: Bool
    var displayMaxRefreshRate: Int
}

nonisolated struct GFNNVSTStatsSnapshot: Equatable, Sendable {
    // Delivered video.
    var framesPerSecond: Double = 0
    var bitrateKbps: Int = 0
    var width: Int = 0
    var height: Int = 0
    var codec: String = ""
    /// 0 when unknown.
    var roundTripMs: Double = 0
    var jitterMs: Double = 0
    /// Over the last sampling interval.
    var packetLossPercent: Double = 0
    /// Mean over the last sampling interval.
    var decodeTimeMs: Double = 0
    // Cumulative counters since connect.
    var packetsReceived: UInt64 = 0
    var packetsLost: UInt64 = 0
    var packetsRecoveredByFEC: UInt64 = 0
    var nacksSent: UInt64 = 0
    var keyframeRequests: UInt64 = 0
    var framesDecoded: UInt64 = 0
    /// Incomplete or undecodable frames.
    var framesDropped: UInt64 = 0
    /// From the seat's own statistics when available, else 0.
    var gameFps: Double = 0
    // Audio, from the bundle's inbound-rtp statistics.
    var audioPacketsReceived: UInt64 = 0
    var audioConcealedSamples: UInt64 = 0
    var audioJitterBufferMs: Double = 0
}

nonisolated enum GFNNVSTEvent: Sendable {
    /// The seat ended the session; `code` is the NVST result code, `name` its symbolic name when known.
    case sessionTerminated(code: UInt32, name: String?)
    /// The transport cannot continue (decode failure storm, bundle/ICE failure, no video).
    case failed(message: String)
    /// Rumble for `playerIndex`; motors are 0...65535.
    case haptics(playerIndex: Int, leftMotor: UInt16, rightMotor: UInt16, durationMs: Int?)
    case hdrModeChanged(enabled: Bool)
    case inputReady
}

nonisolated enum GFNNVSTError: Error, Equatable, Sendable {
    case noRTSPEndpoint
    case negotiationFailed(String)
    case bundleFailed(String)
    case firstFrameTimeout
    case cancelled
}

/// Sink for decoded frames, called off the main thread at stream cadence.
/// `rtpTimestamp` is the frame's 90 kHz RTP timestamp.
typealias GFNNVSTFrameSink = @Sendable (_ pixelBuffer: CVPixelBuffer, _ rtpTimestamp: UInt32, _ isKeyframe: Bool) -> Void

// MARK: - Mapping between the facade and the ported transport

nonisolated extension GFNNVSTEvent {
    /// One seat rumble record as a facade event. A state record (kind 1) carries no duration and
    /// is held until the next record for that pad; a pulse (kind 2) carries one, with the seat's
    /// 1000 ms default applied when it says zero.
    static func rumble(from event: NvstHapticEvent) -> GFNNVSTEvent {
        .haptics(
            playerIndex: Int(event.gamepadIndex),
            leftMotor: event.leftMotor,
            rightMotor: event.rightMotor,
            durationMs: event.durationMilliseconds == nil ? nil : Int(event.effectiveDurationMilliseconds)
        )
    }

    /// The seat's `0x0109` verdict as a facade event, with the result code's symbolic name.
    static func seatTermination(from termination: NativeNVSTSessionTermination) -> GFNNVSTEvent {
        .sessionTerminated(code: termination.reason.rawValue, name: termination.reason.resultName)
    }

    /// What a terminal report from the transport means to the facade's consumer.
    static func terminal(from termination: NativeNVSTTransportTermination) -> GFNNVSTEvent {
        switch termination {
        case let .sessionTerminated(session): .seatTermination(from: session)
        case let .transportFailed(failure): .failed(message: failure.message)
        }
    }
}

nonisolated extension GFNNVSTError {
    /// What a terminal report means when it lands before `connect()` has returned.
    init(duringConnect termination: NativeNVSTTransportTermination) {
        switch termination {
        case let .sessionTerminated(session):
            self = .negotiationFailed(session.message)
        case let .transportFailed(failure):
            self = failure.origin == .bundle ? .bundleFailed(failure.message) : .negotiationFailed(failure.message)
        }
    }

    /// The facade error for whatever the transport's `connect` threw.
    init(connectFailure error: any Error) {
        if let known = error as? GFNNVSTError {
            self = known
            return
        }
        if error is CancellationError {
            self = .cancelled
            return
        }
        switch error as? NativeNVSTError {
        case .missingControlEndpoint:
            self = .noRTSPEndpoint
        case let .bundleFailed(message):
            self = .bundleFailed(message)
        case let .transportFailed(message):
            self = .negotiationFailed(message)
        case .alreadyRunning, .notRunning, nil:
            self = .negotiationFailed(error.localizedDescription)
        }
    }
}

nonisolated extension GFNNVSTStatsSnapshot {
    /// The facade's view of one transport performance snapshot. Unknown values (-1 in the
    /// transport) read as 0 here.
    init(_ snapshot: NativeNVSTPerformanceSnapshot) {
        let size = Self.dimensions(fromResolution: snapshot.resolution)
        self.init(
            framesPerSecond: max(0, snapshot.streamFramesPerSecond),
            bitrateKbps: Int((max(0, snapshot.bitrateMegabitsPerSecond) * 1000).rounded()),
            width: size.width,
            height: size.height,
            codec: snapshot.codec,
            roundTripMs: max(0, snapshot.latencyMilliseconds),
            jitterMs: max(0, snapshot.jitterMilliseconds),
            packetLossPercent: max(0, snapshot.packetLossPercent),
            decodeTimeMs: max(0, snapshot.decodeMilliseconds),
            packetsReceived: snapshot.packetsReceived,
            packetsLost: snapshot.packetsLost,
            packetsRecoveredByFEC: snapshot.packetsRecoveredByFEC,
            nacksSent: snapshot.retransmissionRequestsSent,
            keyframeRequests: snapshot.keyframeRequestsSent,
            framesDecoded: snapshot.framesDecoded,
            framesDropped: snapshot.framesDropped,
            gameFps: max(0, snapshot.gameFramesPerSecond),
            audioPacketsReceived: snapshot.audioPacketsReceived,
            audioConcealedSamples: snapshot.audioConcealedSamples,
            audioJitterBufferMs: max(0, snapshot.audioJitterBufferMilliseconds)
        )
    }

    /// `"WxH"` → its two numbers; anything else is 0x0.
    static func dimensions(fromResolution resolution: String) -> (width: Int, height: Int) {
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return (0, 0)
        }
        return (width, height)
    }
}
