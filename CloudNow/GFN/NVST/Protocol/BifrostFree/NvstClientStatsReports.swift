import Foundation

// Client→server statistics reports on the control channel.
//
// Recovered from arm64 disassembly of libBifrost2 (`RiClientBackend`'s siblings
// `NvscClientPipeline`, `NvstQosManager`, `ServerControl`) with field-for-field corroboration
// from the binary's embedded `RM_BLOB_DEF` telemetry schema: blob 54 `ClientRtpStats` for
// `0x208`, blob 45 `ClientRtpNackStats` for `0x20a`, blob 5 `RlStats` for `0x209`, blob 18
// `L4SRxStats` for `0x210`, blob 58 `ClientControlChannelStats` for `0x313` and blob 48
// `AudioJitterBuffer` for `0x202`. Every multi-byte field is little-endian; framing is the
// standard `[u16 code][u16 length][payload]` control command. See
// `docs/NVST/OfficialClientAudit.md`.

/// Command `0x208`: the client's RTP receive statistics, a fixed 72-byte payload, sent every
/// `vqos[N].bw.rtpStatsTime` video frames by `NvscClientPipeline::sendRtpStats`. The field set
/// and order match telemetry blob 54 exactly.
nonisolated struct NvstRtpStatsReport: Equatable, Sendable {
    static let commandCode = NvstControlCommandCode.rtpStats
    static let version: UInt16 = 4
    static let payloadLength = 0x48
    /// The official cadence is one report per `vqos[N].bw.rtpStatsTime` video frames; that
    /// config's default value is not recovered from the binary, so this uses a one-second-class
    /// interval at the negotiated frame rate instead.
    static let frameInterval: UInt64 = 120

    let streamIndex: UInt16
    let frameNumber: UInt32
    let totalReceivedPackets: UInt64
    let outOfOrderPackets: UInt32
    /// Loss events: the official counter is queue drop events; the honest analog here is a
    /// finalized-loss range, one event per range.
    let dropEvents: UInt32
    /// Packets that arrived after their sequence was finalized as loss.
    let latePackets: UInt32
    /// Local rejections: authentication, parse, SSRC, stale and reassembly drops.
    let droppedPackets: UInt32
    /// Packets rebuilt by FEC recovery.
    let recoveredPackets: UInt32
    /// The largest single finalized-loss range, in packets.
    let maxDropBurstLength: UInt32
    /// The deepest the reorder buffer has been, in packets.
    let maxWaitingQueueDepth: UInt32
    let duplicatePackets: UInt32
    /// Mic chat bytes uploaded so far, telemetry blob 54's `rm_mic_chat_total_sent_data_bytes`.
    /// Zero until the bundle carries a microphone send section.
    let micChatSentDataBytes: UInt64

    init(streamIndex: UInt16 = 0,
         frameNumber: UInt32,
         totalReceivedPackets: UInt64,
         outOfOrderPackets: UInt32 = 0,
         dropEvents: UInt32 = 0,
         latePackets: UInt32 = 0,
         droppedPackets: UInt32 = 0,
         recoveredPackets: UInt32 = 0,
         maxDropBurstLength: UInt32 = 0,
         maxWaitingQueueDepth: UInt32 = 0,
         duplicatePackets: UInt32 = 0,
         micChatSentDataBytes: UInt64 = 0)
    {
        self.streamIndex = streamIndex
        self.frameNumber = frameNumber
        self.totalReceivedPackets = totalReceivedPackets
        self.outOfOrderPackets = outOfOrderPackets
        self.dropEvents = dropEvents
        self.latePackets = latePackets
        self.droppedPackets = droppedPackets
        self.recoveredPackets = recoveredPackets
        self.maxDropBurstLength = maxDropBurstLength
        self.maxWaitingQueueDepth = maxWaitingQueueDepth
        self.duplicatePackets = duplicatePackets
        self.micChatSentDataBytes = micChatSentDataBytes
    }

    /// The 72-byte payload. Fields this pipeline has no queue analog for (waiting-queue-full /
    /// timed-out / frame-complete drops) are the zero the absence of those queues implies.
    var payload: Data {
        var writer = NvstByteWriter(capacity: Self.payloadLength)
        writer.u16LE(Self.version) // +0x00
        writer.u16LE(streamIndex) // +0x02
        writer.u32LE(frameNumber) // +0x04
        writer.u64LE(totalReceivedPackets) // +0x08
        writer.u32LE(outOfOrderPackets) // +0x10
        writer.u32LE(dropEvents) // +0x14
        writer.u32LE(latePackets) // +0x18
        writer.u32LE(droppedPackets) // +0x1c
        writer.u32LE(recoveredPackets) // +0x20
        writer.u32LE(0) // +0x24 droppedWaitingQueueFull
        writer.u32LE(0) // +0x28 droppedWaitingQueueTimedOut
        writer.u32LE(maxDropBurstLength) // +0x2c
        writer.u32LE(maxWaitingQueueDepth) // +0x30
        writer.u32LE(0) // +0x34 droppedFrameComplete
        writer.u64LE(micChatSentDataBytes) // +0x38 micChatTotalSentDataBytes
        writer.u32LE(0) // +0x40 droppedWaitingFrameTimedOut
        writer.u32LE(duplicatePackets) // +0x44
        return writer.data
    }

    var command: NvstControlCommand {
        NvstControlCommand(code: Self.commandCode, payload: payload)
    }
}

