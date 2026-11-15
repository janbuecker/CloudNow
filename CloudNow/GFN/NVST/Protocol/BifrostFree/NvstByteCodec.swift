import Foundation

// The single binary codec for NVST's wire formats.
//
// NVST's byte layouts are fixed by NVIDIA's seat and recovered from captures: mixed
// endianness within one packet, bit-packed words, fixed widths, padded slots. That
// complexity cannot be abstracted away — but it belongs in exactly one place. Every packet
// type encodes through `NvstByteWriter` and decodes through `NvstByteReader`, so the
// shift-and-mask arithmetic exists once, is unit-tested once, and every packet definition
// reads as a sequence of named fields.
//
// The reader throws on truncation instead of trapping, so a malformed datagram degrades
// into a structured error rather than an index-out-of-range crash.

nonisolated enum NvstByteError: LocalizedError, Equatable, Sendable {
    case truncated(expected: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case let .truncated(expected, available):
            "NVST byte read truncated: needed \(expected) bytes, had \(available)."
        }
    }
}

/// An append-style encoder for NVST wire formats.
///
/// Method names carry the byte order explicitly (`u32LE`, `u16BE`) because NVST packets mix
/// endianness within a single payload — a "native order" default would be a bug factory.
nonisolated struct NvstByteWriter: Sendable {
    private(set) var data: Data

    init(capacity: Int = 0) {
        data = Data()
        if capacity > 0 {
            data.reserveCapacity(capacity)
        }
    }

    var count: Int {
        data.count
    }

    var isEmpty: Bool {
        data.isEmpty
    }

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16LE(_ value: UInt16) {
        appendInteger(value.littleEndian)
    }

    mutating func u16BE(_ value: UInt16) {
        appendInteger(value.bigEndian)
    }

    mutating func u32LE(_ value: UInt32) {
        appendInteger(value.littleEndian)
    }

    mutating func u32BE(_ value: UInt32) {
        appendInteger(value.bigEndian)
    }

    mutating func u64LE(_ value: UInt64) {
        appendInteger(value.littleEndian)
    }

    mutating func u64BE(_ value: UInt64) {
        appendInteger(value.bigEndian)
    }

    /// IEEE 754 single precision, little-endian — the wire's float form (`NvstFrameAck`).
    mutating func float32LE(_ value: Float) {
        appendInteger(value.bitPattern.littleEndian)
    }

    /// IEEE 754 double precision, little-endian.
    mutating func float64LE(_ value: Double) {
        appendInteger(value.bitPattern.littleEndian)
    }

    mutating func bytes(_ bytes: some Sequence<UInt8>) {
        data.append(contentsOf: bytes)
    }

    /// The bulk-copy fast path: `NvstElementaryStream.prepare` writes each NAL through this —
    /// up to 112 KB per access unit — and the raw-pointer append takes Data's memcpy route
    /// instead of the generic Sequence one.
    mutating func bytes(_ raw: UnsafeRawBufferPointer) {
        guard let base = raw.baseAddress, raw.count > 0 else { return }
        data.append(base.assumingMemoryBound(to: UInt8.self), count: raw.count)
    }

    mutating func zeroes(_ count: Int) {
        data.append(Data(repeating: 0, count: max(count, 0)))
    }

    private mutating func appendInteger(_ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}

/// A cursor-style decoder for NVST wire formats.
///
/// Reads consume bytes in order and throw `NvstByteError.truncated` when the input ends
/// early. Works correctly on `Data` slices whose `startIndex` is not zero.
nonisolated struct NvstByteReader: Sendable {
    let data: Data
    private var position: Int

    init(_ data: Data) {
        self.data = data
        position = 0
    }

    /// Bytes already consumed.
    var offset: Int {
        position
    }

    /// Bytes not yet read.
    var remaining: Int {
        data.count - position
    }

    var isAtEnd: Bool {
        position >= data.count
    }

    /// Everything from the cursor onward, without advancing it.
    var unread: Data {
        data.subdata(in: (data.startIndex + position) ..< data.endIndex)
    }

    mutating func u8() throws -> UInt8 {
        try ensure(1)
        defer { position += 1 }
        return byte(0)
    }

    mutating func u16LE() throws -> UInt16 {
        try ensure(2)
        defer { position += 2 }
        return UInt16(byte(0)) | UInt16(byte(1)) << 8
    }

    mutating func u16BE() throws -> UInt16 {
        try ensure(2)
        defer { position += 2 }
        return UInt16(byte(0)) << 8 | UInt16(byte(1))
    }

    mutating func u32LE() throws -> UInt32 {
        try ensure(4)
        defer { position += 4 }
        return UInt32(byte(0)) | UInt32(byte(1)) << 8 | UInt32(byte(2)) << 16 | UInt32(byte(3)) << 24
    }

    mutating func u32BE() throws -> UInt32 {
        try ensure(4)
        defer { position += 4 }
        return UInt32(byte(0)) << 24 | UInt32(byte(1)) << 16 | UInt32(byte(2)) << 8 | UInt32(byte(3))
    }

    mutating func u64LE() throws -> UInt64 {
        try ensure(8)
        defer { position += 8 }
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value |= UInt64(byte(index)) << UInt64(index * 8)
        }
        return value
    }

    mutating func u64BE() throws -> UInt64 {
        try ensure(8)
        defer { position += 8 }
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value = value << 8 | UInt64(byte(index))
        }
        return value
    }

    mutating func float32LE() throws -> Float {
        try Float(bitPattern: u32LE())
    }

    mutating func float64LE() throws -> Double {
        try Double(bitPattern: u64LE())
    }

    /// Consumes `count` bytes and returns them as a fresh `Data`.
    mutating func bytes(_ count: Int) throws -> Data {
        try ensure(count)
        let start = data.startIndex + position
        position += count
        return data.subdata(in: start ..< (start + count))
    }

    mutating func skip(_ count: Int) throws {
        try ensure(count)
        position += count
    }

    private func byte(_ ahead: Int) -> UInt8 {
        data[data.startIndex + position + ahead]
    }

    private func ensure(_ count: Int) throws {
        guard count >= 0, remaining >= count else {
            throw NvstByteError.truncated(expected: max(count, 0), available: max(remaining, 0))
        }
    }
}
