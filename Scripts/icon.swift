// Draws the app icon: `swift Scripts/icon.swift icon.png` (see `make icon`).
// With a third word, `front` or `under`, draws only those tiles on a clear,
// full-bleed canvas: the layers of Resources/AppIcon.icon, which macOS 26 and
// later draw with their own plate, light and shadow.
import AppKit

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let layer = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
if layer != nil {
  // the plate is 824 of 1024 pt; a layer fills the canvas
  let t = NSAffineTransform()
  t.translateX(by: 512, yBy: 512)
  t.scale(by: 1024.0 / 824.0)
  t.translateX(by: -512, yBy: -512)
  t.concat()
}
// macOS's icon grid: an 824 pt rounded square in a 1024 pt canvas
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
func grey(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
func shadow(_ blur: Double, _ drop: Double, _ alpha: Double) {
  let s = NSShadow()
  s.shadowColor = NSColor.black.withAlphaComponent(alpha)
  s.shadowBlurRadius = blur
  s.shadowOffset = NSSize(width: 0, height: -drop)
  s.set()
}
if layer == nil {
let body = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
// the plate: lifted off the canvas, lit from above
NSGraphicsContext.saveGraphicsState()
shadow(24, 12, 0.35)
grey(0.07, 0.08, 0.11).setFill()
body.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: grey(0.21, 0.23, 0.33), ending: grey(0.06, 0.07, 0.1))!.draw(in: body, angle: -90)
NSGraphicsContext.saveGraphicsState()
body.addClip()
NSGradient(starting: NSColor.white.withAlphaComponent(0.28), ending: NSColor.white.withAlphaComponent(0))!
  .draw(in: NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183), angle: -90)
NSGradient(starting: grey(0.21, 0.23, 0.33), ending: grey(0.06, 0.07, 0.1))!
  .draw(in: NSBezierPath(roundedRect: tile.insetBy(dx: 5, dy: 5), xRadius: 180, yRadius: 180), angle: -90)
NSGraphicsContext.restoreGraphicsState()
}
// a tiled layout that reads as a lowercase r: the stem and the arm are bright,
// the tile under the arm sits back in the plate
let area = tile.insetBy(dx: 150, dy: 140)
let gap = 36.0
let stem = area.width * 0.42
let arm = area.height * 0.42
let right = area.minX + stem + gap
let under = NSBezierPath(
  roundedRect: NSRect(x: right, y: area.minY, width: area.maxX - right, height: area.height - arm - gap),
  xRadius: 50, yRadius: 50)
if layer != "front" { NSGradient(starting: grey(0.36, 0.38, 0.5), ending: grey(0.27, 0.29, 0.4))!.draw(in: under, angle: -90) }
for rect in layer == "under" ? [] : [
  NSRect(x: area.minX, y: area.minY, width: stem, height: area.height),
  NSRect(x: right, y: area.maxY - arm, width: area.maxX - right, height: arm),
] {
  let path = NSBezierPath(roundedRect: rect, xRadius: 50, yRadius: 50)
  if layer == nil {
    NSGraphicsContext.saveGraphicsState()
    shadow(28, 14, 0.5)
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
  }
  NSGradient(starting: .white, ending: grey(0.8, 0.82, 0.87))!.draw(in: path, angle: -90)
}
image.unlockFocus()
let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
