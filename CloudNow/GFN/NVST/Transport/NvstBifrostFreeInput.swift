import Dispatch
import Foundation

// Input activation, the gamepad state path and the periodic performance snapshot.

extension NvstBifrostFreeTransport {
    // MARK: - Input activation

    /// The official client reports its window and system state once, shortly after PLAY, with
    /// zeros. Nothing else in our session tells the seat the client is present and in focus, and a
    /// seat that gates remote input on focus would ignore every packet until it hears this.
    func announceClientState() {
        guard phase != .tornDown, let bundle, !didAnnounceClientState else { return }
        didAnnounceClientState = true
        let window = bundle.sendControl(.windowStateChange())
        let system = bundle.sendControl(.systemStateChange())
        logger?("NVST client state announced (window=\(window) system=\(system))")
    }

    func inputDidNegotiate(_ version: UInt16) {
        // No input heartbeat: the captured official client sends none.
        logger?("NVST input negotiated at protocol version \(version); ready=\(bundle?.isInputReady == true)")
        activateInputIfReady()
    }

    /// Runs the activation chain once both halves are in place: the seat's protocol version and
    /// an open control channel to send the chain on.
    func activateInputIfReady() {
        guard phase != .tornDown, let bundle, bundle.isInputReady else { return }
        activateInput()
    }

    /// Sends the device descriptor and enable that the native stack puts between the seat's
    /// handshake and its first input event. Remote-input packets that match the native stack's
    /// byte for byte are ignored by the seat until this chain has run.
    func activateInput() {
        guard let bundle, !didActivateInput else { return }
        didActivateInput = true
        // The native stack's order, which is not the same as sending the same messages in any
        // order: the enable goes out clear first, the descriptor and ready follow, then the window
        // and system state, and the enable is only set afterwards. The seat answers the tail of
        // this chain with gamepad-handling and cursor-info.
        var sent: [String] = []
        sent.append("enableOff=\(bundle.sendControl(NvstInputActivation.enableInput(counter: 1, isEnabled: false)))")
        // ONE device descriptor, whose bitmap names every connected pad. The official client sends
        // a single `0x20d` whose descriptor index equals the device index its state packets carry;
        // announcing a second descriptor at a different index registers a phantom pad, and the
        // game then listens to the wrong one. Pad 0 is what the captured client announces here;
        // the gamepad path re-announces the bitmap when the set of connected pads changes.
        let activationBitmap = NvstGamepadPacket.connectedBitmap
        sent.append("descriptor=\(bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: sessionElapsedMicroseconds(), connectedBitmap: activationBitmap)))")
        // Cursor capture and remote cursor tracking, exactly as the captured chain sends them.
        // This client draws no pointer of its own, so capture is never turned back off: the seat
        // keeps compositing its pointer into the video, and its cursor notifications go unread.
        sent.append("cursorCapture=\(bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: true)))")
        sent.append("cursorTrack=\(bundle.sendControl(NvstInputActivation.mimicRemoteCursor(isEnabled: true)))")
        sent.append("window=\(bundle.sendControl(.windowStateChange()))")
        sent.append("system=\(bundle.sendControl(.systemStateChange()))")
        sent.append("enableOn=\(bundle.sendControl(NvstInputActivation.enableInput(counter: UInt32((videoPipeline?.snapshot.frameAcksSent ?? 0) + 1))))")
        // Haptics on. The seat sends no `0x010b` rumble until the client has enabled the feature
        // with RI type 13 (`RiClientBackend::enableHaptics`); the official client sends it whenever
        // a rumble-capable pad is present. Always on here: a pad without motors just never gets a
        // command it could act on, and the seat otherwise stays silent for every pad.
        sent.append("haptics=\(sendFramedRemoteInput(NvstRemoteInput.hapticsState(enabled: true)))")
        logger?("NVST input activation sent (\(sent.joined(separator: " ")))")
        // From here on gamepad state is accepted, under the bitmap the descriptor just announced.
        gamepadInput.activate(bundle: bundle, registeredBitmap: activationBitmap)
        onInputReady?()
    }

