import Dispatch
import Foundation

/// Counts decoded frames and remembers when the last one arrived, off every actor: the decode
/// callback writes it at stream cadence, and the first-frame wait and the stall watchdog read it.
final nonisolated class NvstFrameMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: UInt64 = 0
    private var lastFrameUptimeNanoseconds: UInt64?

    /// Called for every decoded frame, on the decode thread.
    func noteFrame(uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        frames &+= 1
        lastFrameUptimeNanoseconds = uptimeNanoseconds
        lock.unlock()
    }

    var decodedFrameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    /// Seconds since the last decoded frame; nil before the first one.
    func secondsSinceLastFrame(uptimeNanoseconds now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Double? {
        lock.lock()
        let last = lastFrameUptimeNanoseconds
        lock.unlock()
        guard let last else { return nil }
        return now > last ? Double(now - last) / 1_000_000_000 : 0
    }
}

/// The conditions under which a connected NVST stream is declared dead. The transport itself
/// reports only a seat termination and a decode failure storm; a stream that simply stops, or a
/// control connection that dies, is noticed here.
nonisolated enum NvstBifrostFreeWatchdog {
    /// How long a connected stream may go without a decoded frame. The seat keeps sending frames
    /// for a static scene, so ten silent seconds is a dead video path, not a quiet game.
    static let stallTimeoutSeconds = 10.0

    /// How long the RTSPS keepalive may go unanswered. The seat answers every `GET_PARAMETER`
    /// (sent every 2 s) and ends a session whose control connection is gone.
    static let keepAliveTimeoutSeconds = 10.0

    /// How often the transport's housekeeping tick runs.
    static let tickSeconds = 1.0

    /// The stall verdict for a stream that has already shown its first frame.
    static func isStalled(secondsSinceLastFrame: Double?) -> Bool {
        guard let secondsSinceLastFrame else { return false }
        return secondsSinceLastFrame >= stallTimeoutSeconds
    }

    /// What the RTSPS connection's keepalive summary says about its health.
    struct KeepAliveStatus: Equatable, Sendable {
        var sent = 0
        var answered = 0
        /// The connection recorded a socket failure.
        var failed = false
    }

    /// Reads `keepalives=<sent>/<answered> … failed=<0|1> …`, the control connection's own
    /// diagnostic summary and the only view of its liveness the negotiated session exposes.
    /// Nil when the text is not that summary.
    static func keepAliveStatus(fromSummary summary: String) -> KeepAliveStatus? {
        var status = KeepAliveStatus()
        var sawCounters = false
        for field in summary.split(separator: " ") {
            if field.hasPrefix("keepalives=") {
                let counts = field.dropFirst("keepalives=".count).split(separator: "/")
                guard counts.count == 2, let sent = Int(counts[0]), let answered = Int(counts[1]) else { return nil }
                status.sent = sent
                status.answered = answered
                sawCounters = true
            } else if field.hasPrefix("failed=") {
                status.failed = field.dropFirst("failed=".count) != "0"
            }
        }
        return sawCounters ? status : nil
    }

    /// Tracks keepalive progress between ticks: the connection is dead when it says so itself, or
    /// when a seat that had been answering keepalives has answered none for
    /// `keepAliveTimeoutSeconds`. A seat that never answered one is not judged on silence: only
    /// its socket failing counts.
    struct KeepAliveTracker: Equatable, Sendable {
        private(set) var lastAnswered = 0
        private(set) var lastProgressUptimeSeconds: Double?

        /// Returns the failure to report, or nil while the control connection looks alive.
        mutating func failure(for status: KeepAliveStatus, uptimeSeconds now: Double) -> String? {
            if status.failed {
                return "The RTSPS control connection to the seat failed."
            }
            if lastProgressUptimeSeconds == nil || status.answered > lastAnswered {
                lastAnswered = status.answered
                lastProgressUptimeSeconds = now
                return nil
            }
            guard lastAnswered > 0, let lastProgress = lastProgressUptimeSeconds,
                  now - lastProgress >= NvstBifrostFreeWatchdog.keepAliveTimeoutSeconds else { return nil }
            return "The seat stopped answering the RTSPS keepalive."
        }
    }
}

