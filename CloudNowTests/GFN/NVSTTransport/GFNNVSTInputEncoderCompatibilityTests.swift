@testable import CloudNow
import Foundation
import Testing

/// Pins the contract between CloudNow's `InputEncoder` and the NVST transport: whatever the
/// encoder emits for a gamepad, at either protocol version, must decode and be re-encodable.
@Suite("NVST transport accepts InputEncoder gamepad reports")
struct GFNNVSTInputEncoderCompatibilityTests {
    private func encodedGamepad(protocolVersion: Int) -> Data {
        let encoder = InputEncoder(timestampProvider: { 1_763_164_800_000_000 })
        encoder.setProtocolVersion(protocolVersion)
        let packet = EncodedInputPacket()
        encoder.encodeGamepad(
            controllerId: 2,
            buttons: 0x1234,
            leftTrigger: 0x40,
            rightTrigger: 0xC0,
            leftStickX: -32768,
            leftStickY: 32767,
            rightStickX: 1234,
            rightStickY: -4321,
            gamepadBitmap: 0x0505,
            into: packet
        )
        return Data(TestBytes.bytes(of: packet))
    }

    @Test("Both encoder protocol versions decode to the same NVST report", arguments: [2, 3])
    func encoderOutputDecodes(protocolVersion: Int) throws {
        let data = encodedGamepad(protocolVersion: protocolVersion)
        #expect(data.count == (protocolVersion >= 3 ? NvstGamepadReport.wrappedLength : NvstGamepadReport.eventLength))
        let report = try #require(NvstGamepadReport(report: data))
        #expect(report.gamepadIndex == 2)
        #expect(report.connectedBitmap == 0x0505)
        #expect(report.buttons == 0x1234)
        #expect(report.leftTrigger == 0x40)
        #expect(report.rightTrigger == 0xC0)
        #expect(report.leftStickX == -32768)
        #expect(report.leftStickY == 32767)
        #expect(report.rightStickX == 1234)
        #expect(report.rightStickY == -4321)
    }

    @Test("The NVST event differs from the encoder's only in its timestamp")
    func rewrittenEventMatchesEncoderLayout() throws {
        let source = [UInt8](encodedGamepad(protocolVersion: 2))
        let report = try #require(NvstGamepadReport(report: Data(source)))
        let command = try #require(report.encodedCommand(sequence: 1, timestampMicroseconds: 42, connectedBitmap: report.connectedBitmap))
        let event = [UInt8](command.suffix(NvstGamepadReport.eventLength))
        #expect(Array(event[0 ..< 30]) == Array(source[0 ..< 30]))
        #expect(TestBytes.uint64LE(event, at: 30) == 42)
        #expect(TestBytes.uint64LE(source, at: 30) == 1_763_164_800_000_000)
    }

    @Test("Other encoder output is not mistaken for gamepad state", arguments: [2, 3])
    func nonGamepadEncoderOutputIsRejected(protocolVersion: Int) {
        let encoder = InputEncoder(timestampProvider: { 1 })
        encoder.setProtocolVersion(protocolVersion)
        let packet = EncodedInputPacket()
        encoder.encodeHeartbeat(into: packet)
        #expect(NvstGamepadReport(report: Data(TestBytes.bytes(of: packet))) == nil)
        encoder.encodeHapticsEnabled(true, into: packet)
        #expect(NvstGamepadReport(report: Data(TestBytes.bytes(of: packet))) == nil)
        encoder.encodeMouseMove(dx: 3, dy: -4, into: packet)
        #expect(NvstGamepadReport(report: Data(TestBytes.bytes(of: packet))) == nil)
    }
}