    /// Frames one remote-input packet in the session's timestamp envelope and writes it to the
    /// control channel as command `0x206`. Microseconds since the session began, not since the
    /// epoch: the captured client sends ~25.9 s into a 26 s session, and an epoch timestamp is
    /// ~1.7e15 — a seat that sanity-checks it against session time discards the packet.
    @discardableResult
    func sendFramedRemoteInput(_ packet: Data) -> Bool {
        guard let bundle, bundle.isInputReady else { return false }
        inputSequence &+= 1
        let framed = NvstRemoteInput.framed(packet,
                                            framing: .enveloped,
                                            sequence: inputSequence,
                                            timestampMicroseconds: sessionElapsedMicroseconds())
        let accepted = bundle.sendControl(NvstControlCommand(code: NvstRemoteInput.commandCode, payload: framed))
        if accepted {
            inputEventsSent += 1
        }
        return accepted
    }

    // MARK: - Performance

    /// Feeds the statistics HUD from the receive path's own counters, about once a second.
    ///
    /// `streamFramesPerSecond` and the other rates cover the interval since the previous call,
    /// not the session: an average would mask a real stall late in a long session.
    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard phase == .connected, let receiver, sessionStartedAt != nil else { return nil }
        // The only suspension points, taken before any counter is read so one snapshot describes
        // one instant.
        let audio = await bundle?.audioReception()
        var controlRoundTrip = -1.0
        if let session {
            controlRoundTrip = await session.controlRoundTripMilliseconds()
        }
        guard phase == .connected else { return nil }

        let stats = receiver.stats
        let video = videoPipeline?.snapshot ?? NvstVideoPipeline.Counters()
        let framesDecoded = decoder?.decodedFrameCount ?? 0
        let rates = performanceSampler.advance(to: NvstPerformanceSampler.Sample(
            uptimeSeconds: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000,
            framesDecoded: framesDecoded,
            bytesReceived: stats.bytesReceived,
            packetsReceived: stats.authenticatedPackets,
            packetsLost: UInt64(stats.lastCumulativeLost),
            framesHandled: video.framesHandled,
            totalDecodeMilliseconds: video.total.decode,
            audioJitterBufferDelaySeconds: audio?.jitterBufferDelaySeconds,
            audioJitterBufferEmitted: audio?.jitterBufferEmitted
        ))

        // ICE candidate-pair RTT is the preferred latency source, but this seat never answers
        // libwebrtc's connectivity checks, so it is normally -1. Fallbacks, most direct first: the
        // Mjolnir socket's own STUN round trip on the media path (measured only if the seat
        // answers, which it may not), then the control connection's keepalive turnaround, which
        // the seat answers for the whole session.
        let latency = Self.firstAvailableRoundTrip([
            bundle?.roundTripMilliseconds ?? -1,
            receiver.roundTripMilliseconds,
            controlRoundTrip,
        ])

