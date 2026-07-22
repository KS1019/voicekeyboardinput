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

    func testDefaultExpiryAllowsTimeForManualAppToKeyboardSwitch() throws {
        let createdAt = Date(timeIntervalSince1970: 1_720_000_000)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "switch back manually",
            createdAt: createdAt
        ))

        XCTAssertFalse(transcript.isExpired(at: createdAt.addingTimeInterval(60)))
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

    func testClaimPlacesLeaseWithoutMarkingTranscriptConsumed() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "lease before insert",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        store.save(transcript)

        let claimedTranscript = store.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        )

        XCTAssertEqual(claimedTranscript, transcript)
        XCTAssertNil(store.lastConsumedToken())
        XCTAssertEqual(store.latestTranscript()?.isConsumed, false)
        XCTAssertNil(store.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
    }

    func testExpiredDeliveryLeaseCanBeClaimedAgain() throws {
        let defaults = try makeDefaults()
        let firstStore = SharedDictationTranscriptStore(defaults: defaults)
        let secondStore = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "retry after insertion failure",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        firstStore.save(transcript)

        XCTAssertEqual(firstStore.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ), transcript)
        XCTAssertEqual(secondStore.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_016)
        ), transcript)
    }

    func testMarkConsumedMakesClaimIrreversibleAfterLeaseExpires() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "inserted successfully",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        store.save(transcript)
        let claimedTranscript = try XCTUnwrap(store.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))

        store.markConsumed(claimedTranscript)

        XCTAssertEqual(store.lastConsumedToken(), transcript.token)
        XCTAssertEqual(store.latestTranscript()?.isConsumed, true)
        XCTAssertNil(store.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_016)
        ))
    }

    func testConcurrentClaimsHaveSingleWinner() throws {
        let defaults = try makeDefaults()
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-a",
            commandToken: "command-a",
            text: "insert exactly once",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        let harness = ConcurrentClaimHarness(
            stores: [
                SharedDictationTranscriptStore(defaults: defaults),
                SharedDictationTranscriptStore(defaults: defaults)
            ],
            transcript: transcript
        )
        harness.stores[0].save(transcript)

        DispatchQueue.concurrentPerform(iterations: harness.stores.count) { index in
            harness.claim(usingStoreAt: index)
        }

        XCTAssertEqual(harness.claims, [transcript])
    }

    func testMarkConsumedDoesNotOverwriteTranscriptSavedAfterItsRead() throws {
        let defaults = try makeInterleavingDefaults()
        let consumingStore = SharedDictationTranscriptStore(defaults: defaults)
        let savingStore = SharedDictationTranscriptStore(defaults: defaults)
        let consumedTranscript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-a",
            commandToken: "command-a",
            text: "already claimed",
            createdAt: Date(timeIntervalSince1970: 1_720_000_004)
        ))
        let newerTranscript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-b",
            commandToken: "command-b",
            text: "saved concurrently",
            createdAt: Date(timeIntervalSince1970: 1_720_000_005)
        ))
        consumingStore.save(consumedTranscript)
        let concurrentSave = ConcurrentSaveHarness(
            store: savingStore,
            transcript: newerTranscript
        )
        defaults.afterNextObjectRead = {
            concurrentSave.start()
        }

        consumingStore.markConsumed(consumedTranscript)
        XCTAssertTrue(concurrentSave.waitUntilFinished())

        XCTAssertEqual(consumingStore.latestTranscript(), newerTranscript)
        XCTAssertEqual(consumingStore.lastConsumedToken(), consumedTranscript.token)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SharedDictationTranscriptStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeInterleavingDefaults() throws -> InterleavingUserDefaults {
        let suiteName = "SharedDictationTranscriptStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(InterleavingUserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class ConcurrentClaimHarness: @unchecked Sendable {
    let stores: [SharedDictationTranscriptStore]
    private let transcript: SharedDictationTranscript
    private let resultLock = NSLock()
    private var claimedTranscripts: [SharedDictationTranscript] = []

    var claims: [SharedDictationTranscript] {
        resultLock.lock()
        defer { resultLock.unlock() }
        return claimedTranscripts
    }

    init(
        stores: [SharedDictationTranscriptStore],
        transcript: SharedDictationTranscript
    ) {
        self.stores = stores
        self.transcript = transcript
    }

    func claim(usingStoreAt index: Int) {
        guard let claimedTranscript = stores[index].claimLatestTranscript(
            forSessionID: transcript.sessionID,
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ) else { return }
        resultLock.lock()
        claimedTranscripts.append(claimedTranscript)
        resultLock.unlock()
    }
}

private final class ConcurrentSaveHarness: @unchecked Sendable {
    private let store: SharedDictationTranscriptStore
    private let transcript: SharedDictationTranscript
    private let finished = DispatchSemaphore(value: 0)

    init(
        store: SharedDictationTranscriptStore,
        transcript: SharedDictationTranscript
    ) {
        self.store = store
        self.transcript = transcript
    }

    func start() {
        DispatchQueue.global().async { [self] in
            store.save(transcript)
            finished.signal()
        }
    }

    func waitUntilFinished() -> Bool {
        finished.wait(timeout: .now() + 2) == .success
    }
}

private final class InterleavingUserDefaults: UserDefaults, @unchecked Sendable {
    var afterNextObjectRead: (() -> Void)?

    override func object(forKey defaultName: String) -> Any? {
        let value = super.object(forKey: defaultName)
        let action = afterNextObjectRead
        afterNextObjectRead = nil
        action?()
        return value
    }
}
