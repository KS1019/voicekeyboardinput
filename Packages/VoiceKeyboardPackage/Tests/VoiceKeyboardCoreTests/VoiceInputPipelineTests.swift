import VoiceKeyboardCore
import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import XCTest

final class VoiceInputPipelineTests: XCTestCase {
    private let deleteWordCount = TextDeletionCount(5)!

    func testPipelinePlansOperations() {
        let pipeline = VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let operations = pipeline.operations(
            for: "hello comma world",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(operations, [
            .insertText("hello"),
            .insertText(","),
            .insertText(" world")
        ])
    }

    func testPipelineCleansInsertedText() async throws {
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            cleanupService: CapitalizingTextCleanupService()
        )

        let result = try await pipeline.prepareInsertedText(
            for: "hello world",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(result, .insertableText("Hello world", cleanupApplied: true))
    }

    func testPipelinePreservesContextSpacingAroundCleanedText() async throws {
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            cleanupService: CapitalizingTextCleanupService()
        )

        let result = try await pipeline.prepareInsertedText(
            for: "world",
            documentContextBeforeInput: "hello"
        )

        XCTAssertEqual(result, .insertableText(" World", cleanupApplied: true))
    }

    func testPipelineDoesNotDuplicateBoundaryWhitespacePreservedByCleanup() async throws {
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            cleanupService: IdentityTextCleanupService()
        )

        let result = try await pipeline.prepareInsertedText(
            for: "world space",
            documentContextBeforeInput: "hello"
        )

        XCTAssertEqual(result, .insertableText(" world ", cleanupApplied: true))
    }

    func testPipelineSendsPlannedTextAndLocaleToCleanupService() async throws {
        let cleanupService = CapturingTextCleanupService()
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "ja-JP"),
            cleanupService: cleanupService
        )

        let result = try await pipeline.prepareInsertedText(
            for: "hello comma world",
            documentContextBeforeInput: "prefix"
        )
        let captured = await cleanupService.capturedCall()

        XCTAssertEqual(captured?.text, " hello, world")
        XCTAssertEqual(captured?.locale, VoiceKeyboardLocale(identifier: "ja-JP"))
        XCTAssertEqual(result, .insertableText(" hello, world", cleanupApplied: true))
    }

    func testPipelineCleansCommandPunctuationWithoutExtraSpaces() async throws {
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            cleanupService: CapitalizingTextCleanupService()
        )

        let result = try await pipeline.prepareInsertedText(
            for: "hello comma world",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(result, .insertableText("Hello, world", cleanupApplied: true))
    }

    func testPipelinePreservesWhitespaceOnlyCommandsWithCleanup() async throws {
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            cleanupService: CapitalizingTextCleanupService()
        )

        let space = try await pipeline.prepareInsertedText(
            for: "space",
            documentContextBeforeInput: ""
        )
        let tab = try await pipeline.prepareInsertedText(
            for: "tab",
            documentContextBeforeInput: ""
        )
        let newline = try await pipeline.prepareInsertedText(
            for: "newline",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(space, .insertableText(" ", cleanupApplied: true))
        XCTAssertEqual(tab, .insertableText("\t", cleanupApplied: true))
        XCTAssertEqual(newline, .insertableText("\n", cleanupApplied: true))
    }

    func testPipelineRequiresCleanupServiceForInsertableTextPreparation() async throws {
        let pipeline = VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))

        do {
            _ = try await pipeline.prepareInsertedText(
                for: "hello comma world",
                documentContextBeforeInput: ""
            )
            XCTFail("Expected cleanup service requirement error")
        } catch {
            XCTAssertEqual(error as? VoiceInputPipelineError, .textCleanupServiceRequired)
        }
    }

    func testPipelineReturnsEditingOperationsForUnsupportedCommand() async throws {
        let pipeline = VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))

        let result = try await pipeline.prepareInsertedText(
            for: "command copy hello",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(result, .editingOperations([
            .showUnsupportedCommand("command copy"),
            .insertText("hello")
        ]))
    }

    func testPipelinePropagatesCleanupError() async {
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            cleanupService: FailingTextCleanupService()
        )

        do {
            _ = try await pipeline.prepareInsertedText(
                for: "hello world",
                documentContextBeforeInput: ""
            )
            XCTFail("Expected cleanup error")
        } catch {
            XCTAssertEqual(error as? CleanupTestError, .failed)
        }
    }

    func testPipelineDoesNotInvokeCleanupForEditingOperations() async throws {
        let cleanupService = SpyTextCleanupService()
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            cleanupService: cleanupService
        )

        let result = try await pipeline.prepareInsertedText(
            for: "hello delete word",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(result, .editingOperations([
            .insertText("hello"),
            .deleteBackward(count: deleteWordCount)
        ]))
        let callCount = await cleanupService.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testPipelineRequiresCleanupServiceForEmptyInsertableTextPreparation() async throws {
        let pipeline = VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))

        do {
            _ = try await pipeline.prepareInsertedText(
                for: "",
                documentContextBeforeInput: ""
            )
            XCTFail("Expected cleanup service requirement error")
        } catch {
            XCTAssertEqual(error as? VoiceInputPipelineError, .textCleanupServiceRequired)
        }
    }

    func testPipelineReturnsCleanedEmptyTextWithCleanupService() async throws {
        let pipeline = VoiceInputPipeline(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            cleanupService: CapitalizingTextCleanupService()
        )

        let result = try await pipeline.prepareInsertedText(
            for: "",
            documentContextBeforeInput: ""
        )

        XCTAssertEqual(result, .insertableText("", cleanupApplied: true))
    }
}

private enum CleanupTestError: Error {
    case failed
}

private struct CapitalizingTextCleanupService: TextCleanupService {
    func cleanedText(from text: String, locale: VoiceKeyboardLocale) async throws -> String {
        let trimmed = text.trimmingWhitespace()
        guard let first = trimmed.first else { return "" }

        return String(first).uppercased() + trimmed.dropFirst()
    }
}

private struct FailingTextCleanupService: TextCleanupService {
    func cleanedText(from text: String, locale: VoiceKeyboardLocale) async throws -> String {
        throw CleanupTestError.failed
    }
}

private struct IdentityTextCleanupService: TextCleanupService {
    func cleanedText(from text: String, locale: VoiceKeyboardLocale) async throws -> String {
        text
    }
}

private actor CapturingTextCleanupService: TextCleanupService {
    private var captured: (text: String, locale: VoiceKeyboardLocale)?

    func capturedCall() -> (text: String, locale: VoiceKeyboardLocale)? {
        captured
    }

    func cleanedText(from text: String, locale: VoiceKeyboardLocale) async throws -> String {
        captured = (text, locale)
        return text
    }
}

private actor SpyTextCleanupService: TextCleanupService {
    private var calls = 0

    func callCount() -> Int {
        calls
    }

    func cleanedText(from text: String, locale: VoiceKeyboardLocale) async throws -> String {
        calls += 1
        return text
    }
}

private extension String {
    func trimmingWhitespace() -> String {
        let withoutLeading = drop(while: \.isWhitespace)
        let withoutTrailing = withoutLeading.reversed().drop(while: \.isWhitespace).reversed()
        return String(withoutTrailing)
    }
}
