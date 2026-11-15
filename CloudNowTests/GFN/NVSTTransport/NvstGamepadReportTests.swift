@testable import CloudNow
import Foundation
import Testing

/// CloudNow's gamepad reports are decoded and re-encoded as NVST gamepad commands. These tests
/// pin the layout both ways, byte for byte.
@Suite("NVST gamepad report rewriting")
struct NvstGamepadReportTests {
    /// The 38-byte event exactly as `InputEncoder.encodeGamepad` lays it out at protocol version 2.
    static func bareReport(
        controllerId: Int = 1,
        bitmap: UInt16 = 0x0303,
        buttons: UInt16 = 0xA55A,
        leftTrigger: UInt8 = 0x12,
        rightTrigger: UInt8 = 0xFE,
        sticks: (Int16, Int16, Int16, Int16) = (-2, 0x1234, .min, .max),
        timestamp: UInt64 = 1_763_164_800_000_000
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 38)
        func put16(_ value: UInt16, _ offset: Int) {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        bytes[0] = 12
        put16(26, 4)
        put16(UInt16(controllerId & 3), 6)
        put16(bitmap, 8)
        put16(20, 10)
        put16(buttons, 12)
        bytes[14] = leftTrigger
        bytes[15] = rightTrigger
        put16(UInt16(bitPattern: sticks.0), 16)
        put16(UInt16(bitPattern: sticks.1), 18)
        put16(UInt16(bitPattern: sticks.2), 20)
        put16(UInt16(bitPattern: sticks.3), 22)
        bytes[26] = 0x55
        for index in 0 ..< 8 {
            bytes[30 + index] = UInt8(truncatingIfNeeded: timestamp >> UInt64(index * 8))
        }
        return bytes
    }