/// Turns the transport's cumulative counters into the per-interval rates a HUD shows.
nonisolated struct NvstPerformanceSampler: Equatable, Sendable {
    /// One reading of the cumulative counters.
    struct Sample: Equatable, Sendable {
        var uptimeSeconds = 0.0
        var framesDecoded: UInt64 = 0
        var bytesReceived: UInt64 = 0
        var packetsReceived: UInt64 = 0
        var packetsLost: UInt64 = 0
        var framesHandled: UInt64 = 0
        /// The pipeline's cumulative decode time, in milliseconds.
        var totalDecodeMilliseconds = 0.0
        /// libwebrtc's cumulative `jitterBufferDelay` / `jitterBufferEmittedCount`; nil while the
        /// bundle reports no inbound audio.
        var audioJitterBufferDelaySeconds: Double?
        var audioJitterBufferEmitted: UInt64?
    }

    /// What happened between two readings.
    struct Rates: Equatable, Sendable {
        var framesPerSecond = 0.0
        var megabitsPerSecond = 0.0
        /// lost / (received + lost) over the interval, in percent — the way the WebRTC path
        /// computes it, so the two HUDs report the same quantity.
        var packetLossPercent = 0.0
        /// Mean decode cost of the frames handled in the interval; -1 when there were none.
        var decodeMilliseconds = -1.0
        /// Mean jitter-buffer dwell of the audio emitted in the interval; -1 when unknown.
        var audioJitterBufferMilliseconds = -1.0
    }

    private(set) var previous: Sample?

    /// Starts a new measurement from `origin`, typically all-zero counters at session start.
    init(origin: Sample? = nil) {
        previous = origin
    }

    /// Records `sample` and returns the rates since the previous one. The first reading with no
    /// origin has nothing to compare against and reports zeros.
    mutating func advance(to sample: Sample) -> Rates {
        defer { previous = sample }
        guard let previous else { return Rates() }
        let interval = max(0.001, sample.uptimeSeconds - previous.uptimeSeconds)
        var rates = Rates()
        rates.framesPerSecond = Double(Self.delta(sample.framesDecoded, previous.framesDecoded)) / interval
        rates.megabitsPerSecond = Double(Self.delta(sample.bytesReceived, previous.bytesReceived)) * 8 / interval / 1_000_000
        let received = Self.delta(sample.packetsReceived, previous.packetsReceived)
        let lost = Self.delta(sample.packetsLost, previous.packetsLost)
        if received + lost > 0 {
            rates.packetLossPercent = Double(lost) * 100 / Double(received + lost)
        }
        let handled = Self.delta(sample.framesHandled, previous.framesHandled)
        if handled > 0 {
            rates.decodeMilliseconds = max(0, sample.totalDecodeMilliseconds - previous.totalDecodeMilliseconds) / Double(handled)
        }
        if let delay = sample.audioJitterBufferDelaySeconds, let emitted = sample.audioJitterBufferEmitted,
           let previousDelay = previous.audioJitterBufferDelaySeconds, let previousEmitted = previous.audioJitterBufferEmitted,
           emitted > previousEmitted
        {
            rates.audioJitterBufferMilliseconds = max(0, delay - previousDelay) / Double(emitted - previousEmitted) * 1000
        }
        return rates
    }

    /// A cumulative counter's growth; a counter that went backwards (a restarted receiver) reads
    /// as no growth rather than as a huge one.
    static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

/// Resumes a continuation exactly once, with whichever answer arrives first. Used to bound waits
/// on callbacks that are not guaranteed to fire: a statistics request against a closing peer
/// connection, a TEARDOWN on a control socket that has gone quiet.
final nonisolated class NvstOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// Returns true when this call was the one that resumed the continuation.
    @discardableResult
    func resume(_ value: Value) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}