        var snapshot = NativeNVSTPerformanceSnapshot()
        snapshot.available = stats.framesEmitted > 0
        // The seat's own 0x0101 statistics carry the game render rate.
        snapshot.gameFramesPerSecond = latestSeatStats?.gameFramesPerSecond ?? -1
        snapshot.streamFramesPerSecond = rates.framesPerSecond
        snapshot.latencyMilliseconds = latency
        snapshot.jitterMilliseconds = Double(stats.lastJitter) * 1000 / Double(NvstVideoToolboxDecoder.clockRate)
        snapshot.packetLossPercent = rates.packetLossPercent
        snapshot.decodeMilliseconds = rates.decodeMilliseconds
        snapshot.decodeP99Milliseconds = video.framesHandled > 0 ? video.decodeP99Milliseconds : -1
        snapshot.bitrateMegabitsPerSecond = rates.megabitsPerSecond
        // What the decoder actually produced, falling back to the negotiated string until the
        // first frame lands. A seat that ignored the requested geometry shows up here.
        snapshot.resolution = decoder?.decodedResolution ?? negotiatedResolution ?? ""
        snapshot.codec = negotiatedCodec ?? lastHandoff.map(\.codec.rawValue) ?? ""
        snapshot.negotiatedFramesPerSecond = negotiatedFps.map(Double.init) ?? -1
        snapshot.decoderIsHardware = decoder?.isHardwareAccelerated ?? true
        snapshot.bitstreamFormat = decoder?.bitstreamFormat?.summary ?? ""
        snapshot.decoderOutputFormat = decoder?.outputPixelFormatName ?? ""
        snapshot.audioJitterBufferMilliseconds = rates.audioJitterBufferMilliseconds
        snapshot.packetsReceived = stats.authenticatedPackets
        snapshot.packetsLost = UInt64(stats.lastCumulativeLost)
        snapshot.packetsRecoveredByFEC = stats.recoveredPackets
        // Retransmissions are asked for over the control channel first and by SRTCP NACK as the
        // fallback; a request that fell back is in both tallies, so the larger one is reported.
        snapshot.retransmissionRequestsSent = max(stats.retransmissionRequestsSent, UInt64(max(0, receiver.nackSummary.requests)))
        snapshot.keyframeRequestsSent = UInt64(idrRequestsSent)
        snapshot.framesDecoded = framesDecoded
        snapshot.framesDropped = stats.abandonedFrames
            + UInt64(max(0, video.missingParameterSetFrames))
            + UInt64(max(0, video.framesSkippedForLatency))
            + (decoder?.failedFrameCount ?? 0)
        snapshot.audioPacketsReceived = audio?.packets ?? 0
        snapshot.audioConcealedSamples = audio?.concealed ?? 0
        return snapshot
    }

    /// The first non-negative sample, or -1 when no source has one.
    static func firstAvailableRoundTrip(_ candidates: [Double]) -> Double {
        candidates.first { $0 >= 0 && $0.isFinite } ?? -1
    }
}

// MARK: - Gamepad state

