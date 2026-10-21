import Foundation
import Observation
import WebKit

/// The Browser tab: one bare web view that lives as long as the app, so switching tabs never reloads it.
@MainActor @Observable
final class BrowserModel: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var address = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var title = ""
    /// Why the last page couldn't open (nothing answering there, say), shown instead of WebKit's
    /// blank white page. Cleared when a page starts showing.
    private(set) var loadError: String?
    private var project: URL?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            webView.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.isLoading = w.isLoading } },
            webView.observe(\.url) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = w.url else { return }
                    self.address = url.absoluteString
                    self.remember(url)
                }
            },
            webView.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
        ]
    }

    /// Switches project: shows the last page you had open for it.
    func open(project: URL?) {
        guard project != self.project else { return }
        self.project = project
        if let project, let last = UserDefaults.standard.string(forKey: key(project)), let url = URL(string: last) {
            load(url)
        } else {
            address = ""
            webView.loadHTMLString("", baseURL: nil)
        }
    }

    /// Typed into the address bar: "localhost:4200" or "example.com" work without a scheme.
    func go(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let withScheme = t.contains("://") ? t : (t.hasPrefix("localhost") || t.hasPrefix("127.0.0.1") ? "http://" : "https://") + t
        if let url = URL(string: withScheme) { load(url) }
    }

    func load(_ url: URL) {
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Run found a local URL in your app's output: show it, unless you're already on a page (one
    /// that couldn't open doesn't count: the server it waited for is up now).
    func openIfIdle(_ url: URL) {
        if webView.url == nil || webView.url?.absoluteString == "about:blank" || address.isEmpty || loadError != nil { load(url) }
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    /// Reloads, or tries the address again after a page that couldn't open.
    func reload() { if loadError != nil { go(address) } else { webView.reload() } }

    private func remember(_ url: URL) {
        guard let project, url.scheme == "http" || url.scheme == "https" else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: key(project))
    }

    private func key(_ project: URL) -> String { "browser.last." + project.standardizedFileURL.path }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated { loadError = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = Self.message(error)
        MainActor.assumeIsolated { if let message { loadError = message } }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}

    /// What to say about a failed load; nil when it was only stopped or replaced by another one.
    nonisolated private static func message(_ error: Error) -> String? {
        let e = error as NSError
        guard !(e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) else { return nil }
        if e.domain == NSURLErrorDomain, [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(e.code) {
            return "Nothing is answering there. Is the dev server running?"
        }
        return e.localizedDescription
    }
}
