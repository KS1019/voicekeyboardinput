import UIKit
import WebKit
import VoiceKeyboardModels

@MainActor
protocol KeyboardAudioCapturing: AnyObject {
    func preload(in container: UIView)
    func start(permitsMicrophone: @escaping () -> Bool, handle: @escaping (WebKitDictationCapture.Event) -> Void)
    func finish()
    func cancel()
}

/// Owns one local WebKit document and discards it at the end of each attempt.
@MainActor
final class WebKitDictationCapture: NSObject, WKNavigationDelegate, WKUIDelegate, KeyboardAudioCapturing {
    enum Event {
        case started
        case stopping
        case segment(DictationPCM)
        case finished(DictationPCM)
        case startupFailed
        case failed
    }

    private enum Phase {
        case starting
        case recording
        case draining
    }

    private struct Session {
        let id = UUID()
        let permitsMicrophone: () -> Bool
        let handle: (Event) -> Void
        var phase = Phase.starting
        var startSent = false
        var pcm = DictationPCM()
    }

    private static let pageURL = URL(string: "https://dictation.voicekeyboard.invalid/")!

    private weak var container: UIView?
    private var webView: WKWebView?
    private var initialNavigation: WKNavigation?
    private var pageLoaded = false
    private var session: Session?
    private var deadline: Task<Void, Never>?
    private let recordingStallTimeout: Duration

    init(recordingStallTimeout: Duration = .seconds(3)) {
        self.recordingStallTimeout = recordingStallTimeout
        super.init()
    }

    isolated deinit {
        dispose()
    }

    func preload(in container: UIView) {
        self.container = container
        guard webView == nil,
              let url = Bundle(for: Self.self).url(forResource: "DictationCapture", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(MessageHandler(capture: self), name: "dictation")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        view.alpha = 0.02
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        container.addSubview(view)
        initialNavigation = view.loadHTMLString(html, baseURL: Self.pageURL)
    }

    func start(permitsMicrophone: @escaping () -> Bool, handle: @escaping (Event) -> Void) {
        guard session == nil else { return }
        if let container {
            preload(in: container)
        }
        guard webView != nil, permitsMicrophone() else {
            dispose()
            handle(.startupFailed)
            return
        }
        let session = Session(permitsMicrophone: permitsMicrophone, handle: handle)
        self.session = session
        setDeadline(.seconds(2), id: session.id) { $0.end(.startupFailed) }
        startIfLoaded()
    }

    func finish() {
        guard let session, session.phase != .draining else { return }
        self.session?.phase = .draining
        session.handle(.stopping)
        guard session.startSent, let webView else {
            end(.failed)
            return
        }
        // Script flushes buffered samples before acknowledging that input has
        // stopped. Without its acknowledgement, dispose the view and use the
        // PCM already delivered to native code.
        setDeadline(.seconds(1), id: session.id) { $0.finishDrain() }
        webView.evaluateJavaScript("stopDictation('\(session.id.uuidString)')") { [weak self] _, error in
            guard let self, self.session?.id == session.id, error != nil else { return }
            self.finishDrain()
        }
    }

    func cancel() {
        dispose()
    }

    private func startIfLoaded() {
        guard pageLoaded, let webView, let session,
              session.phase == .starting, !session.startSent else { return }
        guard session.permitsMicrophone() else {
            end(.startupFailed)
            return
        }
        self.session?.startSent = true
        webView.evaluateJavaScript("startDictation('\(session.id.uuidString)'); void 0") { [weak self] _, error in
            guard let self, self.session?.id == session.id, error != nil else { return }
            self.fail()
        }
    }

    private func setDeadline(
        _ delay: Duration,
        id: UUID,
        action: @escaping (WebKitDictationCapture) -> Void
    ) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.session?.id == id else { return }
            action(self)
        }
    }

    private func fail() {
        guard let session else {
            dispose()
            return
        }
        end(session.phase == .starting ? .startupFailed : .failed)
    }

    private func finishDrain() {
        guard let session, session.phase == .draining else { return }
        end(.finished(session.pcm))
    }

    private func end(_ event: Event) {
        let handle = session?.handle
        dispose()
        handle?(event)
    }

    private func dispose() {
        deadline?.cancel()
        deadline = nil
        let captureID = session?.id
        session = nil
        pageLoaded = false
        initialNavigation = nil
        guard let webView else { return }
        self.webView = nil
        if let captureID {
            webView.evaluateJavaScript("cancelDictation('\(captureID.uuidString)')")
        }
        webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dictation")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === self.webView,
              !pageLoaded,
              navigationAction.targetFrame?.isMainFrame == true,
              navigationAction.navigationType == .other,
              navigationAction.request.url == Self.pageURL else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === initialNavigation,
              webView.url == Self.pageURL else { return }
        pageLoaded = true
        startIfLoaded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if webView === self.webView && navigation === initialNavigation { fail() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if webView === self.webView && navigation === initialNavigation { fail() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { fail() }
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        guard webView === self.webView, pageLoaded,
              type == .microphone, isCaptureFrame(frame), Self.isCaptureOrigin(origin),
              let session, session.startSent, session.phase != .draining,
              session.permitsMicrophone() else { return .deny }
        return .grant
    }

    private static func isCaptureOrigin(_ origin: WKSecurityOrigin) -> Bool {
        origin.protocol == "https" && origin.host == pageURL.host
            && (origin.port == 0 || origin.port == 443)
    }

    private func isCaptureFrame(_ frame: WKFrameInfo) -> Bool {
        frame.isMainFrame && frame.request.url == Self.pageURL && Self.isCaptureOrigin(frame.securityOrigin)
    }

    private func receive(_ message: WKScriptMessage) {
        guard message.name == "dictation", message.webView === webView,
              pageLoaded, isCaptureFrame(message.frameInfo),
              let sessionID = session?.id, session?.startSent == true,
              let body = message.body as? [String: Any],
              body["id"] as? String == sessionID.uuidString,
              let type = body["type"] as? String else { return }
        switch type {
        case "pcm":
            guard body.count == 3, let base64 = body["data"] as? String else { return }
            guard session?.permitsMicrophone() == true else {
                end(.failed)
                return
            }
            guard session?.pcm.append(base64: base64) == true else { return }
            if session?.phase == .starting {
                session?.phase = .recording
                session?.handle(.started)
            }
            if session?.phase == .recording {
                setDeadline(recordingStallTimeout, id: sessionID) { $0.end(.failed) }
            }
            if session?.pcm.isFull == true { finish() }
        case "segment" where body.count == 2:
            guard session?.phase == .recording, let pcm = session?.pcm else { return }
            self.session?.pcm = DictationPCM()
            if pcm.sampleCount > 0 { session?.handle(.segment(pcm)) }
        case "stopped" where body.count == 2:
            finishDrain()
        case "failed" where body.count == 2:
            fail()
        default:
            break
        }
    }

    private class MessageHandler: NSObject, WKScriptMessageHandler {
        private weak var capture: WebKitDictationCapture?

        init(capture: WebKitDictationCapture) {
            self.capture = capture
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            capture?.receive(message)
        }
    }
}
