import SwiftUI
import WebKit

/// An instagram.com page, for what the app doesn't show natively yet (messages, activity)
/// and for logging in. Filter.js keeps Reels and Explore out of it.
struct WebScreen: UIViewRepresentable {
    let path: String
    var onCookiesChange: (() -> Void)?

    func makeCoordinator() -> WebPage {
        WebPage(path: path, onCookiesChange: onCookiesChange)
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// Instagram's own login page. The app switches to the native screens once the session cookie appears.
struct LoginView: View {
    @Environment(Session.self) private var session

    var body: some View {
        WebScreen(path: "/accounts/login/") {
            Task { await session.refresh() }
        }
    }
}

@MainActor
final class WebPage: NSObject {
    let webView: WKWebView
    private let onCookiesChange: (() -> Void)?

    init(path: String, onCookiesChange: (() -> Void)?) {
        self.onCookiesChange = onCookiesChange

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Session.dataStore
        configuration.userContentController = WebFilters.contentController()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true  // Debug pages from Safari's Develop menu on the Mac.
        #endif
        if onCookiesChange != nil {
            Session.dataStore.httpCookieStore.add(self)
        }
        webView.load(URLRequest(url: URL(string: path, relativeTo: InstagramAPI.site)!))
    }

    /// Sites that open in the web view. Anything else goes to Safari.
    private static func staysInApp(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        // facebook.com is there for "Log in with Facebook".
        return ["instagram.com", "facebook.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func openOutside(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

extension WebPage: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        onCookiesChange?()
    }
}

extension WebPage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }

        // Embedded frames (video players, login helpers) load as the site intends.
        if let frame = action.targetFrame, !frame.isMainFrame { return .allow }

        switch url.scheme?.lowercased() {
        case "http", "https":
            guard Self.staysInApp(url) else {
                openOutside(url)
                return .cancel
            }
            if action.targetFrame == nil {
                // target="_blank": keep it in this view.
                webView.load(action.request)
                return .cancel
            }
            return .allow
        case "about", "blob", "data":
            return .allow
        case "mailto", "tel", "sms":
            openOutside(url)
            return .cancel
        default:
            // instagram:// and itms-apps:// would bounce you into the official app or the App Store.
            return .cancel
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    #if DEBUG
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ScriptSearch.runIfRequested(in: webView)
    }
    #endif
}

extension WebPage: WKUIDelegate {
    /// window.open(): stay in this view, or go to Safari for other sites.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased()) {
            if Self.staysInApp(url) {
                webView.load(action.request)
            } else {
                openOutside(url)
            }
        }
        return nil
    }
}
