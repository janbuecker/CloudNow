@testable import CloudNow
import Foundation
import Testing

@Suite("NVST connect request mapping")
struct NvstBifrostFreeProfileTests {
    static func request(
        endpoints: [GFNNVSTConnectionEndpoint] = [
            GFNNVSTConnectionEndpoint(usage: 14, ip: "203.0.113.10", port: 322, resourcePath: "rtsps://203.0.113.10:322", appLevelProtocol: 6),
        ],
        fallbackHost: String = "seat.example.invalid",
        isResume: Bool = false,
        width: Int = 3840,
        height: Int = 2160,
        fps: Int = 120,
        maxBitrateKbps: Int = 75000,
        codec: GFNNVSTVideoCodec = .h265,
        bitDepth: Int = 10,
        chroma444: Bool = false,
        hdrEnabled: Bool = true,
        displayMaxRefreshRate: Int = 120
    ) -> GFNNVSTConnectRequest {
        GFNNVSTConnectRequest(
            sessionId: "session-1",
            fallbackHost: fallbackHost,
            endpoints: endpoints,
            isResume: isResume,
            width: width,
            height: height,
            fps: fps,
            maxBitrateKbps: maxBitrateKbps,
            codec: codec,
            bitDepth: bitDepth,
            chroma444: chroma444,
            hdrEnabled: hdrEnabled,
            displayMaxRefreshRate: displayMaxRefreshRate
        )
    }

    // MARK: Endpoint selection

    @Test("An rtsps resource path is taken verbatim, ahead of everything else")
    func resourcePathEndpoint() {
        let request = Self.request(endpoints: [
            GFNNVSTConnectionEndpoint(usage: 2, ip: "203.0.113.11", port: 49005, resourcePath: nil, appLevelProtocol: nil),
            GFNNVSTConnectionEndpoint(usage: 14, ip: "203.0.113.10", port: 322, resourcePath: "rtsps://203.0.113.10:322", appLevelProtocol: nil),
        ])
        #expect(NvstBifrostFreeProfile.rtspsEndpoints(for: request).first == "rtsps://203.0.113.10:322")
    }

    @Test("A tagged entry without a resource path is synthesized from its address and port")
    func taggedEndpoint() {
        let byUsage = Self.request(endpoints: [
            GFNNVSTConnectionEndpoint(usage: 16, ip: "203.0.113.12", port: 322, resourcePath: nil, appLevelProtocol: nil),
        ])
        #expect(NvstBifrostFreeProfile.rtspsEndpoints(for: byUsage).first == "rtsps://203.0.113.12:322")
        let byProtocol = Self.request(endpoints: [
            GFNNVSTConnectionEndpoint(usage: 14, ip: "203.0.113.13", port: 322, resourcePath: "/nvst/", appLevelProtocol: 6),
        ])
        #expect(NvstBifrostFreeProfile.rtspsEndpoints(for: byProtocol).first == "rtsps://203.0.113.13:322")
    }

    @Test("An entry with no usable address falls back to the seat host")
    func fallbackHostEndpoint() {
        for ip in [nil, "", "0.0.0.0"] as [String?] {
            let request = Self.request(
                endpoints: [GFNNVSTConnectionEndpoint(usage: 16, ip: ip, port: 322, resourcePath: nil, appLevelProtocol: nil)],
                fallbackHost: "seat.example.invalid:443"
            )
            #expect(NvstBifrostFreeProfile.rtspsEndpoints(for: request) == ["rtsps://seat.example.invalid:322"])
        }
    }

