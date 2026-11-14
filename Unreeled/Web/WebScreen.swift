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
    /// When you last tapped a link in the page (or a button that opens one in a new window).
    private var linkTappedAt = Date.distantPast

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
        webView.load(URLRequest(url: Self.page(at: path)))
    }

    /// The page at `path` on www.instagram.com. A path that would lead to another site, or to no
    /// page at all, as one taken from a link someone shared can, opens the home page instead.
    private static func page(at path: String) -> URL {
        guard let url = URL(string: path, relativeTo: InstagramAPI.site)?.absoluteURL,
              url.scheme == "https", url.host()?.lowercased() == InstagramAPI.site.host()
        else { return InstagramAPI.site }
        return url
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

        // Safari, another app or a call only right after you tapped a link: a page never sends you
        // out of the app on its own. Right after rather than only for the link itself, because
        // Instagram passes links to other sites through a page of its own (l.instagram.com),
        // which then moves on to them.
        if action.navigationType == .linkActivated { linkTappedAt = .now }
        let tapped = Date.now.timeIntervalSince(linkTappedAt) < 10

        switch url.scheme?.lowercased() {
        case "http", "https":
            guard Self.staysInApp(url) else {
                if tapped { openOutside(url) }
                return .cancel
            }
            if action.targetFrame == nil {
                // target="_blank": keep it in this view.
                webView.load(action.request)
                return .cancel
            }
            return .allow
        case "about":
            // A blank page, as a new window starts with. No other page without an address: with
            // no address bar on screen, nothing would tell it apart from one of Instagram's.
            return url.absoluteString == "about:blank" ? .allow : .cancel
        case "mailto", "tel", "sms":
            if tapped { openOutside(url) }
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
    /// window.open(), which WebKit allows only at a tap: stay in this view, or go to Safari for
    /// other sites.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased()) {
            if Self.staysInApp(url) {
                // Perhaps Instagram's page that passes a link on to another site: it was tapped.
                linkTappedAt = .now
                webView.load(action.request)
            } else {
                openOutside(url)
            }
        }
        return nil
    }
}
