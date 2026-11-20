import Foundation
import VoiceKeyboardModels
import XCTest

final class DictationPCMTests: XCTestCase {
    func testRejectsMalformedEmptyOddAndOversizedChunks() {
        var recording = DictationPCM()
        for invalid in ["!", "", "AQ==", Data(repeating: 0, count: 8194).base64EncodedString()] {
            XCTAssertFalse(recording.append(base64: invalid))
        }
        XCTAssertEqual(recording.sampleCount, 0)
    }

    func testDecodesSignedLittleEndianAndNormalizesWithoutClipping() {
        var recording = DictationPCM()
        XCTAssertTrue(recording.append(base64: Data([0, 128, 0, 64, 0, 0]).base64EncodedString()))
        let samples = recording.normalizedSamples()
        XCTAssertEqual(samples[0], -0.9, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.45, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0)
    }

    func testSilenceStaysFiniteAndQuietInputGainIsBounded() {
        var recording = DictationPCM()
        XCTAssertTrue(recording.append(base64: Data([0, 0, 1, 0]).base64EncodedString()))
        let samples = recording.normalizedSamples()
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 4.0 / 32768, accuracy: 0.000001)
    }

    func testTruncatesAtSixtySeconds() {
        var recording = DictationPCM()
        let chunk = Data(repeating: 0, count: 8192).base64EncodedString()
        for _ in 0..<235 {
            XCTAssertTrue(recording.append(base64: chunk))
        }
        XCTAssertEqual(recording.sampleCount, 960_000)
        XCTAssertTrue(recording.isFull)
        XCTAssertFalse(recording.append(base64: chunk))
    }
}
