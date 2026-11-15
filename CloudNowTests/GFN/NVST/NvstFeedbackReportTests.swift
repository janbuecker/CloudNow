@testable import CloudNow
import Foundation
import Testing

private func bytes(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index ..< next], radix: 16)!)
        index = next
    }
    return data
}

private func word(_ payload: Data, _ offset: Int) -> UInt32 {
    payload[offset ..< (offset + 4)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
}

private func half(_ payload: Data, _ offset: Int) -> UInt16 {
    UInt16(payload[offset]) | UInt16(payload[offset + 1]) << 8
}

struct NvstFeedbackReportTests {
    /// The whole point of replacing the software GHASH was speed, so the replacement has to agree
    /// with it bit for bit. This recomputes GCM's tag the slow, explicit way — GHASH over the AAD
    /// and ciphertext, XORed with E(K, J0) — and holds the hardware path to it.
    @Test func hardwareGcmTagAgreesWithTheSoftwareGhash() throws {
        let key = Data((0 ..< 32).map { UInt8($0 &* 7 &+ 3) })
        let iv = Data((0 ..< 12).map { UInt8($0 &* 5 &+ 1) })
        let aad = Data((0 ..< 32).map { UInt8($0 &* 3) })
        let plaintext = Data((0 ..< 1200).map { UInt8($0 % 251) })

        let cipher = try SrtpGcm8(key: key)
        let sealed = try cipher.seal(iv: iv, aad: aad, plaintext: plaintext, tagLength: 8)
        let ciphertext = sealed.prefix(plaintext.count)
        let tag = sealed.suffix(8)

        let h = try SrtpCryptor.blockEncrypt(key: key, block: Data(repeating: 0, count: 16))
        let s0 = try SrtpCryptor.blockEncrypt(key: key, block: SrtpGcm8.j0(iv: iv))
        let ghash = [UInt8](GHash.hash(key: h, aad: aad, ciphertext: Data(ciphertext)))
        let s0Bytes = [UInt8](s0)
        let expected = Data((0 ..< 8).map { ghash[$0] ^ s0Bytes[$0] })

        #expect(tag == expected)
        // And the pair round-trips, which is what the receive path actually relies on.
        #expect(try cipher.decrypt(iv: iv, aad: aad, ciphertext: Data(ciphertext), authenticationTag: Data(tag)) == plaintext)
    }

    @Test func aTamperedTagStillFailsAuthentication() throws {
        let key = Data((0 ..< 32).map { UInt8($0) })
        let iv = Data(repeating: 9, count: 12)
        let aad = Data(repeating: 4, count: 32)
        let cipher = try SrtpGcm8(key: key)
        let sealed = try cipher.seal(iv: iv, aad: aad, plaintext: Data(repeating: 1, count: 64), tagLength: 8)
        var tag = Data(sealed.suffix(8))
        tag[0] ^= 0x01
        #expect(throws: SrtpCryptoError.authenticationFailed) {
            _ = try cipher.decrypt(iv: iv, aad: aad, ciphertext: sealed.prefix(64), authenticationTag: tag)
        }
    }

    /// Byte-exact against a captured `0x203` from the native stack — a ~75 fps session
    /// (`target` at `+24` = 13338 us = 1_000_000/74.98).
    @Test func theFramePacingReportMatchesTheCapturedBytes() {
        let captured = bytes("05000000000000000200000001000000803e0000803e00001a340000")
        let report = NvstFramePacingReport(
            frameNumber: 1,
            targetFrameTimeMicroseconds: 13338,
            measuredFrameTimeMicroseconds: 16000,
            displayVsyncMicroseconds: 16000, // the capture's `+16`
            groupCount: 2
        )
        #expect(report.payload == captured)
        #expect(report.command.code == 0x203)
    }

    /// Byte-exact against a captured `0x203` from a second, later session (2026-08-28, 5120x2160
    /// @120, real gameplay) — confirms `+16` stays 16000 regardless of negotiated fps while `+24`
    /// tracks it (8333 us = 1_000_000/120.01), and `+20` carries the raw unclamped measured value.
    @Test func theFramePacingReportMatchesA120fpsCapturedSample() {
        let captured = bytes("05000000000000000700000012000000803e00007a5e00008d200000")
        let report = NvstFramePacingReport(
            frameNumber: 18,
            targetFrameTimeMicroseconds: 8333,
            measuredFrameTimeMicroseconds: 24186,
            displayVsyncMicroseconds: 16000, // `+16` stays 16000 regardless of negotiated fps
            groupCount: 7
        )
        #expect(report.payload == captured)
    }

    /// The captured `0x207` reports are all exactly 52 bytes, and every field this models sits
    /// where the capture puts it.
    ///
    /// `+48` is deliberately not asserted against the sample: it tracks the cumulative byte count
    /// to within ~80 bytes across the capture, but its first five samples echo the timestamp
    /// instead, so no single sample is reproducible.
    ///
    /// `+20`, `+24` and `+44` are asserted for placement rather than against the sample. They
    /// carry per-report delay and rate estimates, so the captured values belong to the captured
    /// session; what has to stay true is that our measurements land on those offsets, because
    /// sending zeros there is what left the seat's delay-based controller with no evidence.
    @Test func theQosReportMatchesTheCapturedLayout() {
        let captured = bytes("070000000000000006000000020000004" + "8bc0300" + "000000003d0000000000e803e803a43132c01b000000000000000000fabb0300")
        let report = NvstQosReport(
            sequence: 6,
            framesReceived: 2,
            bytesReceived: 244_808,
            linkCapabilityKbps: 12708,
            rtpTimestamp: 1_818_674,
            previousBytesReceived: 244_808,
            isWarmedUp: false
        )
        let payload = report.payload
        #expect(payload.count == 52)
        #expect(captured.count == 52)
        for offset in [0, 4, 8, 12, 16, 36, 40] {
            #expect(word(payload, offset) == word(captured, offset), "word at +\(offset)")
        }
        for offset in [28, 30, 32, 34] {
            #expect(half(payload, offset) == half(captured, offset), "half at +\(offset)")
        }
        #expect(word(payload, 0) == 7)
        #expect(report.command.code == 0x207)
    }

    /// The delay and rate samples reach the offsets the seat reads them from. Sent as zero the
    /// whole time this client has existed, which reads as a path with no measurable delay and no
    /// measurable throughput — while the vendored client, on the same seat, holds a steady 120 fps
    /// against our 91.
    @Test func theQosReportCarriesItsDelayAndRateSamples() {
        let report = NvstQosReport(
            sequence: 9,
            framesReceived: 120,
            bytesReceived: 2_000_000,
            linkCapabilityKbps: UInt16(clamping: 100_000),
            rtpTimestamp: 90000,
            previousBytesReceived: 1_900_000,
            delayMicroseconds: 174,
            delayTrendMicroseconds: 59,
            intervalBits: 48000,
            isWarmedUp: true
        )
        let payload = report.payload
        #expect(word(payload, 20) == 174)
        #expect(word(payload, 24) == 59)
        #expect(word(payload, 44) == 48000)
        #expect(half(payload, 34) == UInt16.max)
        // The two byte counters must differ, or a controller differencing them reads zero
        // throughput no matter what the link is carrying.
        #expect(word(payload, 16) != word(payload, 48))
        // +40 is zero in every captured report.
        #expect(word(payload, 40) == 0)
    }

    /// The per-frame report is 102 bytes with the frame counter, size and cadence at the offsets
    /// the capture uses, and the pacing target must describe the display rather than the rate
    /// frames happen to be arriving at.
    @Test func theFrameAckPlacesItsFieldsWhereTheCapturePutsThem() {
        let ack = NvstFrameAck(
            frameNumber: 42,
            clientTimeMilliseconds: 20320.16,
            frameBytes: 15168,
            interFrameMicroseconds: 16667,
            stageMilliseconds: [4.5]
        )
        let payload = ack.payload
        #expect(payload.count == 102)
        #expect(half(payload, 0) == 1)
        #expect(half(payload, 2) == 9)
        #expect(word(payload, 4) == 42)
        #expect(word(payload, 8) == 0)
        #expect(payload[12 ..< 20].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } == 20320.16.bitPattern)
        #expect(Float(bitPattern: word(payload, 48)) == -1)
        #expect(word(payload, 72) == 15168)
        #expect(word(payload, 84) == 16384)
        #expect(word(payload, 96) == 16667)
        #expect(half(payload, 100) == 0)
        // A single measured latency fills all five rising stage marks rather than claiming a stage
        // took no time at all.
        for index in 0 ..< 5 {
            #expect(Float(bitPattern: word(payload, 28 + index * 4)) == 4.5)
        }
        #expect(ack.command.code == 0x204)
    }
}

