import AppKit

/// Borders around tiled windows, with public API only. Two click-through
/// overlays per display:
///
/// - one just below normal windows draws every border. Windows cover all of it
///   but the part in the gaps, so nothing has to be ordered against the window a
///   border belongs to. Window shadows fall on it and dim it.
/// - one just above normal windows redraws the focused window's border, outside
///   its frame only, so the active colour is exact. The focused window is in
///   front, so this never covers another window's content.
///
/// A floating window is marked only while it has focus: any other time its
/// border would sit under, or over, whatever it overlaps.
final class Borders {
  private var overlays: [(window: NSWindow, view: BorderView, screen: Int)] = []

  func update(_ rects: [(rect: CGRect, active: Bool)], _ style: Config.Border, glow: Bool = false) {
    let screens = NSScreen.screens
    if overlays.map(\.window.frame) != screens.flatMap({ [$0.frame, $0.frame] }) {
      overlays.forEach { $0.window.close() }
      overlays = style.width > 0 ? screens.indices.flatMap { i in [false, true].map { overlay(i, above: $0) } } : []
    }
    for o in overlays {
      let origin = screens[o.screen].axFrame.origin
      o.view.style = style
      o.view.glow = glow
      o.view.rects = rects.filter { $0.active || !o.view.above }
        .map { ($0.rect.offsetBy(dx: -origin.x, dy: -origin.y), $0.active) }
    }
  }

  private func overlay(_ screen: Int, above: Bool) -> (NSWindow, BorderView, Int) {
    let w = NSWindow(
      contentRect: NSScreen.screens[screen].frame, styleMask: .borderless, backing: .buffered, defer: false)
    let view = BorderView()
    view.above = above
    w.isReleasedWhenClosed = false
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + (above ? 1 : -1))
    // transient: on every Space, and put away with the windows when Mission Control shows them all
    w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    w.contentView = view
    w.orderFrontRegardless()
    return (w, view, screen)
  }
}

private final class BorderView: NSView {
  var above = false
  var style = Config.Border()
  var glow = false  // a soft halo round the focused window instead of hard borders
  var rects: [(CGRect, Bool)] = [] {
    didSet { needsDisplay = true }
  }
  override var isFlipped: Bool { true }  // top-left origin, like Accessibility frames

  override func draw(_: NSRect) {
    // ponytail: macOS doesn't report a window's corner radius. 18 is a guess on
    // the round side, so the top overlay never paints over a window's corner.
    let radius: CGFloat = 18
    // inactive first, so the active colour wins where neighbours share a gap
    for (rect, active) in rects.sorted(by: { !$0.1 && $1.1 }) {
      if glow {
        guard above, active else { continue }
        let window = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let outside = NSBezierPath(rect: bounds)
        outside.append(window)
        outside.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        outside.addClip()  // the halo never paints over the window itself
        let halo = NSShadow()
        halo.shadowBlurRadius = style.width * 3
        halo.shadowColor = style.activeColor
        halo.set()
        style.activeColor.setFill()
        window.fill()
        NSGraphicsContext.restoreGraphicsState()
        continue
      }
      let ring = NSBezierPath(
        roundedRect: rect.insetBy(dx: -style.width, dy: -style.width), xRadius: radius + style.width,
        yRadius: radius + style.width)
      // below, the ring reaches under the window to fill the slivers at its
      // rounded corners; above, it stops at the frame
      ring.append(
        above
          ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
          : NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 6, yRadius: 6))
      ring.windingRule = .evenOdd
      (active ? style.activeColor : style.inactiveColor).setFill()
      ring.fill()
    }
  }
}