/// One gamepad state report as CloudNow's `InputEncoder.encodeGamepad` produces it, decoded back
/// into its fields.
///
/// Two layouts are accepted, because the encoder emits either depending on its protocol version:
/// - the bare 38-byte event (protocol version 2);
/// - the same event behind the 16-byte partially-reliable wrapper, 54 bytes (protocol version 3):
///   `0x23, u64 BE timestamp, 0x26, pad, u16 BE sequence, 0x21, u16 BE 38`.
///
/// The event itself is `u32 LE 12, u16 LE 26, u16 LE pad, u16 LE bitmap, u16 LE 20,
/// u16 LE buttons, u8 LT, u8 RT, 4 × i16 LE sticks, …, u64 LE timestamp at +30`. The timestamps
/// and the wrapper's sequence are discarded: the encoder stamps microseconds since the epoch and
/// counts from its own start, while the seat expects microseconds since the NVST session began
/// and a per-pad sequence starting at 1.
nonisolated struct NvstGamepadReport: Equatable, Sendable {
    static let eventLength = 38
    static let wrapperLength = 16
    static let wrappedLength = wrapperLength + eventLength
    /// `GeronimoInputEventType.gamepad` as the event's leading u32.
    static let gamepadEventType: UInt32 = 12
    static let gamepadEventSize: UInt16 = 26

    var gamepadIndex: UInt16
    var connectedBitmap: UInt16
    var buttons: UInt16
    var leftTrigger: UInt8
    var rightTrigger: UInt8
    var leftStickX: Int16
    var leftStickY: Int16
    var rightStickX: Int16
    var rightStickY: Int16

    /// Nil for anything that is not a gamepad state report: heartbeats, keyboard, mouse, haptics
    /// enable, Sony HID reports, or a truncated buffer.
    init?(report: Data) {
        let bytes = [UInt8](report)
        let event: ArraySlice<UInt8>
        switch bytes.count {
        case Self.eventLength:
            event = bytes[...]
        case Self.wrappedLength:
            guard bytes[0] == GeronimoInputEnvelope.headerByte,
                  bytes[9] == GeronimoInputEnvelope.partiallyReliablePayloadTag,
                  bytes[13] == GeronimoInputEnvelope.lengthPrefixedPayloadTag,
                  Int(bytes[14]) << 8 | Int(bytes[15]) == Self.eventLength else { return nil }
            event = bytes[Self.wrapperLength...]
        default:
            return nil
        }
        let base = event.startIndex
        func u16(_ offset: Int) -> UInt16 {
            UInt16(event[base + offset]) | UInt16(event[base + offset + 1]) << 8
        }
        let type = UInt32(u16(0)) | UInt32(u16(2)) << 16
        guard type == Self.gamepadEventType, u16(4) == Self.gamepadEventSize else { return nil }
        let index = u16(6)
        guard index < 4 else { return nil }
        gamepadIndex = index
        connectedBitmap = u16(8)
        buttons = u16(12)
        leftTrigger = event[base + 14]
        rightTrigger = event[base + 15]
        leftStickX = Int16(bitPattern: u16(16))
        leftStickY = Int16(bitPattern: u16(18))
        rightStickX = Int16(bitPattern: u16(20))
        rightStickY = Int16(bitPattern: u16(22))
    }

    /// Whether the report's own bitmap still lists the pad it describes. A report that does not
    /// is the neutral state CloudNow sends for a pad that has just disconnected.
    var listsOwnPad: Bool {
        connectedBitmap & (UInt16(1) << gamepadIndex) != 0
    }

    /// The bitmap to announce for this report: the seat is never told about zero devices, so an
    /// empty set falls back to pad 0, which the activation chain announced.
    var announcedBitmap: UInt16 {
        connectedBitmap == 0 ? NvstGamepadPacket.connectedBitmap : connectedBitmap
    }

    /// The NVST state packet for this report.
    func packet(sequence: UInt16, timestampMicroseconds: UInt64, connectedBitmap: UInt16) -> NvstGamepadPacket {
        NvstGamepadPacket(
            sequence: sequence,
            timestampMicroseconds: timestampMicroseconds,
            buttons: buttons,
            leftTrigger: leftTrigger,
            rightTrigger: rightTrigger,
            leftStickX: leftStickX,
            leftStickY: leftStickY,
            rightStickX: rightStickX,
            rightStickY: rightStickY,
            gamepadIndex: gamepadIndex,
            connectedBitmap: connectedBitmap
        )
    }

    /// The bytes written to `input_channel_partially_reliable`: the 4-byte NVST command header
    /// (`0x020d`, length 54) followed by the wrapped event.
    func encodedCommand(sequence: UInt16, timestampMicroseconds: UInt64, connectedBitmap: UInt16) -> Data? {
        try? packet(sequence: sequence, timestampMicroseconds: timestampMicroseconds, connectedBitmap: connectedBitmap)
            .command.encoded
    }
}

