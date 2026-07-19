import Foundation
import VoiceKeyboardModels
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

    func testStatusRoundTripsThroughDefaults() throws {
        let defaults = try makeDefaults()
        let store = SharedDictationSessionStore(defaults: defaults)
        let statuses: [SharedDictationSessionStatus] = [
            .idle,
            .commandPending(token: "a", requestedAt: Date(timeIntervalSince1970: 1)),
            .commandAcknowledged(token: "a", acknowledgedAt: Date(timeIntervalSince1970: 2)),
            .recording(token: "a", startedAt: Date(timeIntervalSince1970: 3), timeoutSeconds: 8),
            .transcribing(token: "a"),
            .transcriptReady(token: "a"),
            .failed(token: "a", message: "Audio unavailable"),
            .cancelled(token: "a")
        ]

        for status in statuses {
            store.saveStatus(status)
            XCTAssertEqual(store.status(), status)
        }
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
            source: .keyboard
        )

        XCTAssertEqual(stop.sessionID, start.sessionID)
        XCTAssertNotEqual(stop.token, start.token)
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

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SharedDictationSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
