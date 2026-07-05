import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

final class VoiceActivityPresentationSnapshotTests: XCTestCase {
    func testDirectInitializerStoresPresentationFields() {
        let meterSnapshot = VoiceActivityMeterSnapshot(
            state: .listening(level: 0.5),
            barCount: VoiceActivityMeterBarCount(3)!
        )
        let snapshot = VoiceActivityPresentationSnapshot(
            title: "Localized title",
            accessibilityValue: "Localized accessibility",
            meterSnapshot: meterSnapshot,
            tone: .positive
        )

        XCTAssertEqual(snapshot.title, "Localized title")
        XCTAssertEqual(snapshot.accessibilityValue, "Localized accessibility")
        XCTAssertEqual(snapshot.meterSnapshot, meterSnapshot)
        XCTAssertEqual(snapshot.tone, .positive)
    }

    func testPhaseMapsToTitleAndTone() {
        let cases: [(VoiceActivityState, String, String, PresentationTone)] = [
            (.unavailable, "Off", "Off", .critical),
            (.idle, "Idle", "Idle", .muted),
            (.listening, "Listening", "Listening", .positive),
            (.listening(level: 0), "Listening", "Listening, low input", .positive),
            (.listening(level: 0.34), "Listening", "Listening, medium input", .positive),
            (.listening(level: 0.67), "Listening", "Listening, high input", .positive),
            (.processing, "Processing", "Processing", .warning)
        ]

        for (state, title, accessibilityValue, tone) in cases {
            let snapshot = VoiceActivityPresentationSnapshot(
                state: state,
                meterBarCount: VoiceActivityMeterBarCount(3)!
            )

            XCTAssertEqual(snapshot.title, title)
            XCTAssertEqual(snapshot.accessibilityValue, accessibilityValue)
            XCTAssertEqual(snapshot.tone, tone)
        }
    }

    func testNonListeningStatesHaveInactiveMeters() {
        let states: [VoiceActivityState] = [.unavailable, .idle, .processing]

        for state in states {
            let snapshot = VoiceActivityPresentationSnapshot(
                state: state,
                meterBarCount: VoiceActivityMeterBarCount(3)!
            )

            XCTAssertEqual(snapshot.meterSnapshot.barLevels, [0, 0, 0])
        }
    }

    func testListeningWithLevelHasActiveMeter() {
        let snapshot = VoiceActivityPresentationSnapshot(
            state: .listening(level: 0.6),
            meterBarCount: VoiceActivityMeterBarCount(3)!
        )

        assertEqual(snapshot.meterSnapshot.barLevels, [0.4, 0.6, 0.4])
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