/// Command `0x20a`: RTP NACK statistics, a fixed 28-byte payload emitted right after each
/// `0x208` by the same builder when the per-stream NACK-stats flag is set. Matches telemetry
/// blob 45. This client does not send NACKs (loss recovery rides FEC and keyframe requests), so
/// its counters are zero — the same payload the official client sends when its receiver is not
/// yet constructed.
nonisolated struct NvstRtpNackStatsReport: Equatable, Sendable {
    static let commandCode = NvstControlCommandCode.rtpStatsCompact
    static let version: UInt16 = 2
    static let payloadLength = 0x1C

    let streamIndex: UInt16
    let frameNumber: UInt32
    let nackRequestsSent: UInt32
    let nackedPacketsRequested: UInt32
    let nackedPacketsReceived: UInt32
    let nackedPacketsUtilized: UInt32
    let nackedPacketsRetried: UInt32

    init(streamIndex: UInt16 = 0,
         frameNumber: UInt32,
         nackRequestsSent: UInt32 = 0,
         nackedPacketsRequested: UInt32 = 0,
         nackedPacketsReceived: UInt32 = 0,
         nackedPacketsUtilized: UInt32 = 0,
         nackedPacketsRetried: UInt32 = 0)
    {
        self.streamIndex = streamIndex
        self.frameNumber = frameNumber
        self.nackRequestsSent = nackRequestsSent
        self.nackedPacketsRequested = nackedPacketsRequested
        self.nackedPacketsReceived = nackedPacketsReceived
        self.nackedPacketsUtilized = nackedPacketsUtilized
        self.nackedPacketsRetried = nackedPacketsRetried
    }

    var payload: Data {
        var writer = NvstByteWriter(capacity: Self.payloadLength)
        writer.u16LE(Self.version) // +0x00
        writer.u16LE(streamIndex) // +0x02
        writer.u32LE(frameNumber) // +0x04
        writer.u32LE(nackRequestsSent) // +0x08
        writer.u32LE(nackedPacketsRequested) // +0x0c
        writer.u32LE(nackedPacketsReceived) // +0x10
        writer.u32LE(nackedPacketsUtilized) // +0x14
        writer.u32LE(nackedPacketsRetried) // +0x18
        return writer.data
    }

    var command: NvstControlCommand {
        NvstControlCommand(code: Self.commandCode, payload: payload)
    }
}

/// One per-frame entry of the RL (rate limiter) feedback, command `0x209`.
nonisolated struct NvstRlFeedbackEntry: Equatable, Sendable {
    let frameNumber: UInt32
    /// The rate limiter's weighted bandwidth estimate; kbps inferred from the writer context
    /// (`updateWeightedBandwidthEstimation` feeds it), not from a string.
    let bandwidthEstimateKbps: UInt32
    /// Late packets recorded for the frame — the seat reads this as loss pressure.
    let latePackets: UInt16
    /// A secondary bandwidth parameter, tenths-of-a-percent scaled (or zero); units inferred
    /// from the `× 10.0` conversion at its only writer.
    let bandwidthUtilizationTenthsPercent: UInt16
}

/// Command `0x209`: reinforcement-learning rate-control feedback, variable `12 + 16 * count`
/// bytes, at most 16 frame entries per packet. Version 3 is the constant this build writes;
/// `SignalingHandler::handleVideoMediaBlock` stores the same default and this build has no SDP
/// path for any other value. Entries the official client cannot source are skipped, not zeroed;
/// the entry's trailing two bytes are never written by the library (stale staging memory), so
/// the canonical encoding zeros them.
nonisolated struct NvstRlFeedbackReport: Equatable, Sendable {
    static let commandCode = NvstControlCommandCode.rlFeedback
    static let version: UInt32 = 3
    static let maxEntries = 16

    let streamIndex: UInt16
    let entries: [NvstRlFeedbackEntry]

    init(streamIndex: UInt16 = 0, entries: [NvstRlFeedbackEntry]) {
        self.streamIndex = streamIndex
        self.entries = Array(entries.prefix(Self.maxEntries))
    }

    var payload: Data {
        var writer = NvstByteWriter(capacity: 12 + 16 * entries.count)
        writer.u32LE(Self.version) // +0x00
        writer.u32LE(UInt32(streamIndex)) // +0x04
        writer.u32LE(UInt32(entries.count)) // +0x08
        for entry in entries {
            writer.u32LE(entry.frameNumber) // +0x0c + 16*i
            writer.u32LE(entry.bandwidthEstimateKbps) // +0x04
            writer.u32LE(UInt32(entry.latePackets)) // +0x08 (u16 zero-extended on the wire)
            writer.u16LE(entry.bandwidthUtilizationTenthsPercent) // +0x0c
            writer.zeroes(2) // +0x0e unwritten staging; zeroed here
        }
        return writer.data
    }

    var command: NvstControlCommand {
        NvstControlCommand(code: Self.commandCode, payload: payload)
    }
}

