import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import Synchronization

/// Maps CloudNow's GeForce NOW session and settings onto the experimental NVST transport request.
///
/// This is GFN-only policy: the Xbox provider never sees it.
nonisolated enum GFNNVSTRequestBuilder {
    /// Returns `nil` when the session advertises nothing the transport could negotiate with.
    static func makeRequest(
        session: SessionInfo,
        settings: StreamSettings,
        colorRequest: StreamColorRequest,
        displayMaxRefreshRate: Int
    ) -> GFNNVSTConnectRequest? {
        guard !session.nvstEndpoints.isEmpty, !session.serverIp.isEmpty else { return nil }
        let (width, height) = resolution(from: settings.resolution)
        return GFNNVSTConnectRequest(
            sessionId: session.sessionId,
            fallbackHost: session.serverIp,
            endpoints: session.nvstEndpoints,
            isResume: false,
            width: width,
            height: height,
            fps: settings.fps,
            maxBitrateKbps: settings.maxBitrateKbps,
            codec: codec(for: settings.codec),
            bitDepth: colorRequest.bitDepth >= 10 ? 10 : 8,
            chroma444: settings.effectiveChromaFormat == .yuv444,
            hdrEnabled: colorRequest.hdrRequested,
            displayMaxRefreshRate: max(displayMaxRefreshRate, settings.fps)
        )
    }

    static func resolution(from value: String) -> (width: Int, height: Int) {
        let parts = value.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return (1920, 1080)
        }
        return (width, height)
    }

    static func codec(for codec: VideoCodec) -> GFNNVSTVideoCodec {
        switch codec.resolvedCodec {
        case .h264: .h264
        case .av1: .av1
        default: .h265
        }
    }
}

/// Hands NVST-decoded pixel buffers to whichever video surface is currently bound.
///
/// The transport decodes off the main thread before a surface may exist, and the surface can be
/// rebuilt while a stream is live, so the sink is swapped under a lock instead of captured once.
final nonisolated class GFNNVSTFrameRelay: Sendable {
    typealias Sink = @Sendable (LKRTCVideoFrame) -> Void

    private let sink = Mutex<Sink?>(nil)

    func setSink(_ newSink: Sink?) {
        sink.withLock { $0 = newSink }
    }

    func deliver(_ pixelBuffer: CVPixelBuffer, rtpTimestamp: UInt32) {
        guard let sink = sink.withLock({ $0 }) else { return }
        // Same wrapping as the in-tree VideoToolbox decoders, so the surface's mailbox, pacing,
        // HDR inspection and diagnostics treat both transports identically.
        let frame = LKRTCVideoFrame(
            buffer: LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: 0
        )
        frame.timeStamp = Int32(bitPattern: rtpTimestamp)
        sink(frame)
    }
}

/// Counters for input handed to the NVST transport, mirroring the WebRTC input statistics.
nonisolated struct GFNNVSTInputCounters: Equatable, Sendable {
    var generated: UInt64 = 0
    var accepted: UInt64 = 0
    var dropped: UInt64 = 0
}

/// Routes `InputSender` packets to the NVST input channel.
///
/// Only gamepad reports are carried in this experimental version; the transport rejects
/// everything else, which is counted as dropped rather than queued.
final nonisolated class GFNNVSTInputChannel: DataChannelSender, Sendable {
    private let send: @Sendable (Data) -> Bool
    private let counters = Mutex(GFNNVSTInputCounters())

    init(send: @escaping @Sendable (Data) -> Bool) {
        self.send = send
    }

    func sendData(
        _ packet: EncodedInputPacket,
        completion: @escaping @Sendable (InputSendDisposition) -> Void
    ) {
        // The packet's storage is pooled and reused by the sender, so the report is copied out.
        let report = Data(bytes: packet.storage.bytes, count: packet.count)
        let accepted = send(report)
        counters.withLock { counters in
            counters.generated &+= 1
            if accepted {
                counters.accepted &+= 1
            } else {
                counters.dropped &+= 1
            }
        }
        completion(accepted ? .accepted : .rejected)
    }

    func snapshot() -> GFNNVSTInputCounters {
        counters.withLock { $0 }
    }
}

/// Interval values derived from two cumulative NVST statistics snapshots.
nonisolated struct GFNNVSTStatsDelta: Equatable, Sendable {
    var nacks: Int = 0
    var keyframeRequests: Int = 0
    var framesDropped: Int = 0
    var fecRecoveredPackets: Int = 0

    init(current: GFNNVSTStatsSnapshot, previous: GFNNVSTStatsSnapshot?) {
        guard let previous else { return }
        nacks = Self.interval(current.nacksSent, previous.nacksSent)
        keyframeRequests = Self.interval(current.keyframeRequests, previous.keyframeRequests)
        framesDropped = Self.interval(current.framesDropped, previous.framesDropped)
        fecRecoveredPackets = Self.interval(current.packetsRecoveredByFEC, previous.packetsRecoveredByFEC)
    }

    /// Counters restart when the transport is rebuilt; a smaller value is treated as a reset.
    static func interval(_ current: UInt64, _ previous: UInt64) -> Int {
        current >= previous ? Int(clamping: current - previous) : 0
    }
}
