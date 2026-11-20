import VoiceKeyboardCommands
import VoiceKeyboardModels
import XCTest

final class VoiceCommandParserTests: XCTestCase {
    func testParsesPunctuationAndNewline() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let result = parser.parse("comma newline")

        XCTAssertEqual(result.elements, [
            .command(.insertText(",")),
            .command(.insertText("\n"))
        ])
    }

    func testPunctuationAliasInsideOrdinaryProseRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertEqual(parser.parse("hello comma world").elements, [
            .text("hello comma world")
        ])
    }

    func testParsesNewLineAsSingleCommand() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let result = parser.parse("new line")

        XCTAssertEqual(result.elements, [
            .command(.insertText("\n"))
        ])
    }

    func testParsesEditingCommands() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let result = parser.parse("command delete word command delete sentence")
        XCTAssertEqual(result.elements, [
            .command(.deleteWord),
            .command(.deleteSentence)
        ])
    }

    func testDestructiveCommandsInsideARequestRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertEqual(
            parser.parse("delete word is a phrase").elements,
            [.text("delete word is a phrase")]
        )
    }

    func testUnprefixedDestructiveCommandRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertEqual(parser.parse("delete word").elements, [.text("delete word")])
        XCTAssertEqual(
            parser.parse("command delete word").elements,
            [.command(.deleteWord)]
        )
    }

    func testWhitespaceOnlyTranscriptRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))
        let transcript = "  \n\t"

        let parsed = parser.parse(transcript)
        XCTAssertEqual(parsed.elements, [.text(transcript)])
    }

    func testJapaneseUnspacedExpansionHonorsElementLimit() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))
        let transcript = String(repeating: "読点／", count: 600)

        let parsed = parser.parse(transcript)
        XCTAssertEqual(parsed.elements, [.text(transcript)])
        XCTAssertTrue(parsed.didOverflow)
    }

    func testDestructiveCommandsRemainLiteralWhenNaturalTextPrecedesThem() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        for transcript in [
            "the phrase delete word",
            "say delete word",
            "do not delete sentence"
        ] {
            XCTAssertEqual(
                parser.parse(transcript).elements,
                [.text(transcript)],
                transcript
            )
        }
    }

    func testDestructiveCommandsCanBeFollowedByExplicitCommandWords() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertEqual(
            parser.parse("command delete word comma").elements,
            [.command(.deleteWord), .command(.insertText(","))]
        )
    }

    func testRecognizesIncompleteMultiWordCommandPrefixes() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertTrue(parser.hasIncompleteCommandPrefix("delete"))
        XCTAssertTrue(parser.hasIncompleteCommandPrefix("hello new"))
        XCTAssertFalse(parser.hasIncompleteCommandPrefix("delete word"))
        XCTAssertFalse(parser.hasIncompleteCommandPrefix("hello world"))
    }

    func testRecognizesIncompleteJapaneseAliasesAcrossFinalizedSegments() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        XCTAssertTrue(parser.hasIncompleteCommandPrefix("改"))
        XCTAssertTrue(parser.hasIncompleteCommandPrefix("こんにちは／読"))
        XCTAssertFalse(parser.hasIncompleteCommandPrefix("こんにちは読"))
        XCTAssertFalse(parser.hasIncompleteCommandPrefix("改行"))
        XCTAssertFalse(parser.hasIncompleteCommandPrefix("こんにちは読点"))

        XCTAssertEqual(
            parser.parse("改" + "行").elements,
            [.command(.insertText("\n"))]
        )
        XCTAssertEqual(
            parser.parse("読" + "点").elements,
            [.command(.insertText("、"))]
        )
    }

    func testParsesUnsupportedShortcutCommands() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let result = parser.parse("command copy hello")
        XCTAssertEqual(result.elements, [
            .command(.unsupportedShortcut("command copy")),
            .text("hello")
        ])
    }

    func testParsesMixedCaseMultiWordUnsupportedShortcutAlias() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let result = parser.parse("Command Select All")

        XCTAssertEqual(result.elements, [
            .command(.unsupportedShortcut("command select all"))
        ])
    }

    func testPunctuationAdjacentAliasesRemainText() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let result = parser.parse("comma, quote, newline.")

        XCTAssertEqual(result.elements, [
            .text("comma, quote, newline.")
        ])
    }

    func testLiteralTranscriptPreservesWhitespaceExactly() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertEqual(
            parser.parse("hello  \tworld\nnext").elements,
            [.text("hello  \tworld\nnext")]
        )
    }

    func testNaturalLanguagePunctuationAliasesRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        for transcript in [
            "I need some space",
            "Please add a comma here",
            "The quote was missing",
            "This is a question mark"
        ] {
            XCTAssertEqual(
                parser.parse(transcript).elements,
                [.text(transcript)],
                transcript
            )
        }

        for transcript in [
            "there is no space left",
            "comma splice",
            "quote me"
        ] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }

        for transcript in [
            "The word period",
            "I said comma",
            "I mentioned tab"
        ] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testPunctuationAroundNaturalLanguageCuesRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        for transcript in [
            "The word, period",
            "I said, comma",
            "I mentioned: tab"
        ] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testOrdinaryProseWithCommandWordsRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        for transcript in [
            "Oxford comma debate",
            "space exploration",
            "the command copy failed"
        ] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testNaturalLanguageNewlineAndParenthesisAliasesRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        for transcript in [
            "new line of business",
            "newline character",
            "use open parenthesis",
            "comma and period",
            "space bar",
            "open parenthesis or close parenthesis"
        ] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testNaturalLanguageNounPhrasesBeginningWithAliasesRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        for transcript in ["new line item", "space station", "period drama", "question mark icon"] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testNaturalLanguageInstructionsUsingSensitiveAliasesRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        for transcript in ["Press space to continue", "We quote Alice"] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testDestructiveCommandDoesNotCrossTranscriptLineBreaks() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))
        let transcript = "command\ndelete word"

        XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)])
    }

    func testMultiWordCommandDoesNotCrossNonCanonicalWhitespace() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        for transcript in ["open\nparenthesis", "question\tmark", "new  line"] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testNaturalLanguagePunctuationAliasWithUnlistedCueRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertEqual(
            parser.parse("I prefer comma syntax").elements,
            [.text("I prefer comma syntax")]
        )
    }

    func testJapaneseNaturalLanguageConnectorsRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        for transcript in [
            "読点なら句点", "読点また句点", "読点ないし句点", "読点もしくは句点",
            "読点若しくは句点", "読点並びに句点"
        ] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testJapaneseImplicitCommandOverflowFallsBackWithOverflowMarker() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let transcript = String(repeating: "読点／", count: 300)
        let result = parser.parse(transcript)

        XCTAssertTrue(result.didOverflow)
        XCTAssertEqual(result.elements.count, 1)
        XCTAssertEqual(result.elements.first, .text(transcript))
    }

    func testLiteralizedDestructivePhraseDoesNotExecuteLaterPunctuationCommand() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertEqual(
            parser.parse("say delete word comma").elements,
            [.text("say delete word comma")]
        )
    }

    func testMixedPrefixedAndUnprefixedDestructiveCommandsRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        XCTAssertEqual(
            parser.parse("command delete word delete sentence").elements,
            [.text("command delete word delete sentence")]
        )
    }

    func testJapanesePunctuationAliasesInsideProseRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは 読点 世界 改行")
        XCTAssertEqual(result.elements, [.text("こんにちは 読点 世界 改行")])
    }

    func testJapaneseNewlineAliasWithFollowingCueRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        for transcript in ["改行 は必要", "改行について"] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }

        for transcript in ["改行 がいる", "空白 を入れる"] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testParsesJapaneseAliasesAtPunctuationBoundariesWithoutWhitespace() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは／読点／世界／改行")
        XCTAssertEqual(result.elements, [
            .text("こんにちは／"),
            .command(.insertText("、")),
            .text("／世界／"),
            .command(.insertText("\n"))
        ])
    }

    func testJapaneseUnspacedCommandSequenceCanEndWithACommand() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは読点世界改行")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界"),
            .command(.insertText("\n"))
        ])
    }

    func testJapaneseImplicitCommandSequenceDoesNotParseNaturalLanguageChunks() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        for transcript in [
            "改行コード改行",
            "読点の使い方読点",
            "改行する句点",
            "改行位置句点",
            "説明改行句点"
        ] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testJapaneseNaturalLanguageCompoundWithMultipleAliasesRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        XCTAssertEqual(
            parser.parse("改行時読点").elements,
            [.text("改行時読点")]
        )
    }

    func testJapaneseListsAndComparisonsRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        for transcript in ["読点より句点", "読点、句点", "読点直後に句点"] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testJapanesePostpositionAfterCommandAliasRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        XCTAssertEqual(parser.parse("読点後に句点").elements, [.text("読点後に句点")])
    }

    func testVeryLongJapaneseSegmentFallsBackBeforeImplicitRescan() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))
        let transcript = String(repeating: "あ", count: 4_097)

        let parsed = parser.parse(transcript)
        XCTAssertEqual(parsed.elements, [.text(transcript)])
        XCTAssertFalse(parsed.didOverflow)
    }

    func testJapaneseParticlesPreventImplicitCommandSequenceParsing() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        for transcript in [
            "読点と句点", "改行や空白", "句点から読点", "読点および句点",
            "読点または句点", "読点か句点", "読点・句点"
        ] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testJapaneseAliasesEmbeddedInNaturalTextRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        for transcript in [
            "改行コード",
            "空白文字",
            "読点の使い方",
            "この改行コード",
            "この空白について読点",
            "句読点",
            "空白について読点"
        ] {
            XCTAssertEqual(
                parser.parse(transcript).elements,
                [.text(transcript)],
                transcript
            )
        }
    }

    func testJapaneseAliasInsideQuotationRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        XCTAssertEqual(
            parser.parse("「読点」について").elements,
            [.text("「読点」について")]
        )
    }

    func testJapaneseCommandAliasInsideMixedProseRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        for transcript in ["読点 多すぎ", "改行 不要", "句点 について"] {
            XCTAssertEqual(parser.parse(transcript).elements, [.text(transcript)], transcript)
        }
    }

    func testParsesJapaneseAliasesForLocaleWithExtension() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja@calendar=japanese"))

        let result = parser.parse("こんにちは 読点 世界")
        XCTAssertEqual(result.elements, [.text("こんにちは 読点 世界")])
    }

    func testParsesJapaneseAliasesForUppercaseUnderscoreLocale() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "JA_jp"))

        let result = parser.parse("こんにちは 読点 世界")
        XCTAssertEqual(result.elements, [.text("こんにちは 読点 世界")])
    }

    func testSingleJapaneseTerminalAliasInsideTextRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは読点 世界")
        XCTAssertEqual(result.elements, [
            .text("こんにちは読点 世界")
        ])
    }

    func testJapaneseUnspacedParsingIgnoresEnglishAliases() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("spacebar")
        XCTAssertEqual(result.elements, [.text("spacebar")])
    }

    func testMalformedJapaneseLikeLocaleDoesNotEnableJapaneseAliases() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "japanese"))

        let result = parser.parse("こんにちは読点世界")
        XCTAssertEqual(result.elements, [.text("こんにちは読点世界")])
    }

    func testNonLocalePrefixesDoNotEnableJapaneseAliases() {
        for identifier in ["javascript", "japanese@calendar=japanese", "ja-", "ja--JP", ""] {
            let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: identifier))

            let result = parser.parse("読点")
            XCTAssertEqual(result.elements, [.text("読点")], identifier)
        }

        let malformedSubtagParser = VoiceCommandParser(
            locale: VoiceKeyboardLocale(identifier: "ja-💣")
        )
        XCTAssertEqual(malformedSubtagParser.parse("読点").elements, [.text("読点")])
    }
}