struct NvstInputActivationTests {
    /// Byte-exact against the `0x20d` the native stack sends before its first input event. The
    /// prefix is `0x23` followed by the session clock in microseconds, big-endian, which is the
    /// same "versioned" prefix the remote-input path uses.
    @Test func theDeviceDescriptorMatchesTheCapturedBytes() {
        let captured = bytes("23000000000132bc31220c0000001a000000020014000000000000000000000000000000550000000000000000000000")
        let command = NvstInputActivation.deviceDescriptor(timestampMicroseconds: 20_102_193, connectedBitmap: 2)
        #expect(command.payload == captured)
        #expect(command.code == 0x20D)
        #expect(captured.count == 48)

        // The bitmap is a u16, so the XInput-style bit lands in the byte after it — and the
        // descriptor must carry exactly what the state packet carries, or the seat registers one
        // kind of device and then receives updates for another.
        let xinput = NvstInputActivation.deviceDescriptor(timestampMicroseconds: 1, connectedBitmap: 0x0101).payload
        #expect([UInt8](xinput)[9 + 9] == 0x01)
        #expect([UInt8](xinput)[9 + 10] == 0x01)
    }

    /// The teardown message differs from the pre-input one only in this field, which is what makes
    /// it a parameter rather than part of the captured body.
    @Test func theConnectedBitmapIsTheOnlyFieldThatMovesBetweenSamples() {
        let preInput = NvstInputActivation.deviceDescriptor(timestampMicroseconds: 49_628_349, connectedBitmap: 2).payload
        let teardown = NvstInputActivation.deviceDescriptor(timestampMicroseconds: 49_628_349, connectedBitmap: 1).payload
        #expect(preInput.count == teardown.count)
        #expect(zip(preInput, teardown).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset) == [9 + 9])
        #expect(teardown == bytes("230000000002f544bd220c0000001a000000010014000000000000000000000000000000550000000000000000000000"))
    }

