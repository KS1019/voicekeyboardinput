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

    func testExpiredStopCanRecoverCompletedTranscriptWithoutAStaleClaim() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let now = Date()
        let start = SharedDictationSessionCommand(
            token: "expired-stop-source",
            kind: .start,
            source: .keyboard,
            requestedAt: now.addingTimeInterval(-20),
            expiresAt: now.addingTimeInterval(120),
            sessionID: "expired-stop-session"
        )
        let stop = SharedDictationSessionCommand(
            token: "expired-stop-replacement",
            kind: .stop,
            source: .keyboard,
            requestedAt: now.addingTimeInterval(-20),
            expiresAt: now.addingTimeInterval(-1),
            sessionID: start.sessionID,
            replacesCommandToken: start.token
        )

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.saveCommand(stop))
        XCTAssertTrue(store.saveStatus(.transcribing(token: start.token)))
        XCTAssertTrue(store.recoverCompletedTranscriptAfterExpiredStop(
            sourceCommandToken: start.token,
            throughCommandToken: stop.token,
            now: now
        ))
        XCTAssertEqual(
            store.status(forCommandToken: start.token),
            .transcriptReady(token: start.token)
        )
    }

    func testExpiredCancelCannotRecoverCompletedTranscript() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let now = Date()
        let start = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: now.addingTimeInterval(-20),
            expiryInterval: 120,
            sessionID: "expired-cancel-session"
        )
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            requestedAt: now.addingTimeInterval(-20),
            expiryInterval: 1,
            replacingCommandToken: start.token
        )

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.saveCommand(cancel))
        XCTAssertTrue(store.saveStatus(.transcribing(token: start.token)))
        XCTAssertFalse(store.recoverCompletedTranscriptAfterExpiredStop(
            sourceCommandToken: start.token,
            throughCommandToken: cancel.token,
            now: now
        ))
        XCTAssertEqual(
            store.status(forCommandToken: start.token),
            .transcribing(token: start.token)
        )
    }

    func testClaimedCancelCannotAuthorizeTranscriptRecovery() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let start = SharedDictationSessionCommand.start(
            source: .keyboard,
            sessionID: "claimed-cancel-session"
        )
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )
        let owner = "cancel-owner"

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.saveCommand(cancel))
        XCTAssertTrue(store.saveHeartbeat(SharedDictationAppHeartbeat(
            token: owner,
            lastSeenAt: Date(),
            sessionState: .armed
        )))
        XCTAssertEqual(
            store.claimCommand(
                afterLastClaimedToken: start.token,
                ownerToken: owner,
                source: .keyboard
            ),
            cancel
        )
        XCTAssertFalse(store.recoverCompletedTranscriptStatus(
            sourceCommandToken: start.token,
            throughCommandToken: cancel.token,
            ownerToken: owner
        ))
    }

    func testExpiredStopCannotRecoverAfterNewerCancellation() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let now = Date()
        let start = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: now.addingTimeInterval(-20),
            expiryInterval: 120,
            sessionID: "replacement-order-session"
        )
        let expiredStop = SharedDictationSessionCommand.stop(
            sessionID: start.sessionID,
            source: .keyboard,
            requestedAt: now.addingTimeInterval(-20),
            expiryInterval: 1,
            replacingCommandToken: start.token
        )
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            requestedAt: now,
            replacingCommandToken: start.token
        )

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.saveCommand(expiredStop))
        XCTAssertTrue(store.saveCommand(cancel))
        XCTAssertTrue(store.saveStatus(.transcribing(token: start.token)))
        XCTAssertFalse(store.recoverCompletedTranscriptAfterExpiredStop(
            sourceCommandToken: start.token,
            throughCommandToken: expiredStop.token,
            now: now
        ))
        XCTAssertEqual(store.status(forCommandToken: start.token), .transcribing(token: start.token))
    }

    func testHistoricalTranscriptPromotionCannotCrossCancellationFence() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let start = SharedDictationSessionCommand.start(
            source: .keyboard,
            sessionID: "historical-cancel-session"
        )
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )

        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.saveCommand(cancel))
        XCTAssertTrue(store.saveStatus(.transcribing(token: start.token)))
        XCTAssertFalse(store.saveStatus(
            .transcriptReady(token: start.token),
            allowRecoveryFromTranscriptReady: true
        ))
        XCTAssertEqual(store.status(forCommandToken: start.token), .transcribing(token: start.token))
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

    func testStatusResolutionDistinguishesMissingFoundAndMalformed() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)

        XCTAssertEqual(
            store.statusResolution(forCommandToken: "status-missing"),
            .missing
        )
        XCTAssertTrue(store.saveStatus(.recording(
            token: "status-found",
            startedAt: Date(timeIntervalSince1970: 3),
            timeoutSeconds: 8
        )))
        XCTAssertEqual(
            store.statusResolution(forCommandToken: "status-found"),
            .found(.recording(
                token: "status-found",
                startedAt: Date(timeIntervalSince1970: 3),
                timeoutSeconds: 8
            ))
        )

        defaults.set(Data([0xFF]), forKey: "sharedDictation.session.status.status-malformed")
        XCTAssertEqual(
            store.statusResolution(forCommandToken: "status-malformed"),
            .unavailable
        )
    }

    func testStaleCancellationKeepsLiveActiveStateButCleansUpDeadProducer() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let requestedAt = Date(timeIntervalSince1970: 100)
        let command = SharedDictationSessionCommand(
            token: "active-not-yet-expired",
            kind: .start,
            source: .keyboard,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(10),
            sessionID: "active-session"
        )

        XCTAssertTrue(store.saveCommand(command))
        XCTAssertTrue(store.saveStatus(.recording(
            token: command.token,
            startedAt: requestedAt,
            timeoutSeconds: 8
        )))
        XCTAssertFalse(store.cancelStaleKeyboardCommand(
            token: command.token,
            now: requestedAt.addingTimeInterval(5)
        ))
        XCTAssertTrue(store.saveHeartbeat(SharedDictationAppHeartbeat(
            token: "live-owner",
            sessionID: command.sessionID,
            lastSeenAt: requestedAt.addingTimeInterval(10),
            sessionState: .recording
        )))
        XCTAssertFalse(store.cancelStaleKeyboardCommand(
            token: command.token,
            now: requestedAt.addingTimeInterval(10)
        ))
        XCTAssertTrue(store.cancelStaleKeyboardCommand(
            token: command.token,
            now: requestedAt.addingTimeInterval(16)
        ))
        XCTAssertEqual(
            store.status(forCommandToken: command.token),
            .failed(
                token: command.token,
                message: "Keyboard producer timed out; a committed transcript may still be recovered."
            )
        )

        let pendingCommand = SharedDictationSessionCommand(
            token: "expired-pending",
            kind: .start,
            source: .keyboard,
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(10),
            sessionID: "expired-pending-session"
        )
        XCTAssertTrue(store.saveCommand(pendingCommand))
        XCTAssertTrue(store.cancelStaleKeyboardCommand(
            token: pendingCommand.token,
            now: requestedAt.addingTimeInterval(10)
        ))
        XCTAssertEqual(
            store.status(forCommandToken: pendingCommand.token),
            .cancelled(token: pendingCommand.token)
        )
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

    func testDocumentContextFingerprintAcceptsHostWindowTruncationAtTheCaret() {
        let expectedContext = String(repeating: "x", count: 512) + "tail"
        let observedContext = String(expectedContext.suffix(256))
        let documentIdentifier = UUID()
        let fingerprint = SharedDictationDocumentContextFingerprint(
            beforeInput: expectedContext,
            afterInput: nil,
            documentIdentifier: documentIdentifier
        )

        XCTAssertTrue(fingerprint.matches(
            beforeInput: observedContext,
            afterInput: nil,
            documentIdentifier: documentIdentifier
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

    func testFileBackedMigrationPreservesStatusAndRecoveryWAL() throws {
        let defaults = try makeDefaults()
        let legacyStore = SharedDictationSessionStore(defaults: defaults)
        let start = SharedDictationSessionCommand.start(source: .keyboard)
        let recording = SharedDictationSessionStatus.recording(
            token: start.token,
            startedAt: start.requestedAt,
            timeoutSeconds: 8
        )
        let cancel = SharedDictationSessionCommand.cancel(
            sessionID: start.sessionID,
            source: .keyboard,
            replacingCommandToken: start.token
        )

        XCTAssertTrue(legacyStore.saveCommand(start))
        XCTAssertTrue(legacyStore.saveStatus(recording))
        XCTAssertTrue(legacyStore.recordCancellationIntent(cancel))
        XCTAssertTrue(legacyStore.recordDeliveryFailureIntent(
            token: start.token,
            message: "delivery retry"
        ))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDictationSessionStoreMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: directory.appendingPathComponent("session.json"),
            lockFileURL: directory.appendingPathComponent("session.lock")
        ))

        XCTAssertTrue(fileStore.storageHealth())
        XCTAssertTrue(fileStore.saveHeartbeat(SharedDictationAppHeartbeat(
            token: "migration-owner",
            sessionID: start.sessionID,
            lastSeenAt: Date(),
            sessionState: .recording
        )))
        XCTAssertEqual(fileStore.statusResolution(forCommandToken: start.token), .found(recording))
        XCTAssertEqual(fileStore.pendingDeliveryFailureIntents(), [start.token: "delivery retry"])
        XCTAssertEqual(fileStore.pendingCancellationIntents(), [cancel])
    }

    func testFileBackedMigrationRetainsLegacyLatestStatusAfterStatusIndexWasAbsent() throws {
        let defaults = try makeDefaults()
        let legacyStore = SharedDictationSessionStore(defaults: defaults)
        let start = SharedDictationSessionCommand.start(source: .keyboard)
        let recording = SharedDictationSessionStatus.recording(
            token: start.token,
            startedAt: start.requestedAt,
            timeoutSeconds: 8
        )
        XCTAssertTrue(legacyStore.saveCommand(start))
        XCTAssertTrue(legacyStore.saveStatus(recording))
        defaults.removeObject(forKey: "sharedDictation.session.status.\(start.token)")
        defaults.removeObject(forKey: "sharedDictation.session.statusIndex")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDictationSessionStoreLegacyStatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: directory.appendingPathComponent("session.json"),
            lockFileURL: directory.appendingPathComponent("session.lock")
        ))

        XCTAssertEqual(fileStore.statusResolution(forCommandToken: start.token), .found(recording))
        XCTAssertTrue(fileStore.saveStatus(.transcribing(token: start.token)))
        XCTAssertEqual(
            fileStore.statusResolution(forCommandToken: start.token),
            .found(.transcribing(token: start.token))
        )
    }

    func testFileBackedMigrationFailsClosedForMalformedLegacySafetyRecords() throws {
        let keys = [
            "sharedDictation.session.statusIndex",
            "sharedDictation.session.status",
            "sharedDictation.session.claims",
            "sharedDictation.session.claimOwners",
            "sharedDictation.session.heartbeat",
            "sharedDictation.session.deliveryFailureIntents",
            "sharedDictation.session.cancellationIntents"
        ]

        for (index, key) in keys.enumerated() {
            let defaults = try makeDefaults()
            defaults.set(Data([0xFF]), forKey: key)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SharedDictationSessionStoreMalformedLegacy-\(index)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try XCTUnwrap(SharedDictationSessionStore(
                defaults: defaults,
                envelopeURL: directory.appendingPathComponent("session.json"),
                lockFileURL: directory.appendingPathComponent("session.lock")
            ))

            XCTAssertFalse(store.storageHealth(), key)
            XCTAssertFalse(store.saveHeartbeat(SharedDictationAppHeartbeat(
                token: "blocked-\(index)",
                lastSeenAt: Date(),
                sessionState: .armed
            )), key)
        }
    }

    func testCancelledStatusCannotBeReanimatedWithoutReplacementClaim() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let command = SharedDictationSessionCommand.start(source: .keyboard)

        XCTAssertTrue(store.saveCommand(command))
        XCTAssertTrue(store.saveStatus(.cancelled(token: command.token)))
        XCTAssertFalse(store.saveStatus(
            .transcriptReady(token: command.token),
            allowRecoveryFromTranscriptReady: true
        ))
        XCTAssertEqual(store.status(forCommandToken: command.token), .cancelled(token: command.token))
    }

    func testTranscriptReadyCommandSurvivesHistoryChurnAfterCommandExpiry() throws {
        let defaults = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDictationSessionStoreTranscriptRetentionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(SharedDictationSessionStore(
            defaults: defaults,
            envelopeURL: directory.appendingPathComponent("session.json"),
            lockFileURL: directory.appendingPathComponent("session.lock")
        ))
        let requestedAt = Date()
        let start = SharedDictationSessionCommand.start(
            source: .keyboard,
            requestedAt: requestedAt,
            expiryInterval: 1
        )
        XCTAssertTrue(store.saveCommand(start))
        XCTAssertTrue(store.saveStatus(.transcriptReady(token: start.token), now: requestedAt))

        let staleRequestedAt = requestedAt.addingTimeInterval(-100)
        for index in 0..<40 {
            let churn = SharedDictationSessionCommand(
                token: "expired-churn-\(index)",
                kind: .start,
                source: .keyboard,
                requestedAt: staleRequestedAt,
                expiresAt: staleRequestedAt.addingTimeInterval(1),
                sessionID: "expired-churn-session-\(index)"
            )
            XCTAssertTrue(store.saveCommand(churn), "churn \(index)")
        }

        XCTAssertEqual(store.commandResolution(forToken: start.token), .found(start))
        XCTAssertEqual(
            store.statusResolution(forCommandToken: start.token),
            .found(.transcriptReady(token: start.token))
        )
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
