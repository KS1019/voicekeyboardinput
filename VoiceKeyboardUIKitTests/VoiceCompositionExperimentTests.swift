@testable import VoiceKeyboardInput
import UIKit
import XCTest

@MainActor
final class VoiceCompositionExperimentTests: XCTestCase {
    func testLiteralModeNeverExecutesCommandWording() {
        var draft = VoiceCompositionExperiment()
        let token = draft.begin(mode: .literal)
        draft.update(cumulativeTranscript: "ここから日本語", generation: token)
        XCTAssertEqual(draft.commit(generation: token), .insert("ここから日本語"))
    }

    func testPartialCommandWaitsForCompleteUtteranceAndCommitsOnce() {
        var draft = VoiceCompositionExperiment()
        let token = draft.begin(mode: .command)
        draft.update(cumulativeTranscript: "new line", generation: token)
        draft.update(cumulativeTranscript: "new line item", generation: token)
        XCTAssertEqual(draft.commit(generation: token), .insert("new line item"))
        XCTAssertNil(draft.commit(generation: token))
        XCTAssertEqual(draft.mode, .literal)
    }

    func testExplicitLanguageCommandAndNewline() {
        var draft = VoiceCompositionExperiment()
        var token = draft.begin(mode: .command)
        draft.update(cumulativeTranscript: "ここから日本語", generation: token)
        XCTAssertEqual(draft.commit(generation: token), .language("ja-JP"))
        token = draft.begin(mode: .command)
        draft.update(cumulativeTranscript: "改行して", generation: token)
        XCTAssertEqual(draft.commit(generation: token), .insert("\n"))
    }

    func testNegationQuotationAndDeletionStayLiteral() {
        for text in ["改行しないで", "「改行して」と書いて", "delete word", "command delete word", "ここから日本語という例"] {
            var draft = VoiceCompositionExperiment()
            let token = draft.begin(mode: .command)
            draft.update(cumulativeTranscript: text, generation: token)
            XCTAssertEqual(draft.commit(generation: token), .insert(text))
        }
    }

    func testChangedDestinationRejectsLateResultAndCommit() {
        var draft = VoiceCompositionExperiment()
        let old = draft.begin(mode: .command)
        draft.update(cumulativeTranscript: "改行して", generation: old)
        _ = draft.begin(mode: .literal)
        XCTAssertFalse(draft.update(cumulativeTranscript: "late text", generation: old))
        XCTAssertNil(draft.commit(generation: old))
        XCTAssertEqual(draft.draft, "")
    }

    func testLongDraftRetainsTailWithoutDuplicatingPartialHypotheses() {
        var draft = VoiceCompositionExperiment()
        let token = draft.begin(mode: .literal)
        let text = String(repeating: "文", count: 180)
        draft.update(cumulativeTranscript: String(text.prefix(80)), generation: token)
        draft.update(cumulativeTranscript: text, generation: token)
        XCTAssertTrue(draft.shouldOfferCommit)
        XCTAssertEqual(draft.commit(generation: token), .insert(text))
        XCTAssertNil(draft.commit(generation: token))
    }

    func testOversizeUpdateDoesNotSilentlyTruncateDraft() {
        var draft = VoiceCompositionExperiment()
        let token = draft.begin(mode: .literal)
        draft.update(cumulativeTranscript: "kept", generation: token)
        XCTAssertFalse(draft.update(cumulativeTranscript: String(repeating: "x", count: 513), generation: token))
        XCTAssertEqual(draft.draft, "kept")
    }

    func testUIKitMarkedTextReplacesCompositionThenUnmarksWithoutDuplication() {
        let field = UITextField()
        field.text = "prefix "
        let end = field.endOfDocument
        field.selectedTextRange = field.textRange(from: end, to: end)
        field.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        let final = "日本語😀"
        field.setMarkedText(final, selectedRange: NSRange(location: final.utf16.count, length: 0))
        XCTAssertEqual(field.text, "prefix " + final)
        XCTAssertNotNil(field.markedTextRange)
        field.unmarkText()
        XCTAssertNil(field.markedTextRange)
        XCTAssertEqual(field.text, "prefix " + final)
    }
}
