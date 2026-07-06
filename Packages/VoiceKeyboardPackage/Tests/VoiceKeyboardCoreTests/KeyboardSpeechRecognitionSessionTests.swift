import VoiceKeyboardCore
import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import XCTest

final class KeyboardSpeechRecognitionSessionTests: XCTestCase {
    func testStartEmitsListeningThenTranscribingThenInsertion() async {
        let service = FakeSpeechRecognitionService(updates: [
            SpeechRecognitionUpdate(transcript: "hello", isFinal: false, inputLevel: 0.4),
            SpeechRecognitionUpdate(transcript: "hello world", isFinal: true, inputLevel: 0.8)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: ""
        ))

        XCTAssertEqual(events.map(\.state), [
            .listening,
            .transcribing(SpeechRecognitionUpdate(transcript: "hello", isFinal: false, inputLevel: 0.4)),
            .inserted("hello world")
        ])
        XCTAssertEqual(events.last?.actions, [.insertText("hello world")])
    }

    func testFinalCommandTranscriptProducesDeleteAction() async {
        let service = FakeSpeechRecognitionService(updates: [
            SpeechRecognitionUpdate(transcript: "delete word", isFinal: true)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: "hello world"
        ))

        XCTAssertEqual(events.last?.actions, [.deleteBackward(count: TextDeletionCount(5)!)])
    }

    func testStartFailureEmitsRecognitionFailed() async {
        let service = FakeSpeechRecognitionService(startError: .microphonePermissionDenied)
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: nil
        ))

        XCTAssertEqual(events.map(\.state), [.listening, .recognitionFailed(.microphonePermissionDenied)])
        XCTAssertEqual(events.last?.actions, [])
    }
}

private struct FakeSpeechRecognitionService: SpeechRecognitionService {
    var updates: [SpeechRecognitionUpdate] = []
    var startError: SpeechRecognitionError?

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        if let startError { throw startError }
        return SpeechRecognitionUpdateStream { continuation in
            for update in updates {
                continuation.yield(update)
            }
            continuation.finish()
        }
    }

    func stop() async {}
}

private func collect(
    _ stream: AsyncStream<KeyboardSpeechRecognitionEvent>
) async -> [KeyboardSpeechRecognitionEvent] {
    var events: [KeyboardSpeechRecognitionEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}
