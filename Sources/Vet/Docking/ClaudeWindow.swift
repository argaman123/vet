import AppKit
import ApplicationServices
import VetCore

/// Thin Accessibility wrapper around Claude Desktop's main window.
@MainActor
final class ClaudeWindow {
    nonisolated static let bundleID = "com.anthropic.claudefordesktop"
    nonisolated static let appURL = URL(fileURLWithPath: "/Applications/Claude.app")

    let app: NSRunningApplication
    let element: AXUIElement
    private var observer: AXObserver?
    private var onMove: (() -> Void)?

    private init(app: NSRunningApplication, element: AXUIElement) {
        self.app = app
        self.element = element
    }

    static func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    /// Claude's main window: the AX main window, else its largest standard window.
    static func find() -> ClaudeWindow? {
        guard let app = runningApp() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let main: AXUIElement = attribute(appElement, kAXMainWindowAttribute) {
            return ClaudeWindow(app: app, element: main)
        }
        let windows: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) ?? []
        let standard = windows.filter { (attribute($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
        let largest = standard.max { area($0) < area($1) }
        return largest.map { ClaudeWindow(app: app, element: $0) }
    }

    var isAlive: Bool { !app.isTerminated && (Self.attribute(element, kAXRoleAttribute) as String?) != nil }

    var axFrame: CGRect? {
        guard let p: CGPoint = Self.value(element, kAXPositionAttribute, .cgPoint),
              let s: CGSize = Self.value(element, kAXSizeAttribute, .cgSize) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Sets position, then size, then position again: AX clamps size against the current position.
    @discardableResult
    func setAXFrame(_ r: CGRect) -> Bool {
        var origin = r.origin, size = r.size
        let pos = AXValueCreate(.cgPoint, &origin)!, sz = AXValueCreate(.cgSize, &size)!
        let a = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
        let b = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sz)
        let c = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
        return a == .success && b == .success && c == .success
    }

    var isMinimized: Bool { (Self.attribute(element, kAXMinimizedAttribute) as Bool?) ?? false }
    func unminimize() { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }

    var isFullScreen: Bool { (Self.attribute(element, "AXFullScreen") as Bool?) ?? false }
    func exitFullScreen() { AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse) }

    /// Brings Claude's window to the front, handing activation over from Vet.
    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    /// Calls `handler` on the main thread whenever Claude's window moves or resizes.
    func observeMoves(_ handler: @escaping () -> Void) {
        onMove = handler
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let window = Unmanaged<ClaudeWindow>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { window.onMove?() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, element, kAXMovedNotification as CFString, refcon)
        AXObserverAddNotification(obs, element, kAXResizedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    func stopObserving() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        onMove = nil
    }

    // MARK: AX helpers

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    private static func value<T>(_ el: AXUIElement, _ name: String, _ type: AXValueType) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(axValue, type, pointer) else { return nil }
        return pointer.pointee
    }

    private static func area(_ el: AXUIElement) -> CGFloat {
        let s: CGSize = value(el, kAXSizeAttribute, .cgSize) ?? .zero
        return s.width * s.height
    }
}
