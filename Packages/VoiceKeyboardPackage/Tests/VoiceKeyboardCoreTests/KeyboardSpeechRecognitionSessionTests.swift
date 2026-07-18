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
        XCTAssertTrue(stopWasCalled)
        await service.releaseStop()
        let stopCompleted = await service.waitForStopCompletion(timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(stopCompleted)
    }

    func testCancellationAndStreamTerminationJoinOneAwaitedStop() async {
        let service = FakeSpeechRecognitionService(startSuspendsUntilStopped: true)
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let consumer = Task {
            await collectFirst(1, from: session.events(
                locale: VoiceKeyboardLocale(identifier: "en-US"),
                documentContextBeforeInput: ""
            ))
        }

        _ = await consumer.value
        let stopStarted = await service.waitForStopStarted(timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(stopStarted)
        let firstStopCallCount = await service.serviceStopCallCount()
        XCTAssertEqual(firstStopCallCount, 1)
        let completedBeforeRelease = await service.waitForStopCompletion(timeoutNanoseconds: 50_000_000)
        XCTAssertFalse(completedBeforeRelease)

        await service.releaseStop()
        let stopCompleted = await service.waitForStopCompletion(timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(stopCompleted)
        let finalStopCallCount = await service.serviceStopCallCount()
        XCTAssertEqual(finalStopCallCount, 1)
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

    func serviceStopCallCount() async -> Int {
        await controller.currentStopCallCount()
    }

    func waitForStopStarted(timeoutNanoseconds: UInt64) async -> Bool {
        await controller.waitForStopStarted(timeoutNanoseconds: timeoutNanoseconds)
    }

    func releaseStop() async {
        await controller.releaseStop()
    }

    func waitForStopCompletion(timeoutNanoseconds: UInt64) async -> Bool {
        await controller.waitForStopCompletion(timeoutNanoseconds: timeoutNanoseconds)
    }
}

private actor FakeSpeechRecognitionServiceController {
    private let initialUpdates: [SpeechRecognitionUpdate]
    private let keepsStreamOpen: Bool
    private let startSuspendsUntilStopped: Bool
    private var continuation: SpeechRecognitionUpdateStream.Continuation?
    private var stopCallCount = 0
    private var stopStarted = false
    private var stopCompleted = false
    private var releaseStopContinuation: CheckedContinuation<Void, Never>?

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

    func stop() async {
        stopCallCount += 1
        stopStarted = true
        continuation?.finish()
        continuation = nil
        guard startSuspendsUntilStopped else {
            stopCompleted = true
            return
        }
        await withCheckedContinuation { continuation in
            if stopCompleted {
                continuation.resume()
            } else {
                releaseStopContinuation = continuation
            }
        }
        stopCompleted = true
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

    func currentStopCallCount() -> Int {
        stopCallCount
    }

    func waitForStopStarted(timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if stopStarted {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return stopStarted
    }

    func releaseStop() {
        releaseStopContinuation?.resume()
        releaseStopContinuation = nil
    }

    func waitForStopCompletion(timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if stopCompleted {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return stopCompleted
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
