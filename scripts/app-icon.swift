// app-icon.swift <outdir>: draws the Vet app icon candidates (the shipped one is v3-4.png, "the bridge"); Resources/AppIcon.icns is built from it with sips + iconutil.
import AppKit
func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a) }
let S: CGFloat = 1024, shape = NSRect(x: 100, y: 100, width: 824, height: 824)
func squircle() -> NSBezierPath { NSBezierPath(roundedRect: shape, xRadius: 185, yRadius: 185) }
func render(_ mark: () -> Void) -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S)); img.lockFocus()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 26; sh.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor.black.setFill(); squircle().fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); squircle().addClip()
    NSGradient(starting: hex(0x1E1E20), ending: hex(0x111112))!.draw(in: shape, angle: -90)
    mark()
    NSGraphicsContext.restoreGraphicsState()
    let rim = squircle(); rim.lineWidth = 4
    NSColor.white.withAlphaComponent(0.12).setStroke(); rim.stroke()
    img.unlockFocus(); return img
}
func poly(_ pts: [NSPoint]) -> NSBezierPath { let p = NSBezierPath(); p.move(to: pts[0]); pts.dropFirst().forEach { p.line(to: $0) }; p.close(); return p }
func fill(_ p: NSBezierPath, _ a: UInt32, _ b: UInt32, _ angle: CGFloat = -90) { NSGradient(starting: hex(a), ending: hex(b))!.draw(in: p, angle: angle) }

// 1: folded V — two planes, the green one folding over the blue
let m1 = render {
    let left = poly([NSPoint(x: 250, y: 740), NSPoint(x: 400, y: 740), NSPoint(x: 560, y: 360), NSPoint(x: 470, y: 270)])
    fill(left, 0x5A9BFF, 0x2D5FD0)
    // shadow of the fold
    let fold = poly([NSPoint(x: 470, y: 270), NSPoint(x: 560, y: 360), NSPoint(x: 600, y: 300), NSPoint(x: 520, y: 240)])
    hex(0x000000, 0.35).setFill(); fold.fill()
    let right = poly([NSPoint(x: 470, y: 270), NSPoint(x: 580, y: 270), NSPoint(x: 780, y: 740), NSPoint(x: 630, y: 740)])
    fill(right, 0x7BE3A0, 0x2FA963)
}
// 2: one bold V with a blue→green gradient
let m2 = render {
    let v = poly([NSPoint(x: 240, y: 750), NSPoint(x: 405, y: 750), NSPoint(x: 512, y: 470), NSPoint(x: 619, y: 750), NSPoint(x: 784, y: 750), NSPoint(x: 590, y: 270), NSPoint(x: 434, y: 270)])
    NSGradient(colors: [hex(0x4F8BFF), hex(0x38C2D8), hex(0x5ADB8A)])!.draw(in: v, angle: -35)
}
// 3: extruded V — light top face, deeper side face
let m3 = render {
    let top = poly([NSPoint(x: 250, y: 740), NSPoint(x: 390, y: 740), NSPoint(x: 512, y: 430), NSPoint(x: 634, y: 740), NSPoint(x: 774, y: 740), NSPoint(x: 580, y: 300), NSPoint(x: 444, y: 300)])
    let side = poly([NSPoint(x: 444, y: 300), NSPoint(x: 580, y: 300), NSPoint(x: 580, y: 250), NSPoint(x: 444, y: 250)])
    let leftSide = poly([NSPoint(x: 250, y: 740), NSPoint(x: 444, y: 300), NSPoint(x: 444, y: 250), NSPoint(x: 250, y: 690)])
    let rightSide = poly([NSPoint(x: 580, y: 300), NSPoint(x: 774, y: 740), NSPoint(x: 774, y: 690), NSPoint(x: 580, y: 250)])
    fill(leftSide, 0x2B57B8, 0x1B3C8A); fill(side, 0x1F4BA6, 0x163579); fill(rightSide, 0x2B57B8, 0x1B3C8A)
    fill(top, 0x9DD8FF, 0x4F8BFF)
}
// 4: the bridge — the diff ribbon as one bold shape, blue to green
let m4 = render {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 220, y: 700)); p.line(to: NSPoint(x: 400, y: 700))
    p.curve(to: NSPoint(x: 624, y: 470), controlPoint1: NSPoint(x: 520, y: 700), controlPoint2: NSPoint(x: 500, y: 470))
    p.line(to: NSPoint(x: 804, y: 470)); p.line(to: NSPoint(x: 804, y: 324)); p.line(to: NSPoint(x: 624, y: 324))
    p.curve(to: NSPoint(x: 400, y: 554), controlPoint1: NSPoint(x: 420, y: 324), controlPoint2: NSPoint(x: 520, y: 554))
    p.line(to: NSPoint(x: 220, y: 554)); p.close()
    NSGradient(colors: [hex(0x4F8BFF), hex(0x3BC0D6), hex(0x5ADB8A)])!.draw(in: p, angle: 0)
}
let out = CommandLine.arguments[1], all = [m1, m2, m3, m4]
for (k, i) in all.enumerated() { try! NSBitmapImageRep(data: i.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/v3-\(k + 1).png")) }
// preview in a dock-like strip with the user's neighbors
let neighbors = ["/Applications/WebStorm.app", "/Applications/Visual Studio Code.app", "/Applications/Claude.app", "/Applications/Tabby.app"].map { NSWorkspace.shared.icon(forFile: $0) }
let pv = NSImage(size: NSSize(width: 1640, height: 700)); pv.lockFocus()
NSColor(white: 0.24, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1640, height: 700).fill()
for (k, i) in all.enumerated() {
    let x = 30 + CGFloat(k) * 405
    i.draw(in: NSRect(x: x, y: 300, width: 360, height: 360))
    ("\(k + 1)" as NSString).draw(at: NSPoint(x: x + 8, y: 650), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.white])
}
// dock row: neighbors + the four candidates at Dock size
var x: CGFloat = 60
for icon in neighbors.prefix(2) { icon.draw(in: NSRect(x: x, y: 60, width: 150, height: 150)); x += 165 }
for i in all { i.draw(in: NSRect(x: x, y: 60, width: 150, height: 150)); x += 165 }
for icon in neighbors.suffix(2) { icon.draw(in: NSRect(x: x, y: 60, width: 150, height: 150)); x += 165 }
pv.unlockFocus()
try! NSBitmapImageRep(data: pv.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/logos3.png"))
