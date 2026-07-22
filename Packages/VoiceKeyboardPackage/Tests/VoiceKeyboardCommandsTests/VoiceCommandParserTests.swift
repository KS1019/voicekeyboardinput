import VoiceKeyboardCommands
import VoiceKeyboardModels
import XCTest

final class VoiceCommandParserTests: XCTestCase {
    func testParsesPunctuationAndNewline() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let result = parser.parse("hello comma world newline next line")

        XCTAssertEqual(result.elements, [
            .text("hello"),
            .command(.insertText(",")),
            .text("world"),
            .command(.insertText("\n")),
            .text("next"),
            .text("line")
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

        let result = parser.parse("delete word delete sentence")
        XCTAssertEqual(result.elements, [
            .command(.deleteWord),
            .command(.deleteSentence)
        ])
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
            .text("comma,"),
            .text("quote,"),
            .text("newline.")
        ])
    }

    func testParsesJapaneseNewlineAndPunctuationAliases() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは 読点 世界 改行")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界"),
            .command(.insertText("\n"))
        ])
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

    func testParsesJapaneseUnspacedCommandSequenceWithTerminalCommand() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは読点世界改行")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界"),
            .command(.insertText("\n"))
        ])
    }

    func testJapaneseAliasesEmbeddedInNaturalTextRemainLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        for transcript in ["改行コード", "空白文字", "読点の使い方", "この改行コード", "句読点"] {
            XCTAssertEqual(
                parser.parse(transcript).elements,
                [.text(transcript)],
                transcript
            )
        }
    }

    func testParsesJapaneseAliasesForLocaleWithExtension() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja@calendar=japanese"))

        let result = parser.parse("こんにちは 読点 世界")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界")
        ])
    }

    func testParsesJapaneseAliasesForUppercaseUnderscoreLocale() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "JA_jp"))

        let result = parser.parse("こんにちは 読点 世界")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界")
        ])
    }

    func testSingleJapaneseTerminalAliasInsideTextRemainsLiteral() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは読点 世界")
        XCTAssertEqual(result.elements, [
            .text("こんにちは読点"),
            .text("世界")
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
        for identifier in ["javascript", "japanese@calendar=japanese", ""] {
            let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: identifier))

            let result = parser.parse("こんにちは読点世界")
            XCTAssertEqual(result.elements, [.text("こんにちは読点世界")], identifier)
        }
    }
}
