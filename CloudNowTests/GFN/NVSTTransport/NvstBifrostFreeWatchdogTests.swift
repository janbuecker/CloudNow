@testable import CloudNow
import Foundation
import Testing

@Suite("NVST watchdog and statistics aggregation")
struct NvstBifrostFreeWatchdogTests {
    // MARK: Frames

    @Test("The frame monitor counts frames and measures the time since the last one")
    func frameMonitor() {
        let monitor = NvstFrameMonitor()
        #expect(monitor.decodedFrameCount == 0)
        #expect(monitor.secondsSinceLastFrame(uptimeNanoseconds: 5_000_000_000) == nil)
        monitor.noteFrame(uptimeNanoseconds: 1_000_000_000)
        monitor.noteFrame(uptimeNanoseconds: 2_000_000_000)
        #expect(monitor.decodedFrameCount == 2)
        #expect(monitor.secondsSinceLastFrame(uptimeNanoseconds: 4_500_000_000) == 2.5)
        // A reading taken before the last frame's own stamp is not a negative interval.
        #expect(monitor.secondsSinceLastFrame(uptimeNanoseconds: 1_500_000_000) == 0)
    }

    @Test("A stream is stalled after ten seconds without a frame, never before its first")
    func stallVerdict() {
        #expect(!NvstBifrostFreeWatchdog.isStalled(secondsSinceLastFrame: nil))
        #expect(!NvstBifrostFreeWatchdog.isStalled(secondsSinceLastFrame: 0.02))
        #expect(!NvstBifrostFreeWatchdog.isStalled(secondsSinceLastFrame: 9.9))
        #expect(NvstBifrostFreeWatchdog.isStalled(secondsSinceLastFrame: 10))
        #expect(NvstBifrostFreeWatchdog.stallTimeoutSeconds == 10)
    }

    // MARK: Control keepalive

