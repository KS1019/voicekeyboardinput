import Foundation
import VoiceKeyboardModels
import VoiceKeyboardSharedStorage
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

        let now = Date(timeIntervalSince1970: 1_720_000_010)
        let firstConsumedTranscript = store.consumeLatestTranscript(
            afterLastConsumedToken: nil,
            now: now
        )
        XCTAssertEqual(firstConsumedTranscript, transcript)
        store.markConsumed(transcript)

        let lastConsumedToken = store.lastConsumedToken()
        let secondConsumedTranscript = store.consumeLatestTranscript(
            afterLastConsumedToken: lastConsumedToken,
            now: now
        )
        XCTAssertNil(secondConsumedTranscript)
    }

    func testTranscriptForAnotherSessionIsNotAccepted() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-a",
            commandToken: "command-a",
            text: "only session a",
            createdAt: Date(timeIntervalSince1970: 1_720_000_003)
        ))
        store.save(transcript)

        XCTAssertNil(store.consumeLatestTranscript(
            forSessionID: "session-b",
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
        XCTAssertEqual(
            store.consumeLatestTranscript(
                forSessionID: "session-a",
                afterLastConsumedToken: nil,
                now: Date(timeIntervalSince1970: 1_720_000_010)
            ),
            transcript
        )
    }

    func testExpiredTranscriptIsNotConsumed() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-a",
            commandToken: "command-a",
            text: "expired",
            createdAt: Date(timeIntervalSince1970: 100),
            expiryInterval: 10
        ))
        store.save(transcript)

        XCTAssertNil(store.consumeLatestTranscript(
            forSessionID: "session-a",
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 111)
        ))
    }

    func testClaimMarksTranscriptConsumedBeforeCallerInsertsIt() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "claim before insert",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        store.save(transcript)

        let claimedTranscript = store.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        )

        XCTAssertEqual(claimedTranscript, transcript)
        XCTAssertEqual(store.lastConsumedToken(), transcript.token)
        XCTAssertNil(store.consumeLatestTranscript(
            afterLastConsumedToken: store.lastConsumedToken(),
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SharedDictationTranscriptStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
