import VoiceKeyboardModels
import XCTest

final class SharedDictationSessionStatusKeyboardInteractionTests: XCTestCase {
    func testPendingAndRunningStatusesAcceptKeyboardStopCommand() {
        let statuses: [SharedDictationSessionStatus] = [
            .commandPending(token: "token", requestedAt: Date()),
            .commandAcknowledged(token: "token", acknowledgedAt: Date()),
            .recording(token: "token", startedAt: Date(), timeoutSeconds: 8),
            .transcribing(token: "token")
        ]

        XCTAssertTrue(statuses.allSatisfy(\.acceptsKeyboardStopCommand))
    }

    func testTerminalStatusesDoNotAcceptKeyboardStopCommand() {
        let statuses: [SharedDictationSessionStatus] = [
            .idle,
            .transcriptReady(token: "token"),
            .failed(token: "token", message: "failed"),
            .cancelled(token: "token")
        ]

        XCTAssertFalse(statuses.contains(where: \.acceptsKeyboardStopCommand))
    }
}
