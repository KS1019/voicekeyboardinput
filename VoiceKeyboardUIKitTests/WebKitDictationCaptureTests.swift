import UIKit
import WebKit
import XCTest

@MainActor
final class WebKitDictationCaptureTests: XCTestCase {
    private var window: UIWindow!
    private var container: UIView!
    private var capture: WebKitDictationCapture!

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        container = controller.view
        capture = WebKitDictationCapture()
    }

    override func tearDown() {
        capture.cancel()
        capture = nil
        window.isHidden = true
        window = nil
        container = nil
        super.tearDown()
    }

    func testLocalPageAcceptsPCMAndDrainsBeforeCompletion() async throws {
        let webView = try await loadPage()
        try await installMicrophone(in: webView, producesPCM: true)
        let started = expectation(description: "first PCM accepted from local main frame")
        let finished = expectation(description: "drained recording")
        var sampleCount = 0
        capture.start(permitsMicrophone: { true }) { event in
            switch event {
            case .started:
                started.fulfill()
            case .finished(let pcm):
                sampleCount = pcm.sampleCount
                finished.fulfill()
            case .failed, .startupFailed:
                XCTFail("The local WebKit page should deliver real PCM messages")
            case .stopping, .segment:
                break
            }
        }
        await fulfillment(of: [started], timeout: 5)
        capture.finish()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(sampleCount, 1600)
        XCTAssertTrue(container.subviews.compactMap { $0 as? WKWebView }.isEmpty)
    }

    func testTwoLiveSegmentsAndStopDrainDoNotReplayAudio() async throws {
        let webView = try await loadPage()
        try await installMicrophone(in: webView, producesPCM: true)
        let started = expectation(description: "recording")
        let segments = expectation(description: "two live segments")
        segments.expectedFulfillmentCount = 2
        let stopped = expectation(description: "tail drained")
        var counts: [Int] = []
        capture.start(permitsMicrophone: { true }) { event in
            switch event {
            case .started: started.fulfill()
            case .segment(let pcm):
                counts.append(pcm.sampleCount)
                segments.fulfill()
            case .finished(let pcm):
                counts.append(pcm.sampleCount)
                stopped.fulfill()
            case .failed, .startupFailed: XCTFail("Capture failed")
            case .stopping: break
            }
        }
        await fulfillment(of: [started], timeout: 5)
        // First 1600 samples came from resume(). Supply two speech/pause
        // boundaries through the real audio callback, followed by a short tail.
        _ = try await webView.evaluateJavaScript("""
        function feed(n, value) {
            window.testProcessor.onaudioprocess({
                inputBuffer: { getChannelData: () => new Float32Array(n).fill(value) },
                outputBuffer: { getChannelData: () => new Float32Array(n) }
            });
        }
        feed(11200, 0); feed(1600, 0.25); feed(11200, 0); feed(321, 0.5);
        void 0;
        """)
        await fulfillment(of: [segments], timeout: 5)
        XCTAssertEqual(counts, [12800, 12800])
        XCTAssertFalse(container.subviews.compactMap { $0 as? WKWebView }.isEmpty)
        capture.finish()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(counts, [12800, 12800, 321])
    }

    func testOngoingPCMRefreshesWatchdogUntilExplicitStop() async throws {
        capture = WebKitDictationCapture(recordingStallTimeout: .milliseconds(500))
        let webView = try await loadPage()
        try await installMicrophone(in: webView, producesPCM: true)
        let started = expectation(description: "capture started")
        let finished = expectation(description: "explicit Stop")
        var didFinish = false
        capture.start(permitsMicrophone: { true }) { event in
            switch event {
            case .started: started.fulfill()
            case .finished:
                didFinish = true
                finished.fulfill()
            case .failed, .startupFailed: XCTFail("Ongoing PCM must keep capture alive")
            case .stopping, .segment: break
            }
        }
        await fulfillment(of: [started], timeout: 5)
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(150))
            _ = try await webView.evaluateJavaScript("""
            window.testProcessor.onaudioprocess({
                inputBuffer: { getChannelData: () => new Float32Array(1600).fill(0.25) },
                outputBuffer: { getChannelData: () => new Float32Array(1600) }
            }); void 0;
            """)
        }
        XCTAssertFalse(didFinish)
        capture.finish()
        await fulfillment(of: [finished], timeout: 3)
    }

    func testMissingPCMAfterStartupFailsInsteadOfReportingSuccessfulStop() async throws {
        capture = WebKitDictationCapture(recordingStallTimeout: .milliseconds(200))
        let webView = try await loadPage()
        try await installMicrophone(in: webView, producesPCM: true)
        let failed = expectation(description: "capture stalled")
        capture.start(permitsMicrophone: { true }) { event in
            switch event {
            case .failed: failed.fulfill()
            case .finished, .startupFailed: XCTFail("Stalled capture is a failure after startup")
            default: break
            }
        }
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(container.subviews.compactMap { $0 as? WKWebView }.isEmpty)
    }

    func testQuietPCMReachesNativeSegmentDelivery() async throws {
        let webView = try await loadPage()
        let script = Self.fakeMicrophone
            .replacingOccurrences(of: "new Float32Array(1600)", with: "new Float32Array(128000)")
            .replacingOccurrences(of: "fill(0.25)", with: "fill(1 / 32768)")
        _ = try await webView.evaluateJavaScript(script + "; void 0")
        let delivered = expectation(description: "quiet segment reaches native delivery")
        capture.start(permitsMicrophone: { true }) { event in
            if case .segment(let pcm) = event {
                XCTAssertEqual(pcm.sampleCount, 128000)
                XCTAssertGreaterThan(pcm.normalizedSamples()[0], 0)
                delivered.fulfill()
            }
        }
        await fulfillment(of: [delivered], timeout: 5)
        capture.cancel()
    }

    func testNoPCMTriggersStartupFallbackAndDisposesPage() async throws {
        let webView = try await loadPage()
        try await installMicrophone(in: webView, producesPCM: false)
        let failed = expectation(description: "startup deadline")
        let start = ContinuousClock.now
        capture.start(permitsMicrophone: { true }) { event in
            if case .startupFailed = event {
                failed.fulfill()
            } else {
                XCTFail("A pending permission request cannot report capture started")
            }
        }
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(1900))
        XCTAssertTrue(container.subviews.compactMap { $0 as? WKWebView }.isEmpty)
    }

    func testCancelPendingCaptureDoesNotProduceFallbackOrTranscript() async throws {
        let webView = try await loadPage()
        try await installMicrophone(in: webView, producesPCM: false)
        let event = expectation(description: "cancelled attempt must be silent")
        event.isInverted = true
        capture.start(permitsMicrophone: { true }) { _ in event.fulfill() }
        capture.cancel()
        await fulfillment(of: [event], timeout: 2.2)
        XCTAssertTrue(container.subviews.compactMap { $0 as? WKWebView }.isEmpty)
    }

    func testPermissionGateRejectsBeforeStartingPageCapture() async throws {
        _ = try await loadPage()
        let failed = expectation(description: "permission unavailable")
        capture.start(permitsMicrophone: { false }) { event in
            if case .startupFailed = event { failed.fulfill() }
            else { XCTFail("Missing permission must not start recording") }
        }
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(container.subviews.compactMap { $0 as? WKWebView }.isEmpty)
    }

    private func loadPage() async throws -> WKWebView {
        capture.preload(in: container)
        let webView = try XCTUnwrap(container.subviews.compactMap { $0 as? WKWebView }.first)
        for _ in 0..<100 {
            if !webView.isLoading,
               let ready = try? await webView.evaluateJavaScript("typeof startDictation === 'function'"),
               ready as? Bool == true {
                XCTAssertEqual(webView.url?.host, "dictation.voicekeyboard.invalid")
                return webView
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Inline capture page did not load")
        return webView
    }

    private func installMicrophone(in webView: WKWebView, producesPCM: Bool) async throws {
        let script = producesPCM ? Self.fakeMicrophone : """
        Object.defineProperty(navigator, 'mediaDevices', { configurable: true,
            value: { getUserMedia: () => new Promise(() => {}) } });
        """
        _ = try await webView.evaluateJavaScript(script + "; void 0")
    }

    private static let fakeMicrophone = """
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true,
        value: { getUserMedia: async () => {
            const track = { stop() {} };
            return { getTracks: () => [track], getAudioTracks: () => [track] };
        } }
    });
    window.AudioContext = class {
        constructor() { this.sampleRate = 16000; this.destination = {}; }
        createMediaStreamSource() { return { connect() {}, disconnect() {} }; }
        createScriptProcessor() {
            this.processor = { connect() {}, disconnect() {} };
            window.testProcessor = this.processor;
            return this.processor;
        }
        resume() {
            this.processor.onaudioprocess({
                inputBuffer: { getChannelData: () => new Float32Array(1600).fill(0.25) },
                outputBuffer: { getChannelData: () => new Float32Array(1600) }
            });
            return Promise.resolve();
        }
        close() { return Promise.resolve(); }
    };
    """
}