    /// Both captured `0x20b` forms: the enable clear early in the chain, and set immediately before
    /// input starts.
    @Test func theEnableMatchesBothCapturedForms() {
        #expect(NvstInputActivation.enableInput(counter: 1, isEnabled: false).payload == bytes("000000000100000000000000"))
        #expect(NvstInputActivation.enableInput(counter: 122).payload == bytes("000000007a00000001000000"))
        #expect(NvstInputActivation.enableInput(counter: 124).payload == bytes("000000007c00000001000000"))
        #expect(NvstInputActivation.enableInput(counter: 1).code == 0x20B)
    }

    /// `0x308` is mouse cursor capture, not a "ready" ping. Sending it as a zero byte told the seat
    /// to stop compositing its cursor while we kept drawing our own.
    @Test func theCursorCommandsCarryTheirBooleanPayload() {
        #expect(NvstInputActivation.mouseCursorCapture(isEnabled: true).code == 0x308)
        #expect(NvstInputActivation.mouseCursorCapture(isEnabled: true).payload == Data([1]))
        #expect(NvstInputActivation.mouseCursorCapture(isEnabled: false).payload == Data([0]))
        #expect(NvstInputActivation.mimicRemoteCursor(isEnabled: true).code == 0x30D)
        #expect(NvstInputActivation.mimicRemoteCursor(isEnabled: true).payload == Data([1]))
    }

    /// Three little-endian words: stream index, state, frame number. The active window state is 19;
    /// writing it into the first word left the session looking inactive and stopped the seat from
    /// publishing cursor mode updates.
    @Test func theWindowStateAnnouncesTheActiveStateInTheSecondWord() {
        #expect(NvstControlCommand.windowStateChange().payload == bytes("000000001300000000000000"))
        #expect(NvstControlCommand.windowStateChange().code == 0x320)
        #expect(NvstControlCommand.systemStateChange().payload == bytes("000000000000000000000000"))
    }

