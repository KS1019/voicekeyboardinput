import Foundation
import VoiceKeyboardModels
import VoiceKeyboardSharedStorage
import XCTest

final class SharedDictationTranscriptStoreTests: XCTestCase {
    private struct LegacyDeliveryLeaseFixture: Codable {
        let transcriptToken: String
        let expiresAt: Date
        let ownerID: String?
    }

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

    func testLatestTranscriptResolutionDistinguishesMissingFromUnavailable() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)

        XCTAssertEqual(
            store.latestTranscriptResolution(forSessionID: "missing-session"),
            .missing
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceKeyboardTranscriptUnreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let envelopeURL = root.appendingPathComponent("envelope.json")
        let lockURL = root.appendingPathComponent("store.lock")
        let fileStore = try XCTUnwrap(SharedDictationTranscriptStore(
            defaults: try makeDefaults(),
            envelopeURL: envelopeURL,
            lockFileURL: lockURL
        ))
        XCTAssertTrue(fileStore.save(try XCTUnwrap(SharedDictationTranscript(
            sessionID: "unavailable-session",
            commandToken: "unavailable-command",
            text: "protected result"
        ))))
        try Data([0xFF]).write(to: envelopeURL, options: [.atomic])
        try Data([0xFF]).write(to: envelopeURL.appendingPathExtension("backup"), options: [.atomic])

        let reopened = try XCTUnwrap(SharedDictationTranscriptStore(
            defaults: try makeDefaults(),
            envelopeURL: envelopeURL,
            lockFileURL: lockURL
        ))
        XCTAssertEqual(
            reopened.latestTranscriptResolution(forSessionID: "unavailable-session"),
            .unavailable
        )
    }

    func testLegacySingletonTranscriptIsIncludedInRecoveryAndMigration() throws {
        let defaults = try makeDefaults()
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "legacy-session",
            commandToken: "legacy-command",
            text: "legacy transcript"
        ))
        defaults.set(try JSONEncoder().encode(transcript), forKey: "sharedDictation.transcriptRecord")
        let store = SharedDictationTranscriptStore(defaults: defaults)

        XCTAssertEqual(store.latestTranscript(), transcript)
        XCTAssertEqual(
            store.unconsumedTranscriptsResolution(),
            .available([transcript])
        )
    }

    func testCorruptLegacySingletonTranscriptFailsClosed() throws {
        let defaults = try makeDefaults()
        defaults.set(Data([0xFF]), forKey: "sharedDictation.transcriptRecord")
        let store = SharedDictationTranscriptStore(defaults: defaults)

        XCTAssertEqual(
            store.latestTranscriptResolution(forSessionID: "legacy-session"),
            .unavailable
        )
        XCTAssertEqual(store.unconsumedTranscriptsResolution(), .unavailable)
    }

    func testCorruptLegacyMetadataFailsClosed() throws {
        let keys = [
            "sharedDictation.transcriptIndex",
            "sharedDictation.consumedTokenIndex",
            "sharedDictation.transcriptEnvelope"
        ]

        for key in keys {
            let defaults = try makeDefaults()
            defaults.set("wrong-type", forKey: key)
            let store = SharedDictationTranscriptStore(defaults: defaults)

            XCTAssertEqual(
                store.unconsumedTranscriptsResolution(),
                .unavailable,
                "legacy key should fail closed: \(key)"
            )
        }
    }

    func testCorruptLegacyDeliveryLeaseFailsClosed() throws {
        let defaults = try makeDefaults()
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "lease payload",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        defaults.set(
            try JSONEncoder().encode(transcript),
            forKey: "sharedDictation.transcriptRecord"
        )
        defaults.set("wrong-type", forKey: "sharedDictation.deliveryLease")
        let store = SharedDictationTranscriptStore(defaults: defaults)

        XCTAssertNil(store.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
        XCTAssertEqual(store.unconsumedTranscriptsResolution(), .unavailable)
    }

    func testCorruptTokenScopedLegacyDeliveryLeaseFailsClosed() throws {
        let defaults = try makeDefaults()
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "scoped lease payload",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        defaults.set(
            try JSONEncoder().encode(transcript),
            forKey: "sharedDictation.transcriptRecord"
        )
        defaults.set(
            "wrong-type",
            forKey: "sharedDictation.deliveryLease.\(transcript.token)"
        )
        let store = SharedDictationTranscriptStore(defaults: defaults)

        XCTAssertNil(store.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
        XCTAssertEqual(store.unconsumedTranscriptsResolution(), .unavailable)
    }

    func testMismatchedTokenScopedLegacyDeliveryLeaseFailsClosed() throws {
        let defaults = try makeDefaults()
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            text: "scoped lease payload",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        let otherTranscript = try XCTUnwrap(SharedDictationTranscript(
            text: "other payload",
            createdAt: Date(timeIntervalSince1970: 1_720_000_003)
        ))
        defaults.set(
            try JSONEncoder().encode(transcript),
            forKey: "sharedDictation.transcriptRecord"
        )
        defaults.set(
            try JSONEncoder().encode(LegacyDeliveryLeaseFixture(
                transcriptToken: otherTranscript.token,
                expiresAt: Date(timeIntervalSince1970: 1_720_000_030),
                ownerID: "other-owner"
            )),
            forKey: "sharedDictation.deliveryLease.\(transcript.token)"
        )
        let store = SharedDictationTranscriptStore(defaults: defaults)

        XCTAssertNil(store.claimLatestTranscript(
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
        XCTAssertEqual(store.unconsumedTranscriptsResolution(), .unavailable)
    }

    func testIndexedLegacyTranscriptWithoutRecordFailsClosed() throws {
        let defaults = try makeDefaults()
        defaults.set(
            try JSONEncoder().encode(["missing-legacy-record"]),
            forKey: "sharedDictation.transcriptIndex"
        )
        let store = SharedDictationTranscriptStore(defaults: defaults)

        XCTAssertEqual(store.unconsumedTranscriptsResolution(), .unavailable)
        XCTAssertEqual(
            store.latestTranscriptResolution(forSessionID: "missing-session"),
            .unavailable
        )
    }

    func testConflictingTranscriptForSameCommandIsRejectedWriteOnce() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let first = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "write-once-session",
            commandToken: "write-once-command",
            text: "first result"
        ))
        let conflicting = try XCTUnwrap(SharedDictationTranscript(
            sessionID: first.sessionID,
            commandToken: first.commandToken,
            text: "conflicting result"
        ))

        XCTAssertTrue(store.save(first))
        XCTAssertFalse(store.save(conflicting))
        XCTAssertEqual(store.latestTranscript(), first)
    }

    func testFileBackedStoreRoundTripsDeliveryJournal() throws {
        let defaults = try makeDefaults()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceKeyboardTranscriptStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try XCTUnwrap(SharedDictationTranscriptStore(
            defaults: defaults,
            envelopeURL: root.appendingPathComponent("envelope.json"),
            lockFileURL: root.appendingPathComponent("store.lock")
        ))
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "file-backed-session",
            commandToken: "file-backed-command",
            text: "file-backed delivery"
        ))
        let context = SharedDictationDocumentContextFingerprint(
            beforeInput: "before",
            afterInput: "after",
            documentIdentifier: UUID()
        )

        XCTAssertTrue(store.save(transcript))
        XCTAssertTrue(store.beginDelivery(
            transcript,
            beforeContext: context,
            afterContext: context,
            ownerID: "file-owner"
        ))
        XCTAssertEqual(store.pendingDelivery(forSessionID: transcript.sessionID)?.ownerID, "file-owner")
        XCTAssertEqual(
            store.pendingDeliveryResolution(forCommandToken: transcript.commandToken),
            .found(store.pendingDelivery(forSessionID: transcript.sessionID)!)
        )
        XCTAssertEqual(
            store.pendingDeliveryResolution(forCommandToken: "missing-command"),
            .missing
        )
        XCTAssertEqual(store.latestTranscript(), transcript)
    }

    func testFileBackedStoreRecoversFromCorruptPrimaryUsingBackup() throws {
        let defaults = try makeDefaults()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceKeyboardTranscriptRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let envelopeURL = root.appendingPathComponent("envelope.json")
        let store = try XCTUnwrap(SharedDictationTranscriptStore(
            defaults: defaults,
            envelopeURL: envelopeURL,
            lockFileURL: root.appendingPathComponent("store.lock")
        ))
        let first = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "recovery-session",
            commandToken: "first-command",
            text: "first",
            createdAt: Date(timeIntervalSince1970: 1_720_000_001)
        ))
        let second = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "recovery-session",
            commandToken: "second-command",
            text: "second",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))
        try Data([0xFF]).write(to: envelopeURL, options: [.atomic])

        let recoveredStore = try XCTUnwrap(SharedDictationTranscriptStore(
            defaults: try makeDefaults(),
            envelopeURL: envelopeURL,
            lockFileURL: root.appendingPathComponent("store.lock")
        ))
        XCTAssertEqual(recoveredStore.latestTranscript(), second)
    }

    func testEmptyTranscriptIsRejectedButWhitespaceIsPreserved() throws {
        XCTAssertNil(SharedDictationTranscript(text: ""))
        let transcript = try XCTUnwrap(SharedDictationTranscript(text: "  \n"))
        XCTAssertEqual(transcript.text, "  \n")
    }

    func testCompatibilityTranscriptTokenDoesNotEmbedLongText() throws {
        let text = String(repeating: "あ", count: 1_000)

        let transcript = try XCTUnwrap(SharedDictationTranscript(text: text))

        XCTAssertEqual(transcript.text, text)
        XCTAssertLessThanOrEqual(
            transcript.commandToken.utf8.count,
            SharedDictationTranscript.maximumIdentifierByteCount
        )
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
            now: Date(timeIntervalSince1970: 1_720_000_041)
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

    func testAtomicClaimMarksConsumedBeforeHostMutation() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-a",
            commandToken: "command-a",
            text: "at most once",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        store.save(transcript)

        XCTAssertEqual(store.claimAndMarkConsumedLatestTranscript(
            forSessionID: "session-a",
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ), transcript)
        XCTAssertEqual(store.lastConsumedToken(), transcript.token)
        XCTAssertNil(store.claimAndMarkConsumedLatestTranscript(
            forSessionID: "session-a",
            afterLastConsumedToken: nil,
            now: Date(timeIntervalSince1970: 1_720_000_020)
        ))
    }

    func testPendingDeliveryCanBeResumedUntilMarkedDelivered() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-a",
            commandToken: "command-a",
            text: "recoverable delivery",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        let before = SharedDictationDocumentContextFingerprint(
            beforeInput: "hello",
            afterInput: nil,
            documentIdentifier: nil,
            selectedText: nil
        )
        let after = SharedDictationDocumentContextFingerprint(
            beforeInput: "hello recoverable delivery",
            afterInput: nil,
            documentIdentifier: nil,
            selectedText: nil
        )
        store.save(transcript)
        XCTAssertEqual(
            store.claimLatestTranscript(
                forSessionID: transcript.sessionID,
                afterLastConsumedToken: nil,
                now: Date(timeIntervalSince1970: 1_720_000_010)
            ),
            transcript
        )
        XCTAssertTrue(store.beginDelivery(transcript, beforeContext: before, afterContext: after))
        XCTAssertEqual(
            store.resumePendingDelivery(
                forSessionID: transcript.sessionID,
                now: Date(timeIntervalSince1970: 1_720_000_010)
            ),
            transcript
        )
        XCTAssertEqual(store.pendingDelivery(forSessionID: transcript.sessionID)?.transcriptToken, transcript.token)
        // Legacy operation-zero journals may still be resumed, but they are
        // not allowed to consume a transcript without an explicit operation
        // plan. The keyboard upgrades them before calling markDelivered.
        XCTAssertFalse(store.markDelivered(transcriptToken: transcript.token))
        XCTAssertNotNil(store.pendingDelivery(forSessionID: transcript.sessionID))
        XCTAssertEqual(store.latestTranscript()?.isConsumed, false)
    }

    func testInFlightMutationIsNeverAutomaticallyReplayedAfterLeaseExpiry() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-in-flight",
            commandToken: "command-in-flight",
            text: "ambiguous host edit",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        let documentIdentifier = UUID()
        let before = SharedDictationDocumentContextFingerprint(
            beforeInput: "hello",
            afterInput: nil,
            documentIdentifier: documentIdentifier,
            selectedText: nil
        )
        let after = SharedDictationDocumentContextFingerprint(
            beforeInput: "hello ambiguous host edit",
            afterInput: nil,
            documentIdentifier: documentIdentifier,
            selectedText: nil
        )
        store.save(transcript)

        XCTAssertTrue(store.beginDelivery(
            transcript,
            beforeContext: before,
            afterContext: after,
            operations: [.insertText(" ambiguous host edit")],
            stepContexts: [before, after],
            ownerID: "owner-a",
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
        XCTAssertTrue(store.beginDeliveryMutation(
            transcriptToken: transcript.token,
            operationIndex: 0,
            ownerID: "owner-a",
            now: Date(timeIntervalSince1970: 1_720_000_011)
        ))
        XCTAssertTrue(store.pendingDelivery(forSessionID: transcript.sessionID)?.mutationInFlight == true)

        XCTAssertNil(store.resumePendingDelivery(
            forSessionID: transcript.sessionID,
            now: Date(timeIntervalSince1970: 1_720_000_042),
            ownerID: "owner-b"
        ))
    }

    func testInFlightMutationCannotBeDiscardedAndCanBeQuarantined() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-quarantine",
            commandToken: "command-quarantine",
            text: "ambiguous",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        let identifier = UUID()
        let before = SharedDictationDocumentContextFingerprint(
            beforeInput: "hello",
            afterInput: nil,
            documentIdentifier: identifier
        )
        let after = SharedDictationDocumentContextFingerprint(
            beforeInput: "hello ambiguous",
            afterInput: nil,
            documentIdentifier: identifier
        )
        XCTAssertTrue(store.save(transcript))
        XCTAssertTrue(store.beginDelivery(
            transcript,
            beforeContext: before,
            afterContext: after,
            operations: [.insertText(" ambiguous")],
            stepContexts: [before, after],
            ownerID: "owner-a",
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
        XCTAssertTrue(store.beginDeliveryMutation(
            transcriptToken: transcript.token,
            operationIndex: 0,
            ownerID: "owner-a",
            now: Date(timeIntervalSince1970: 1_720_000_011)
        ))
        XCTAssertFalse(store.discardPendingDelivery(
            transcriptToken: transcript.token,
            ownerID: "owner-a",
            now: Date(timeIntervalSince1970: 1_720_000_011)
        ))
        XCTAssertTrue(store.quarantinePendingDelivery(
            transcriptToken: transcript.token,
            ownerID: "owner-a",
            now: Date(timeIntervalSince1970: 1_720_000_011)
        ))
        XCTAssertTrue(store.pendingDelivery(forSessionID: transcript.sessionID)?.isQuarantined == true)
        XCTAssertNil(store.resumePendingDelivery(
            forSessionID: transcript.sessionID,
            now: Date(timeIntervalSince1970: 1_720_000_042),
            ownerID: "owner-b"
        ))
    }

    func testEvictedAmbiguousDeliveryLeavesATombstone() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        var firstTranscript: SharedDictationTranscript?

        for index in 0..<10 {
            let transcript = try XCTUnwrap(SharedDictationTranscript(
                sessionID: "session-ambiguous-\(index)",
                commandToken: "command-ambiguous-\(index)",
                text: "ambiguous \(index)"
            ))
            firstTranscript = firstTranscript ?? transcript
            let documentIdentifier = UUID()
            let before = SharedDictationDocumentContextFingerprint(
                beforeInput: "before \(index)",
                afterInput: nil,
                documentIdentifier: documentIdentifier
            )
            let after = SharedDictationDocumentContextFingerprint(
                beforeInput: "after \(index)",
                afterInput: nil,
                documentIdentifier: documentIdentifier
            )

            XCTAssertTrue(store.save(transcript))
            XCTAssertTrue(store.beginDelivery(
                transcript,
                beforeContext: before,
                afterContext: after,
                operations: [.insertText(" ambiguous \(index)")],
                stepContexts: [before, after],
                ownerID: "owner-\(index)"
            ))
            XCTAssertTrue(store.beginDeliveryMutation(
                transcriptToken: transcript.token,
                operationIndex: 0,
                ownerID: "owner-\(index)"
            ))
            XCTAssertTrue(store.quarantinePendingDelivery(
                transcriptToken: transcript.token,
                ownerID: "owner-\(index)"
            ))
        }

        let first = try XCTUnwrap(firstTranscript)
        XCTAssertNil(store.pendingDelivery(forSessionID: first.sessionID))
        XCTAssertFalse(store.save(first))
    }

    func testDeliveryWithOperationsRequiresCompleteStepContexts() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-contexts",
            commandToken: "command-contexts",
            text: "x"
        ))
        XCTAssertTrue(store.save(transcript))
        let context = SharedDictationDocumentContextFingerprint(beforeInput: "", afterInput: nil)
        XCTAssertFalse(store.beginDelivery(
            transcript,
            beforeContext: context,
            afterContext: context,
            operations: [.insertText("x")],
            stepContexts: []
        ))
    }

    func testPartiallyAppliedDeliveryCannotBeReplacedFromOperationZero() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-partial",
            commandToken: "command-partial",
            text: "partial"
        ))
        let before = SharedDictationDocumentContextFingerprint(beforeInput: "a", afterInput: nil)
        let afterFirst = SharedDictationDocumentContextFingerprint(beforeInput: "ax", afterInput: nil)
        let afterSecond = SharedDictationDocumentContextFingerprint(beforeInput: "axy", afterInput: nil)
        let operations: [SharedDictationTranscriptDelivery.Operation] = [
            .insertText("x"),
            .insertText("y")
        ]
        XCTAssertTrue(store.save(transcript))
        XCTAssertTrue(store.beginDelivery(
            transcript,
            beforeContext: before,
            afterContext: afterSecond,
            operations: operations,
            stepContexts: [before, afterFirst, afterSecond],
            ownerID: "owner-partial"
        ))
        XCTAssertTrue(store.beginDeliveryMutation(
            transcriptToken: transcript.token,
            operationIndex: 0,
            ownerID: "owner-partial"
        ))
        XCTAssertTrue(store.markDeliveryProgress(
            transcriptToken: transcript.token,
            appliedOperationCount: 1,
            ownerID: "owner-partial",
            observedContext: afterFirst
        ))
        XCTAssertFalse(store.beginDelivery(
            transcript,
            beforeContext: before,
            afterContext: afterSecond,
            operations: operations,
            stepContexts: [before, afterFirst, afterSecond],
            ownerID: "owner-partial"
        ))
    }

    func testPendingDeliveryCannotBeResumedByAnotherOwnerUntilLeaseExpires() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let transcript = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-owner",
            commandToken: "command-owner",
            text: "owned delivery",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))
        let before = SharedDictationDocumentContextFingerprint(
            beforeInput: "hello",
            afterInput: nil,
            documentIdentifier: nil,
            selectedText: nil
        )
        store.save(transcript)

        XCTAssertTrue(store.beginDelivery(
            transcript,
            beforeContext: before,
            afterContext: before,
            ownerID: "owner-a",
            now: Date(timeIntervalSince1970: 1_720_000_010)
        ))
        XCTAssertNil(store.resumePendingDelivery(
            forSessionID: transcript.sessionID,
            now: Date(timeIntervalSince1970: 1_720_000_011),
            ownerID: "owner-b"
        ))
        XCTAssertEqual(
            store.resumePendingDelivery(
                forSessionID: transcript.sessionID,
                now: Date(timeIntervalSince1970: 1_720_000_041),
                ownerID: "owner-b"
            ),
            transcript
        )
        XCTAssertEqual(
            store.pendingDelivery(forSessionID: transcript.sessionID)?.ownerID,
            "owner-b"
        )
        XCTAssertFalse(store.discardPendingDelivery(
            transcriptToken: transcript.token,
            ownerID: "owner-a",
            now: Date(timeIntervalSince1970: 1_720_000_041)
        ))
        XCTAssertTrue(store.discardPendingDelivery(
            transcriptToken: transcript.token,
            ownerID: "owner-b",
            now: Date(timeIntervalSince1970: 1_720_000_041)
        ))
    }

    func testSessionHistorySurvivesASecondSessionSave() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationTranscriptStore(defaults: defaults)
        let first = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-a",
            commandToken: "command-a",
            text: "first session",
            createdAt: Date(timeIntervalSince1970: 1_720_000_001)
        ))
        let second = try XCTUnwrap(SharedDictationTranscript(
            sessionID: "session-b",
            commandToken: "command-b",
            text: "second session",
            createdAt: Date(timeIntervalSince1970: 1_720_000_002)
        ))

        store.save(first)
        store.save(second)

        XCTAssertEqual(store.latestTranscript(forSessionID: "session-a"), first)
        XCTAssertEqual(store.latestTranscript(forSessionID: "session-b"), second)
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
