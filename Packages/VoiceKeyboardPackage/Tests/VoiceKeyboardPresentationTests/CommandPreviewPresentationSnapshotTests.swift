import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

final class CommandPreviewPresentationSnapshotTests: XCTestCase {
    private let deleteWordCount = TextDeletionCount(5)!

    func testFormatsOperationPreviewLines() {
        let snapshot = CommandPreviewPresentationSnapshot(operations: [
            .insertText("hello"),
            .insertText("\n"),
            .deleteBackward(count: deleteWordCount),
            .showUnsupportedCommand("command copy")
        ])

        XCTAssertEqual(
            snapshot.displayText,
            """
            insert "hello"
            insert "\\n"
            delete 5
            unsupported "command copy"
            """
        )
    }

    func testEmptyOperationsProduceEmptyPreview() {
        let snapshot = CommandPreviewPresentationSnapshot.empty

        XCTAssertEqual(snapshot.displayText, "Command operations appear here.")
    }
}
