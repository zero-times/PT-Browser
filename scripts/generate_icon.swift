import AppKit
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.04, green: 0.15, blue: 0.18, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.29, blue: 0.30, alpha: 1)])!
gradient.draw(in: rect, angle: 45)
let ring = NSBezierPath(ovalIn: NSRect(x: 180, y: 180, width: 664, height: 664))
NSColor(calibratedWhite: 1, alpha: 0.13).setStroke(); ring.lineWidth = 3; ring.stroke()
for i in 0..<48 {
 let angle = CGFloat(i) * .pi * 2 / 48
 let r1: CGFloat = i % 4 == 0 ? 290 : 307
 let p = NSBezierPath(); p.move(to: NSPoint(x: 512 + sin(angle)*r1,y:512 + cos(angle)*r1)); p.line(to: NSPoint(x:512 + sin(angle)*320,y:512 + cos(angle)*320)); p.lineWidth = i % 4 == 0 ? 5 : 3; p.lineCapStyle = .round
 NSColor(calibratedWhite: 1, alpha: i % 4 == 0 ? 0.8 : 0.28).setStroke(); p.stroke()
}
let needle = NSBezierPath(); needle.move(to: NSPoint(x: 677, y: 726)); needle.line(to: NSPoint(x: 559, y: 465)); needle.line(to: NSPoint(x: 346, y: 298)); needle.line(to: NSPoint(x: 464, y: 559)); needle.close()
NSColor(calibratedRed: 0.35, green: 0.94, blue: 0.83, alpha: 1).setFill(); needle.fill()
let inner = NSBezierPath(); inner.move(to: NSPoint(x: 512, y: 512)); inner.line(to: NSPoint(x: 677, y: 726)); inner.line(to: NSPoint(x: 559, y: 465)); inner.close(); NSColor.white.setFill(); inner.fill()
let dot = NSBezierPath(ovalIn: NSRect(x: 488,y:488,width:48,height:48)); NSColor(calibratedRed:0.04,green:0.22,blue:0.23,alpha:1).setFill(); dot.fill()
image.unlockFocus()
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
