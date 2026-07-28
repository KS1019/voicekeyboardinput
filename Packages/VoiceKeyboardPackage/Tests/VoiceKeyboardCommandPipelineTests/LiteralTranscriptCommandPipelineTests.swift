import VoiceKeyboardCommandPipeline
import VoiceKeyboardModels
import XCTest

final class LiteralTranscriptCommandPipelineTests: XCTestCase {
    func testPreviewExposesParsedElementsAndPlannedOperations() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US")
        )

        let preview = pipeline.preview(
            for: "comma",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(preview.elements, [
            .command(.insertText(",")),
        ])
        XCTAssertEqual(preview.operations, [
            .insertText(",")
        ])
    }

    func testJapanesePreviewKeepsAmbiguousUnspacedAliasesLiteral() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "ja-JP")
        )

        let preview = pipeline.preview(
            for: "こんにちは読点世界改行",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(preview.elements, [
            .text("こんにちは読点世界改行")
        ])
        XCTAssertEqual(preview.operations, [
            .insertText("こんにちは読点世界改行")
        ])
    }

    func testPreviewRejectsOversizedInputWithoutParsingIt() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US")
        )
        let preview = pipeline.preview(
            for: String(repeating: "x", count: LiteralTranscriptCommandPipeline.maximumInputCharacterCount + 1),
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(preview.operations, [])
        XCTAssertEqual(preview.elements, [.text("Transcript is too large to preview safely.")])
    }

    func testBoundedPreviewRejectsPlannerAddedBoundaryThatExceedsPayloadLimit() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US")
        )
        let transcript = String(
            repeating: "a",
            count: VoiceKeyboardTextLimits.maximumCharacterCount
        )

        XCTAssertNil(pipeline.boundedPreview(
            for: transcript,
            documentContextBeforeInput: "existing text",
            maximumOperationCount: 4
        ))
    }
}