/// Command `0x210`: ECN congestion feedback, variable `12 + 5 * count` bytes, at most 16
/// entries. The official client reports only frames with a non-zero percentage of CE-marked
/// packets (L4S receive stats, telemetry blob 18); a client that never sees ECN marking sends
/// nothing, which is what this client does until it parses CE marks.
nonisolated struct NvstEcnFeedbackReport: Equatable, Sendable {
    static let commandCode = NvstControlCommandCode.ecnFeedback
    static let maxEntries = 16

    struct Entry: Equatable, Sendable {
        let frameNumber: UInt32
        /// Percentage of the frame's packets that arrived CE-marked.
        let ceMarkedPercent: UInt8
    }

    let streamIndex: UInt16
    let entries: [Entry]

    init(streamIndex: UInt16 = 0, entries: [Entry]) {
        self.streamIndex = streamIndex
        self.entries = Array(entries.prefix(Self.maxEntries))
    }

    var payload: Data {
        var writer = NvstByteWriter(capacity: 12 + 5 * entries.count)
        writer.u32LE(UInt32(streamIndex)) // +0x00
        writer.u32LE(0) // +0x04 reserved; the library writes zero
        writer.u32LE(UInt32(entries.count)) // +0x08
        for entry in entries {
            writer.u32LE(entry.frameNumber) // +0x0c + 5*i
            writer.u8(entry.ceMarkedPercent) // +0x04
        }
        return writer.data
    }

    var command: NvstControlCommand {
        NvstControlCommand(code: Self.commandCode, payload: payload)
    }
}

/// One command's counters in the control-channel statistics report.
nonisolated struct NvstControlChannelCommandStats: Equatable, Sendable {
    let commandCode: UInt16
    let messagesSent: UInt32
    let messagesFailed: UInt32
    let aggregatedBytes: UInt64
}

/// Command `0x313`: control-channel statistics, a variable `28 + 20 * count` payload sent by
/// stream 0's pipeline every `general.controlChannelStatsTransmitIntervalMs` (60 s in the
/// announce this client sends). Header version 2 is written by `ServerControl`'s constructor;
/// the timestamp is microseconds since the library's steady-clock epoch, and `dumpStats` pins
/// every field's meaning. Matches telemetry blob 58's per-command content.
nonisolated struct NvstControlChannelStatsReport: Equatable, Sendable {
    static let commandCode = NvstControlCommandCode.controlChannelStats
    static let version: UInt32 = 2
    /// The transmit interval this client's own announce declares
    /// (`general.controlChannelStatsTransmitIntervalMs`).
    static let transmitInterval: TimeInterval = 60

    let timestampMicroseconds: UInt64
    let totalMessagesSent: UInt32
    let totalMessagesFailed: UInt32
    let totalBytesSent: UInt64
    let commands: [NvstControlChannelCommandStats]

    var payload: Data {
        var writer = NvstByteWriter(capacity: 28 + 20 * commands.count)
        writer.u32LE(Self.version) // +0x00
        writer.u64LE(timestampMicroseconds) // +0x04
        writer.u32LE(totalMessagesSent) // +0x0c
        writer.u32LE(totalMessagesFailed) // +0x10
        writer.u64LE(totalBytesSent) // +0x14
        for command in commands {
            writer.u32LE(UInt32(command.commandCode)) // +0x00 + 20*i
            writer.u32LE(command.messagesSent) // +0x04
            writer.u32LE(command.messagesFailed) // +0x08
            writer.u64LE(command.aggregatedBytes) // +0x0c
        }
        return writer.data
    }

    var command: NvstControlCommand {
        NvstControlCommand(code: Self.commandCode, payload: payload)
    }
}

