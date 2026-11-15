@testable import CloudNow
import Foundation
import Testing

/// The codec is the one place NVST's byte arithmetic lives, so it carries its own byte-order
/// golden vectors and truncation guarantees. Every packet encoder/parser migrates onto it,
/// and a regression here would move every wire byte.
@Suite(.serialized)
struct NvstByteCodecTests {
    @Test func writerEmitsExactBytesPerEndianness() {
        var writer = NvstByteWriter(capacity: 64)
        writer.u8(0x01)
        writer.u16LE(0x1122)
        writer.u16BE(0x1122)
        writer.u32LE(0x1122_3344)
        writer.u32BE(0x1122_3344)
        writer.u64LE(0x1122_3344_5566_7788)
        writer.u64BE(0x1122_3344_5566_7788)
        #expect(writer.data == Data([
            0x01,
            0x22, 0x11,
            0x11, 0x22,
            0x44, 0x33, 0x22, 0x11,
            0x11, 0x22, 0x33, 0x44,
            0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        ]))
        #expect(writer.count == 29)
    }

    @Test func writerEncodesFloatsAsIeeeLittleEndian() {
        var writer = NvstByteWriter()
        writer.float32LE(1.0)
        writer.float32LE(-1.0)
        writer.float64LE(1.5)
        #expect(writer.data == Data([0x00, 0x00, 0x80, 0x3F,
                                     0x00, 0x00, 0x80, 0xBF,
                                     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F]))
    }

    @Test func writerAppendsRawBytesAndZeroPadding() {
        var writer = NvstByteWriter()
        writer.bytes([0xAB, 0xCD])
        writer.zeroes(3)
        writer.bytes(Data([0xEF]))
        #expect(writer.data == Data([0xAB, 0xCD, 0x00, 0x00, 0x00, 0xEF]))
    }

    @Test func readerDecodesEveryWidthBothEndiannesses() throws {
        let wireBytes = Data([0x01,
                              0x22, 0x11,
                              0x11, 0x22,
                              0x44, 0x33, 0x22, 0x11,
                              0x11, 0x22, 0x33, 0x44,
                              0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
                              0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                              0x00, 0x00, 0x80, 0x3F,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F])
        var reader = NvstByteReader(wireBytes)
        #expect(try reader.u8() == 0x01)
        #expect(try reader.u16LE() == 0x1122)
        #expect(try reader.u16BE() == 0x1122)
        #expect(try reader.u32LE() == 0x1122_3344)
        #expect(try reader.u32BE() == 0x1122_3344)
        #expect(try reader.u64LE() == 0x1122_3344_5566_7788)
        #expect(try reader.u64BE() == 0x1122_3344_5566_7788)
        #expect(try reader.float32LE() == 1.0)
        #expect(try reader.float64LE() == 1.5)
        #expect(reader.isAtEnd)
        #expect(reader.remaining == 0)
    }

    @Test func readerHandsOutSlicesAndSkips() throws {
        var reader = NvstByteReader(Data([1, 2, 3, 4, 5, 6, 7]))
        #expect(try reader.bytes(2) == Data([1, 2]))
        try reader.skip(1)
        #expect(try reader.u8() == 4)
        #expect(reader.unread == Data([5, 6, 7]))
        #expect(reader.remaining == 3)
    }

    @Test func everyReadThrowsOnTruncationInsteadOfTrapping() throws {
        var empty = NvstByteReader(Data())
        #expect(throws: NvstByteError.self) { try empty.u8() }
        #expect(throws: NvstByteError.self) { try empty.u16LE() }
        #expect(throws: NvstByteError.self) { try empty.u16BE() }
        #expect(throws: NvstByteError.self) { try empty.u32LE() }
        #expect(throws: NvstByteError.self) { try empty.u32BE() }
        #expect(throws: NvstByteError.self) { try empty.u64LE() }
        #expect(throws: NvstByteError.self) { try empty.u64BE() }
        #expect(throws: NvstByteError.self) { try empty.float32LE() }
        #expect(throws: NvstByteError.self) { try empty.float64LE() }
        #expect(throws: NvstByteError.self) { try empty.bytes(1) }
        #expect(throws: NvstByteError.self) { try empty.skip(1) }

        var short = NvstByteReader(Data([0xFF, 0xFE]))
        #expect(try short.u8() == 0xFF)
        #expect(throws: NvstByteError.truncated(expected: 2, available: 1)) { try short.u16BE() }
    }

    @Test func failedReadDoesNotConsumeBytes() {
        var reader = NvstByteReader(Data([0xAA, 0xBB]))
        #expect(throws: NvstByteError.self) { try reader.u32LE() }
        #expect(reader.remaining == 2)
        #expect((try? reader.u16BE()) == 0xAABB)
    }

    @Test func readsWorkOnSlicesWithNonZeroStartIndex() throws {
        let full = Data([0, 0, 1, 2, 3, 4, 5])
        var reader = NvstByteReader(full[2...])
        #expect(try reader.u32BE() == 0x0102_0304)
        #expect(try reader.u8() == 0x05)
        #expect(reader.isAtEnd)
    }
}
