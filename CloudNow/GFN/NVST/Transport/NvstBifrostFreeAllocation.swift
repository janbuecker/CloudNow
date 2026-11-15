import Foundation

// Reading the connect request: where the seat's RTSPS control endpoint is, the stream profile the
// request implies, and what the RTSP negotiator is asked for.

nonisolated enum NvstBifrostFreeProfile {
    struct StreamProfile: Equatable, Sendable {
        var resolution: String?
        var fps: Int?
        var codec: String?
        /// The initial and peak rate announced to the seat.
        var bitrateKbps: Int?
        /// The user's ceiling specifically. Announcing a cap that was really an initial rate would
        /// clamp the stream to its starting point, so the two stay separate.
        var maximumBitrateKbps: Int?
    }

    /// Upper bound on `initialBitrateKbps`. Exists only so a nonsense configured value cannot ask
    /// the seat for an absurd rate — normal ceilings (including 100 Mbps) pass through untouched.
    static let maximumInitialBitrateKbps = 150_000

    /// A 60 Hz display's frame interval, which is what the captured client reports.
    static let targetFrameTimeMicroseconds: UInt32 = 16000

    // MARK: - Endpoints

    /// The RTSPS control endpoints the session advertises, in the order the negotiator should try
    /// them. Empty means NVST cannot be negotiated for this session.
    ///
    /// Only the control endpoint is read from CloudMatch: an entry whose `resourcePath` is an
    /// `rtsps://` URL is taken verbatim; otherwise `usage == 16`, `appLevelProtocol == 6` or port
    /// 322 marks one, on the entry's own address or the session host. A fresh session also tries
    /// the default control port on the session host as a last resort; a resume does not, because
    /// a seat that has not finished the hand-over serves no RTSP there.
    static func rtspsEndpoints(for request: GFNNVSTConnectRequest) -> [String] {
        let connections: [[String: Any]] = request.endpoints.map { endpoint in
            var connection: [String: Any] = ["usage": endpoint.usage, "port": endpoint.port]
            if let ip = endpoint.ip {
                connection["ip"] = ip
            }
            if let resourcePath = endpoint.resourcePath {
                connection["resourcePath"] = resourcePath
            }
            if let appLevelProtocol = endpoint.appLevelProtocol {
                connection["appLevelProtocol"] = appLevelProtocol
            }
            return connection
        }
        return NvstRtspEndpoints.collect(
            connections: connections,
            fallbackHost: host(from: request.fallbackHost),
            allowsAssumedControlPort: !request.isResume
        )
    }

    /// `host:port` or bare host → host.
    static func host(from server: String) -> String? {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: ":").first.map(String.init)
    }

    // MARK: - Profile

    /// The stream profile this session negotiates with.
    static func streamProfile(for request: GFNNVSTConnectRequest) -> StreamProfile {
        var profile = StreamProfile()
        if request.width > 0, request.height > 0 {
            profile.resolution = "\(request.width)x\(request.height)"
        }
        if request.fps > 0 {
            profile.fps = request.fps
        }
        profile.codec = codecName(request.codec)
        if request.maxBitrateKbps > 0 {
            profile.maximumBitrateKbps = request.maxBitrateKbps
            // The INITIAL rate — not the ceiling — is what actually bounds throughput, because the
            // seat's congestion control never ramps up on this path: the stream settles at ~65% of
            // initialBitrateKbps (the announced relaxMaxBitrate.customAvgBitrateThresholdPercent:65)
            // no matter how high the ceiling is. So the initial rate has to BE the target, not a
            // cautious opening bid: ask for what the user configured.
            profile.bitrateKbps = min(request.maxBitrateKbps, maximumInitialBitrateKbps)
        }
        return profile
    }

    /// The codec name the negotiator parses (`NVSTVideoCodec.parse`) and announces as
    /// `x-nv-vqos[0].bitStreamFormat`.
    static func codecName(_ codec: GFNNVSTVideoCodec) -> String {
        switch codec {
        case .h264: "H264"
        case .h265: "H265"
        case .av1: "AV1"
        }
    }

    /// The session's colour tier (`8bit_420`, `10bit_420`, `8bit_444`, `10bit_444`), announced as
    /// `video[0].bitDepth` / `chromaFormat` so the ANNOUNCE agrees with what the session request
    /// asked for. Always supplied: leaving it out keeps the captured baseline's 10-bit 4:2:0.
    static func colorQuality(bitDepth: Int, chroma444: Bool) -> String {
        "\(bitDepth >= 10 ? "10bit" : "8bit")_\(chroma444 ? "444" : "420")"
    }

    /// What the RTSP negotiator is asked for: the resolved profile plus the client-side switches.
    /// Every switch is spelled out because the negotiation input's own defaults differ from what
    /// this transport needs.
    static func negotiationInput(for request: GFNNVSTConnectRequest,
                                 endpoints: [String],
                                 timeout: Duration) -> NvstRtspNegotiationInput
    {
        let profile = streamProfile(for: request)
        return NvstRtspNegotiationInput(
            sessionID: request.sessionId,
            rtspsEndpoints: endpoints,
            resolution: profile.resolution,
            fps: profile.fps,
            codec: profile.codec,
            bitrateKbps: profile.bitrateKbps,
            maximumBitrateKbps: profile.maximumBitrateKbps,
            // The session request asks CloudMatch for no server-side prefilter, so the announce
            // says the same instead of inheriting the captured baseline's sharpen/denoise.
            prefilterMode: 0,
            prefilterSharpness: nil,
            prefilterDenoise: nil,
            prefilterModel: nil,
            colorQuality: colorQuality(bitDepth: request.bitDepth, chroma444: request.chroma444),
            // The captured baseline always announces `dx9EnableHdr:1`; this makes the seat encode
            // HDR only when the session asked for it.
            isHDREnabled: request.hdrEnabled,
            // The captured client's value; it lets the seat pace the game's own frame rate.
            isCloudGsyncEnabled: true,
            audioChannelCount: NvstWebRtcBundle.audioChannelCount,
            timeout: timeout,
            // False keeps `general.rtcpOnSctp` out of the announce, as the working capture does;
            // the client still opens `rtcp_on_sctp_private` and reports on both planes.
            rtcpOnSctp: false,
            forcesLegacyPath: false,
            // The seat's one-way-delay rate control stays on (the vendor default): its evidence is
            // the `0x207` QoS report this transport sends at 18 Hz.
            disablesOwdCongestionControl: false,
            announcesExtendedSettings: false,
            // A larger ANNOUNCE echoing the seat's offer made the seat drop DTLS; keep it off.
            echoesOfferedAttributes: false,
            // Nil keeps the captured baseline, which is the Adaptive announce.
            vsyncMode: nil,
            announceOverrides: []
        )
    }

    // MARK: - Pacing

    /// The frame interval the pacer is told to aim for: the **session's** frame rate, not the
    /// client display's.
    static func sessionFrameTimeMicroseconds(fps: Int?) -> UInt32 {
        guard let fps, fps > 0 else { return targetFrameTimeMicroseconds }
        return UInt32(1_000_000 / fps)
    }

    /// The display's vsync interval the frame-pacing reports claim. The seat paces its own frame
    /// generation to whatever interval the client reports, so it has to describe the real screen.
    static func displayVsyncMicroseconds(maxRefreshRate: Int) -> UInt32 {
        maxRefreshRate > 0 ? UInt32(1_000_000 / maxRefreshRate) : targetFrameTimeMicroseconds
    }

    /// The link capability the `0x207` QoS report claims: at least as high as the configured
    /// ceiling (clamped to the field's UInt16 range) so the seat's rate controller ramps toward
    /// it. The captured default (12708) was a low-bandwidth session and pins the seat there.
    static func linkCapabilityKbps(maximumBitrateKbps: Int) -> UInt16 {
        UInt16(clamping: max(Int(NvstQosReport.defaultLinkCapabilityKbps), maximumBitrateKbps))
    }

    // MARK: - Negotiation outcome

    /// Why PLAY did not start the stream, read from the negotiator's step list; nil when PLAY was
    /// accepted, skipped at the seat's request, or answered 455 (which the seat treats as fine).
    /// The negotiator records these without throwing, so the transport has to look.
    static func playFailure(inSteps steps: [String]) -> String? {
        for step in steps {
            if step == "play-timeout" {
                return "The seat did not answer PLAY."
            }
            if step.hasPrefix("play-failed-") {
                return "The seat refused PLAY with status \(step.dropFirst("play-failed-".count))."
            }
        }
        return nil
    }
}
