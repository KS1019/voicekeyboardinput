import UIKit
import XCTest
import VoiceKeyboardModels

@MainActor
final class KeyboardSpeechCaptureCoordinatorTests: XCTestCase {
    func testLiveSegmentsStayOrderedAndStopDrainsTailExactlyOnce() async {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        let events = coordinator.recognitionEvents(locale: .init(identifier: "en-US"), hasFullAccess: { true })
        capture.send(.started)
        capture.send(.segment(Self.pcm))
        capture.send(.segment(Self.pcm))
        XCTAssertEqual(speech.starts, 1, "must not cancel an in-flight segment")
        speech.complete("alpha")
        XCTAssertFalse(capture.stopped, "first text is committed while recording continues")
        XCTAssertEqual(speech.starts, 2)
        capture.tail = Self.pcm
        coordinator.finishRecognition()
        speech.complete("bravo")
        XCTAssertEqual(speech.starts, 3, "Stop must retain the final short segment")
        speech.complete("charlie")

        // Delay the consumer deliberately: status events must not evict text.
        var transcripts: [String] = []
        var document = ""
        var finishes = 0
        for await event in events {
            switch event {
            case .transcript(let text):
                transcripts.append(text)
                let (_, actions) = KeyboardSpeechCaptureCoordinator.insertionResult(
                    text, context: document, locale: .init(identifier: "en-US")
                )
                for action in actions {
                    if case .insertText(let text) = action { document += text }
                }
            case .finished: finishes += 1
            default: break
            }
        }
        XCTAssertEqual(transcripts, ["alpha", "bravo", "charlie"])
        XCTAssertEqual(document, "alpha bravo charlie")
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(speech.starts, 3)
    }

    func testControllerKeepsRecordingAfterOwnCallbacksButCancelsExternalEdits() async throws {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        let controller = HostKeyboardController(speechCaptureCoordinator: coordinator)
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        controller.startDirectKeyboardRecognition()
        defer { controller.viewWillDisappear(false) }
        capture.send(.started)
        capture.send(.segment(Self.pcm))
        speech.complete("alpha")
        try await waitForText("alpha", in: controller.proxy)
        controller.textDidChange(nil)
        controller.selectionDidChange(nil)
        XCTAssertFalse(capture.stopped, "own asynchronous callbacks must not stop recording")
        capture.send(.segment(Self.pcm))
        speech.complete("bravo")
        try await waitForText("alpha bravo", in: controller.proxy)
        controller.textDidChange(nil)
        capture.tail = Self.pcm
        coordinator.finishRecognition()
        speech.complete("charlie")
        try await waitForText("alpha bravo charlie", in: controller.proxy)
        XCTAssertEqual(speech.starts, 3)
        await Task.yield()
        let labels = allLabels(in: controller.view).compactMap(\.text)
        XCTAssertTrue(labels.contains(where: { $0.contains("charlie") }))
        XCTAssertFalse(labels.contains(where: { $0.contains("Continue speaking") }))

        // A new recording must still stop on an actual host edit.
        controller.startDirectKeyboardRecognition()
        capture.send(.segment(Self.pcm))
        let lateResult = speech.completion
        controller.proxy.text = "host edited"
        controller.textDidChange(nil)
        lateResult?(.success("stale"))
        await Task.yield()
        XCTAssertTrue(capture.stopped)
        XCTAssertEqual(controller.proxy.text, "host edited")
    }

    func testRecognitionFailurePreservesLaterSegmentsAndStopTail() async {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        let events = coordinator.recognitionEvents(locale: .init(identifier: "en-US"), hasFullAccess: { true })
        capture.send(.segment(Self.pcm))
        capture.send(.segment(Self.pcm))
        capture.tail = Self.pcm
        coordinator.finishRecognition()
        speech.fail()
        speech.complete("second")
        speech.complete("tail")
        var text: [String] = []
        for await event in events {
            if case .transcript(let value) = event { text.append(value) }
        }
        XCTAssertEqual(speech.starts, 3)
        XCTAssertEqual(text, ["second", "tail"])
    }

    func testQuietShortSegmentIsSubmittedToRecognition() {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        _ = coordinator.recognitionEvents(locale: .init(identifier: "en-US"), hasFullAccess: { true })
        var quiet = DictationPCM()
        _ = quiet.append(base64: Data([1, 0]).base64EncodedString())
        capture.send(.segment(quiet))
        XCTAssertEqual(speech.starts, 1)
        coordinator.cancelRecognition()
    }

    func testFatalFailurePreservesRecognizedPendingText() async throws {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        let controller = HostKeyboardController(speechCaptureCoordinator: coordinator)
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        controller.startDirectKeyboardRecognition()
        capture.send(.segment(Self.pcm))
        speech.complete("new line item")
        capture.send(.segment(Self.pcm))
        speech.completion?(.failure(.speechAuthorizationDenied))
        try await waitForText("new line item", in: controller.proxy)
        XCTAssertTrue(capture.stopped)
        controller.viewWillDisappear(false)
    }

    func testRecognitionGapCannotRemoveNegationAndEnableDeletion() async throws {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        let controller = HostKeyboardController(speechCaptureCoordinator: coordinator)
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        controller.startDirectKeyboardRecognition()
        capture.send(.segment(Self.pcm))
        speech.complete("do not")
        capture.send(.segment(Self.pcm))
        speech.fail()
        capture.send(.segment(Self.pcm))
        speech.complete("command delete word")
        coordinator.finishRecognition()
        try await waitForText("do not command delete word", in: controller.proxy)
        controller.viewWillDisappear(false)
    }

