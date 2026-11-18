import AppKit

/// Native Spaces, through public API only. macOS has no public call to list,
/// identify, switch or populate Spaces, so:
///
/// - identity: an invisible 1pt marker window of ours sits on each Space we have
///   seen; `NSWindow.isOnActiveSpace` says which one is showing.
/// - switching: we press the "Switch to Desktop N" shortcut the user enabled in
///   System Settings, reading the key combination from their preferences.
/// - numbers: a marker learns its desktop number when we switch to it by number.
///   The Spaces showing at launch take theirs from macOS's Spaces preferences.
///   Only the menu bar and back-and-forth depend on numbers.
final class Spaces {
  private var markers: [Int: NSWindow] = [:]
  private var release: (() -> Void)?
  private(set) var shown: [NSScreen: Int] = [:]  // desktop number showing on each display
  private(set) var desktops = 0
  private var learned: [Int: Int] = [:]  // marker -> desktop number
  private var lastActive: [NSScreen: Int] = [:]  // marker showing on each display
  private var asked: (n: Int, at: Date)?
  private var ranges: [NSScreen: Range<Int>] = [:]  // the desktop numbers each display holds
  private(set) var current: Int?
  private(set) var previous: Int?

  init() {
    let saved = savedNumbers()
    lastActive = Dictionary(active(), uniquingKeysWith: { a, _ in a })
    for (screen, key) in lastActive { learned[key] = saved[screen] }
    infer(lastActive)
    shown = lastActive.compactMapValues { learned[$0] }
    current = NSScreen.screens.first.flatMap { shown[$0] }
  }

  // HACK: private API, read-only. CGSCopyManagedDisplaySpaces is the window
  // server's own list of each display's Spaces and which one is showing; nothing
  // public says that. Looked up by name at run time, so if a macOS update removes
  // it this returns nil and numbers fall back to the preferences file and learning.
  private let liveSpaces: () -> [[String: Any]]? = {
    typealias Connection = @convention(c) () -> Int32
    typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
    let anywhere = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard let connection = dlsym(anywhere, "CGSMainConnectionID"),
      let copy = dlsym(anywhere, "CGSCopyManagedDisplaySpaces")
    else { return { nil } }
    return {
      unsafeBitCast(copy, to: Copy.self)(unsafeBitCast(connection, to: Connection.self)())?
        .takeRetainedValue() as? [[String: Any]]
    }
  }()
  private var exact = false  // the last numbers came from the window server, not the preferences file