    /// The mouse encoding, held against a real captured event so a refactor cannot drift it. This
    /// is a +24/+24 relative move stamped 23.181032 s into the session.
    @Test func aMouseMoveMatchesTheCapturedInputEvent() {
        let captured = bytes("000000240e0000000000000a0700000000180018000000000000000000000000e8ba610100000000")
        let framed = NvstRemoteInput.framed(
            NvstRemoteInput.mouseMove(deltaX: 24, deltaY: 24),
            framing: .enveloped,
            sequence: 0,
            timestampMicroseconds: 23_182_056
        )
        #expect(framed == captured)
    }

    @Test func aLeftButtonPressAndReleaseMatchTheCapturedEvents() {
        let press = NvstRemoteInput.framed(
            NvstRemoteInput.mouseButton(.left, isPressed: true),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 23_184_218
        )
        let release = NvstRemoteInput.framed(
            NvstRemoteInput.mouseButton(.left, isPressed: false),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 23_184_327
        )
        #expect(press == bytes("000000240e0000000000000608000000010000000000000000000000000000005ac3610100000000"))
        #expect(release == bytes("000000240e000000000000060900000001000000000000000000000000000000c7c3610100000000"))
    }
}

struct NvstKeyboardAndGamepadTests {
    /// Byte-exact against a captured key-down and key-up of `A` from the native stack.
    @Test func aKeyDownAndUpMatchTheCapturedEvents() {
        let timestamp: UInt64 = 0x0000_0000_015B_15B1
        let down = NvstRemoteInput.framed(
            NvstRemoteInput.keyboard(virtualKey: 0x41, isPressed: true),
            framing: .enveloped, sequence: 0, timestampMicroseconds: timestamp
        )
        #expect(down.count == 48)
        // Inner type 3 is key down; the body is the virtual key big-endian.
        #expect(down[12] == 3)
        #expect(down[16] == 0x00 && down[17] == 0x41)
        let up = NvstRemoteInput.framed(
            NvstRemoteInput.keyboard(virtualKey: 0x41, isPressed: false),
            framing: .enveloped, sequence: 0, timestampMicroseconds: timestamp
        )
        #expect(up[12] == 4)
        // A key packet is 48 bytes: the 22-byte inner, zero padding out to the timestamp's slot,
        // and the single little-endian microsecond timestamp in the last 8 bytes. Earlier reads
        // of the captures mistook the stable padding for a second timestamp; `SendPacket` writes
        // one clock value, and the padding region is stale buffer content the official client
        // does not zero.
        #expect(up.count == 48)
        #expect(Array(up[30 ..< 40]) == Array(repeating: 0, count: 10))
        #expect(Array(up[40 ..< 48]) == withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })
    }

    /// The individual fields, so a regression names the field it broke rather than dumping 54 bytes.
    /// Offsets are into the 38-byte `GeronimoInputEventType.gamepad` event, which the envelope puts
    /// at payload offset 16.
    @Test func gamepadPacketMatchesTheCapturedStructure() {
        func event(_ p: NvstGamepadPacket) -> [UInt8] {
            Array(p.payload.dropFirst(16))
        }
        func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
            UInt16(b[o]) | UInt16(b[o + 1]) << 8
        }

        let a = event(NvstGamepadPacket(sequence: 1, timestampMicroseconds: 0, buttons: NvstGamepadPacket.Button.a))
        #expect(a.count == NvstGamepadPacket.eventLength)
        #expect(u16(a, 0) == 12) // GeronimoInputEventType.gamepad
        #expect(u16(a, 4) == 26) // raw-gamepad-data tag from initializeRawGamepadData
        #expect(u16(a, 6) == 0) // gamepad id; handleGamepadStateEvent rejects >= 4
        // event[8..10] is the CONNECTED BITMAP as a u16 (updateGamepadsBitmap writes a u16):
        // bit i = gamepad i connected, bit (i+8) = that pad is XInput-style. 0x0101 = one pad on
        // slot 0, XInput. (3 announced gamepads 0 AND 1 — one controller became two in the game.)
        #expect(u16(a, 8) == 0x0101)
        #expect(u16(a, 10) == 20)
        #expect(u16(a, 26) == 0x55) // marker
        #expect(u16(a, 12) == 0x1000) // A button

