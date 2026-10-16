import SwiftUI
import WebKit

/// Browser tab: address bar, back, forward, reload. Nothing else.
struct BrowserView: View {
    @Bindable var model: BrowserModel
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).disabled(!model.canGoBack).help("Back")
                Button { model.forward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(!model.canGoForward).help("Forward")
                Button { model.reload() } label: { Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload")
                TextField("Address, e.g. localhost:4200", text: $model.address)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .glassEffect(.regular, in: .capsule)
                    .focused($editing)
                    .onSubmit { model.go(model.address); editing = false }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            WebViewHost(webView: model.webView)
        }
    }
}

/// Hosts the long-lived WKWebView owned by the model.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
