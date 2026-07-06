import Foundation
import VoiceKeyboardModels
import XCTest

final class SharedDictationTranscriptStoreTests: XCTestCase {
    func testSavesAndLoadsLatestTranscript() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "hello from app",
            createdAt: Date(timeIntervalSince1970: 1_720_000_000)
        ))

        store.save(transcript)

        let latestTranscript = store.latestTranscript()
        XCTAssertEqual(latestTranscript, transcript)
    }

    func testBlankTranscriptIsRejected() {
        XCTAssertNil(SharedDictationTranscript(text: "   "))
    }

    func testLatestTranscriptCanBeConsumedOnlyOnceForKnownToken() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "insert once",
            createdAt: Date(timeIntervalSince1970: 1_720_000_001)
        ))
        store.save(transcript)

        let firstConsumedTranscript = store.consumeLatestTranscript(afterLastConsumedToken: nil)
        XCTAssertEqual(firstConsumedTranscript, transcript)
        store.markConsumed(transcript)

        let lastConsumedToken = store.lastConsumedToken()
        let secondConsumedTranscript = store.consumeLatestTranscript(
            afterLastConsumedToken: lastConsumedToken
        )
        XCTAssertNil(secondConsumedTranscript)
    }

    func testClaimMarksTranscriptConsumedBeforeCallerInsertsIt() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "claim before insert",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        store.save(transcript)

        let claimedTranscript = store.claimLatestTranscript(afterLastConsumedToken: nil)

        XCTAssertEqual(claimedTranscript, transcript)
        XCTAssertEqual(store.lastConsumedToken(), transcript.token)
        XCTAssertNil(store.consumeLatestTranscript(afterLastConsumedToken: store.lastConsumedToken()))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SharedDictationTranscriptStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
