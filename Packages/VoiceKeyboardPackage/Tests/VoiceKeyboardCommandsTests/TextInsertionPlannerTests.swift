import VoiceKeyboardCommands
import VoiceKeyboardModels
import XCTest

final class TextInsertionPlannerTests: XCTestCase {
    func testPlansTextAndCommandInsertion() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .text("hello"),
            .command(.insertText(",")),
            .text("world"),
            .command(.insertText("\n")),
            .text("again")
        ])

        let operations = planner.plan(transcript, documentContextBeforeInput: "")
        XCTAssertEqual(operations, [
            .insertText("hello"),
            .insertText(","),
            .insertText(" world"),
            .insertText("\n"),
            .insertText("again")
        ])
    }

    func testPlansSpacesBetweenPlainWords() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .text("hello"),
            .text("world")
        ])

        let operations = planner.plan(transcript, documentContextBeforeInput: "")
        XCTAssertEqual(operations, [
            .insertText("hello"),
            .insertText(" world")
        ])
    }

    func testPlansTextInsideQuotesWithoutInnerSpaces() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .command(.insertText("\"")),
            .text("hello"),
            .command(.insertText("\"")),
            .text("world")
        ])

        let operations = planner.plan(transcript, documentContextBeforeInput: "")
        XCTAssertEqual(operations, [
            .insertText("\""),
            .insertText("hello"),
            .insertText("\""),
            .insertText(" world")
        ])
    }

    func testPlansEnglishOpeningDelimitersWithLeadingSpace() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .text("hello"),
            .command(.insertText("(")),
            .text("world"),
            .command(.insertText(")")),
            .command(.insertText("\"")),
            .text("quoted"),
            .command(.insertText("\""))
        ])

        XCTAssertEqual(
            planner.plan(transcript, documentContextBeforeInput: ""),
            [
                .insertText("hello"),
                .insertText(" ("),
                .insertText("world"),
                .insertText(")"),
                .insertText(" \""),
                .insertText("quoted"),
                .insertText("\"")
            ]
        )
    }

    func testDoesNotInsertSpaceAfterJapanesePunctuationCommands() {
        let planner = TextInsertionPlanner()

        for punctuation in ["、", "。", "？", "！"] {
            let transcript = ParsedTranscript(elements: [
                .text("前"),
                .command(.insertText(punctuation)),
                .text("後")
            ])

            XCTAssertEqual(
                planner.plan(transcript, documentContextBeforeInput: ""),
                [.insertText("前"), .insertText(punctuation), .insertText("後")]
            )
        }
    }

    func testInitialTextSpacingUsesDocumentContext() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.text("world")])

        let operations = planner.plan(transcript, documentContextBeforeInput: "hello")
        XCTAssertEqual(operations, [.insertText(" world")])
    }

    func testInitialTextSpacingDoesNotAddSpaceAfterWhitespaceOrOpenPunctuation() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.text("world")])

        XCTAssertEqual(
            planner.plan(transcript, documentContextBeforeInput: "hello "),
            [.insertText("world")]
        )
        XCTAssertEqual(
            planner.plan(transcript, documentContextBeforeInput: "hello\n"),
            [.insertText("world")]
        )
        XCTAssertEqual(
            planner.plan(transcript, documentContextBeforeInput: "("),
            [.insertText("world")]
        )
    }

    func testInitialTextSpacingDoesNotAddSpaceAfterOpeningDoubleQuote() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.text("hello")])

        let operations = planner.plan(
            transcript,
            documentContextBeforeInput: "He said \""
        )

        XCTAssertEqual(operations, [.insertText("hello")])
    }

    func testInitialTextSpacingDoesNotAddSpaceAfterJapanesePunctuation() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.text("後")])

        for punctuation in ["、", "。", "？", "！"] {
            XCTAssertEqual(
                planner.plan(transcript, documentContextBeforeInput: "前\(punctuation)"),
                [.insertText("後")]
            )
        }
    }

    func testInitialTextSpacingDoesNotAddSpaceBetweenJapaneseText() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.text("後")])

        let operations = planner.plan(transcript, documentContextBeforeInput: "前")
        XCTAssertEqual(operations, [.insertText("後")])
    }

    func testInitialTextSpacingDoesNotAddSpaceBetweenEnglishAndJapaneseText() {
        let planner = TextInsertionPlanner()

        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.text("後")]),
                documentContextBeforeInput: "abc"
            ),
            [.insertText("後")]
        )
        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.text("world")]),
                documentContextBeforeInput: "前"
            ),
            [.insertText("world")]
        )
    }

    func testPlansAdjacentJapaneseTextWithoutAsciiSpace() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .text("前"),
            .text("後")
        ])

        let operations = planner.plan(transcript, documentContextBeforeInput: "")
        XCTAssertEqual(operations, [
            .insertText("前"),
            .insertText("後")
        ])
    }

    func testPlansDeleteWordFromVisibleContext() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteWord)])

        let operations = planner.plan(transcript, documentContextBeforeInput: "hello world")
        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(5))])
    }

    func testPlansDeleteWordIncludingTrailingWhitespace() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteWord)])

        let operations = planner.plan(transcript, documentContextBeforeInput: "hello world ")
        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(6))])
    }

    func testPlansDeleteAfterInsertedTextAgainstVirtualContext() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .text("hi"),
            .command(.deleteWord)
        ])

        let operations = planner.plan(transcript, documentContextBeforeInput: "hello ")
        XCTAssertEqual(operations, [
            .insertText("hi"),
            .deleteBackward(count: deleteCount(2))
        ])
    }

    func testPlansRepeatedDeletesAgainstVirtualContext() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .command(.deleteWord),
            .command(.deleteWord)
        ])

        let operations = planner.plan(transcript, documentContextBeforeInput: "one two")
        XCTAssertEqual(operations, [
            .deleteBackward(count: deleteCount(3)),
            .deleteBackward(count: deleteCount(4))
        ])
    }

    func testPlansDeleteSentenceFromVisibleContext() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        let operations = planner.plan(transcript, documentContextBeforeInput: "One. Two three")
        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(10))])
    }

    func testPlansDeleteSentenceIncludingSeparatorWhitespace() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        let operations = planner.plan(transcript, documentContextBeforeInput: "One.  Two")
        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(5))])
    }

    func testPlansDeleteSentenceIncludingTrailingWhitespace() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        let operations = planner.plan(transcript, documentContextBeforeInput: "One. Two ")
        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(5))])
    }

    func testPlansDeleteSentenceAfterJapaneseTerminator() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        let operations = planner.plan(transcript, documentContextBeforeInput: "一。二三")
        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(2))])
    }

    func testPlansDeleteSentenceIncludingStackedAsciiTerminators() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        let operations = planner.plan(
            transcript,
            documentContextBeforeInput: "One. Hello!!"
        )

        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(8))])
    }

    func testPlansDeleteSentenceIncludingStackedJapaneseTerminators() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        let operations = planner.plan(
            transcript,
            documentContextBeforeInput: "一。二三！！"
        )

        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(4))])
    }

    func testPlansDeleteSentenceIncludingTrailingClosingDelimiters() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        XCTAssertEqual(
            planner.plan(
                transcript,
                documentContextBeforeInput: "One. \"Two.\""
            ),
            [.deleteBackward(count: deleteCount(7))]
        )

        XCTAssertEqual(
            planner.plan(
                transcript,
                documentContextBeforeInput: "One. (Two.)"
            ),
            [.deleteBackward(count: deleteCount(7))]
        )

        XCTAssertEqual(
            planner.plan(
                transcript,
                documentContextBeforeInput: "一。「二。」"
            ),
            [.deleteBackward(count: deleteCount(4))]
        )
    }

    func testPlansDeleteSentenceIncludingUnicodeClosingDelimiters() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        XCTAssertEqual(
            planner.plan(
                transcript,
                documentContextBeforeInput: "One. “Two.”"
            ),
            [.deleteBackward(count: deleteCount(7))]
        )

        XCTAssertEqual(
            planner.plan(
                transcript,
                documentContextBeforeInput: "One. （Two。）"
            ),
            [.deleteBackward(count: deleteCount(7))]
        )
    }

    func testPlansTextWithSpaceAfterDeletingSentence() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .command(.deleteSentence),
            .text("next")
        ])

        XCTAssertEqual(
            planner.plan(transcript, documentContextBeforeInput: "One. Two"),
            [
                .deleteBackward(count: deleteCount(4)),
                .insertText(" next")
            ]
        )
    }

    func testSkipsDeleteCommandsWithZeroCount() {
        let planner = TextInsertionPlanner()

        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.command(.deleteWord)]),
                documentContextBeforeInput: ""
            ),
            []
        )
        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.command(.deleteSentence)]),
                documentContextBeforeInput: "   "
            ),
            []
        )
    }

    func testUnsupportedShortcutProducesFeedbackOperation() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.unsupportedShortcut("command copy"))])

        let operations = planner.plan(transcript, documentContextBeforeInput: "hello")
        XCTAssertEqual(operations, [.showUnsupportedCommand("command copy")])
    }
}

private func deleteCount(_ value: Int) -> TextDeletionCount {
    guard let count = TextDeletionCount(value) else {
        preconditionFailure("Expected positive deletion count")
    }
    return count
}