  /// Desktop numbers as Mission Control counts them: across displays in its
  /// order, full-screen Spaces not counted.
  // ponytail: the fallback is an undocumented preferences file, read with a public
  // call. macOS saves it lazily (it was still stale 8 s after a switch), so it is
  // trusted for the desktop count and once at launch, never for what is showing now.
  private func savedNumbers() -> [NSScreen: Int] {
    let domain = "com.apple.spaces" as CFString
    CFPreferencesAppSynchronize(domain)
    let conf = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, domain) as? [String: Any]
    var out: [NSScreen: Int] = [:]
    desktops = 0
    ranges = [:]
    let live = liveSpaces()
    exact = live != nil
    for monitor in live ?? (conf?["Management Data"] as? [String: Any])?["Monitors"] as? [[String: Any]] ?? [] {
      guard let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }  // a display not connected
      let uuids = spaces.filter { $0["type"] as? Int == 0 }.compactMap { $0["uuid"] as? String }
      defer { desktops += uuids.count }
      let display = monitor["Display Identifier"] as? String
      let screen = display == "Main" ? NSScreen.screens.first : NSScreen.screens.first { $0.uuid == display }
      if let screen { ranges[screen] = desktops + 1..<desktops + 1 + uuids.count }
      if let screen, let now = (monitor["Current Space"] as? [String: Any])?["uuid"] as? String,
        let i = uuids.firstIndex(of: now)
      {
        out[screen] = desktops + i + 1
      }
    }
    return out
  }

  /// Numbers that need no learning: a display's only desktop, and the one
  /// desktop of a display whose others are all known.
  private func infer(_ now: [NSScreen: Int]) {
    for (screen, key) in now {
      guard let range = ranges[screen] else { continue }
      if range.count == 1 {
        learned = learned.filter { $0.value != range.lowerBound }
        learned[key] = nil
      }
      let free = range.filter { !learned.values.contains($0) }
      if learned[key] == nil, free.count == 1 { learned[key] = free[0] }
    }
  }

  private func arrive(_ n: Int) {
    guard n != current else { return }
    previous = current
    current = n
  }

  /// The marker showing on each screen, creating one where a Space is new to us.
  /// Screens showing a full-screen Space are left out: nothing is managed there.
  func active() -> [(NSScreen, Int)] {
    var out: [(NSScreen, Int)] = []
    for screen in NSScreen.screens {
      if let key = markers.filter({ $0.value.isOnActiveSpace && $0.value.screen == screen }).keys.min() {
        out.append((screen, key))
        continue
      }
      let w = NSWindow(
        contentRect: CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 1, height: 1),
        styleMask: .borderless, backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      w.alphaValue = 0
      w.ignoresMouseEvents = true
      w.hasShadow = false
      w.collectionBehavior = [.stationary, .ignoresCycle]  // out of Mission Control and Cmd-`
      w.orderFrontRegardless()
      guard w.isOnActiveSpace else {
        w.close()
        continue
      }
      let key = (markers.keys.max() ?? 0) + 1
      markers[key] = w
      out.append((screen, key))
    }
    return out
  }

  /// The user's "Switch to Desktop N" shortcut, or nil while it is switched off.
  func shortcut(_ n: Int) -> (key: CGKeyCode, flags: CGEventFlags)? {
    let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, hotkeys) as? [String: Any]
    guard let entry = all?["\(117 + n)"] as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
      let p = (entry["value"] as? [String: Any])?["parameters"] as? [Int], p.count == 3
    else { return nil }
    return (CGKeyCode(p[1]), CGEventFlags(rawValue: UInt64(p[2])))
  }

  private let hotkeys = "com.apple.symbolichotkeys" as CFString

  /// Turns on "Switch to Desktop 1" to "6", keeping whatever keys are assigned
  /// (Control-number when none are), exactly as ticking them in System Settings does.
  func enableShortcuts() {
    var all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, hotkeys) as? [String: Any] ?? [:]
    for (i, digit) in [18, 19, 20, 21, 23, 22].enumerated() {
      var entry =
        all["\(118 + i)"] as? [String: Any]
        ?? ["value": ["type": "standard", "parameters": [65535, digit, Int(CGEventFlags.maskControl.rawValue)]]]
      entry["enabled"] = true
      all["\(118 + i)"] = entry
    }
    CFPreferencesSetAppValue("AppleSymbolicHotKeys" as CFString, all as CFDictionary, hotkeys)
    CFPreferencesAppSynchronize(hotkeys)
    // macOS rereads its shortcuts at login, or when this system tool tells it to
    let p = Process()
    p.executableURL = URL(
      fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
    p.arguments = ["-u"]
    try? p.run()
  }

  func switchTo(_ n: Int) -> Bool {
    guard let s = shortcut(n) else { return false }
    press(s, n)
    return true
  }

  /// Takes a window along to desktop `n` the way a person would: hold its title
  /// bar, press the desktop shortcut, let go once the Space has changed.
  // ponytail: a window with no bare title bar (a video window that hides it) won't
  // come along; make the grab point a per-app setting if that matters.
  func carry(_ frame: CGRect, to n: Int) -> Bool {
    guard let s = shortcut(n), release == nil else { return false }
    let home = CGEvent(source: nil)?.location ?? .zero
    // along the top edge, the spot nearest the middle that is bare title bar, not a tab, button or field
    let bare = ["AXWindow", "AXToolbar", "AXGroup", "AXStaticText", "AXSplitGroup"]
    let spots = stride(from: frame.minX + 90, to: frame.maxX - 40, by: 50).map { CGPoint(x: $0, y: frame.minY + 8) }
    let grab =
      spots.filter { p in
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit)
        return hit.flatMap { Win(el: $0, pid: 0).get(kAXRoleAttribute) }.map(bare.contains) ?? false
      }.min { abs($0.x - frame.midX) < abs($1.x - frame.midX) } ?? CGPoint(x: frame.midX, y: frame.minY + 6)
    let held = CGPoint(x: grab.x, y: grab.y + 40)
    mouse(.leftMouseDown, grab)
    release = { [unowned self] in
      self.mouse(.leftMouseUp, held)
      CGWarpMouseCursorPosition(home)
    }
    // far enough that macOS takes it for a drag rather than a click
    for step in 1...4 {
      after(0.03 * Double(step)) { self.mouse(.leftMouseDragged, CGPoint(x: grab.x, y: grab.y + CGFloat(step) * 10)) }
    }
    after(0.3) { self.press(s, n) }
    after(1.5) { self.letGo() }  // the Space never changed (already there): let go anyway
    return true
  }

  /// Call on NSWorkspace.activeSpaceDidChangeNotification.
  func spaceChanged() {
    let now = Dictionary(active(), uniquingKeysWith: { a, _ in a })
    let arrived = now.filter { lastActive[$0.key] != $0.value }
    lastActive = now
    let numbers = savedNumbers()  // desktops may have been added or removed
    // when two displays change at once, only the one that holds desktop n arrived at it
    let key = asked.flatMap { a in
      !exact && Date().timeIntervalSince(a.at) < 1.5
        ? arrived.first { ranges[$0.key]?.contains(a.n) ?? true }?.value : nil
    }
    if let key, let a = asked {
      learned = learned.filter { $0.value != a.n }  // a number belongs to one Space
      learned[key] = a.n
    }
    if exact { for (screen, key) in now { learned[key] = numbers[screen] } } else { infer(now) }
    if key == nil, let n = arrived.values.compactMap({ learned[$0] }).first {
      arrive(n)  // switched by swipe or Mission Control
    }
    asked = nil
    shown = now.compactMapValues { learned[$0] }
    if release != nil { after(0.3) { self.letGo() } }  // let the slide animation finish
  }

  func describe() -> String {
    let shortcuts = (1...6).map { "\($0):\(shortcut($0) == nil ? "off" : "on")" }.joined(separator: " ")
    return """
      separate Spaces per display: \(NSScreen.screensHaveSeparateSpaces)
      "Switch to Desktop N" shortcuts: \(shortcuts)
      workspace: \(current.map(String.init) ?? "unknown"), previous: \(previous.map(String.init) ?? "unknown")
      desktop numbers from: \(exact ? "window server (private, read-only)" : "preferences and learning")
      Spaces seen: \(markers.count), desktops: \(desktops), showing: \(shown.map { "\($0.key.localizedName)=\($0.value)" }.sorted())
      """
  }

  private func press(_ s: (key: CGKeyCode, flags: CGEventFlags), _ n: Int) {
    arrive(n)
    asked = (n, Date())
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: s.key, keyDown: down)
      e?.flags = down ? s.flags : []
      e?.post(tap: .cghidEventTap)
    }
  }

  private func letGo() {
    let r = release
    release = nil
    r?()
  }

  private func mouse(_ type: CGEventType, _ at: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
    e?.flags = []  // never a Control-click, whatever modifiers the last shortcut left behind
    e?.post(tap: .cghidEventTap)
  }

  private func after(_ seconds: Double, _ work: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }
}

extension NSScreen {
  /// The display's UUID, as the Spaces preferences name it.
  var uuid: String? {
    guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
      let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, u) as String?
  }
}
