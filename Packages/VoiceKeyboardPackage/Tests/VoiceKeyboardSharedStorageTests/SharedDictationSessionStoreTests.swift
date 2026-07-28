import Foundation
import VoiceKeyboardModels
import VoiceKeyboardSharedStorage
import XCTest

final class SharedDictationSessionStoreTests: XCTestCase {
    func testSavesAndClaimsStartCommandOnce() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let command = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date(timeIntervalSince1970: 10)
        )

        store.saveCommand(command)

        XCTAssertEqual(store.latestCommand(), command)
        XCTAssertEqual(store.status(), .idle)
        XCTAssertEqual(
            store.claimCommand(
                afterLastClaimedToken: nil,
                now: Date(timeIntervalSince1970: 15)
            ),
            command
        )
        XCTAssertNil(store.claimCommand(
            afterLastClaimedToken: command.token,
            now: Date(timeIntervalSince1970: 15)
        ))
    }

    func testClaimedCancelSupersedesStartForAnotherOwner() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let start = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date()
        )
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.saveCommand(cancel))
        XCTAssertEqual(
            store.claimCommand(
                afterLastClaimedToken: nil,
                ownerToken: "owner-a",
                source: .keyboard
            ),
            cancel
        )
        XCTAssertNil(store.claimCommand(
            afterLastClaimedToken: nil,
            ownerToken: "owner-b",
            source: .keyboard
        ))
    }

    func testOwnedStopCanPromoteACompletedTranscriptBeforeCancellation() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let ownerToken = "containing-app-owner"
        let start = SharedDictationSessionCommand.start(
            source: .keyboard,
            sessionID: "completed-before-stop"
        )
        let stop = SharedDictationSessionCommand.stop(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )
        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.saveCommand(stop))
        XCTAssertTrue(store.saveHeartbeat(SharedDictationAppHeartbeat(
            token: ownerToken,
            lastSeenAt: Date(),
            sessionState: .armed
        )))
        XCTAssertEqual(
            store.claimCommand(
                afterLastClaimedToken: start.token,
                ownerToken: ownerToken,
                source: .keyboard
            ),
            stop
        )

        XCTAssertTrue(store.recoverCompletedTranscriptStatus(
            sourceCommandToken: start.token,
            throughCommandToken: stop.token,
            ownerToken: ownerToken
        ))
        XCTAssertEqual(store.status(forCommandToken: start.token), .transcriptReady(token: start.token))
        XCTAssertTrue(store.saveStatus(.cancelled(token: stop.token), ownerToken: ownerToken))
    }

    func testCancellationIntentSuppressesStartUntilItCanBePublished() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let start = SharedDictationSessionCommand.start(source: .keyboard)
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.recordCancellationIntent(cancel))
        XCTAssertEqual(store.pendingCancellationIntents(), [cancel])
        XCTAssertNil(store.claimCommand(
            afterLastClaimedToken: nil,
            ownerToken: "owner-a",
            source: .keyboard
        ))

        XCTAssertTrue(store.saveCommand(cancel))
        XCTAssertTrue(store.pendingCancellationIntents().isEmpty)
        XCTAssertEqual(store.command(forToken: cancel.token), cancel)
    }

    func testExactClaimIsSupersededByPendingCancellationIntent() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let start = SharedDictationSessionCommand.start(source: .keyboard)
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.recordCancellationIntent(cancel))
        XCTAssertFalse(store.claimCommand(
            token: start.token,
            ownerToken: "manual-route"
        ))
    }

    func testConflictingCommandReuseIsRejectedWithoutOverwritingOriginal() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let requestedAt = Date()
        let original = SharedDictationSessionCommand(
            token: "write-once-token",
            kind: .start,
            source: .keyboard,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(10),
            sessionID: "write-once-session"
        )
        let conflicting = SharedDictationSessionCommand(
            token: original.token,
            kind: .cancel,
            source: .keyboard,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(10),
            sessionID: original.sessionID,
            replacesCommandToken: original.token
        )

        XCTAssertTrue(store.saveCommand(original))
        XCTAssertTrue(store.saveCommand(original))
        XCTAssertFalse(store.saveCommand(conflicting))
        XCTAssertEqual(store.command(forToken: original.token), original)
    }

    func testCancellationIntentKeepsReplacementStartDuringHistoryPruning() throws {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDictationSessionStoreIntentRetention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: directory.appendingPathComponent("session.json"),
            lockFileURL: directory.appendingPathComponent("session.lock")
        ))
        let start = SharedDictationSessionCommand.start(source: .keyboard)
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.recordCancellationIntent(cancel))
        for index in 0..<31 {
            XCTAssertTrue(store.saveCommand(SharedDictationSessionCommand.start(
                source: .containingApp,
                sessionID: "history-session-\(index)"
            )))
        }
        XCTAssertFalse(store.saveCommand(SharedDictationSessionCommand.start(
            source: .containingApp,
            sessionID: "history-session-over-capacity"
        )))

        XCTAssertEqual(store.command(forToken: start.token), start)
        XCTAssertEqual(store.pendingCancellationIntents(), [cancel])
    }

    func testUnreadableFileBackedEnvelopeIsReportedAsUnavailable() throws {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDictationSessionStoreUnreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let envelopeURL = directory.appendingPathComponent("session.json")
        let backupURL = envelopeURL.appendingPathExtension("backup")
        let lockURL = directory.appendingPathComponent("session.lock")
        let store = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: envelopeURL,
            lockFileURL: lockURL
        ))
        XCTAssertTrue(store.saveCommand(.start(source: .keyboard)))
        try Data([0xFF]).write(to: envelopeURL, options: [.atomic])
        try Data([0xFF]).write(to: backupURL, options: [.atomic])

        let reopened = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: envelopeURL,
            lockFileURL: lockURL
        ))
        XCTAssertFalse(reopened.storageHealth())
        XCTAssertEqual(reopened.commandResolution(forToken: "missing"), .unavailable)
        XCTAssertEqual(reopened.commandHistoryResolution(), .unavailable)
    }

    func testHistoricalDeliveryFailureIntentDoesNotRegressNewerLatestStatus() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let first = SharedDictationSessionCommand.start(source: .keyboard)
        let second = SharedDictationSessionCommand.start(source: .keyboard)

        XCTAssertTrue(store.saveCommand(first))
        XCTAssertTrue(store.saveStatus(.transcriptReady(token: first.token)))
        XCTAssertTrue(store.recordDeliveryFailureIntent(token: first.token, message: "old delivery"))
        XCTAssertTrue(store.saveCommand(second))
        let newerStatus = SharedDictationSessionStatus.recording(
            token: second.token,
            startedAt: Date(),
            timeoutSeconds: 8
        )
        XCTAssertTrue(store.saveStatus(newerStatus))

        XCTAssertTrue(store.saveDeliveryFailure(token: first.token, message: "old delivery"))
        XCTAssertEqual(store.status(), newerStatus)
        XCTAssertEqual(
            store.status(forCommandToken: first.token),
            .failed(token: first.token, message: "old delivery")
        )
        XCTAssertTrue(store.pendingDeliveryFailureIntents().isEmpty)
    }

    func testExpiredCommandIsNotClaimed() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let command = SharedDictationSessionCommand(
            token: "expired",
            kind: .start,
            source: .keyboard,
            requestedAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 11)
        )

        store.saveCommand(command)

        XCTAssertNil(store.claimCommand(
            afterLastClaimedToken: nil,
            now: Date(timeIntervalSince1970: 12)
        ))
    }

    func testDefaultsBackedClaimIsSharedAcrossStoreInstances() throws {
        let defaults = try makeDefaults()
        let firstStore = SharedDictationSessionStore(defaults: defaults)
        let secondStore = SharedDictationSessionStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 100)
        let command = SharedDictationSessionCommand(
            token: "defaults-claim",
            kind: .start,
            source: .keyboard,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )

        XCTAssertTrue(firstStore.saveCommand(command))
        XCTAssertEqual(
            firstStore.claimCommand(
                afterLastClaimedToken: nil,
                now: now,
                ownerToken: "owner-a",
                source: .keyboard
            ),
            command
        )
        XCTAssertNil(secondStore.claimCommand(
            afterLastClaimedToken: nil,
            now: now,
            ownerToken: "owner-b",
            source: .keyboard
        ))
    }

    func testStatusRoundTripsThroughDefaults() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let statuses: [SharedDictationSessionStatus] = [
            .idle,
            .commandPending(token: "a", requestedAt: Date(timeIntervalSince1970: 1)),
            .commandAcknowledged(token: "a", acknowledgedAt: Date(timeIntervalSince1970: 2)),
            .recording(token: "a", startedAt: Date(timeIntervalSince1970: 3), timeoutSeconds: 8),
            .transcribing(token: "a"),
            .transcriptReady(token: "a")
        ]

        for status in statuses {
            XCTAssertTrue(store.saveStatus(status))
            XCTAssertEqual(store.status(), status)
        }

        for status in [
            SharedDictationSessionStatus.failed(token: "a", message: "Audio unavailable"),
            .cancelled(token: "a")
        ] {
            let terminalStore = SharedDictationSessionStore(defaults: try makeDefaults())
            XCTAssertTrue(terminalStore.saveStatus(status))
            XCTAssertEqual(terminalStore.status(), status)
        }
    }

    func testTerminalStatusCannotBeRegressedByLateAudioCallback() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let token = "terminal"
        XCTAssertTrue(store.saveStatus(.cancelled(token: token)))

        XCTAssertFalse(store.saveStatus(.recording(
            token: token,
            startedAt: Date(timeIntervalSince1970: 3),
            timeoutSeconds: 8
        )))
        XCTAssertEqual(store.status(), .cancelled(token: token))
    }

    func testSavingCommandDoesNotOverwriteAppOwnedStatus() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let status = SharedDictationSessionStatus.recording(
            token: "app-command",
            startedAt: Date(timeIntervalSince1970: 20),
            timeoutSeconds: 8
        )
        let command = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: Date(timeIntervalSince1970: 21)
        )

        store.saveStatus(status)
        store.saveCommand(command)

        XCTAssertEqual(store.status(), status)
    }

    func testStopCommandTargetsTheStartSession() throws {
        let start = SharedDictationSessionCommand.start(source: .keyboard)
        let stop = SharedDictationSessionCommand.stop(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )

        XCTAssertEqual(stop.sessionID, start.sessionID)
        XCTAssertNotEqual(stop.token, start.token)
        XCTAssertEqual(stop.replacesCommandToken, start.token)
    }

    func testCommandHistoryKeepsTheReplacedStartCommandReadable() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let start = SharedDictationSessionCommand.start(source: .keyboard)
        let stop = SharedDictationSessionCommand.stop(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )

        store.saveCommand(start)
        store.saveCommand(stop)

        XCTAssertEqual(store.command(forToken: start.token), start)
        XCTAssertEqual(store.command(forToken: stop.token), stop)
    }

    func testDocumentContextFingerprintRoundTripsWithoutStoringContextText() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let documentIdentifier = UUID()
        let fingerprint = SharedDictationDocumentContextFingerprint(
            beforeInput: "private note",
            afterInput: nil,
            documentIdentifier: documentIdentifier,
            selectedText: nil
        )
        let command = SharedDictationSessionCommand.start(
            source: .keyboard,
            documentContextFingerprint: fingerprint
        )

        store.saveCommand(command)

        let restored = try XCTUnwrap(store.command(forToken: command.token))
        XCTAssertEqual(restored.documentContextFingerprint, fingerprint)
        XCTAssertTrue(fingerprint.matches(
            beforeInput: "private note",
            afterInput: nil,
            documentIdentifier: documentIdentifier,
            selectedText: nil
        ))
        XCTAssertFalse(fingerprint.matches(
            beforeInput: "private note",
            afterInput: nil,
            documentIdentifier: UUID(),
            selectedText: nil
        ))
        XCTAssertFalse(fingerprint.matches(
            beforeInput: "private note",
            afterInput: nil,
            documentIdentifier: documentIdentifier,
            selectedText: "selected"
        ))
    }

    func testHeartbeatRoundTripsThroughDefaults() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let heartbeat = SharedDictationAppHeartbeat(
            token: "app-session",
            lastSeenAt: Date(timeIntervalSince1970: 100),
            sessionState: .armed
        )

        store.saveHeartbeat(heartbeat)

        XCTAssertEqual(store.heartbeat(), heartbeat)
    }

    func testFileBackedStoresFenceOwnersAndRenewExpiredCommandsWithFreshHeartbeat() throws {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDictationSessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let envelopeURL = directory.appendingPathComponent("session.json")
        let lockURL = directory.appendingPathComponent("session.lock")
        let firstStore = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: envelopeURL,
            lockFileURL: lockURL
        ))
        let secondStore = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: envelopeURL,
            lockFileURL: lockURL
        ))
        let owner = "owner-a"
        let command = SharedDictationSessionCommand(
            token: "file-backed-command",
            kind: .start,
            source: .keyboard,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(1)
        )

        XCTAssertTrue(firstStore.saveHeartbeat(SharedDictationAppHeartbeat(
            token: owner,
            sessionID: command.sessionID,
            lastSeenAt: now,
            sessionState: .recording
        )))
        XCTAssertTrue(firstStore.saveCommand(command))
        XCTAssertFalse(secondStore.claimCommand(token: command.token, now: now, ownerToken: nil))
        XCTAssertTrue(firstStore.claimCommand(token: command.token, now: now, ownerToken: owner))

        let renewedAt = now.addingTimeInterval(2)
        XCTAssertTrue(secondStore.saveHeartbeat(SharedDictationAppHeartbeat(
            token: owner,
            sessionID: command.sessionID,
            lastSeenAt: renewedAt,
            sessionState: .recording
        )))
        XCTAssertTrue(secondStore.renewCommandClaim(
            token: command.token,
            ownerToken: owner,
            now: renewedAt
        ))
        XCTAssertEqual(secondStore.claimOwner(forCommandToken: command.token, now: renewedAt), owner)
    }

    func testExpiredClaimIsReclaimableEvenWhenOwnerHeartbeatIsStillFresh() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let command = SharedDictationSessionCommand(
            token: "expired-lease",
            kind: .start,
            source: .keyboard,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(30),
            sessionID: "session-expired-lease"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDictationSessionStoreLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: directory.appendingPathComponent("session.json"),
            lockFileURL: directory.appendingPathComponent("session.lock")
        ))
        XCTAssertTrue(fileStore.saveHeartbeat(SharedDictationAppHeartbeat(
            token: "owner",
            sessionID: command.sessionID,
            lastSeenAt: now,
            sessionState: .armed
        )))
        XCTAssertTrue(fileStore.saveCommand(command))
        XCTAssertTrue(fileStore.claimCommand(token: command.token, now: now, ownerToken: "owner"))

        let afterLease = now.addingTimeInterval(11)
        XCTAssertNil(fileStore.claimOwner(forCommandToken: command.token, now: afterLease))
        XCTAssertEqual(
            fileStore.claimCommand(afterLastClaimedToken: nil, now: afterLease, ownerToken: "new-owner"),
            command
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SharedDictationSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