    @Test("Control endpoints on port 322 are preferred over tagged entries on other ports")
    func endpointOrdering() {
        let request = Self.request(endpoints: [
            GFNNVSTConnectionEndpoint(usage: 16, ip: "203.0.113.20", port: 48010, resourcePath: nil, appLevelProtocol: nil),
            GFNNVSTConnectionEndpoint(usage: 14, ip: "203.0.113.21", port: 322, resourcePath: nil, appLevelProtocol: nil),
            GFNNVSTConnectionEndpoint(usage: 16, ip: "203.0.113.22", port: 322, resourcePath: nil, appLevelProtocol: nil),
        ], fallbackHost: "")
        #expect(NvstBifrostFreeProfile.rtspsEndpoints(for: request) == [
            "rtsps://203.0.113.22:322",
            "rtsps://203.0.113.21:322",
            "rtsps://203.0.113.20:48010",
        ])
    }

    @Test("A fresh session assumes the default control port; a resume does not")
    func assumedControlPort() {
        let webRTCOnly = [GFNNVSTConnectionEndpoint(usage: 14, ip: "203.0.113.10", port: 443, resourcePath: "/nvst/", appLevelProtocol: nil)]
        let fresh = Self.request(endpoints: webRTCOnly, isResume: false)
        #expect(NvstBifrostFreeProfile.rtspsEndpoints(for: fresh) == ["rtsps://seat.example.invalid:322"])
        // A session created by a WebRTC client advertises no :322 until the seat has re-provisioned
        // for NVST, and guessing it reaches a host that does not serve RTSP.
        let resume = Self.request(endpoints: webRTCOnly, isResume: true)
        #expect(NvstBifrostFreeProfile.rtspsEndpoints(for: resume).isEmpty)
        #expect(NvstBifrostFreeProfile.rtspsEndpoints(for: Self.request(endpoints: [], fallbackHost: "", isResume: false)).isEmpty)
    }

    @Test("The session host is read with or without a port")
    func hostParsing() {
        #expect(NvstBifrostFreeProfile.host(from: "seat.example.invalid:443") == "seat.example.invalid")
        #expect(NvstBifrostFreeProfile.host(from: " 203.0.113.10 ") == "203.0.113.10")
        #expect(NvstBifrostFreeProfile.host(from: "   ") == nil)
    }

    // MARK: Negotiation input

    @Test("The request's resolution, frame rate and bitrate reach the negotiator")
    func negotiationInputProfile() {
        let endpoints = ["rtsps://203.0.113.10:322"]
        let input = NvstBifrostFreeProfile.negotiationInput(for: Self.request(), endpoints: endpoints, timeout: .seconds(7))
        #expect(input.sessionID == "session-1")
        #expect(input.rtspsEndpoints == endpoints)
        #expect(input.resolution == "3840x2160")
        #expect(input.fps == 120)
        #expect(input.codec == "H265")
        // The initial rate is the target: the seat settles at a fraction of it and never ramps.
        #expect(input.bitrateKbps == 75000)
        #expect(input.maximumBitrateKbps == 75000)
        #expect(input.timeout == .seconds(7))
        #expect(input.audioChannelCount == 2)
    }

    @Test("The client-side switches are spelled out rather than left to the input's defaults")
    func negotiationInputSwitches() {
        let input = NvstBifrostFreeProfile.negotiationInput(for: Self.request(), endpoints: ["rtsps://203.0.113.10:322"], timeout: .seconds(20))
        #expect(!input.rtcpOnSctp)
        #expect(!input.forcesLegacyPath)
        // The seat's one-way-delay rate control stays on.
        #expect(!input.disablesOwdCongestionControl)
        #expect(!input.announcesExtendedSettings)
        #expect(!input.echoesOfferedAttributes)
        #expect(input.vsyncMode == nil)
        #expect(input.announceOverrides.isEmpty)
        #expect(input.prefilterMode == 0)
        #expect(input.prefilterModel == nil)
        #expect(input.prefilterSharpness == nil)
        #expect(input.prefilterDenoise == nil)
        #expect(input.isCloudGsyncEnabled)
    }

    @Test(
        "Each codec is announced under the name the negotiator parses",
        arguments: [
            (GFNNVSTVideoCodec.h264, "H264", NVSTVideoCodec.h264),
            (.h265, "H265", .hevc),
            (.av1, "AV1", .av1),
        ]
    )
    func codecMapping(codec: GFNNVSTVideoCodec, name: String, parsed: NVSTVideoCodec) {
        let input = NvstBifrostFreeProfile.negotiationInput(for: Self.request(codec: codec), endpoints: ["rtsps://203.0.113.10:322"], timeout: .seconds(20))
        #expect(input.codec == name)
        #expect(NVSTVideoCodec.parse(name) == parsed)
    }

    @Test(
        "Bit depth and chroma become the announced colour tier",
        arguments: [
            (8, false, "8bit_420"),
            (10, false, "10bit_420"),
            (8, true, "8bit_444"),
            (10, true, "10bit_444"),
        ]
    )
    func colorQuality(bitDepth: Int, chroma444: Bool, expected: String) {
        let request = Self.request(bitDepth: bitDepth, chroma444: chroma444)
        let input = NvstBifrostFreeProfile.negotiationInput(for: request, endpoints: ["rtsps://203.0.113.10:322"], timeout: .seconds(20))
        #expect(input.colorQuality == expected)
        // The announce builder must understand the tier, or the captured baseline's 10-bit 4:2:0
        // would silently stand in for it.
        let format = NvstRtspSdp.colorFormat(forColorQuality: expected)
        #expect(format.bitDepth == bitDepth)
        #expect(format.chromaFormat == (chroma444 ? 3 : 1))
    }

    @Test("HDR is announced only when the session asked for it", arguments: [true, false])
    func hdrFlag(enabled: Bool) {
        let input = NvstBifrostFreeProfile.negotiationInput(for: Self.request(hdrEnabled: enabled), endpoints: ["rtsps://203.0.113.10:322"], timeout: .seconds(20))
        #expect(input.isHDREnabled == enabled)
    }

    @Test("A nonsense bitrate ceiling is clamped for the initial rate only")
    func bitrateClamp() {
        let profile = NvstBifrostFreeProfile.streamProfile(for: Self.request(maxBitrateKbps: 500_000))
        #expect(profile.maximumBitrateKbps == 500_000)
        #expect(profile.bitrateKbps == NvstBifrostFreeProfile.maximumInitialBitrateKbps)
        let normal = NvstBifrostFreeProfile.streamProfile(for: Self.request(maxBitrateKbps: 100_000))
        #expect(normal.bitrateKbps == 100_000)
    }

    @Test("Missing values leave the announce defaults in place")
    func emptyProfile() {
        let profile = NvstBifrostFreeProfile.streamProfile(for: Self.request(width: 0, height: 0, fps: 0, maxBitrateKbps: 0))
        #expect(profile.resolution == nil)
        #expect(profile.fps == nil)
        #expect(profile.bitrateKbps == nil)
        #expect(profile.maximumBitrateKbps == nil)
        #expect(profile.codec == "H265")
    }

    // MARK: Pacing

    @Test("Pacing follows the session frame rate and the display refresh rate")
    func pacingIntervals() {
        #expect(NvstBifrostFreeProfile.sessionFrameTimeMicroseconds(fps: 120) == 8333)
        #expect(NvstBifrostFreeProfile.sessionFrameTimeMicroseconds(fps: 60) == 16666)
        #expect(NvstBifrostFreeProfile.sessionFrameTimeMicroseconds(fps: nil) == 16000)
        #expect(NvstBifrostFreeProfile.sessionFrameTimeMicroseconds(fps: 0) == 16000)
        #expect(NvstBifrostFreeProfile.displayVsyncMicroseconds(maxRefreshRate: 60) == 16666)
        #expect(NvstBifrostFreeProfile.displayVsyncMicroseconds(maxRefreshRate: 120) == 8333)
        #expect(NvstBifrostFreeProfile.displayVsyncMicroseconds(maxRefreshRate: 0) == 16000)
    }

    @Test("The reported link capability follows the ceiling within the field's range")
    func linkCapability() {
        #expect(NvstBifrostFreeProfile.linkCapabilityKbps(maximumBitrateKbps: 0) == NvstQosReport.defaultLinkCapabilityKbps)
        #expect(NvstBifrostFreeProfile.linkCapabilityKbps(maximumBitrateKbps: 50000) == 50000)
        #expect(NvstBifrostFreeProfile.linkCapabilityKbps(maximumBitrateKbps: 100_000) == UInt16.max)
    }

    // MARK: Negotiation outcome

    @Test("A refused or unanswered PLAY is a failure; accepted, skipped and 455 are not")
    func playOutcome() {
        let prefix = ["wss-open", "options", "describe", "setup-video", "native-receive-armed", "announce", "native-announce-armed"]
        #expect(NvstBifrostFreeProfile.playFailure(inSteps: prefix + ["play"]) == nil)
        #expect(NvstBifrostFreeProfile.playFailure(inSteps: prefix + ["play-skipped"]) == nil)
        #expect(NvstBifrostFreeProfile.playFailure(inSteps: prefix + ["play-455"]) == nil)
        #expect(NvstBifrostFreeProfile.playFailure(inSteps: prefix + ["play-failed-500"])?.contains("500") == true)
        #expect(NvstBifrostFreeProfile.playFailure(inSteps: prefix + ["play-timeout"]) != nil)
        #expect(NvstBifrostFreeProfile.playFailure(inSteps: []) == nil)
    }
}
