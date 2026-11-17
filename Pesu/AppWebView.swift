import SwiftUI
import WebKit
import SafariServices
import AVFoundation

/// The live Pesu web app in a WKWebView, set up to behave like a native iPhone app:
/// edge swipe to go back, inline media, sound without a tap first, haptics from the page,
/// JavaScript alerts as iOS alerts, and outside links in Safari's in-app viewer.
/// Generated from the Kolam iOS shell template (kolam-design-system/ios/shell-template).
struct AppWebView: UIViewRepresentable {
    static let home: URL = {
        #if DEBUG
        // Debug builds only: `simctl launch <device> <bundle> -KolamStartURL "<url>"` opens another route (for screenshots).
        if let s = UserDefaults.standard.string(forKey: "KolamStartURL"), let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://pesu-phrases.vercel.app/")!
    }()
    /// Hosts that stay inside the app; every other http(s) link opens in Safari's viewer.
    static let appHosts: Set<String> = ["pesu-phrases.vercel.app"]

    let url: URL
    @Binding var loading: Bool
    @Binding var failed: Bool
    let reloadToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // "Pesu-iOS" + "Kolam-iOS" let the page's kolam-ios.js turn on the iOS look.
        config.applicationNameForUserAgent = "Pesu-iOS/1.0 Kolam-iOS/1.0 Mobile/15E148"
        config.userContentController.add(context.coordinator, name: "haptic")
        config.userContentController.add(context.coordinator, name: "tts")   // Pesu's read-aloud → AVSpeechSynthesizer
        config.userContentController.addUserScript(WKUserScript(source: Self.shellScript(),
                                                                injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true      // swipe from the left edge to go back
        web.allowsLinkPreview = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(named: "LaunchBackground")
        #if DEBUG
        web.isInspectable = true                             // Safari ▸ Develop, for debugging
        #endif
        web.load(URLRequest(url: url))
        context.coordinator.lastToken = reloadToken
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {    // "Try Again" after being offline
            context.coordinator.lastToken = reloadToken
            web.load(URLRequest(url: url))
        }
    }

    /// window.KolamShell tells the kit it runs in this shell, and passes accessibility settings
    /// that have no CSS media query in WebKit yet.
    static func shellScript() -> String {
        let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled ? "true" : "false"
        let boldText = UIAccessibility.isBoldTextEnabled ? "true" : "false"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        // The languages this iPhone has voices for, so the page can say when one is missing (e.g. no Tamil voice installed).
        let langs = Array(Set(AVSpeechSynthesisVoice.speechVoices().map { $0.language })).sorted()
        let langsJS = "[" + langs.map { "'\($0)'" }.joined(separator: ",") + "]"
        return """
        window.KolamShell = { platform: 'ios', app: 'Pesu', version: '\(version)', nativeBack: true,
          reduceTransparency: \(reduceTransparency), boldText: \(boldText), ttsLangs: \(langsJS) };
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AVSpeechSynthesizerDelegate {
        let parent: AppWebView
        // MARK: Text to speech: the page posts { action: 'speak', id, text, lang, rate } or { action: 'stop' }.
        // Web Speech in WKWebView has no Tamil voice choice and stops with the silent switch; AVSpeechSynthesizer
        // uses the app's .playback audio session and every voice installed on the iPhone.
        private let synth = AVSpeechSynthesizer()
        private var spoken: [ObjectIdentifier: Int] = [:]
        private weak var ttsWeb: WKWebView?
        private func handleTTS(_ body: Any, from web: WKWebView?) {
            guard let msg = body as? [String: Any], let action = msg["action"] as? String else { return }
            if action == "stop" { spoken.removeAll(); synth.stopSpeaking(at: .immediate); return }
            guard action == "speak", let text = msg["text"] as? String else { return }
            ttsWeb = web
            spoken.removeAll()
            synth.stopSpeaking(at: .immediate)
            let u = AVSpeechUtterance(string: text)
            let lang = msg["lang"] as? String ?? "en-GB"
            u.voice = AVSpeechSynthesisVoice(language: lang)
                ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(String(lang.prefix(2))) }
            // Web Speech rate 1 ≈ AVSpeechUtteranceDefaultSpeechRate (0.5); Pesu uses 0.92 normal, 0.6 slow.
            let rate = (msg["rate"] as? Double) ?? 0.92
            u.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, Float(rate) * AVSpeechUtteranceDefaultSpeechRate))
            if let id = msg["id"] as? Int { spoken[ObjectIdentifier(u)] = id }
            synth.delegate = self
            synth.speak(u)
        }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
            guard let id = spoken.removeValue(forKey: ObjectIdentifier(u)) else { return }
            DispatchQueue.main.async { self.ttsWeb?.evaluateJavaScript("window.__pesuTTSDone && window.__pesuTTSDone(\(id))") }
        }
        var lastToken = 0
        init(_ parent: AppWebView) { self.parent = parent }

        // MARK: Loading state
        var ranDebugJS = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            #if DEBUG
            // Debug builds only: `-KolamJS "<line>"` runs one line of JavaScript after the first load (screenshot set-up).
            if !ranDebugJS, let js = UserDefaults.standard.string(forKey: "KolamJS") { ranDebugJS = true; webView.evaluateJavaScript(js) }
            #endif
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.failed = true }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()                                 // iOS reclaimed memory in the background
        }

        // MARK: Links: the app stays in the web view; other sites open in Safari's viewer
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["mailto", "tel", "sms", "facetime", "maps", "itms-apps"].contains(scheme) {
                UIApplication.shared.open(url)
                return decisionHandler(.cancel)
            }
            let isApp = url.host.map { AppWebView.appHosts.contains($0) } ?? true
            if action.navigationType == .linkActivated && !isApp && (scheme == "https" || scheme == "http") {
                openInSafari(url, from: webView)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        // target="_blank" links and window.open()
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = action.request.url else { return nil }
            if let host = url.host, AppWebView.appHosts.contains(host) { webView.load(URLRequest(url: url)) }
            else { openInSafari(url, from: webView) }
            return nil
        }

        private func openInSafari(_ url: URL, from view: UIView) {
            guard let root = view.window?.rootViewController else { return }
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = UIColor(named: "AccentColor")
            (root.presentedViewController ?? root).present(safari, animated: true)
        }

        // MARK: JavaScript alert() / confirm() as iOS alerts (WKWebView shows nothing otherwise)
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(alert, from: webView, orElse: completionHandler)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(alert, from: webView) { completionHandler(false) }
        }
        private func present(_ vc: UIViewController, from view: UIView, orElse fallback: @escaping () -> Void) {
            guard let root = view.window?.rootViewController else { return fallback() }
            (root.presentedViewController ?? root).present(vc, animated: true)
        }

        // Camera and microphone for the app's own pages: iOS asks once; the page then gets it.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(AppWebView.appHosts.contains(origin.host) ? .grant : .prompt)
        }

        // MARK: Haptics requested by the page (KolamIOS.haptic(kind))
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "tts" { handleTTS(message.body, from: message.webView); return }
            guard message.name == "haptic" else { return }
            switch message.body as? String ?? "light" {
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "selection": UISelectionFeedbackGenerator().selectionChanged()
            case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case "rigid": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}
