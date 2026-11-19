import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
func png(_ image: NSImage, at url: URL, opaque: Bool = false) throws {
    var rect = CGRect(origin: .zero, size: image.size)
    guard var cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { fatalError("Image export failed") }
    if opaque {
        let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        cg = context.makeImage()!
    }
    guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { fatalError("PNG export failed") }
    try data.write(to: url)
}

let sky = NSImage(size: NSSize(width: 1290, height: 2796))
sky.lockFocus()
NSGradient(starting: NSColor(red: 0.85, green: 0.92, blue: 0.98, alpha: 1), ending: NSColor(red: 0.42, green: 0.64, blue: 0.84, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: 1290, height: 2796), angle: 90)
NSColor.white.withAlphaComponent(0.55).setFill()
NSBezierPath(ovalIn: NSRect(x: 890, y: 1900, width: 190, height: 190)).fill()
let cloud = NSBezierPath()
cloud.move(to: NSPoint(x: -80, y: 850))
cloud.curve(to: NSPoint(x: 1370, y: 850), controlPoint1: NSPoint(x: 200, y: 1150), controlPoint2: NSPoint(x: 950, y: 520))
cloud.line(to: NSPoint(x: 1370, y: 0)); cloud.line(to: .zero); cloud.close()
NSColor.white.withAlphaComponent(0.15).setFill(); cloud.fill()
sky.unlockFocus()
try png(sky, at: root.appendingPathComponent("Resources/Wallpapers/sky.png"))

let icon = NSImage(size: NSSize(width: 1024, height: 1024))
icon.lockFocus()
NSGradient(starting: NSColor(red: 0.87, green: 0.94, blue: 1, alpha: 1), ending: NSColor(red: 0.46, green: 0.68, blue: 0.87, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 90)
NSColor.white.withAlphaComponent(0.32).setFill(); NSBezierPath(ovalIn: NSRect(x: 166, y: 166, width: 692, height: 692)).fill()
if let mascot = NSImage(contentsOf: root.appendingPathComponent("Resources/Assets.xcassets/mood-4.imageset/mood-4.png")) {
    mascot.draw(in: NSRect(x: 170, y: 110, width: 684, height: 684))
}
icon.unlockFocus()
try png(icon, at: root.appendingPathComponent("Resources/AppIcon.png"), opaque: true)
