@testable import CloudNow
import Foundation
import Testing

@Suite(.serialized)
struct NvstAnnexBTests {
    /// The seat pads some access units with zeros before a start code (seen live ahead of a
    /// parameter-set change). Taken as a unit, `00 00` is an invalid NAL header and VideoToolbox
    /// rejected the whole frame as bad data.
    @Test func zeroPaddingBetweenStartCodesIsNotANalUnit() {
        let slice: [UInt8] = [0x02, 0x01, 0xD4, 0x60, 0x8A]
        let accessUnit = Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01] + slice + [0x00, 0x00])
        let units = NvstAnnexB.nalUnits(accessUnit)
        #expect(units.count == 1)
        #expect(units.first?.length == slice.count)
        let sample = NvstElementaryStream.prepare(accessUnit, codec: .hevc).sample
        #expect(sample == Data([0x00, 0x00, 0x00, UInt8(slice.count)] + slice))
    }

    @Test func findStartCodeFindsFourByteFirst() {
        let data = Data([0x00, 0x00, 0x00, 0x01, 0x65])
        let found = NvstAnnexB.findStartCode(data)
        #expect(found?.offset == 0)
        #expect(found?.prefixLength == 4)
    }

    @Test func findStartCodeFallsBackToThreeByte() {
        let data = Data([0x0A, 0x0B, 0x00, 0x00, 0x01, 0x65])
        let found = NvstAnnexB.findStartCode(data)
        #expect(found?.offset == 2)
        #expect(found?.prefixLength == 3)
    }

    @Test func theEarliestStartCodeWinsRegardlessOfLength() {
        // Scanning the whole buffer for the four-byte form first would skip an earlier three-byte
        // start code and hand the decoder a truncated access unit.
        let data = Data([0x00, 0x00, 0x01, 0x65, 0xAA, 0x00, 0x00, 0x00, 0x01, 0x41])
        let found = NvstAnnexB.findStartCode(data)
        #expect(found?.offset == 0)
        #expect(found?.prefixLength == 3)
        // A four-byte code that genuinely comes first still wins.
        let fourFirst = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x00, 0x00, 0x01, 0x41])
        #expect(NvstAnnexB.findStartCode(fourFirst)?.prefixLength == 4)
        #expect(NvstAnnexB.findStartCode(Data([0x01, 0x02])) == nil)
    }

    @Test func isKeyframeDetectsIdrNalTypeFive() {
        // SPS(7) + PPS(8) + IDR(5)
        let keyframe = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x00, 0x00, 0x00, 0x01, 0x68, 0x00, 0x00, 0x00, 0x01, 0x65, 0x88])
        #expect(NvstAnnexB.isKeyframe(keyframe))
        // Non-IDR slice (1)
        let nonKeyframe = Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x88])
        #expect(!NvstAnnexB.isKeyframe(nonKeyframe))
    }

    @Test func picturePayloadTrimsToFirstStartCode() {
        // GS metadata precedes the actual NAL start code.
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x00, 0x00, 0x00, 0x01, 0x65, 0x77])
        let payload = NvstAnnexB.picturePayload(data)
        #expect(payload == Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x77]))
    }

    @Test func datagramClassifierDistinguishesTypes() {
        let rtp = Data([0x90, 0xE0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x11, 0x22, 0x33, 0x44])
        let stun = Data([0x00, 0x01, 0x00, 0x4C, 0x21, 0x12, 0xA4, 0x42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let dtls = Data([0x16, 0xFE, 0xFD, 0x00, 0x00, 0x01])
        #expect(NvstDatagramClassifier.looksLikeRTP(rtp))
        #expect(NvstDatagramClassifier.looksLikeSTUN(stun))
        #expect(NvstDatagramClassifier.looksLikeDTLS(dtls))
        #expect(NvstDatagramClassifier.rtpSSRC(rtp) == 0x1122_3344)
        #expect(!NvstDatagramClassifier.looksLikeRTP(stun))
        #expect(!NvstDatagramClassifier.looksLikeRTP(dtls))
    }
}

struct NvstElementaryStreamTests {
    /// SPS(7) + PPS(8) + AUD(9) + IDR(5), Annex-B delimited with mixed 3- and 4-byte prefixes.
    private static let h264AccessUnit = Data([
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xE0,
        0x00, 0x00, 0x01, 0x68, 0xCE,
        0x00, 0x00, 0x00, 0x01, 0x09, 0x10,
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84,
    ])

    @Test func nalUnitsSpanBothStartCodeLengths() {
        let units = NvstAnnexB.nalUnits(Self.h264AccessUnit)
        #expect(units.map(\.length) == [3, 2, 2, 3])
        #expect(units.map(\.offset) == [4, 10, 16, 22])
    }

    @Test func parameterSetsAreLiftedOutOfAKeyframe() {
        let sets = NvstElementaryStream.parameterSets(in: Self.h264AccessUnit, codec: .h264)
        #expect(sets.sequenceParameterSets == [Data([0x67, 0x42, 0xE0])])
        #expect(sets.pictureParameterSets == [Data([0x68, 0xCE])])
        #expect(sets.videoParameterSets.isEmpty)
        #expect(sets.isComplete)
        // H.264 wants SPS then PPS; HEVC prepends VPS.
        #expect(sets.ordered == [Data([0x67, 0x42, 0xE0]), Data([0x68, 0xCE])])
    }

    @Test func hevcParameterSetsUseTheSixBitNalType() {
        // VPS(32) + SPS(33) + PPS(34) + IDR_W_RADL(19)
        let unit = Data([
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x42, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x44, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAF,
        ])
        let sets = NvstElementaryStream.parameterSets(in: unit, codec: .hevc)
        #expect(sets.videoParameterSets == [Data([0x40, 0x01])])
        #expect(sets.sequenceParameterSets == [Data([0x42, 0x01])])
        #expect(sets.pictureParameterSets == [Data([0x44, 0x01])])
        #expect(sets.ordered.count == 3)
        #expect(NvstAnnexB.isKeyframe(unit, codec: .hevc))
        // The H.264 reading of the same bytes must not accidentally match.
        #expect(!NvstAnnexB.isKeyframe(unit, codec: .h264))
    }

    @Test func pictureNalUnitsExcludeParameterSetsAndDelimiters() {
        let units = NvstElementaryStream.pictureNalUnits(in: Self.h264AccessUnit, codec: .h264)
        #expect(units == [Data([0x65, 0x88, 0x84])])
    }

    @Test func sampleDataIsFourByteLengthPrefixed() {
        let sample = NvstElementaryStream.sampleData(for: Self.h264AccessUnit, codec: .h264)
        #expect(sample == Data([0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84]))
        // Two NAL units keep their own prefixes.
        let two = NvstElementaryStream.lengthPrefixed([Data([0xAA]), Data([0xBB, 0xCC])])
        #expect(two == Data([0, 0, 0, 1, 0xAA, 0, 0, 0, 2, 0xBB, 0xCC]))
    }

    @Test func aDeltaFrameCarriesNoParameterSets() {
        let delta = Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9A])
        let sets = NvstElementaryStream.parameterSets(in: delta, codec: .h264)
        #expect(!sets.isComplete)
        #expect(NvstElementaryStream.pictureNalUnits(in: delta, codec: .h264) == [Data([0x41, 0x9A])])
    }

    /// `prepare` is the single copy-free pass the decoder actually runs, so it must agree with
    /// the split helpers: parameter sets and the AUD lifted out, the IDR length-prefixed.
    @Test func prepareStripsAv1TemporalDelimitersAndHarvestsTheSequenceHeader() {
        // Temporal delimiter + sequence header + frame: the TD is not sample data, and the SH
        // becomes the parameter set the av1C format description is built from.
        let unit = Data([0x12, 0x00, 0x0A, 0x02, 0xAA, 0xBB, 0x32, 0x01, 0x00])
        let prepared = NvstElementaryStream.prepare(unit, codec: .av1)
        #expect(prepared.sample == Data([0x0A, 0x02, 0xAA, 0xBB, 0x32, 0x01, 0x00]))
        // The configuration form is the wire OBU verbatim — VideoToolbox's av1C validation
        // requires the size field.
        #expect(prepared.parameterSets.sequenceParameterSets == [Data([0x0A, 0x02, 0xAA, 0xBB])])
        #expect(prepared.parameterSets.isComplete(for: .av1))
        #expect(!prepared.parameterSets.isComplete)
    }

    @Test func av1KeyframeDetectionReadsTheObuFrameHeader() {
        // FRAME OBU, first payload bit show_existing_frame=0, frame_type=0 (KEY_FRAME).
        let keyframe = Data([0x32, 0x02, 0x00, 0x99])
        #expect(NvstAnnexB.scan(keyframe, codec: .av1).isKeyframe)
        // frame_type=1 (INTER_FRAME) is not.
        let inter = Data([0x32, 0x02, 0x20, 0x99])
        #expect(!NvstAnnexB.scan(inter, codec: .av1).isKeyframe)
    }
}
