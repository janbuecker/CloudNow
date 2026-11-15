@testable import CloudNow
import CoreMedia
import Foundation
import Testing

@Suite("NVST facade mapping")
struct GFNNVSTMappingTests {
    // MARK: Events

    @Test("A held rumble state maps to haptics without a duration")
    func hapticStateEvent() {
        let event = GFNNVSTEvent.rumble(from: NvstHapticEvent(gamepadIndex: 2, leftMotor: 0x8000, rightMotor: 0x4000))
        guard case let .haptics(playerIndex, leftMotor, rightMotor, durationMs) = event else {
            Issue.record("expected a haptics event")
            return
        }
        #expect(playerIndex == 2)
        #expect(leftMotor == 0x8000)
        #expect(rightMotor == 0x4000)
        #expect(durationMs == nil)
    }

    @Test("A rumble pulse carries its duration, with the seat's default for zero", arguments: [(UInt16(250), 250), (0, 1000)])
    func hapticPulseEvent(duration: UInt16, expected: Int) {
        let event = GFNNVSTEvent.rumble(from: NvstHapticEvent(gamepadIndex: 0, leftMotor: 65535, rightMotor: 0, durationMilliseconds: duration))
        guard case let .haptics(playerIndex, leftMotor, rightMotor, durationMs) = event else {
            Issue.record("expected a haptics event")
            return
        }
        #expect(playerIndex == 0)
        #expect(leftMotor == 65535)
        #expect(rightMotor == 0)
        #expect(durationMs == expected)
    }

    @Test("Rumble parsed from the seat's command reaches the facade unchanged")
    func hapticCommandToEvents() throws {
        // kind 1, 12 bytes: pad 0 left 0x8000 right 0x4000; pad 1 silent.
        let command = NvstControlCommand(code: NvstControlCommandCode(rawValue: 0x010B), payload: Data([
            0x01, 0x00, 0x0C, 0x00,
            0x00, 0x00, 0x00, 0x80, 0x00, 0x40,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]))
        let events = try #require(NvstHapticEvent.parse(command)).map(GFNNVSTEvent.rumble(from:))
        #expect(events.count == 2)
        guard case let .haptics(firstPlayer, firstLeft, firstRight, _) = events[0],
              case let .haptics(secondPlayer, secondLeft, secondRight, _) = events[1]
        else {
            Issue.record("expected two haptics events")
            return
        }
        #expect((firstPlayer, firstLeft, firstRight) == (0, 0x8000, 0x4000))
        #expect((secondPlayer, secondLeft, secondRight) == (1, 0, 0))
    }

    @Test("A seat termination is named from its result code")
    func terminationNaming() throws {
        let known = try #require(NvstResultCode.names.first)
        let termination = NvstSeatTermination(result: known.key, payload: Data())
        let event = GFNNVSTEvent.terminal(from: .sessionTerminated(termination.sessionTermination))
        guard case let .sessionTerminated(code, name) = event else {
            Issue.record("expected a session termination")
            return
        }
        #expect(code == known.key)
        #expect(name == known.value)
    }

    @Test("An unknown result code is reported without a name")
    func unknownTerminationCode() {
        let code: UInt32 = 0x7FFF_FFF1
        #expect(NvstResultCode.name(for: code) == nil)
        let termination = NvstSeatTermination(result: code, payload: Data()).sessionTermination
        guard case let .sessionTerminated(reported, name) = GFNNVSTEvent.seatTermination(from: termination) else {
            Issue.record("expected a session termination")
            return
        }
        #expect(reported == code)
        #expect(name == nil)
        #expect(!termination.isPause)
        #expect(!termination.isResumable)
    }

    @Test("A session pause is still a termination of this stream, flagged resumable")
    func pauseTermination() {
        let termination = NvstSeatTermination(result: NvstSeatTermination.sessionPauseResult, payload: Data()).sessionTermination
        #expect(termination.isPause)
        #expect(termination.isResumable)
        #expect(termination.isSessionAlive)
        guard case let .sessionTerminated(code, _) = GFNNVSTEvent.seatTermination(from: termination) else {
            Issue.record("expected a session termination")
            return
        }
        #expect(code == 0x8003_000E)
    }

    @Test("A transport failure becomes a failed event with its message")
    func failureEvent() {
        let failure = NativeNVSTTransportFailure(message: "No video frame was decoded for 10 seconds.", origin: .video, recoveryClassification: .transientNetwork)
        guard case let .failed(message) = GFNNVSTEvent.terminal(from: .transportFailed(failure)) else {
            Issue.record("expected a failed event")
            return
        }
        #expect(message == failure.message)
    }

    // MARK: Errors

