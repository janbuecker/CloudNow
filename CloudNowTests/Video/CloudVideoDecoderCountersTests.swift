@testable import CloudNow
import Testing

@Suite("Video decoder counters")
struct CloudVideoDecoderCountersTests {
    @Test("An empty window reports no samples and no decoder answer")
    func emptySnapshot() {
        let counters = CloudVideoDecoderCounters()

        #expect(counters.snapshot() == CloudVideoDecoderSnapshot())
    }

    @Test("Percentiles describe the recorded decode tail")
    func percentiles() {
        let counters = CloudVideoDecoderCounters()
        for milliseconds in 1 ... 100 {
            counters.recordDecode(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }

        let snapshot = counters.snapshot()

        #expect(snapshot.sampleCount == 100)
        #expect(snapshot.medianDecodeMs == 50)
        #expect(snapshot.p99DecodeMs == 99)
        #expect(snapshot.maxDecodeMs == 100)
    }

    @Test("The window keeps only the most recent samples")
    func boundedWindow() {
        let counters = CloudVideoDecoderCounters()
        counters.recordDecode(nanoseconds: 900_000_000)
        for _ in 0 ..< CloudVideoDecoderCounters.windowSize {
            counters.recordDecode(nanoseconds: 2_000_000)
        }

        let snapshot = counters.snapshot()

        #expect(snapshot.sampleCount == CloudVideoDecoderCounters.windowSize)
        #expect(snapshot.maxDecodeMs == 2)
    }

    @Test("Session builds, reuses, and the hardware answer are tracked and reset")
    func sessionChurn() {
        let counters = CloudVideoDecoderCounters()
        counters.recordSessionBuild(isHardwareAccelerated: true)
        counters.recordSessionReuse()
        counters.recordSessionReuse()

        var snapshot = counters.snapshot()
        #expect(snapshot.sessionBuilds == 1)
        #expect(snapshot.sessionReuses == 2)
        #expect(snapshot.isHardwareAccelerated == true)

        counters.reset()
        snapshot = counters.snapshot()
        #expect(snapshot == CloudVideoDecoderSnapshot())
    }

    @Test("Percentile indexes stay inside the window", arguments: [1, 2, 99, 100, 240])
    func percentileIndexBounds(count: Int) {
        #expect(CloudVideoDecoderCounters.percentileIndex(0, count: count) == 0)
        #expect(CloudVideoDecoderCounters.percentileIndex(1, count: count) == count - 1)
        #expect(CloudVideoDecoderCounters.percentileIndex(0.99, count: count) < count)
    }
}
