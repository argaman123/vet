import SwiftUI
import WebKit

/// Hosts the long-lived WKWebView owned by the model.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    /// How much of the page's top the floating address bar covers.
    var topInset: CGFloat = 0
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.obscuredContentInsets.top != topInset {
            nsView.obscuredContentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
    }
}
