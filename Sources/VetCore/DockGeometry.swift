import CoreGraphics

/// Frame math for docking Claude Desktop's window into Vet's content area.
///
/// Cocoa (NSWindow/NSScreen) uses a bottom-left origin on the primary screen;
/// the Accessibility API uses a top-left origin on the primary screen.
/// Always pass the primary (menu-bar) screen's height: `NSScreen.screens[0].frame.height`.
public enum DockGeometry {
    /// Width of the left rail, in points.
    public static let railWidth: CGFloat = 56
    /// Height kept clear at the top of the rail for the window's traffic-light buttons.
    public static let titlebarGap: CGFloat = 40

    public static func axRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    public static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        // The flip is its own inverse.
        axRect(fromCocoa: rect, primaryScreenHeight: primaryScreenHeight)
    }

    /// Where Claude's window belongs, in Cocoa coordinates: right of the rail, full window height.
    public static func claudeTargetFrame(mainWindowFrame f: CGRect) -> CGRect {
        CGRect(x: f.minX + railWidth, y: f.minY, width: f.width - railWidth, height: f.height)
    }

    /// Where Vet's main window belongs when the user has moved or resized Claude's window (Cocoa coordinates).
    public static func mainWindowFrame(forClaudeFrame c: CGRect) -> CGRect {
        CGRect(x: c.minX - railWidth, y: c.minY, width: c.width + railWidth, height: c.height)
    }

    /// The rail panel's frame, in Cocoa coordinates: left edge, below the traffic lights.
    public static func railFrame(mainWindowFrame f: CGRect) -> CGRect {
        CGRect(x: f.minX, y: f.minY, width: railWidth, height: f.height - titlebarGap)
    }

    public static func isDocked(claudeFrame: CGRect, target: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(claudeFrame.minX - target.minX) <= tolerance && abs(claudeFrame.minY - target.minY) <= tolerance
            && abs(claudeFrame.width - target.width) <= tolerance && abs(claudeFrame.height - target.height) <= tolerance
    }
}