        let start = event(NvstGamepadPacket(sequence: 8, timestampMicroseconds: 0, buttons: NvstGamepadPacket.Button.start))
        #expect(u16(start, 12) == 0x0010)

        let lx = event(NvstGamepadPacket(sequence: 2, timestampMicroseconds: 0, buttons: 0, leftStickX: NvstGamepadPacket.axis(0.5)))
        #expect(Int16(bitPattern: u16(lx, 16)) == 16384) // left stick X
        #expect(u16(lx, 12) == 0) // no buttons
        #expect(u16(lx, 26) == 0x55) // axis write did not clobber the marker

        // Both triggers share one u16: left low, right high.
        let tr = event(NvstGamepadPacket(sequence: 7, timestampMicroseconds: 0, buttons: 0,
                                         leftTrigger: 0x12, rightTrigger: NvstGamepadPacket.trigger(1)))
        #expect(u16(tr, 14) == 0xFF12)

        // The per-packet timestamp is one u64 LE at 30 and never overwrites the marker.
        let ts = event(NvstGamepadPacket(sequence: 3, timestampMicroseconds: 0x1122_3344, buttons: 0))
        #expect(u16(ts, 26) == 0x55)
        let stamp = (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(ts[30 + $1]) << UInt64($1 * 8) }
        #expect(stamp == 0x1122_3344)
        let big = event(NvstGamepadPacket(sequence: 4, timestampMicroseconds: 0x0000_00AA_BBCC_DDEE, buttons: 0))
        let bigStamp = (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(big[30 + $1]) << UInt64($1 * 8) }
        #expect(bigStamp == 0x0000_00AA_BBCC_DDEE)
    }

    /// The envelope itself: `[0x23][u64 BE][0x26][index][u16 BE seq][0x21][u16 BE 38]`. The two
    /// length bytes and the `0x21` tag are exactly what the old 52-byte packet was missing.
    @Test func gamepadPacketCarriesTheLengthPrefixedPartiallyReliableEnvelope() {
        let packet = NvstGamepadPacket(sequence: 0x0102, timestampMicroseconds: 0, buttons: 0).payload
        let bytes = Array(packet)
        #expect(bytes.count == 54)
        #expect(bytes[0] == GeronimoInputEnvelope.headerByte)
        #expect(bytes[9] == GeronimoInputEnvelope.partiallyReliablePayloadTag)
        #expect(bytes[10] == 0) // gamepad index
        #expect(bytes[11] == 0x01 && bytes[12] == 0x02) // sequence, big-endian u16
        #expect(bytes[13] == GeronimoInputEnvelope.lengthPrefixedPayloadTag)
        #expect(bytes[14] == 0x00 && bytes[15] == 38) // payload length, big-endian
    }

    /// The axis and trigger scalings the capture pins down: 0.5, 0.25 and -0.75 land on exactly
    /// `value * 32768`, and the triggers on `value * 255`.
    @Test func axesAndTriggersUseTheCapturedScaling() {
        #expect(NvstGamepadPacket.axis(0.5) == 16384)
        #expect(NvstGamepadPacket.axis(0.25) == 8192)
        #expect(NvstGamepadPacket.axis(-0.75) == -24576)
        #expect(NvstGamepadPacket.axis(1) == 32767)
        #expect(NvstGamepadPacket.axis(-1) == -32768)
        #expect(NvstGamepadPacket.trigger(0.5) == 128)
        #expect(NvstGamepadPacket.trigger(1) == 255)
        #expect(NvstGamepadPacket.trigger(0) == 0)
    }
}

