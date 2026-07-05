import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

final class VoiceActivityMeterSnapshotTests: XCTestCase {
    func testListeningStateMapsInputLevelToBarLevels() {
        let snapshot = VoiceActivityMeterSnapshot(
            state: .listening(level: 0.8),
            barCount: VoiceActivityMeterBarCount(5)!
        )

        assertEqual(snapshot.barLevels, [0.48, 0.64, 0.8, 0.64, 0.48])
    }

    func testNonListeningStatesExposeInactiveBars() {
        let barCount = VoiceActivityMeterBarCount(3)!

        XCTAssertEqual(
            VoiceActivityMeterSnapshot(state: .idle, barCount: barCount).barLevels,
            [0, 0, 0]
        )
        XCTAssertEqual(
            VoiceActivityMeterSnapshot(state: .processing, barCount: barCount).barLevels,
            [0, 0, 0]
        )
        XCTAssertEqual(
            VoiceActivityMeterSnapshot(state: .unavailable, barCount: barCount).barLevels,
            [0, 0, 0]
        )
    }

    func testBarCountRequiresPositiveValue() {
        XCTAssertEqual(VoiceActivityMeterBarCount.standardVisibleBars.value, 7)
        XCTAssertEqual(VoiceActivityMeterBarCount(1)?.value, 1)
        XCTAssertNil(VoiceActivityMeterBarCount(0))
        XCTAssertNil(VoiceActivityMeterBarCount(-1))
    }

    private func assertEqual(
        _ actual: [Double],
        _ expected: [Double],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001, file: file, line: line)
        }
    }
}