    @Test("Connect failures map onto the facade's error cases")
    func connectFailureMapping() {
        #expect(GFNNVSTError(connectFailure: NativeNVSTError.missingControlEndpoint("none")) == .noRTSPEndpoint)
        #expect(GFNNVSTError(connectFailure: NativeNVSTError.bundleFailed("dtls")) == .bundleFailed("dtls"))
        #expect(GFNNVSTError(connectFailure: NativeNVSTError.transportFailed("describe 404")) == .negotiationFailed("describe 404"))
        #expect(GFNNVSTError(connectFailure: CancellationError()) == .cancelled)
        #expect(GFNNVSTError(connectFailure: GFNNVSTError.firstFrameTimeout) == .firstFrameTimeout)
        #expect(GFNNVSTError(connectFailure: NativeNVSTError.alreadyRunning)
            == .negotiationFailed("Native NVST stream is already running."))
    }

    @Test("A terminal report during connect fails the connect with the matching error")
    func terminalDuringConnectMapping() {
        let bundle = NativeNVSTTransportFailure(message: "ICE failed", origin: .bundle, recoveryClassification: .transientNetwork)
        #expect(GFNNVSTError(duringConnect: .transportFailed(bundle)) == .bundleFailed("ICE failed"))
        let video = NativeNVSTTransportFailure(message: "decode storm", origin: .video, recoveryClassification: .permanent)
        #expect(GFNNVSTError(duringConnect: .transportFailed(video)) == .negotiationFailed("decode storm"))
        let control = NativeNVSTTransportFailure(message: "socket closed", origin: .control, recoveryClassification: .transientNetwork)
        #expect(GFNNVSTError(duringConnect: .transportFailed(control)) == .negotiationFailed("socket closed"))
        let termination = NvstSeatTermination(result: 0x7FFF_FFF1, payload: Data()).sessionTermination
        #expect(GFNNVSTError(duringConnect: .sessionTerminated(termination)) == .negotiationFailed(termination.message))
    }

    // MARK: Statistics

    @Test("A performance snapshot maps onto the facade statistics")
    func statsMapping() {
        var snapshot = NativeNVSTPerformanceSnapshot()
        snapshot.available = true
        snapshot.gameFramesPerSecond = 118.5
        snapshot.streamFramesPerSecond = 119.9
        snapshot.latencyMilliseconds = 12.5
        snapshot.jitterMilliseconds = 0.8
        snapshot.packetLossPercent = 0.25
        snapshot.decodeMilliseconds = 3.2
        snapshot.bitrateMegabitsPerSecond = 42.4567
        snapshot.resolution = "3840x2160"
        snapshot.codec = "H265"
        snapshot.audioJitterBufferMilliseconds = 48
        snapshot.packetsReceived = 100_000
        snapshot.packetsLost = 25
        snapshot.packetsRecoveredByFEC = 20
        snapshot.retransmissionRequestsSent = 4
        snapshot.keyframeRequestsSent = 2
        snapshot.framesDecoded = 7200
        snapshot.framesDropped = 3
        snapshot.audioPacketsReceived = 12000
        snapshot.audioConcealedSamples = 480

        #expect(GFNNVSTStatsSnapshot(snapshot) == GFNNVSTStatsSnapshot(
            framesPerSecond: 119.9,
            bitrateKbps: 42457,
            width: 3840,
            height: 2160,
            codec: "H265",
            roundTripMs: 12.5,
            jitterMs: 0.8,
            packetLossPercent: 0.25,
            decodeTimeMs: 3.2,
            packetsReceived: 100_000,
            packetsLost: 25,
            packetsRecoveredByFEC: 20,
            nacksSent: 4,
            keyframeRequests: 2,
            framesDecoded: 7200,
            framesDropped: 3,
            gameFps: 118.5,
            audioPacketsReceived: 12000,
            audioConcealedSamples: 480,
            audioJitterBufferMs: 48
        ))
    }

    @Test("Values the transport does not know yet read as zero")
    func unknownStatsAreZero() {
        let stats = GFNNVSTStatsSnapshot(NativeNVSTPerformanceSnapshot())
        #expect(stats == GFNNVSTStatsSnapshot())
        #expect(stats.roundTripMs == 0)
        #expect(stats.gameFps == 0)
        #expect(stats.decodeTimeMs == 0)
        #expect(stats.audioJitterBufferMs == 0)
    }

    @Test("The decoded resolution string is split into width and height")
    func resolutionParsing() {
        #expect(GFNNVSTStatsSnapshot.dimensions(fromResolution: "1920x1080") == (1920, 1080))
        #expect(GFNNVSTStatsSnapshot.dimensions(fromResolution: "2560X1440") == (2560, 1440))
        #expect(GFNNVSTStatsSnapshot.dimensions(fromResolution: "") == (0, 0))
        #expect(GFNNVSTStatsSnapshot.dimensions(fromResolution: "1920") == (0, 0))
        #expect(GFNNVSTStatsSnapshot.dimensions(fromResolution: "0x1080") == (0, 0))
        #expect(GFNNVSTStatsSnapshot.dimensions(fromResolution: "wide x tall") == (0, 0))
    }

    @Test("A frame's presentation time is its 90 kHz RTP timestamp")
    func rtpTimestampFromPresentationTime() {
        #expect(GFNNVSTTransport.rtpTimestamp(from: CMTime(value: 90000, timescale: 90000)) == 90000)
        #expect(GFNNVSTTransport.rtpTimestamp(from: CMTime(value: CMTimeValue(UInt32.max), timescale: 90000)) == UInt32.max)
        #expect(GFNNVSTTransport.rtpTimestamp(from: CMTime(value: 0, timescale: 90000)) == 0)
    }

    @Test("Transport errors carry the message they were raised with")
    func nativeErrorDescriptions() {
        #expect(NativeNVSTError.transportFailed("why").errorDescription == "why")
        #expect(NativeNVSTError.bundleFailed("why").errorDescription == "why")
        #expect(NativeNVSTError.missingControlEndpoint("why").errorDescription == "why")
        #expect(NativeNVSTError.notRunning.errorDescription == "Native NVST stream is not running.")
    }
}