struct NvstAbsolutePointerAndWheelTests {
    /// Byte-exact against a captured absolute move. The declared viewport is the stream view's own
    /// content frame: this sample was produced by asking for (1920, 1080), which the view clamped
    /// to its 1632x688 frame before sending.
    @Test func anAbsoluteMoveMatchesTheCapturedEvent() {
        let framed = NvstRemoteInput.framed(
            NvstRemoteInput.absoluteMouseMove(x: 1631, y: 687, viewportWidth: 1632, viewportHeight: 688),
            framing: .enveloped,
            sequence: 0,
            timestampMicroseconds: 0x0000_0000_0167_B3D6
        )
        #expect(framed.count == 48)
        // Compared up to the padding only: the capture's padding carries stale buffer content.
        #expect(framed.map { String(format: "%02x", $0) }.joined().hasPrefix(
            "0000002c0e0000000000000e05000000065f02af0800066002b0"
        ))
        // The canonical encoding zeros the padding and puts the single timestamp last, as
        // `SendPacket` lays it out.
        #expect(Array(framed[30 ..< 40]) == Array(repeating: 0, count: 10))
        #expect(Array(framed[40 ..< 48]) == withUnsafeBytes(of: UInt64(0x0000_0000_0167_B3D6).littleEndian) { Array($0) })
    }

    @Test func theAbsoluteFlagAndViewportAreInTheBody() {
        let packet = NvstRemoteInput.absoluteMouseMove(x: 100, y: 200, viewportWidth: 1632, viewportHeight: 688)
        // Inner packet: [BE u32 length][LE u32 type][body]
        // The inner packet is its 8-byte header plus a 10-byte body, and the length field it
        // declares is 14 — type plus body — which is what the capture carries.
        #expect(packet.count == 18)
        let declaredLength = packet.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(declaredLength == 14)
        #expect(packet[4] == 5)
        #expect(UInt16(packet[8]) << 8 | UInt16(packet[9]) == 100)
        #expect(UInt16(packet[10]) << 8 | UInt16(packet[11]) == 200)
        #expect(UInt16(packet[12]) << 8 | UInt16(packet[13]) == NvstRemoteInput.absoluteFlag)
        #expect(UInt16(packet[14]) << 8 | UInt16(packet[15]) == 1632)
        #expect(UInt16(packet[16]) << 8 | UInt16(packet[17]) == 688)
    }

    /// Byte-exact against a captured single downward notch, which the wire carries as -120.
    ///
    /// The encoder takes `WHEEL_DELTA` units directly and must not rescale: the stream view's
    /// `accumulatedWheelDelta` already multiplies by 120, and the vendored transport passes its
    /// value through untouched. Rescaling here turned one notch into 14400.
    @Test func aWheelMovementMatchesTheCapturedEvent() {
        let down = NvstRemoteInput.framed(
            NvstRemoteInput.mouseWheel(delta: -NvstRemoteInput.wheelDelta16),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 0x0000_0000_0167_B3D6
        )
        #expect(down.count == 40)
        #expect(down.map { String(format: "%02x", $0) }.joined().hasPrefix(
            "000000240e0000000000000a0a0000000000ff88"
        ))
        let up = NvstRemoteInput.mouseWheel(delta: NvstRemoteInput.wheelDelta16)
        #expect(UInt16(up[8]) << 8 | UInt16(up[9]) == 0)
        #expect(Int16(bitPattern: UInt16(up[10]) << 8 | UInt16(up[11])) == 120)
        #expect(NvstRemoteInput.framed(up, framing: .enveloped, sequence: 0, timestampMicroseconds: 1).count == 40)
    }

    /// A full-scale scroll must stay inside the field rather than wrapping through it.
    @Test func aLargeWheelMovementIsNotRescaled() {
        let large = NvstRemoteInput.mouseWheel(delta: 3600) // 30 notches, as a fast flick produces
        #expect(Int16(bitPattern: UInt16(large[10]) << 8 | UInt16(large[11])) == 3600)
    }
}

