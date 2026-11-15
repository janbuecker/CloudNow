@testable import CloudNow
import Foundation
import Testing

@Suite("GeForce NOW NVST request and glue")
struct GFNNVSTSupportTests {
    private static let rtspsEndpoint = GFNNVSTConnectionEndpoint(
        usage: 14,
        ip: "192.0.2.10",
        port: 322,
        resourcePath: "rtsps://192.0.2.10:322",
        appLevelProtocol: 6
    )

    @Test("A session without connection entries is not eligible for NVST")
    func missingEndpoints() {
        let request = GFNNVSTRequestBuilder.makeRequest(
            session: makeSession(endpoints: []),
            settings: StreamSettings(),
            colorRequest: colorRequest(.sdr8),
            displayMaxRefreshRate: 60
        )

        #expect(request == nil)
    }

    @Test("A session without a seat host is not eligible for NVST")
    func missingHost() {
        let request = GFNNVSTRequestBuilder.makeRequest(
            session: makeSession(endpoints: [Self.rtspsEndpoint], serverIp: ""),
            settings: StreamSettings(),
            colorRequest: colorRequest(.sdr8),
            displayMaxRefreshRate: 60
        )

        #expect(request == nil)
    }

    @Test("Stream settings map onto the NVST request")
    func requestMapping() throws {
        var settings = StreamSettings()
        settings.resolution = "3840x2160"
        settings.fps = 120
        settings.maxBitrateKbps = 75000
        settings.codec = .h265
        settings.chromaFormat = .yuv444

        let request = try #require(GFNNVSTRequestBuilder.makeRequest(
            session: makeSession(endpoints: [Self.rtspsEndpoint]),
            settings: settings,
            colorRequest: colorRequest(.hdr10),
            displayMaxRefreshRate: 60
        ))

        #expect(request.sessionId == "fixture-session")
        #expect(request.fallbackHost == "192.0.2.10")
        #expect(request.endpoints == [Self.rtspsEndpoint])
        #expect(!request.isResume)
        #expect(request.width == 3840)
        #expect(request.height == 2160)
        #expect(request.fps == 120)
        #expect(request.maxBitrateKbps == 75000)
        #expect(request.codec == .h265)
        #expect(request.bitDepth == 10)
        #expect(request.chroma444)
        #expect(request.hdrEnabled)
        // The seat is never told the display is slower than the requested stream.
        #expect(request.displayMaxRefreshRate == 120)
    }

    @Test("4:4:4 is only requested with H.265, matching the WebRTC path")
    func chromaRequiresH265() throws {
        var settings = StreamSettings()
        settings.codec = .av1
        settings.chromaFormat = .yuv444

        let request = try #require(GFNNVSTRequestBuilder.makeRequest(
            session: makeSession(endpoints: [Self.rtspsEndpoint]),
            settings: settings,
            colorRequest: colorRequest(.sdr8),
            displayMaxRefreshRate: 120
        ))

        #expect(request.codec == .av1)
        #expect(!request.chroma444)
        #expect(request.bitDepth == 8)
        #expect(!request.hdrEnabled)
    }

    @Test(
        "Codec preferences resolve to an NVST codec",
        arguments: [
            (VideoCodec.automatic, GFNNVSTVideoCodec.h265),
            (.h264, .h264),
            (.h265, .h265),
            (.av1, .av1),
        ]
    )
    func codecMapping(preference: VideoCodec, expected: GFNNVSTVideoCodec) {
        #expect(GFNNVSTRequestBuilder.codec(for: preference) == expected)
    }

    @Test(
        "Resolution strings parse with a 1080p fallback",
        arguments: [
            ("1920x1080", 1920, 1080),
            ("3840x2160", 3840, 2160),
            ("", 1920, 1080),
            ("wide", 1920, 1080),
            ("0x0", 1920, 1080),
            ("1280x720x2", 1920, 1080),
        ]
    )
    func resolutionParsing(value: String, width: Int, height: Int) {
        let parsed = GFNNVSTRequestBuilder.resolution(from: value)

        #expect(parsed.width == width)
        #expect(parsed.height == height)
    }

    @Test("The input channel copies each report and counts the transport's answer")
    func inputChannelCounters() {
        let accepted = Recorder()
        let channel = GFNNVSTInputChannel { report in
            accepted.append(report)
            return report.first == 1
        }
        let dispositions = DispositionRecorder()

        for firstByte in [UInt8(1), 2, 1] {
            let packet = EncodedInputPacket()
            let bytes = packet.prepare(length: 4)
            bytes[0] = firstByte
            channel.sendData(packet) { dispositions.append($0) }
            // Reusing the pooled storage must not change what was already handed over.
            bytes[0] = 0xFF
        }

        #expect(accepted.values == [Data([1, 0, 0, 0]), Data([2, 0, 0, 0]), Data([1, 0, 0, 0])])
        #expect(dispositions.values == [.accepted, .rejected, .accepted])
        #expect(channel.snapshot() == GFNNVSTInputCounters(generated: 3, accepted: 2, dropped: 1))
    }

    @Test("Interval statistics come from cumulative counters")
    func statsDelta() {
        var previous = GFNNVSTStatsSnapshot()
        previous.nacksSent = 10
        previous.keyframeRequests = 1
        previous.framesDropped = 4
        previous.packetsRecoveredByFEC = 100
        var current = previous
        current.nacksSent = 13
        current.keyframeRequests = 2
        current.framesDropped = 4
        current.packetsRecoveredByFEC = 180

        let delta = GFNNVSTStatsDelta(current: current, previous: previous)

        #expect(delta.nacks == 3)
        #expect(delta.keyframeRequests == 1)
        #expect(delta.framesDropped == 0)
        #expect(delta.fecRecoveredPackets == 80)
    }

    @Test("The first sample and a counter reset report no interval")
    func statsDeltaEdges() {
        var current = GFNNVSTStatsSnapshot()
        current.nacksSent = 5
        var larger = current
        larger.nacksSent = 9

        #expect(GFNNVSTStatsDelta(current: current, previous: nil).nacks == 0)
        #expect(GFNNVSTStatsDelta(current: current, previous: larger).nacks == 0)
        #expect(GFNNVSTStatsDelta.interval(.max, 0) == Int.max)
    }

    private func colorRequest(_ mode: StreamColorMode) -> StreamColorRequest {
        StreamColorRequest(
            mode: mode,
            bitDepth: mode.bitDepth,
            hdrRequested: mode == .hdr10,
            chromaFormat: nil,
            displayCapabilities: nil
        )
    }

    private func makeSession(
        endpoints: [GFNNVSTConnectionEndpoint],
        serverIp: String = "192.0.2.10"
    ) -> SessionInfo {
        SessionInfo(
            sessionId: "fixture-session",
            status: 2,
            zone: "https://zone.fixture.invalid",
            streamingBaseUrl: "https://stream.fixture.invalid",
            serverIp: serverIp,
            signalingServer: "\(serverIp):443",
            signalingUrl: "wss://\(serverIp)/nvst/",
            gpuType: "fixture",
            queuePosition: nil,
            seatSetupStep: nil,
            seatSetupEtaMs: nil,
            iceServers: [],
            mediaConnectionInfo: nil,
            clientId: "fixture-client",
            deviceId: "fixture-device",
            adState: nil,
            nvstEndpoints: endpoints
        )
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ value: Data) {
        lock.withLock { storage.append(value) }
    }
}

private final class DispositionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InputSendDisposition] = []

    var values: [InputSendDisposition] {
        lock.withLock { storage }
    }

    func append(_ value: InputSendDisposition) {
        lock.withLock { storage.append(value) }
    }
}