    /// The same event behind the 16-byte wrapper the encoder adds at protocol version 3.
    static func wrappedReport(controllerId: Int = 1, sequence: UInt16 = 0x0102, event: [UInt8]? = nil) -> [UInt8] {
        let event = event ?? bareReport(controllerId: controllerId)
        var bytes: [UInt8] = [0x23]
        bytes += [0x00, 0x06, 0x43, 0x9A, 0x4B, 0x7C, 0x40, 0x00]
        bytes += [0x26, UInt8(controllerId & 0xFF), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        bytes += [0x21, 0x00, 38]
        return bytes + event
    }

    @Test("A bare protocol-v2 report decodes into its fields")
    func decodesBareReport() throws {
        let report = try #require(NvstGamepadReport(report: Data(Self.bareReport())))
        #expect(report.gamepadIndex == 1)
        #expect(report.connectedBitmap == 0x0303)
        #expect(report.buttons == 0xA55A)
        #expect(report.leftTrigger == 0x12)
        #expect(report.rightTrigger == 0xFE)
        #expect(report.leftStickX == -2)
        #expect(report.leftStickY == 0x1234)
        #expect(report.rightStickX == .min)
        #expect(report.rightStickY == .max)
        #expect(report.listsOwnPad)
    }

    @Test("A wrapped protocol-v3 report decodes to the same fields as the bare one")
    func decodesWrappedReport() throws {
        let bare = try #require(NvstGamepadReport(report: Data(Self.bareReport())))
        let wrapped = try #require(NvstGamepadReport(report: Data(Self.wrappedReport())))
        #expect(wrapped == bare)
        #expect(Self.wrappedReport().count == NvstGamepadReport.wrappedLength)
        #expect(NvstGamepadReport.wrappedLength == 54)
        #expect(NvstGamepadReport.eventLength == 38)
    }

    @Test("A report embedded in a larger buffer is decoded from its own bytes")
    func decodesFromSlicedData() throws {
        let padded = Data([0xEE, 0xEE] + Self.wrappedReport() + [0xEE])
        let slice = padded.subdata(in: 2 ..< 56)
        #expect(try #require(NvstGamepadReport(report: slice)).buttons == 0xA55A)
        // A `Data` slice keeps its parent's indices; decoding must not assume they start at zero.
        let view = padded[2 ..< 56]
        #expect(try #require(NvstGamepadReport(report: view)).buttons == 0xA55A)
    }

    @Test(
        "Anything that is not a gamepad state report is rejected",
        arguments: [
            // Heartbeat.
            [0x02, 0x00, 0x00, 0x00],
            // Haptics enable.
            [0x0D, 0x00, 0x00, 0x00, 0x00, 0x01],
            // Keyboard (18 bytes) and mouse move (22 bytes).
            [UInt8](repeating: 0x03, count: 18),
            [UInt8](repeating: 0x07, count: 22),
            // Empty and truncated.
            [],
            [UInt8](NvstGamepadReportTests.bareReport().dropLast()),
            [UInt8](NvstGamepadReportTests.wrappedReport().dropLast()),
            NvstGamepadReportTests.bareReport() + [0x00],
        ] as [[UInt8]]
    )
    func rejectsNonGamepadPackets(bytes: [UInt8]) {
        #expect(NvstGamepadReport(report: Data(bytes)) == nil)
    }

    @Test("A report of the right size with the wrong event type or wrapper is rejected")
    func rejectsMalformedGamepadShapes() {
        var wrongType = Self.bareReport()
        wrongType[0] = 3
        #expect(NvstGamepadReport(report: Data(wrongType)) == nil)
        var wrongSize = Self.bareReport()
        wrongSize[4] = 27
        #expect(NvstGamepadReport(report: Data(wrongSize)) == nil)
        var wrongIndex = Self.bareReport()
        wrongIndex[6] = 4
        #expect(NvstGamepadReport(report: Data(wrongIndex)) == nil)
        for (offset, value) in [(0, UInt8(0x22)), (9, 0x22), (13, 0x22), (15, 37)] {
            var wrapped = Self.wrappedReport()
            wrapped[offset] = value
            #expect(NvstGamepadReport(report: Data(wrapped)) == nil)
        }
        // A 54-byte Sony-style buffer whose inner bytes are not a gamepad event.
        #expect(NvstGamepadReport(report: Data(Self.wrappedReport(event: [UInt8](repeating: 0x11, count: 38)))) == nil)
    }

    @Test("The rewritten command carries the NVST header, session timestamps and its own sequence")
    func rewritesTimestampAndHeader() throws {
        let report = try #require(NvstGamepadReport(report: Data(Self.wrappedReport())))
        let sessionMicroseconds: UInt64 = 0x0000_0001_0203_0405
        let command = try #require(report.encodedCommand(sequence: 7, timestampMicroseconds: sessionMicroseconds, connectedBitmap: 0x0303))
        let bytes = [UInt8](command)
        // `0x020d` little-endian, then the 54-byte payload length.
        #expect(Array(bytes[0 ..< 4]) == [0x0D, 0x02, 0x36, 0x00])
        #expect(bytes.count == 58)
        // The wrapper: 0x23, timestamp big-endian, 0x26, pad, sequence big-endian, 0x21, length.
        #expect(bytes[4] == 0x23)
        #expect(Array(bytes[5 ..< 13]) == [0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        #expect(Array(bytes[13 ..< 17]) == [0x26, 0x01, 0x00, 0x07])
        #expect(Array(bytes[17 ..< 20]) == [0x21, 0x00, 38])
        // The inner timestamp is the same session clock, little-endian, at event offset 30.
        #expect(Array(bytes[50 ..< 58]) == [0x05, 0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x00])
    }

    @Test("Everything except the timestamps and the sequence survives the rewrite byte for byte")
    func rewritePreservesState() throws {
        let source = Self.wrappedReport()
        let report = try #require(NvstGamepadReport(report: Data(source)))
        let command = try #require(report.encodedCommand(sequence: 1, timestampMicroseconds: 0, connectedBitmap: report.connectedBitmap))
        let event = [UInt8](command.dropFirst(4 + NvstGamepadReport.wrapperLength))
        let original = Array(source[NvstGamepadReport.wrapperLength...])
        #expect(event.count == 38)
        #expect(Array(event[0 ..< 30]) == Array(original[0 ..< 30]))
        // Round trip: the rewritten event decodes back to the same report.
        #expect(NvstGamepadReport(report: Data(event)) == report)
        #expect(NvstGamepadReport(report: command.dropFirst(4)) == report)
    }

    @Test("A disconnecting pad's neutral report is recognised and the announced bitmap never empties")
    func disconnectBitmaps() throws {
        // Pad 1 has left: its neutral state arrives with only pad 0 still listed.
        let leaving = try #require(NvstGamepadReport(report: Data(Self.bareReport(controllerId: 1, bitmap: 0x0101, buttons: 0))))
        #expect(!leaving.listsOwnPad)
        #expect(leaving.announcedBitmap == 0x0101)
        // The last pad leaving reports an empty bitmap; the seat is still told about pad 0.
        let last = try #require(NvstGamepadReport(report: Data(Self.bareReport(controllerId: 0, bitmap: 0, buttons: 0))))
        #expect(!last.listsOwnPad)
        #expect(last.announcedBitmap == NvstGamepadPacket.connectedBitmap)
        let present = try #require(NvstGamepadReport(report: Data(Self.bareReport(controllerId: 0, bitmap: 0x0101))))
        #expect(present.listsOwnPad)
        #expect(present.announcedBitmap == 0x0101)
    }

    @Test("Gamepad state is refused until input has been activated")
    func inactiveInputRefusesReports() {
        let input = NvstGamepadInput(clock: NvstSessionClock())
        #expect(!input.isActive)
        #expect(!input.send(report: Data(Self.wrappedReport())))
        #expect(!input.send(report: Data(Self.bareReport())))
        // A valid report that could not be sent is not a rejected packet.
        #expect(input.counters == NvstGamepadInput.Counters())
        #expect(!input.send(report: Data([0x02, 0x00, 0x00, 0x00])))
        #expect(input.counters.rejected == 1)
        #expect(input.counters.sent == 0)
        input.deactivate()
        #expect(!input.isActive)
    }
}
