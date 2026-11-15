import Foundation
import Synchronization

/// Decode-tail timing and decoder-session churn for the active stream.
///
/// The WebRTC statistics report only exposes a mean decode time per interval. A mean hides the
/// tail that actually causes a late frame, and it says nothing about how often the VideoToolbox
/// session was rebuilt, so the app's own decoders record both here.
nonisolated struct CloudVideoDecoderSnapshot: Equatable, Sendable {
    var sampleCount: Int = 0
    var medianDecodeMs: Double = 0
    var p99DecodeMs: Double = 0
    var maxDecodeMs: Double = 0
    /// VideoToolbox sessions created since the stream started. One is the ideal.
    var sessionBuilds: Int = 0
    /// Parameter-set changes absorbed without rebuilding the session.
    var sessionReuses: Int = 0
    /// `nil` until VideoToolbox reports which decoder backs the session.
    var isHardwareAccelerated: Bool?
}

final nonisolated class CloudVideoDecoderCounters: Sendable {
    static let shared = CloudVideoDecoderCounters()

    /// Roughly two seconds at 120 fps; enough for a stable p99 without growing unbounded.
    static let windowSize = 240

    private struct State {
        var samples = [UInt32](repeating: 0, count: CloudVideoDecoderCounters.windowSize)
        var writeIndex = 0
        var filled = 0
        var sessionBuilds = 0
        var sessionReuses = 0
        var isHardwareAccelerated: Bool?
    }

    private let state = Mutex(State())

    func reset() {
        state.withLock { $0 = State() }
    }

    /// Records one synchronous decode call. Durations are stored in microseconds.
    func recordDecode(nanoseconds: UInt64) {
        let microseconds = UInt32(clamping: nanoseconds / 1000)
        state.withLock { state in
            state.samples[state.writeIndex] = microseconds
            state.writeIndex = (state.writeIndex + 1) % Self.windowSize
            state.filled = min(state.filled + 1, Self.windowSize)
        }
    }

    func recordSessionBuild(isHardwareAccelerated: Bool?) {
        state.withLock { state in
            state.sessionBuilds += 1
            state.isHardwareAccelerated = isHardwareAccelerated
        }
    }

    func recordSessionReuse() {
        state.withLock { $0.sessionReuses += 1 }
    }

    func snapshot() -> CloudVideoDecoderSnapshot {
        let (window, builds, reuses, hardware) = state.withLock { state in
            (Array(state.samples.prefix(state.filled)), state.sessionBuilds, state.sessionReuses, state.isHardwareAccelerated)
        }
        var snapshot = CloudVideoDecoderSnapshot(
            sessionBuilds: builds,
            sessionReuses: reuses,
            isHardwareAccelerated: hardware
        )
        guard !window.isEmpty else { return snapshot }
        let sorted = window.sorted()
        snapshot.sampleCount = sorted.count
        snapshot.medianDecodeMs = Self.milliseconds(sorted[Self.percentileIndex(0.5, count: sorted.count)])
        snapshot.p99DecodeMs = Self.milliseconds(sorted[Self.percentileIndex(0.99, count: sorted.count)])
        snapshot.maxDecodeMs = Self.milliseconds(sorted[sorted.count - 1])
        return snapshot
    }

    static func percentileIndex(_ percentile: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let rank = (percentile * Double(count)).rounded(.up) - 1
        return min(max(Int(rank), 0), count - 1)
    }

    private static func milliseconds(_ microseconds: UInt32) -> Double {
        Double(microseconds) / 1000
    }
}
