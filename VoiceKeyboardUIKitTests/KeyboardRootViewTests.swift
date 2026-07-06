@testable import VoiceKeyboardInput
import VoiceKeyboardModels
import VoiceKeyboardPresentation
import XCTest

@MainActor
final class KeyboardRootViewTests: XCTestCase {
    func testListeningSpeechCaptureKeepsMicrophoneEnabledAsStopButton() throws {
        let view = KeyboardRootView()

        view.render(speechCapture: .keyboardSpeechCapture(.listening))
        let button = try microphoneButton(in: view)

        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.configuration?.title, "Stop")
    }

    func testRecognitionUnavailableDisablesMicrophoneButton() throws {
        let view = KeyboardRootView()

        view.render(speechCapture: .keyboardSpeechCapture(.recognitionFailed(.speechRecognizerUnavailable)))

        XCTAssertFalse(try microphoneButton(in: view).isEnabled)
    }

    func testUnavailableSpeechCaptureDisablesMicrophoneButton() throws {
        let view = KeyboardRootView()

        view.render(speechCapture: .keyboardSpeechCapture(.unavailable(.microphoneCaptureUnavailable)))

        XCTAssertFalse(try microphoneButton(in: view).isEnabled)
    }

    func testProbeNeededSpeechCaptureKeepsMicrophoneButtonEnabled() throws {
        let view = KeyboardRootView()

        view.render(speechCapture: .keyboardSpeechCapture(.probeNeeded))

        XCTAssertTrue(try microphoneButton(in: view).isEnabled)
    }

    func testContainingAppLaunchRequiredKeepsMicrophoneButtonEnabled() throws {
        let view = KeyboardRootView()

        view.render(speechCapture: .keyboardSpeechCapture(.containingAppLaunchRequired))

        XCTAssertTrue(try microphoneButton(in: view).isEnabled)
    }

    func testMicrophoneButtonUsesSpeechCaptureActionTitle() throws {
        let view = KeyboardRootView()

        view.render(speechCapture: .keyboardSpeechCapture(.probeNeeded))
        let button = try microphoneButton(in: view)

        XCTAssertEqual(button.accessibilityLabel, "Check mic")
        XCTAssertEqual(button.configuration?.title, "Check mic")
    }

    func testVoiceInputAccessibilityMergesTranscriptAndActivity() throws {
        let view = KeyboardRootView()
        let snapshot = SpeechCapturePresentationSnapshot(
            transcriptText: "Meeting notes",
            statusText: "Listening.",
            microphoneTitle: "Mic active",
            microphoneTone: .positive,
            activeMicrophoneBars: .ready,
            voiceActivityState: .listening(level: 0.72)
        )

        view.render(speechCapture: snapshot)

        let elements = view.descendants().filter {
            $0.isAccessibilityElement && $0.accessibilityLabel == "Voice input"
        }
        XCTAssertEqual(elements.count, 1)
        let value = try XCTUnwrap(elements.first?.accessibilityValue)
        XCTAssertTrue(value.contains("Meeting notes"))
        XCTAssertTrue(value.contains("Listening"))
    }

    func testNextKeyboardVisibilityUpdatesButtonState() throws {
        let view = KeyboardRootView()

        view.setNextKeyboardVisible(false)

        let button = try nextKeyboardButton(in: view)
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(button.isEnabled)
    }

    func testDeleteButtonTriggersAction() throws {
        let view = KeyboardRootView()
        var didDelete = false
        view.onDelete = { didDelete = true }

        try deleteButton(in: view).sendActions(for: .touchUpInside)

        XCTAssertTrue(didDelete)
    }

    func testReturnButtonTriggersAction() throws {
        let view = KeyboardRootView()
        var didReturn = false
        view.onReturn = { didReturn = true }

        try returnButton(in: view).sendActions(for: .touchUpInside)

        XCTAssertTrue(didReturn)
    }

    private func microphoneButton(in view: UIView) throws -> UIButton {
        try button(in: view, identifier: "keyboard.mic")
    }

    private func nextKeyboardButton(in view: UIView) throws -> UIButton {
        try button(in: view, identifier: "keyboard.next")
    }

    private func deleteButton(in view: UIView) throws -> UIButton {
        try button(in: view, identifier: "keyboard.delete")
    }

    private func returnButton(in view: UIView) throws -> UIButton {
        try button(in: view, identifier: "keyboard.return")
    }

    private func button(in view: UIView, identifier: String) throws -> UIButton {
        let matches = view.descendants().compactMap { $0 as? UIButton }.filter {
            $0.accessibilityIdentifier == identifier
        }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first)
    }
}

private extension UIView {
    func descendants() -> [UIView] {
        subviews + subviews.flatMap { $0.descendants() }
    }
}
