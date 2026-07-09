import Foundation
import VoiceKeyboardModels
import XCTest

final class SharedDictationAppHeartbeatTests: XCTestCase {
    func testHeartbeatIsFreshWithinAllowedAge() {
        let heartbeat = SharedDictationAppHeartbeat(
            token: "app-session",
            lastSeenAt: Date(timeIntervalSince1970: 100),
            sessionState: .armed
        )

        XCTAssertTrue(heartbeat.isFresh(
            at: Date(timeIntervalSince1970: 104),
            maxAge: 5
        ))
        XCTAssertFalse(heartbeat.isFresh(
            at: Date(timeIntervalSince1970: 106),
            maxAge: 5
        ))
    }

    func testUnavailableHeartbeatIsNeverFresh() {
        let heartbeat = SharedDictationAppHeartbeat(
            token: "app-session",
            lastSeenAt: Date(timeIntervalSince1970: 100),
            sessionState: .unavailable
        )

        XCTAssertFalse(heartbeat.isFresh(
            at: Date(timeIntervalSince1970: 101),
            maxAge: 5
        ))
    }
}
