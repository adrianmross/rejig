import AppKit

/// The one permission Tilespace needs, asked for the way Rex does: say plainly
/// what it is for and what it is not, open the right Settings pane, offer the app
/// icon to drag into the list, and close by itself the moment access is granted.
final class Permissions {
  private var panel: NSPanel?
  private let granted: () -> Void

  init(granted: @escaping () -> Void) {
    self.granted = granted
    // macOS posts this whenever the Accessibility list changes: no polling
    DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
    ) { [unowned self] _ in
      // the trust flag flips a beat after the notification
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.check() }
    }
  }

  func check() {
    if AXIsProcessTrusted() {
      panel?.close()
      panel = nil
      granted()
    } else if panel == nil {
      show()
    }
  }

  @objc private func openSettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }

  private func show() {
    let icon = DragIcon(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
    icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
    icon.toolTip = "Drag me into the Accessibility list"
    let button = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openSettings))
    button.keyEquivalent = "\r"

    panel = makePanel([
      label("Tilespace needs Accessibility access", .boldSystemFont(ofSize: 15)),
      label(
        "It uses it to find, focus, move and resize windows, and to press the Mission Control "
          + "shortcuts you set up, including holding a window's title bar while it does.",
        .systemFont(ofSize: 13)),
      label(
        "It does not read what is in your windows, watch your typing, record the screen or use the network. "
          + "It asks for no other permission.", .systemFont(ofSize: 13)),
      label(
        "Open the settings, then drag this icon into the list and switch it on. "
          + "This panel closes by itself once access is granted.", .systemFont(ofSize: 13)),
      icon, button,
    ])
  }
}

/// Workspace switching presses macOS's own "Switch to Desktop N" shortcuts, which
/// are off by default. A shortcut can't be dragged into Settings the way an app
/// can, so one button switches them on; the other opens the pane to do it by hand.
final class ShortcutSetup {
  private var panel: NSPanel?
  private let spaces: Spaces
  private let done: () -> Void

  init(_ spaces: Spaces, done: @escaping () -> Void) {
    self.spaces = spaces
    self.done = done
  }

  var missing: [Int] { (1...max(spaces.desktops, 1)).prefix(6).filter { spaces.shortcut($0) == nil } }

  func show() {
    panel?.close()
    let on = NSButton(title: "Turn On Desktop Shortcuts", target: self, action: #selector(enable))
    on.keyEquivalent = "\r"
    panel = makePanel([
      label("Turn on the desktop shortcuts", .boldSystemFont(ofSize: 15)),
      label(
        "Tilespace switches workspaces by pressing macOS's own \"Switch to Desktop\" shortcuts. "
          + "You have \(spaces.desktops) desktops; the shortcut is off for: "
          + "\(missing.map(String.init).joined(separator: ", ")).", .systemFont(ofSize: 13)),
      label(
        "The button ticks \"Switch to Desktop 1\" to \"6\" for you, on Control-1 to Control-6 unless you "
          + "have chosen other keys. Nothing else is changed, and you can untick them in the same place.",
        .systemFont(ofSize: 13)),
      label(
        "Need more workspaces? Add desktops in Mission Control (Control-Up, then +).", .systemFont(ofSize: 13)),
      on, NSButton(title: "Open Keyboard Shortcuts Instead", target: self, action: #selector(openSettings)),
    ])
  }

  @objc private func enable() {
    spaces.enableShortcuts()
    panel?.close()
    panel = nil
    done()
  }

  @objc private func openSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
  }
}

private func label(_ text: String, _ font: NSFont) -> NSTextField {
  let l = NSTextField(wrappingLabelWithString: text)
  l.font = font
  l.preferredMaxLayoutWidth = 320
  return l
}

private func makePanel(_ views: [NSView]) -> NSPanel {
  let stack = NSStackView(views: views)
  stack.orientation = .vertical
  stack.alignment = .leading
  stack.spacing = 12
  stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

  let p = NSPanel(
    contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
  p.title = "Tilespace"
  p.isReleasedWhenClosed = false
  p.level = .floating  // stays beside System Settings while you work in it
  p.contentView = stack
  p.setContentSize(stack.fittingSize)
  if let v = NSScreen.main?.visibleFrame {
    p.setFrameOrigin(CGPoint(x: v.maxX - p.frame.width - 40, y: v.midY - p.frame.height / 2))
  }
  p.orderFrontRegardless()
  return p
}

/// The app's icon, draggable as the app itself, for dropping into the Settings list.
private final class DragIcon: NSImageView, NSDraggingSource {
  override func mouseDown(with event: NSEvent) {
    let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
    item.setDraggingFrame(bounds, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation {
    .copy
  }
}
