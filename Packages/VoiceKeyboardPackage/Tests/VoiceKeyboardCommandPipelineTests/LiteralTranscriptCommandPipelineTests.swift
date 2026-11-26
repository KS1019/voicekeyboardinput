import VoiceKeyboardCommandPipeline
import VoiceKeyboardModels
import XCTest

final class LiteralTranscriptCommandPipelineTests: XCTestCase {
    func testStreamingDefersCommandCandidatesButCommitsOrdinaryText() {
        let pipeline = LiteralTranscriptCommandPipeline(locale: .init(identifier: "en-US"))
        for text in ["new", "new line", "command delete", "command delete word", "hello comma"] {
            XCTAssertTrue(pipeline.mayContainStreamingCommand(text), text)
        }
        XCTAssertFalse(pipeline.mayContainStreamingCommand("hello world"))
    }

    func testStreamingRetainsEarlierLiteralContextWhenResolvingCommands() {
        let pipeline = LiteralTranscriptCommandPipeline(locale: .init(identifier: "en-US"))
        let preview = pipeline.boundedPreview(
            for: "do not command delete word", documentContextBeforeInput: "do not",
            maximumOperationCount: 64, omittingLiteralPrefix: "do not"
        )
        XCTAssertEqual(preview?.operations, [.insertText(" command delete word")])
        XCTAssertNil(pipeline.boundedPreview(
            for: "different text", documentContextBeforeInput: "hello", maximumOperationCount: 64,
            omittingLiteralPrefix: "hello"
        ))
    }

    func testPreviewPreservesNaturalProseAroundPunctuationWords() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US")
        )

        let preview = pipeline.preview(
            for: "hello comma world",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(preview.elements, [
            .text("hello comma world")
        ])
        XCTAssertEqual(preview.operations, [
            .insertText("hello comma world")
        ])
    }

    func testJapanesePreviewParsesACommandTerminatedUnspacedSequence() {
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

    func testPreviewRejectsPlannerAddedBoundaryThatExceedsPayloadLimit() {
        let pipeline = LiteralTranscriptCommandPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US")
        )
        let transcript = String(
            repeating: "a",
            count: LiteralTranscriptCommandPipeline.maximumInputCharacterCount
        )

        let preview = pipeline.preview(
            for: transcript,
            documentContextBeforeInput: "existing text"
        )
        XCTAssertEqual(preview.operations, [])
        XCTAssertEqual(preview.elements, [.text("Transcript is too large to preview safely.")])
    }
}