    func testCommandMeaningSurvivesAudioBoundaries() async throws {
        for (segments, initial, expected) in [
            (["new line", "item"], "", "new line item"),
            (["command delete", "word"], "alpha bravo", "alpha "),
            (["do not", "command delete", "word"], "", "do not command delete word")
        ] {
            let capture = SegmentCapture()
            let speech = SegmentRecognizer()
            let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
            let controller = HostKeyboardController(speechCaptureCoordinator: coordinator)
            controller.proxy.text = initial
            controller.loadViewIfNeeded()
            controller.viewWillAppear(false)
            controller.startDirectKeyboardRecognition()
            for segment in segments {
                capture.send(.segment(Self.pcm))
                speech.complete(segment)
                try await Task.sleep(for: .milliseconds(10))
            }
            coordinator.finishRecognition()
            try await waitForText(expected, in: controller.proxy)
            controller.viewWillDisappear(false)
        }
    }

    func testDelayedSelfCallbackDoesNotCancelButDifferentContextDoes() async throws {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        let controller = HostKeyboardController(speechCaptureCoordinator: coordinator)
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        controller.startDirectKeyboardRecognition()
        capture.send(.segment(Self.pcm))
        speech.complete("alpha")
        try await waitForText("alpha", in: controller.proxy)
        try await Task.sleep(for: .milliseconds(350))
        controller.textDidChange(nil)
        XCTAssertFalse(capture.stopped)
        controller.proxy.text = "external"
        controller.textDidChange(nil)
        XCTAssertTrue(capture.stopped)
        controller.viewWillDisappear(false)
    }

    private func allLabels(in view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { allLabels(in: $0) }
    }

    func testRecognitionGapDoesNotJoinDestructiveCommandAcrossMissingAudio() async throws {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        let controller = HostKeyboardController(speechCaptureCoordinator: coordinator)
        controller.proxy.text = "keep this"
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        controller.startDirectKeyboardRecognition()
        capture.send(.segment(Self.pcm))
        speech.complete("command delete")
        capture.send(.segment(Self.pcm))
        speech.fail()
        capture.send(.segment(Self.pcm))
        speech.complete("word")
        coordinator.finishRecognition()
        try await waitForText("keep this command delete word", in: controller.proxy)
        controller.viewWillDisappear(false)
    }

    private func waitForText(_ expected: String, in proxy: HostDocumentProxy) async throws {
        for _ in 0..<50 {
            if proxy.text == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(expected), got \(proxy.text)")
    }

    func testCancellationDiscardsQueuedSegmentsAndLateResult() async {
        let capture = SegmentCapture()
        let speech = SegmentRecognizer()
        let coordinator = KeyboardSpeechCaptureCoordinator(capture: capture, speech: speech)
        let events = coordinator.recognitionEvents(locale: .init(identifier: "en-US"), hasFullAccess: { true })
        capture.send(.segment(Self.pcm))
        capture.send(.segment(Self.pcm))
        let lateCompletion = speech.completion
        coordinator.cancelRecognition()
        lateCompletion?(.success("stale"))
        var transcripts = 0
        for await event in events {
            if case .transcript = event { transcripts += 1 }
        }
        XCTAssertEqual(transcripts, 0)
        XCTAssertEqual(speech.starts, 1)
        XCTAssertTrue(capture.stopped)
    }

    private static var pcm: DictationPCM {
        var pcm = DictationPCM()
        _ = pcm.append(base64: Data([0, 32, 0, 32]).base64EncodedString())
        return pcm
    }
}

@MainActor
private final class SegmentCapture: KeyboardAudioCapturing {
    var handle: ((WebKitDictationCapture.Event) -> Void)?
    var tail = DictationPCM()
    var stopped = false
    func preload(in container: UIView) {}
    func start(permitsMicrophone: @escaping () -> Bool, handle: @escaping (WebKitDictationCapture.Event) -> Void) {
        self.handle = handle
        stopped = false
    }
    func send(_ event: WebKitDictationCapture.Event) { handle?(event) }
    func finish() {
        guard !stopped else { return }
        stopped = true
        send(.stopping)
        send(.finished(tail))
    }
    func cancel() { stopped = true; handle = nil }
}

@MainActor
private final class SegmentRecognizer: KeyboardSegmentRecognizing {
    var starts = 0
    var completion: ((Result<String, SpeechRecognitionError>) -> Void)?
    func start(_ pcm: DictationPCM, locale: VoiceKeyboardLocale,
               completion: @escaping (Result<String, SpeechRecognitionError>) -> Void) {
        starts += 1
        self.completion = completion
    }
    func complete(_ text: String) {
        let callback = completion
        completion = nil
        callback?(.success(text))
    }
    func fail() {
        let callback = completion
        completion = nil
        callback?(.failure(.recognitionFailed("No final speech result.")))
    }
    func cancel() { completion = nil }
}

@MainActor
private final class HostKeyboardController: KeyboardViewController {
    let proxy = HostDocumentProxy()
    override var textDocumentProxy: any UITextDocumentProxy { proxy }
    override var hasFullAccess: Bool { true }
}

@MainActor
private final class HostDocumentProxy: NSObject, UITextDocumentProxy {
    var text = ""
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { "" }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    let documentIdentifier = UUID()
    var hasText: Bool { !text.isEmpty }
    func insertText(_ text: String) { self.text += text }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}