/// The gamepad state path, deliberately off the transport actor: reports arrive at controller
/// cadence from the input queue and must not wait behind QoS, keepalives or statistics.
///
/// Gamepad state is its own command on the input channel (SCTP stream 10), matching the official
/// client's captured traffic. The `0x20d` device descriptor on the control channel must carry the
/// same connected bitmap as every state packet, so it is re-sent here whenever the bitmap in the
/// reports changes.
final nonisolated class NvstGamepadInput: @unchecked Sendable {
    struct Counters: Equatable, Sendable {
        var sent = 0
        var failed = 0
        /// Reports that were not gamepad state, or named a pad the seat was never told about.
        var rejected = 0
        var registrations = 0
    }

    private let lock = NSLock()
    private let clock: NvstSessionClock
    private var bundle: NvstWebRtcBundle?
    /// Every pad the seat has been told about, as the u16 it was told. Nil until activation.
    private var registeredBitmap: UInt16?
    /// One counter per pad: the wrapper's sequence is per-gamepad on the wire.
    private var sequences: [UInt16: UInt16] = [:]
    private var tallies = Counters()

    init(clock: NvstSessionClock) {
        self.clock = clock
    }

    /// Opens the path once the activation chain has announced `registeredBitmap` to the seat.
    func activate(bundle: NvstWebRtcBundle, registeredBitmap: UInt16) {
        lock.lock()
        self.bundle = bundle
        self.registeredBitmap = registeredBitmap
        sequences.removeAll()
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        bundle = nil
        registeredBitmap = nil
        sequences.removeAll()
        lock.unlock()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bundle != nil
    }

    var counters: Counters {
        lock.lock()
        defer { lock.unlock() }
        return tallies
    }

    /// Sends one CloudNow gamepad report. False when input is not active, the bytes are not a
    /// gamepad report, or the channel refused the write. Callable from any thread; reports are
    /// serialized so sequence numbers and descriptor updates reach the seat in order.
    func send(report data: Data) -> Bool {
        guard let report = NvstGamepadReport(report: data) else {
            lock.withLock { tallies.rejected += 1 }
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard let bundle, let registered = registeredBitmap, bundle.isInputReady else { return false }

        guard report.listsOwnPad else {
            // A pad that has just disconnected: CloudNow sends its neutral state with the pad
            // already gone from the bitmap. The seat only accepts state for pads it still knows,
            // so the neutral state goes out under the bitmap it was last told, and the narrowed
            // bitmap is announced afterwards — re-sending the descriptor without the pad is the
            // disconnect.
            guard registered & (UInt16(1) << report.gamepadIndex) != 0 else {
                tallies.rejected += 1
                return false
            }
            let delivered = sendState(report, bitmap: registered, bundle: bundle)
            let remaining = report.announcedBitmap
            if remaining != registered {
                register(bitmap: remaining, bundle: bundle)
            }
            // A pad that leaves must not keep its counter: a slot reused later would resume
            // mid-stream and its first packets would look stale.
            if remaining & (UInt16(1) << report.gamepadIndex) == 0 {
                sequences[report.gamepadIndex] = nil
            }
            return delivered
        }

        if registered != report.connectedBitmap {
            register(bitmap: report.connectedBitmap, bundle: bundle)
        }
        return sendState(report, bitmap: report.connectedBitmap, bundle: bundle)
    }

    /// Call with `lock` held.
    private func sendState(_ report: NvstGamepadReport, bitmap: UInt16, bundle: NvstWebRtcBundle) -> Bool {
        let sequence = (sequences[report.gamepadIndex] ?? 0) &+ 1
        sequences[report.gamepadIndex] = sequence
        let delivered = report
            .encodedCommand(sequence: sequence, timestampMicroseconds: clock.elapsedMicroseconds(), connectedBitmap: bitmap)
            .map(bundle.sendInput) ?? false
        if delivered {
            tallies.sent += 1
        } else {
            tallies.failed += 1
        }
        return delivered
    }

    /// Sends the `0x20d` device descriptor and records what the seat was told. Recorded even when
    /// the write fails, so a failed announce is not retried on every state packet. Call with
    /// `lock` held.
    private func register(bitmap: UInt16, bundle: NvstWebRtcBundle) {
        _ = bundle.sendControl(NvstInputActivation.deviceDescriptor(
            timestampMicroseconds: clock.elapsedMicroseconds(),
            connectedBitmap: bitmap
        ))
        registeredBitmap = bitmap
        tallies.registrations += 1
    }
}
