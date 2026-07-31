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

    func testPreservesWhitespaceAroundCommandBoundaries() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .text("hello  "),
            .command(.insertText(",")),
            .text("\tworld")
        ])

        XCTAssertEqual(
            planner.plan(transcript, documentContextBeforeInput: ""),
            [.insertText("hello  "), .insertText(","), .insertText("\tworld")]
        )
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

    func testInitialTextSpacingDoesNotAddSpaceAfterUnicodeOpeningDelimiters() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.text("hello")])

        for delimiter in ["“", "‘", "（", "「"] {
            XCTAssertEqual(
                planner.plan(transcript, documentContextBeforeInput: "prefix\(delimiter)"),
                [.insertText("hello")],
                delimiter
            )
        }
    }

    func testSingleQuoteSpacingAndSentenceDeletionTreatsQuotesAsDelimiters() {
        let planner = TextInsertionPlanner()

        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [
                    .command(.insertText("'")),
                    .text("quoted"),
                    .command(.insertText("'")),
                    .text("world")
                ]),
                documentContextBeforeInput: ""
            ),
            [.insertText("'"), .insertText("quoted"), .insertText("'"), .insertText(" world")]
        )

        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.text("world")]),
                documentContextBeforeInput: "He said '"
            ),
            [.insertText("world")]
        )
        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.text("world")]),
                documentContextBeforeInput: "hello 'quoted'"
            ),
            [.insertText(" world")]
        )
        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.command(.deleteSentence)]),
                documentContextBeforeInput: "One. 'Two.'"
            ),
            [.deleteBackward(count: deleteCount(7))]
        )
    }

    func testInitialTextSpacingAddsSpaceAfterWordFinalApostrophe() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.text("car")])

        for context in ["James'", "dogs'"] {
            XCTAssertEqual(
                planner.plan(transcript, documentContextBeforeInput: context),
                [.insertText(" car")],
                context
            )
        }
    }

    func testContractionApostropheDoesNotAffectSingleQuoteParity() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .command(.insertText("'")),
            .text("quoted"),
            .command(.insertText("'")),
            .text("next")
        ])

        XCTAssertEqual(
            planner.plan(transcript, documentContextBeforeInput: "don't"),
            [
                .insertText(" '"),
                .insertText("quoted"),
                .insertText("'"),
                .insertText(" next")
            ]
        )
    }

    func testOpeningCommandDoesNotDuplicateExistingWhitespace() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [
            .command(.insertText("(")),
            .command(.insertText("\""))
        ])

        XCTAssertEqual(
            planner.plan(transcript, documentContextBeforeInput: "hello "),
            [.insertText("("), .insertText("\"")]
        )
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

    func testPlansOnlyOneJapaneseCharacterForDeleteWordWithoutWhitespace() {
        let planner = TextInsertionPlanner()
        let operations = planner.plan(
            ParsedTranscript(elements: [.command(.deleteWord)]),
            documentContextBeforeInput: "今日は晴れ"
        )

        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(1))])

        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.command(.deleteWord)]),
                documentContextBeforeInput: "今日は晴れ。"
            ),
            [.deleteBackward(count: deleteCount(1))]
        )
    }

    func testPlansTheTrailingEnglishWordWhenJapaneseTextPrecedesIt() {
        let planner = TextInsertionPlanner()
        let operations = planner.plan(
            ParsedTranscript(elements: [.command(.deleteWord)]),
            documentContextBeforeInput: "今日は sunny"
        )

        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(5))])
    }

    func testPlansTheTrailingEnglishWordWhenJapaneseTextTouchesIt() {
        let planner = TextInsertionPlanner()
        let operations = planner.plan(
            ParsedTranscript(elements: [.command(.deleteWord)]),
            documentContextBeforeInput: "今日はSwift"
        )

        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(5))])
    }

    func testPlansDeleteWordForApostrophesAndUnderscoresAsOneWord() {
        let planner = TextInsertionPlanner()

        for context in ["don't", "user_name"] {
            XCTAssertEqual(
                planner.plan(
                    ParsedTranscript(elements: [.command(.deleteWord)]),
                    documentContextBeforeInput: context
                ),
                [.deleteBackward(count: deleteCount(context.count))],
                context
            )
        }
    }

    func testDoesNotTreatADecimalPointAsASentenceBoundary() {
        let planner = TextInsertionPlanner()
        let operations = planner.plan(
            ParsedTranscript(elements: [.command(.deleteSentence)]),
            documentContextBeforeInput: "合計は3.14"
        )

        XCTAssertEqual(operations, [.deleteBackward(count: deleteCount(7))])
    }

    func testSentenceDeletionTreatsAllCommonLineSeparatorsAsBoundaries() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        for context in [
            "First line\nSecond",
            "First line\r\nSecond",
            "First line\rSecond",
            "First line\u{85}Second",
            "First line\u{2028}Second",
            "First line\u{2029}Second"
        ] {
            XCTAssertEqual(
                planner.plan(transcript, documentContextBeforeInput: context),
                [.deleteBackward(count: deleteCount("Second".count))],
                context.debugDescription
            )
        }
    }

    func testSentenceDeletionStopsAtAmbiguousAbbreviationPeriods() {
        let planner = TextInsertionPlanner()

        for context in [
            "Visit https://example.com/path",
            "Email me@example.com"
        ] {
            XCTAssertEqual(
                planner.plan(
                    ParsedTranscript(elements: [.command(.deleteSentence)]),
                    documentContextBeforeInput: context
                ),
                [.deleteBackward(count: deleteCount(context.count))],
                context
            )
        }

        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.command(.deleteSentence)]),
                documentContextBeforeInput: "Read e.g. this note"
            ),
            [.deleteBackward(count: deleteCount(" this note".count))]
        )
        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.command(.deleteSentence)]),
                documentContextBeforeInput: "Call Dr. Smith"
            ),
            [.deleteBackward(count: deleteCount(" Smith".count))]
        )
    }

    func testSentenceDeletionStopsAfterSingleLetterInitial() {
        let planner = TextInsertionPlanner()

        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.command(.deleteSentence)]),
                documentContextBeforeInput: "I. Next sentence"
            ),
            [.deleteBackward(count: deleteCount(" Next sentence".count))]
        )
    }

    func testSentenceDeletionCanTreatIncAsAnActualSentenceBoundary() {
        let planner = TextInsertionPlanner()

        XCTAssertEqual(
            planner.plan(
                ParsedTranscript(elements: [.command(.deleteSentence)]),
                documentContextBeforeInput: "Acme Inc. Next sentence."
            ),
            [.deleteBackward(count: deleteCount(15))]
        )
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

    func testPlansDeleteSentenceAfterFullwidthSentenceTerminators() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        for terminator in ["．", "｡", "﹒"] {
            XCTAssertEqual(
                planner.plan(
                    transcript,
                    documentContextBeforeInput: "First\(terminator) Second"
                ),
                [.deleteBackward(count: deleteCount(7))],
                terminator
            )
        }
    }

    func testFullwidthSentenceTerminatorsInsideNumbersDoNotBecomeBoundaries() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        for separator in ["．", "｡", "﹒"] {
            XCTAssertEqual(
                planner.plan(
                    transcript,
                    documentContextBeforeInput: "合計は3\(separator)14"
                ),
                [.deleteBackward(count: deleteCount(7))],
                separator
            )
        }
    }

    func testPlansDeleteSentenceIncludingCJKClosingDelimiters() {
        let planner = TextInsertionPlanner()
        let transcript = ParsedTranscript(elements: [.command(.deleteSentence)])

        XCTAssertEqual(
            planner.plan(
                transcript,
                documentContextBeforeInput: "一。〖二。〗"
            ),
            [.deleteBackward(count: deleteCount(4))]
        )
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

    func testDeleteWordTreatsUnicodeDecimalTokensAsOneWord() {
        let planner = TextInsertionPlanner()

        for context in ["３．１４", "3｡14", "3﹒14"] {
            XCTAssertEqual(
                planner.plan(
                    ParsedTranscript(elements: [.command(.deleteWord)]),
                    documentContextBeforeInput: context
                ),
                [.deleteBackward(count: deleteCount(context.count))],
                context
            )
        }
    }

    func testSplitsDeletionCountsBeyondSingleOperationLimit() {
        let planner = TextInsertionPlanner()
        let context = String(repeating: "x", count: 257)
        let operations = planner.plan(
            ParsedTranscript(elements: [.command(.deleteSentence)]),
            documentContextBeforeInput: context
        )

        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(
            operations.compactMap { operation in
                if case let .deleteBackward(count) = operation { return count.value }
                return nil
            }.reduce(0, +),
            257
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