/// Command `0x202`: audio jitter-buffer statistics, a fixed 124-byte payload sent by the audio
/// QoS thread with explicit reliable delivery. The first four bytes are the version (4), which
/// overwrites the aggregate struct's stream-index half; the remaining fields match telemetry
/// blob 48 `AudioJitterBuffer` in order. Jitter figures are milliseconds; the trailing delay
/// trio is clamped to 255 ms per field.
nonisolated struct NvstAudioJitterBufferStats: Equatable, Sendable {
    static let commandCode = NvstControlCommandCode.audioStats
    static let version: UInt32 = 4
    static let payloadLength = 0x7C

    var totalPackets: UInt32 = 0
    var packetStateBitmap: UInt64 = 0
    var audioStateBitmap: UInt64 = 0
    var jitterBufferStateBitmap: UInt64 = 0
    var systemTime: UInt32 = 0
    var fecCount: UInt32 = 0
    var lostPackets: UInt32 = 0
    var normalPackets: UInt32 = 0
    var packetsDroppedInput: UInt32 = 0
    var packetsDroppedOutput: UInt32 = 0
    var lastRtpTimestamp: UInt32 = 0
    var prunedPackets: UInt32 = 0
    /// Milliseconds.
    var averageBurstJitter: UInt32 = 0
    /// Milliseconds.
    var averageJitter: UInt32 = 0
    var lastPacketMovingAverage: Float = 0
    var countVariance: Float = 0
    var currentThreshold: UInt16 = 0
    var bufferUnderruns: UInt16 = 0
    var bufferOverruns: UInt16 = 0
    var outputDroppedReason0: UInt16 = 0
    var outputDroppedReason1: UInt16 = 0
    var outputDroppedReason2: UInt16 = 0
    var inputDroppedReason0: UInt16 = 0
    var inputDroppedReason1: UInt16 = 0
    var inputDroppedReason2: UInt16 = 0
    var resyncUnderruns: UInt8 = 0
    var resyncOverruns: UInt8 = 0
    var lastPacketCount: UInt8 = 0
    var cryptoDecodeErrors: UInt8 = 0
    var opusDecodeErrors: UInt8 = 0
    var packetSizeErrors: UInt8 = 0
    /// Milliseconds, clamped to 255 as the library clamps them.
    var renderDelayMilliseconds: UInt8 = 0
    var decoderDelayMilliseconds: UInt8 = 0
    var writeDelayMilliseconds: UInt8 = 0

    var payload: Data {
        var writer = NvstByteWriter(capacity: Self.payloadLength)
        writer.u32LE(Self.version) // +0x00
        writer.u32LE(totalPackets) // +0x04
        writer.u64LE(packetStateBitmap) // +0x08
        writer.u64LE(audioStateBitmap) // +0x10
        writer.u64LE(jitterBufferStateBitmap) // +0x18
        writer.u32LE(systemTime) // +0x20
        writer.u32LE(fecCount) // +0x24
        writer.u32LE(lostPackets) // +0x28
        writer.u32LE(normalPackets) // +0x2c
        writer.u32LE(packetsDroppedInput) // +0x30
        writer.u32LE(packetsDroppedOutput) // +0x34
        writer.u32LE(lastRtpTimestamp) // +0x38
        writer.u32LE(prunedPackets) // +0x3c
        writer.u32LE(averageBurstJitter) // +0x40
        writer.u32LE(averageJitter) // +0x44
        writer.float32LE(lastPacketMovingAverage) // +0x48
        writer.float32LE(countVariance) // +0x4c
        writer.u16LE(currentThreshold) // +0x50
        writer.u16LE(bufferUnderruns) // +0x52
        writer.u16LE(bufferOverruns) // +0x54
        writer.u16LE(outputDroppedReason0) // +0x56
        writer.u16LE(outputDroppedReason1) // +0x58
        writer.u16LE(outputDroppedReason2) // +0x5a
        writer.u16LE(inputDroppedReason0) // +0x5c
        writer.u16LE(inputDroppedReason1) // +0x5e
        writer.u16LE(inputDroppedReason2) // +0x60
        writer.u8(resyncUnderruns) // +0x62
        writer.u8(resyncOverruns) // +0x63
        writer.u8(lastPacketCount) // +0x64
        writer.u8(cryptoDecodeErrors) // +0x65
        writer.u8(opusDecodeErrors) // +0x66
        writer.u8(packetSizeErrors) // +0x67
        writer.u8(renderDelayMilliseconds) // +0x68
        writer.u8(decoderDelayMilliseconds) // +0x69
        writer.u8(writeDelayMilliseconds) // +0x6a
        writer.zeroes(Self.payloadLength - 0x6B) // +0x6b struct tail; reserved
        return writer.data
    }

    var command: NvstControlCommand {
        NvstControlCommand(code: Self.commandCode, payload: payload)
    }
}