struct NvstAnnouncedBitrateTests {
    private func announce(bitrateKbps: Int?, maximumBitrateKbps: Int?) -> [String: String] {
        let body = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions(
            resolution: "1920x1080",
            videoPort: 5004,
            officialCloudPath: true,
            rtcpOnSctp: false,
            offeredAttributes: [],
            bitrateKbps: bitrateKbps,
            maximumBitrateKbps: maximumBitrateKbps
        ))
        var attributes: [String: String] = [:]
        for line in body.split(separator: "\r\n") where line.hasPrefix("a=x-nv-") {
            let pair = line.dropFirst("a=".count).split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            attributes[String(pair[0])] = String(pair[1])
        }
        return attributes
    }

    /// The configured ceiling has to replace the captured default, or the setting does nothing on
    /// this path: the capture announces NVIDIA's own 100000 regardless of what the user picked.
    @Test func theConfiguredCeilingIsAnnounced() {
        let announced = announce(bitrateKbps: 25000, maximumBitrateKbps: 40000)
        #expect(announced["x-nv-vqos[0].bw.maximumBitrateKbps"] == "40000")
        #expect(announced["x-nv-video[0].initialBitrateKbps"] == "25000")
        #expect(announced["x-nv-video[0].initialPeakBitrateKbps"] == "25000")
    }

    /// With nothing configured the captured value stands, so absent settings cannot narrow the
    /// stream by accident.
    @Test func withoutACeilingTheCapturedDefaultStands() {
        let announced = announce(bitrateKbps: nil, maximumBitrateKbps: nil)
        #expect(announced["x-nv-vqos[0].bw.maximumBitrateKbps"] == "100000")
    }

    @Test func aZeroCeilingIsIgnoredRatherThanAnnounced() {
        #expect(announce(bitrateKbps: nil, maximumBitrateKbps: 0)["x-nv-vqos[0].bw.maximumBitrateKbps"] == "100000")
    }
}

struct NvstAv1FrameHeaderTests {
    /// AV1 carries no Annex-B start code, so the frame-header boundary is a fixed size chosen by
    /// the payload's first byte. GFN's cloud extended header is 20 bytes — not the 44 of the
    /// similarly named consumer GameStream layout — and the short header is 8.
    @Test func stripsTheGfnCloudAv1FrameHeaders() {
        var short = Data([0x01]) + Data(repeating: 0, count: 7)
        short.append(contentsOf: [0x12, 0x34, 0x56])
        #expect(NvstAnnexB.picturePayload(short, codec: .av1) == Data([0x12, 0x34, 0x56]))

        var extended = Data([0x81]) + Data(repeating: 0, count: 19)
        extended.append(contentsOf: [0xAB, 0xCD])
        #expect(NvstAnnexB.picturePayload(extended, codec: .av1) == Data([0xAB, 0xCD]))

        // A payload that is only a header carries no picture data.
        #expect(NvstAnnexB.picturePayload(Data([0x01]) + Data(repeating: 0, count: 7), codec: .av1) == nil)
        // An unknown leading byte is not guessed at.
        #expect(NvstAnnexB.picturePayload(Data([0x42, 0x00, 0x00, 0x01, 0x09]), codec: .av1) == nil)
        // H.264 still uses the start-code search, so a stray AV1-looking byte changes nothing.
        // (the 4-byte start code is kept, so the picture begins at 00 00 00 01)
        #expect(NvstAnnexB.picturePayload(Data([0x81, 0x00, 0x00, 0x00, 0x01, 0x67]), codec: .h264) == Data([0x00, 0x00, 0x00, 0x01, 0x67]))
    }
}

struct NvstAv1AccessUnitLengthTests {
    /// The GFN cloud AV1 `0x81` header states the whole access unit's size at bytes 16..<20.
    /// AV1 is not self-delimiting, so trailing bytes from the last packet would otherwise reach the
    /// decoder as OBU data.
    @Test func readsTheAdvertisedAccessUnitLength() {
        var header = Data(repeating: 0, count: 20)
        header[0] = 0x81
        header.replaceSubrange(16 ..< 20, with: [0x2A, 0x00, 0x00, 0x00]) // 42, little-endian
        #expect(NvstFrameReassembler.av1AccessUnitLength(in: header, codec: .av1) == 42)
        // The short header carries no such field.
        var short = Data(repeating: 0, count: 20)
        short[0] = 0x01
        #expect(NvstFrameReassembler.av1AccessUnitLength(in: short, codec: .av1) == nil)
        // And it is an AV1-only field.
        #expect(NvstFrameReassembler.av1AccessUnitLength(in: header, codec: .hevc) == nil)
        // A truncated header cannot be read rather than being read as garbage.
        #expect(NvstFrameReassembler.av1AccessUnitLength(in: Data([0x81, 0x00]), codec: .av1) == nil)
    }
}
