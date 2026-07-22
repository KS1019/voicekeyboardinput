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

    func testFinalSpeechAnalyzerSegmentsUseTheUpdatedVirtualContext() async {
        let service = FakeSpeechRecognitionService(initialUpdates: [
            SpeechRecognitionUpdate(transcript: "hello", isFinal: true),
            SpeechRecognitionUpdate(transcript: "world", isFinal: true)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: ""
        ))

        XCTAssertEqual(events.dropFirst().map(\.actions), [
            [.insertText("hello")],
            [.insertText(" world")]
        ])
    }

    func testFinalCommandSegmentsUpdateTheVirtualContext() async {
        let service = FakeSpeechRecognitionService(initialUpdates: [
            SpeechRecognitionUpdate(transcript: "hello", isFinal: true),
            SpeechRecognitionUpdate(transcript: "delete word", isFinal: true),
            SpeechRecognitionUpdate(transcript: "world", isFinal: true)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: ""
        ))

        XCTAssertEqual(events.dropFirst().map(\.actions), [
            [.insertText("hello")],
            [.deleteBackward(count: TextDeletionCount(5)!)],
            [.insertText("world")]
        ])
    }

    func testSplitFinalSegmentsAreRecombinedForMultiWordCommands() async {
        let service = FakeSpeechRecognitionService(initialUpdates: [
            SpeechRecognitionUpdate(transcript: "hello", isFinal: true),
            SpeechRecognitionUpdate(transcript: "delete", isFinal: true),
            SpeechRecognitionUpdate(transcript: "word", isFinal: true)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: "hello world"
        ))

        XCTAssertEqual(events.dropFirst().map(\.actions), [
            [.insertText(" hello")],
            [],
            [.deleteBackward(count: TextDeletionCount(5)!)]
        ])
    }

    func testEventsUseRequestedLocaleForCommandParsing() async {
        let service = FakeSpeechRecognitionService(initialUpdates: [
            SpeechRecognitionUpdate(transcript: "こんにちは 読点 世界", isFinal: true)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "ja-JP"),
            documentContextBeforeInput: ""
        ))

        XCTAssertEqual(events.last?.actions, [.insertText("こんにちは、世界")])
    }

    func testPendingFinalLiteralIsInsertedBeforeRecognitionStreamFailure() async {
        let streamError = SpeechRecognitionError.recognitionFailed("stream failed")
        let service = FakeSpeechRecognitionService(
            initialUpdates: [
                SpeechRecognitionUpdate(transcript: "hello new", isFinal: true)
            ],
            streamError: streamError
        )
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: ""
        ))

        XCTAssertEqual(events.map(\.actions), [
            [],
            [],
            [.insertText("hello new")],
            []
        ])
        XCTAssertEqual(events.suffix(2).map(\.state), [
            .inserted("hello new"),
            .recognitionFailed(streamError)
        ])
    }

    func testSlowConsumerDropsPartialUpdatesButRetainsFinalActions() async {
        let partialUpdates = (0..<100).map {
            SpeechRecognitionUpdate(transcript: "partial \($0)", isFinal: false)
        }
        let service = FakeSpeechRecognitionService(initialUpdates: partialUpdates + [
            SpeechRecognitionUpdate(transcript: "final text", isFinal: true)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )
        let stream = session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: ""
        )

        try? await Task.sleep(nanoseconds: 50_000_000)
        let events = await collect(stream)

        let deliveredPartialCount = events.filter { event in
            guard case let .transcribing(update) = event.state else { return false }
            return !update.isFinal
        }.count
        XCTAssertLessThan(deliveredPartialCount, partialUpdates.count)
        XCTAssertEqual(events.last?.actions, [.insertText("final text")])
        XCTAssertEqual(events.last?.state, .inserted("final text"))
    }

    func testJapaneseFinalSegmentsDoNotGainAsciiSeparators() async {
        let service = FakeSpeechRecognitionService(initialUpdates: [
            SpeechRecognitionUpdate(transcript: "こんにちは", isFinal: true),
            SpeechRecognitionUpdate(transcript: "世界", isFinal: true)
        ])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "ja-JP"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "ja-JP"),
            documentContextBeforeInput: ""
        ))

        XCTAssertEqual(events.dropFirst().map(\.actions), [
            [.insertText("こんにちは")],
            [.insertText("世界")]
        ])
    }

    func testUnsupportedCommandRemainsVisibleAsAnActionAndState() async {
        let finalUpdate = SpeechRecognitionUpdate(transcript: "command copy", isFinal: true)
        let service = FakeSpeechRecognitionService(initialUpdates: [finalUpdate])
        let session = KeyboardSpeechRecognitionSession(
            speechService: service,
            pipeline: VoiceInputPipeline(locale: VoiceKeyboardLocale(identifier: "en-US"))
        )

        let events = await collect(session.events(
            locale: VoiceKeyboardLocale(identifier: "en-US"),
            documentContextBeforeInput: nil
        ))

        XCTAssertEqual(events.last?.state, .unsupportedCommand("command copy"))
        XCTAssertEqual(events.last?.actions, [.showUnsupportedCommand("command copy")])
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
        streamError: SpeechRecognitionError? = nil,
        startError: SpeechRecognitionError? = nil
    ) {
        self.controller = FakeSpeechRecognitionServiceController(
            initialUpdates: initialUpdates,
            keepsStreamOpen: keepsStreamOpen,
            startSuspendsUntilStopped: startSuspendsUntilStopped,
            streamError: streamError
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
    private let streamError: SpeechRecognitionError?
    private var continuation: SpeechRecognitionUpdateStream.Continuation?
    private var stopCallCount = 0
    private var stopStarted = false
    private var stopCompleted = false
    private var releaseStopContinuation: CheckedContinuation<Void, Never>?

    init(
        initialUpdates: [SpeechRecognitionUpdate],
        keepsStreamOpen: Bool,
        startSuspendsUntilStopped: Bool,
        streamError: SpeechRecognitionError?
    ) {
        self.initialUpdates = initialUpdates
        self.keepsStreamOpen = keepsStreamOpen
        self.startSuspendsUntilStopped = startSuspendsUntilStopped
        self.streamError = streamError
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
                continuation.finish(throwing: self.streamError)
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
