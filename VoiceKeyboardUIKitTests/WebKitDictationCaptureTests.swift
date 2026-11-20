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
            case .stopping:
                break
            }
        }
        await fulfillment(of: [started], timeout: 5)
        capture.finish()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(sampleCount, 1600)
        XCTAssertTrue(container.subviews.compactMap { $0 as? WKWebView }.isEmpty)
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
