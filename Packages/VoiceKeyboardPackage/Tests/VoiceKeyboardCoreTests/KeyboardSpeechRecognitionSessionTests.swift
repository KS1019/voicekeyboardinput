import VoiceKeyboardCore
import VoiceKeyboardInterfaces
import VoiceKeyboardModels
import XCTest

final class KeyboardSpeechRecognitionSessionTests: XCTestCase {
    func testStartEmitsListeningThenTranscribingThenInsertion() async {
        let service = FakeSpeechRecognitionService(initialUpdates: [
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

        let expectedStates: [KeyboardSpeechCaptureState] = [
            .listening,
            .transcribing(SpeechRecognitionUpdate(transcript: "hello", isFinal: false, inputLevel: 0.4)),
            .inserted("hello world")
        ]
        let expectedActions: [KeyboardTextInsertionAction] = [.insertText("hello world")]
        XCTAssertEqual(events.map(\.state), expectedStates)
        XCTAssertEqual(events.last?.actions, expectedActions)
    }

    func testEndingEventStreamStopsSpeechServiceWhenRecognitionTaskIsStillSuspended() async {
        let service = FakeSpeechRecognitionService(startSuspendsUntilStopped: true)
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collectFirst(
            1,
            from: session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: ""
        )
        )

        let expectedStates: [KeyboardSpeechCaptureState] = [.listening]
        XCTAssertEqual(events.map(\.state), expectedStates)
        let stopWasCalled = await service.waitForStopCall(timeoutNanoseconds: 500_000_000)
        if !stopWasCalled {
            await service.stop()
        }
        XCTAssertTrue(stopWasCalled)
    }

    func testFinalCommandTranscriptDoesNotClaimTextInsertion() async {
        let finalUpdate = SpeechRecognitionUpdate(transcript: "delete word", isFinal: true)
        let service = FakeSpeechRecognitionService(initialUpdates: [finalUpdate])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: "hello world"
        ))

        let expectedStates: [KeyboardSpeechCaptureState] = [
            .listening,
            .transcribing(finalUpdate)
        ]
        let expectedActions: [KeyboardTextInsertionAction] = [.deleteBackward(count: TextDeletionCount(5)!)]
        XCTAssertEqual(events.map(\.state), expectedStates)
        XCTAssertEqual(events.last?.actions, expectedActions)
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

        let expectedStates: [KeyboardSpeechCaptureState] = [
            .listening,
            .recognitionFailed(.microphonePermissionDenied)
        ]
        XCTAssertEqual(events.map(\.state), expectedStates)
        XCTAssertEqual(events.last?.actions, [])
    }
}

private struct FakeSpeechRecognitionService: SpeechRecognitionService {
    private let controller: FakeSpeechRecognitionServiceController
    var startError: SpeechRecognitionError?

    init(
        initialUpdates: [SpeechRecognitionUpdate] = [],
        keepsStreamOpen: Bool = false,
        startSuspendsUntilStopped: Bool = false,
        startError: SpeechRecognitionError? = nil
    ) {
        self.controller = FakeSpeechRecognitionServiceController(
            initialUpdates: initialUpdates,
            keepsStreamOpen: keepsStreamOpen,
            startSuspendsUntilStopped: startSuspendsUntilStopped
        )
        self.startError = startError
    }

    func start(locale: VoiceKeyboardLocale) async throws(SpeechRecognitionError) -> SpeechRecognitionUpdateStream {
        if let startError { throw startError }
        return await controller.makeStream()
    }

    func stop() async {
        await controller.stop()
    }

    func waitForStopCall(timeoutNanoseconds: UInt64) async -> Bool {
        await controller.waitForStopCall(timeoutNanoseconds: timeoutNanoseconds)
    }
}

private actor FakeSpeechRecognitionServiceController {
    private let initialUpdates: [SpeechRecognitionUpdate]
    private let keepsStreamOpen: Bool
    private let startSuspendsUntilStopped: Bool
    private var continuation: SpeechRecognitionUpdateStream.Continuation?
    private var stopCallCount = 0

    init(
        initialUpdates: [SpeechRecognitionUpdate],
        keepsStreamOpen: Bool,
        startSuspendsUntilStopped: Bool
    ) {
        self.initialUpdates = initialUpdates
        self.keepsStreamOpen = keepsStreamOpen
        self.startSuspendsUntilStopped = startSuspendsUntilStopped
    }

    func makeStream() async -> SpeechRecognitionUpdateStream {
        if startSuspendsUntilStopped {
            while stopCallCount == 0 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return SpeechRecognitionUpdateStream { continuation in
                continuation.finish()
            }
        }

        return SpeechRecognitionUpdateStream { continuation in
            self.continuation = continuation
            for update in self.initialUpdates {
                continuation.yield(update)
            }
            if !self.keepsStreamOpen {
                continuation.finish()
                self.continuation = nil
            }
        }
    }

    func stop() {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }

    func waitForStopCall(timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if stopCallCount > 0 {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return stopCallCount > 0
    }
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

private func collectFirst(
    _ count: Int,
    from stream: AsyncStream<KeyboardSpeechRecognitionEvent>
) async -> [KeyboardSpeechRecognitionEvent] {
    var events: [KeyboardSpeechRecognitionEvent] = []
    for await event in stream {
        events.append(event)
        if events.count == count {
            break
        }
    }
    return events
}
