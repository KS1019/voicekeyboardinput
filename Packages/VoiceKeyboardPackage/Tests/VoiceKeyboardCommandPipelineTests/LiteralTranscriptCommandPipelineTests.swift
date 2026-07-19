import VoiceKeyboardCommandPipeline
import VoiceKeyboardModels
import XCTest

final class LiteralTranscriptCommandPipelineTests: XCTestCase {
    func testPreviewExposesParsedElementsAndPlannedOperations() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US")
        )

        let preview = pipeline.preview(
            for: "hello comma world",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(preview.elements, [
            .text("hello"),
            .command(.insertText(",")),
            .text("world")
        ])
        XCTAssertEqual(preview.operations, [
            .insertText("hello"),
            .insertText(","),
            .insertText(" world")
        ])
    }

    func testJapanesePreviewUsesLocaleSpecificUnspacedAliases() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "ja-JP")
        )

        let preview = pipeline.preview(
            for: "こんにちは読点世界改行",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(preview.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界"),
            .command(.insertText("\n"))
        ])
        XCTAssertEqual(preview.operations, [
            .insertText("こんにちは"),
            .insertText("、"),
            .insertText("世界"),
            .insertText("\n")
        ])
    }
}
