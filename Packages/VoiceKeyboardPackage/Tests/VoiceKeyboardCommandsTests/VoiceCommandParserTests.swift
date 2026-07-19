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

    func testParsesJapaneseAliasesWithoutWhitespace() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは読点世界改行")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界"),
            .command(.insertText("\n"))
        ])
    }

    func testParsesJapaneseAliasesForLocaleWithExtension() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja@calendar=japanese"))

        let result = parser.parse("こんにちは読点世界")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界")
        ])
    }

    func testParsesJapaneseAliasesForUppercaseUnderscoreLocale() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "JA_jp"))

        let result = parser.parse("こんにちは読点世界")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
            .text("世界")
        ])
    }

    func testParsesJapaneseAliasesWithinWhitespaceDelimitedSegments() {
        let parser = VoiceCommandParser(locale: VoiceKeyboardLocale(identifier: "ja-JP"))

        let result = parser.parse("こんにちは読点 世界")
        XCTAssertEqual(result.elements, [
            .text("こんにちは"),
            .command(.insertText("、")),
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