    @Test("The control connection's keepalive summary is read back")
    func keepAliveSummaryParsing() {
        let healthy = "keepalives=12/12 seatPingsAnswered=3 pongsSeen=0 failed=0 rtt=5.1 handshakeRtt=4.8"
        #expect(NvstBifrostFreeWatchdog.keepAliveStatus(fromSummary: healthy)
            == NvstBifrostFreeWatchdog.KeepAliveStatus(sent: 12, answered: 12, failed: false))
        let dead = "keepalives=13/12 seatPingsAnswered=3 pongsSeen=0 failed=1 rtt=5.1 handshakeRtt=4.8 failure=NVST RTSPS connection closed."
        #expect(NvstBifrostFreeWatchdog.keepAliveStatus(fromSummary: dead)
            == NvstBifrostFreeWatchdog.KeepAliveStatus(sent: 13, answered: 12, failed: true))
        #expect(NvstBifrostFreeWatchdog.keepAliveStatus(fromSummary: "") == nil)
        #expect(NvstBifrostFreeWatchdog.keepAliveStatus(fromSummary: "something else entirely") == nil)
        #expect(NvstBifrostFreeWatchdog.keepAliveStatus(fromSummary: "keepalives=abc failed=0") == nil)
    }

    @Test("A failed control socket is reported at once")
    func keepAliveSocketFailure() {
        var tracker = NvstBifrostFreeWatchdog.KeepAliveTracker()
        let status = NvstBifrostFreeWatchdog.KeepAliveStatus(sent: 4, answered: 3, failed: true)
        #expect(tracker.failure(for: status, uptimeSeconds: 100) != nil)
    }

    @Test("A seat that stops answering keepalives is reported after the timeout")
    func keepAliveSilence() {
        var tracker = NvstBifrostFreeWatchdog.KeepAliveTracker()
        func status(_ answered: Int) -> NvstBifrostFreeWatchdog.KeepAliveStatus {
            .init(sent: answered + 1, answered: answered, failed: false)
        }
        #expect(tracker.failure(for: status(3), uptimeSeconds: 100) == nil)
        #expect(tracker.failure(for: status(4), uptimeSeconds: 102) == nil)
        // No further answer: silent, but not yet for long enough.
        #expect(tracker.failure(for: status(4), uptimeSeconds: 111.9) == nil)
        #expect(tracker.failure(for: status(4), uptimeSeconds: 112) != nil)
        // Progress resets the clock.
        #expect(tracker.failure(for: status(5), uptimeSeconds: 113) == nil)
        #expect(tracker.failure(for: status(5), uptimeSeconds: 120) == nil)
    }

    @Test("A seat that never answered a keepalive is not judged on silence")
    func keepAliveNeverAnswered() {
        var tracker = NvstBifrostFreeWatchdog.KeepAliveTracker()
        let status = NvstBifrostFreeWatchdog.KeepAliveStatus(sent: 1, answered: 0, failed: false)
        #expect(tracker.failure(for: status, uptimeSeconds: 0) == nil)
        #expect(tracker.failure(for: status, uptimeSeconds: 600) == nil)
    }

    // MARK: Statistics

    @Test("Cumulative counters become per-interval rates")
    func samplerRates() {
        var sampler = NvstPerformanceSampler(origin: NvstPerformanceSampler.Sample(uptimeSeconds: 10))
        let first = sampler.advance(to: NvstPerformanceSampler.Sample(
            uptimeSeconds: 11,
            framesDecoded: 120,
            bytesReceived: 5_000_000,
            packetsReceived: 4500,
            packetsLost: 0,
            framesHandled: 120,
            totalDecodeMilliseconds: 360,
            audioJitterBufferDelaySeconds: 2,
            audioJitterBufferEmitted: 48000
        ))
        #expect(first.framesPerSecond == 120)
        #expect(first.megabitsPerSecond == 40)
        #expect(first.packetLossPercent == 0)
        #expect(first.decodeMilliseconds == 3)
        // The origin carried no audio counters, so there is no interval to average over yet.
        #expect(first.audioJitterBufferMilliseconds == -1)

        let second = sampler.advance(to: NvstPerformanceSampler.Sample(
            uptimeSeconds: 13,
            framesDecoded: 240,
            bytesReceived: 7_500_000,
            packetsReceived: 5400,
            packetsLost: 100,
            framesHandled: 240,
            totalDecodeMilliseconds: 960,
            audioJitterBufferDelaySeconds: 4802,
            audioJitterBufferEmitted: 144_000
        ))
        #expect(second.framesPerSecond == 60)
        #expect(second.megabitsPerSecond == 10)
        // 100 lost against 900 received in the interval.
        #expect(second.packetLossPercent == 10)
        #expect(second.decodeMilliseconds == 5)
        #expect(abs(second.audioJitterBufferMilliseconds - 50) < 0.000_001)
    }

    @Test("The first reading without an origin reports nothing")
    func samplerFirstReading() {
        var sampler = NvstPerformanceSampler()
        let rates = sampler.advance(to: NvstPerformanceSampler.Sample(uptimeSeconds: 5, framesDecoded: 600, bytesReceived: 1_000_000))
        #expect(rates == NvstPerformanceSampler.Rates())
        #expect(sampler.previous?.framesDecoded == 600)
    }

    @Test("An idle interval and a restarted counter both read as no growth")
    func samplerEdges() {
        var sampler = NvstPerformanceSampler(origin: NvstPerformanceSampler.Sample(
            uptimeSeconds: 1, framesDecoded: 500, bytesReceived: 9000, packetsReceived: 80, packetsLost: 8, framesHandled: 500, totalDecodeMilliseconds: 1000
        ))
        let idle = sampler.advance(to: NvstPerformanceSampler.Sample(
            uptimeSeconds: 2, framesDecoded: 500, bytesReceived: 9000, packetsReceived: 80, packetsLost: 8, framesHandled: 500, totalDecodeMilliseconds: 1000
        ))
        #expect(idle.framesPerSecond == 0)
        #expect(idle.megabitsPerSecond == 0)
        #expect(idle.packetLossPercent == 0)
        // No frame was handled, so there is no decode time to report.
        #expect(idle.decodeMilliseconds == -1)
        let restarted = sampler.advance(to: NvstPerformanceSampler.Sample(uptimeSeconds: 3, framesDecoded: 10, bytesReceived: 100))
        #expect(restarted.framesPerSecond == 0)
        #expect(restarted.megabitsPerSecond == 0)
        #expect(NvstPerformanceSampler.delta(5, 9) == 0)
        #expect(NvstPerformanceSampler.delta(9, 5) == 4)
    }

    @Test("Two readings at the same instant do not divide by zero")
    func samplerZeroInterval() {
        var sampler = NvstPerformanceSampler(origin: NvstPerformanceSampler.Sample(uptimeSeconds: 7))
        let rates = sampler.advance(to: NvstPerformanceSampler.Sample(uptimeSeconds: 7, framesDecoded: 1))
        #expect(rates.framesPerSecond.isFinite)
        #expect(rates.framesPerSecond == 1000)
    }

    @Test("Latency comes from the most direct source that has a sample")
    func roundTripFallback() {
        #expect(NvstBifrostFreeTransport.firstAvailableRoundTrip([-1, -1, 6.5]) == 6.5)
        #expect(NvstBifrostFreeTransport.firstAvailableRoundTrip([3, 8, 6.5]) == 3)
        #expect(NvstBifrostFreeTransport.firstAvailableRoundTrip([-1, 0, 6.5]) == 0)
        #expect(NvstBifrostFreeTransport.firstAvailableRoundTrip([-1, .nan, -1]) == -1)
        #expect(NvstBifrostFreeTransport.firstAvailableRoundTrip([]) == -1)
    }
}
