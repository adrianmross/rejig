import AppKit
import TileCore

/// A window, by its Accessibility element.
struct Win: Hashable {
  let el: AXUIElement
  let pid: pid_t

  static func == (a: Win, b: Win) -> Bool { CFEqual(a.el, b.el) }
  func hash(into h: inout Hasher) { h.combine(CFHash(el)) }

  func get<T>(_ name: String) -> T? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v as? T : nil
  }

  var frame: CGRect? {
    var p: CFTypeRef?
    var s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
      AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success
    else { return nil }
    var r = CGRect.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &r.origin)
    AXValueGetValue(s as! AXValue, .cgSize, &r.size)
    return r
  }

  func setFrame(_ r: CGRect) {
    var origin = r.origin
    var size = r.size
    let s = AXValueCreate(.cgSize, &size)!
    let p = AXValueCreate(.cgPoint, &origin)!
    // size, position, size: a window can't outgrow its display until it has moved
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, s)
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, p)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, s)
  }
}

extension NSScreen {
  /// Frames in Accessibility coordinates: origin at the primary display's top-left.
  private func flipped(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: NSScreen.screens[0].frame.maxY - r.maxY, width: r.width, height: r.height)
  }
  var axFrame: CGRect { flipped(frame) }
  var axVisibleFrame: CGRect { flipped(visibleFrame) }
}

let manager = Manager()

private func axCallback(_: AXObserver, _ el: AXUIElement, _ name: CFString, _: UnsafeMutableRawPointer?) {
  manager.axEvent(el, name as String)
}

/// Everything here runs on the main thread, and only in response to an event:
/// a hotkey, an Accessibility notification, or a workspace notification.
final class Manager {
  let spaces = Spaces()
  var mode = "main"
  var paused = false {
    didSet {
      everything = true
      bind()
      schedule()
    }
  }
  var onChange: () -> Void = {}
  var onShortcutMissing: () -> Void = {}
  private(set) var problems: [String] = []

  private(set) var config = Config()
  private let hotkeys = Hotkeys()
  private var started = false
  private var ids: [Win: Int] = [:]
  private var wins: [Int: Win] = [:]
  private var names: [Int: String] = [:]
  private var userFloat = Set<Int>()
  private var userTile = Set<Int>()
  private var before: [Int: CGRect] = [:]  // a window's frame before it was first snapped, for "snap restore"
  // `split` was just pressed: the next window to appear or be chosen lands beside this one
  private var armed: (beside: Int, tree: Tree, axis: Orientation, at: Date)?
  private var splitting: Bool { armed.map { Date().timeIntervalSince($0.at) < 30 } ?? false }
  // what each app last said about its windows; only apps that raised an event are asked again
  private typealias Seen = (id: Int, frame: CGRect, fullscreen: Bool, resizable: Bool, standard: Bool)
  private var cache: [pid_t: [Seen]] = [:]
  private var dirty = Set<pid_t>()
  private var everything = true  // ask every app: Space, display or configuration changed
  private var born = Set<Win>()  // just created, not yet numbered
  private var launched = Set<pid_t>()  // apps started after us: all their windows are new
  private var stubborn = Set<Int>()  // refused their tile (fixed or minimum size): floated
  private var wrote: [Int: CGRect] = [:]  // frames asked for, awaiting a check
  private var settled: [Int: (asked: CGRect, got: CGRect)] = [:]  // fixed-size windows kept in the layout
  private var seen: [Int: CGRect] = [:]  // every window on the visible Spaces, tiled or not
  private var adopt = false  // a manual drag just ended: take its result into the layout
  private let borders = Borders()
  private var trees: [Int: Tree] = [:]  // by Space marker
  private var active: [(screen: NSScreen, tree: Tree)] = []
  private var rects: [Int: CGRect] = [:]
  private var observers: [pid_t: AXObserver] = [:]
  private var pending = false
  private var dragged = false
  private var lastLayout = Date.distantPast
  private(set) var lastScreen: NSScreen?  // the display with keyboard focus
  private var stats = (count: 0, lastMs: 0.0, maxMs: 0.0)
  private var appMs: [String: Double] = [:]  // time spent asking each app, last reconcile
  private var silent = Set<pid_t>()  // timed out; not asked again until they show signs of life

  func start() {
    guard !started else { return }
    started = true
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)  // a hung app can't stall us
    let ws = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
      NSWorkspace.didWakeNotification,
    ] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [unowned self] in self.workspaceEvent($0) }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [unowned self] _ in
      self.everything = true
      self.schedule()
    }
    // a manual drag or resize is left alone until the button comes up
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [unowned self] _ in
      if self.dragged {
        self.dragged = false
        self.adopt = true
        self.schedule()
      }
    }
    // never run two window managers against the same windows
    if !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty { paused = true }
    reload()
    for command in config.startup {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
      p.arguments = ["-lc", command]
      try? p.run()
    }
  }

  func reload() {
    let (loaded, error) = Config.load()
    config = loaded
    problems = error.map { [$0] } ?? []
    everything = true
    stubborn = []  // fixedSize may have changed: judge every window afresh
    settled = [:]
    bind()
    schedule()
  }

  // MARK: events

  func axEvent(_ el: AXUIElement, _ name: String) {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    silent.remove(pid)
    dirty.insert(pid)
    switch name {
    case kAXUIElementDestroyedNotification:
      forget(Win(el: el, pid: pid))
      schedule()
    case kAXWindowMovedNotification, kAXWindowResizedNotification:
      if NSEvent.pressedMouseButtons != 0 {
        dragged = true
      } else if Date().timeIntervalSince(lastLayout) > 0.5 {  // not the echo of our own write
        schedule()
      }
    case kAXFocusedWindowChangedNotification:
      focusChanged()
    case kAXWindowCreatedNotification:
      let w = Win(el: el, pid: pid)
      if born.count > 100 { born = [] }  // ponytail: created things that never became windows (popovers) pile up here
      if let id = ids[w] { floatIfNew(id, pid) } else { born.insert(w) }
      schedule()
      // apps often size a window just after creating it; look once more when it has settled
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        self.dirty.insert(pid)
        self.schedule()
      }
    default:
      schedule()
    }
  }

  private func workspaceEvent(_ note: Notification) {
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    // switching apps changes no windows; everything else here can
    if note.name == NSWorkspace.didActivateApplicationNotification, let pid = app?.processIdentifier {
      dirty.insert(pid)
    } else {
      everything = true
    }
    switch note.name {
    case NSWorkspace.didTerminateApplicationNotification:
      guard let pid = app?.processIdentifier else { return }
      if let o = observers.removeValue(forKey: pid) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
      }
      silent.remove(pid)
      cache[pid] = nil
      launched.remove(pid)
      born = born.filter { $0.pid != pid }
      ids.keys.filter { $0.pid == pid }.forEach(forget)
    case NSWorkspace.didActivateApplicationNotification:
      focusChanged()
      if let pid = app?.processIdentifier, silent.remove(pid) == nil { return }
    case NSWorkspace.activeSpaceDidChangeNotification:
      spaces.spaceChanged()
      onChange()
    case NSWorkspace.didLaunchApplicationNotification:
      if let pid = app?.processIdentifier { launched.insert(pid) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        self.everything = true
        self.schedule()
      }
    default: break
    }
    schedule()
  }

  /// Coalesces a burst of events into one reconcile.
  private func schedule() {
    guard started, !pending else { return }
    pending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      self.pending = false
      self.reconcile()
    }
  }

  private func observe(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard observers[pid] == nil else { return }
    var created: AXObserver?
    guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }
    let el = AXUIElementCreateApplication(pid)
    for name in [
      kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXWindowMovedNotification,
      kAXWindowResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ] {
      AXObserverAddNotification(observer, el, name as CFString, nil)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    observers[pid] = observer
  }

  private func identify(_ w: Win, _ app: NSRunningApplication) -> Int {
    if let id = ids[w] { return id }
    let id = (wins.keys.max() ?? 0) + 1
    ids[w] = id
    wins[id] = w
    names[id] = app.localizedName ?? "?"
    if born.remove(w) != nil || launched.contains(w.pid) { floatIfNew(id, w.pid) }
    if let o = observers[w.pid] { AXObserverAddNotification(o, w.el, kAXUIElementDestroyedNotification as CFString, nil) }
    return id
  }

  /// With `newWindows: float`, a new window stays as macOS opened it until asked into the layout.
  private func floatIfNew(_ id: Int, _ pid: pid_t) {
    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    if splitting {
      userTile.insert(id)
    } else if config.newWindows == "float", !config.tile.contains(bundle), !userTile.contains(id) {
      userFloat.insert(id)
    }
  }

  private func forget(_ w: Win) {
    guard let id = ids.removeValue(forKey: w) else { return }
    wins[id] = nil
    names[id] = nil
    userFloat.remove(id)
    userTile.remove(id)
    before[id] = nil
    stubborn.remove(id)
    settled[id] = nil
    trees.values.forEach { $0.remove(id) }
  }

  // MARK: reconcile

  private func shouldTile(_ w: Seen, _ app: NSRunningApplication) -> Bool {
    let id = w.id
    if w.fullscreen { return false }
    if userFloat.contains(id) { return false }
    if userTile.contains(id) { return true }
    if stubborn.contains(id) { return false }
    guard w.resizable else { return false }
    if config.tile.contains(app.bundleIdentifier ?? "") { return true }
    let name = app.localizedName ?? ""
    if config.float.contains(where: { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
      return false
    }
    // dialogs, sheets, panels and popovers stay where their app put them
    return w.standard
  }

  /// Brings the trees in line with the windows that exist right now, then lays out.
  /// The Accessibility API only lists windows on the visible Spaces, so trees for
  /// other Spaces are kept as they were until their Space is shown again.
  private func reconcile() {
    guard started, !paused, AXIsProcessTrusted() else { return }
    if dragged, NSEvent.pressedMouseButtons != 0 { return }  // mid-drag: the mouse coming up reconciles
    let t0 = Date()
    let (full, ask) = (everything, dirty)
    everything = false
    dirty = []
    active = spaces.active().map { screen, key in
      let orientation: Orientation = screen.frame.width >= screen.frame.height ? .h : .v
      let tree = trees[key] ?? Tree(orientation: orientation)
      tree.defaultOrientation = orientation
      trees[key] = tree
      return (screen, tree)
    }

    var home: [Int: Tree] = [:]
    appMs = [:]
    seen = [:]
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && !app.isHidden && !app.isTerminated
      && !silent.contains(app.processIdentifier)
    {
      let pid = app.processIdentifier
      if full || ask.contains(pid) || cache[pid] == nil {
        let asked = Date()
        defer { appMs[app.localizedName ?? "?"] = Date().timeIntervalSince(asked) * 1000 }
        observe(app)
        var list: CFTypeRef?
        let answer = AXUIElementCopyAttributeValue(
          AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &list)
        // a napping app (Mail in the background) costs the full timeout on every pass otherwise
        if answer == .cannotComplete { silent.insert(pid) }
        cache[pid] = (list as? [AXUIElement] ?? []).compactMap { el in
          let win = Win(el: el, pid: pid)
          let id = identify(win, app)
          guard let f = win.frame, win.get(kAXMinimizedAttribute) != true else { return nil }
          var resizable: DarwinBoolean = false
          AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &resizable)
          return (
            id, f, win.get("AXFullScreen") == true, resizable.boolValue,
            win.get(kAXSubroleAttribute) == kAXStandardWindowSubrole
          )
        }
      }
      for w in cache[pid] ?? [] {
        let (id, f) = (w.id, w.frame)
        if f.width > 100, f.height > 100 { seen[id] = f }  // for focus; not tooltips and the like
        guard shouldTile(w, app) else { continue }
        let centre = CGPoint(x: f.midX, y: f.midY)
        if let screen = NSScreen.screens.first(where: { $0.axFrame.contains(centre) }) {
          home[id] = active.first { $0.screen == screen }?.tree  // nil on a full-screen Space
        } else {
          home[id] = active.first?.tree  // stranded off every display: bring it back
        }
      }
    }

    // a workspace with tiling off keeps its tree as it was, for when tiling comes back
    for tree in trees.values where tree.enabled {
      let showing = active.contains { $0.tree === tree }
      // an app that stopped answering (Mail napping) keeps its tiles until it speaks again
      for id in tree.windows
      where home[id].map({ $0 !== tree }) ?? (showing && !silent.contains(wins[id]?.pid ?? 0)) { tree.remove(id) }
    }
    for (id, tree) in home.sorted(by: { $0.key < $1.key }) where tree.enabled {
      if splitting, let s = armed, s.tree === tree, !tree.contains(id), tree.contains(s.beside) {
        tree.split(s.beside, with: id, s.axis)
        armed = nil
      } else {
        tree.insert(id)
      }
    }
    if adopt {
      adopt = false
      adoptManualChanges()
    }
    relayout()

    let ms = Date().timeIntervalSince(t0) * 1000
    stats = (stats.count + 1, ms, max(stats.maxMs, ms))
  }

  /// After a mouse drag: a resized window keeps its new size (its neighbours
  /// give way), and a window dropped onto another trades places with it.
  private func adoptManualChanges() {
    if config.drag == "float" {
      // moved or resized by hand: the window is yours now, out of the layout at the frame you gave it
      for (_, tree) in active where tree.enabled {
        for id in tree.windows {
          guard let was = rects[id], let now = wins[id]?.frame,
            abs(now.minX - was.minX) > 5 || abs(now.minY - was.minY) > 5 || abs(now.width - was.width) > 5
              || abs(now.height - was.height) > 5
          else { continue }
          userTile.remove(id)
          userFloat.insert(id)
          tree.remove(id)
        }
      }
      return
    }
    for (_, tree) in active where tree.enabled {
      for id in tree.windows {
        guard let was = rects[id], let now = wins[id]?.frame else { continue }
        let dw = now.width - was.width
        let dh = now.height - was.height
        if abs(dw) > 5 { tree.resize(id, by: dw, inner: config.gaps.inner, axis: .h) }
        if abs(dh) > 5 { tree.resize(id, by: dh, inner: config.gaps.inner, axis: .v) }
        if abs(dw) > 5 || abs(dh) > 5 { continue }
        let centre = CGPoint(x: now.midX, y: now.midY)
        if let other = tree.windows.first(where: { $0 != id && rects[$0]?.contains(centre) == true }) {
          tree.swap(id, other)
          return
        }
      }
    }
  }

  /// A while after writing frames: a window that did not take the size it was
  /// given (System Settings has a fixed width) floats, or with `fixedSize: tile`
  /// keeps its place in the layout at whatever size it did take.
  private func checkWrites() {
    let asked = wrote
    wrote = [:]
    for (id, r) in asked {
      guard let now = wins[id]?.frame, abs(now.width - r.width) > 10 || abs(now.height - r.height) > 10 else { continue }
      if config.fixedSize == "tile" || userTile.contains(id) { settled[id] = (r, now) } else { stubborn.insert(id) }
      schedule()
    }
  }

  private func drawBorders() {
    let focused = focusedID()
    borders.update(
      config.style == "plain" ? [] : rects.map { ($0.value, $0.key == focused) }, config.border,
      glow: config.style == "shadow")
  }

  private func relayout() {
    rects = [:]
    let checking = !wrote.isEmpty
    for (screen, tree) in active where tree.enabled {
      for (id, exact) in tree.layout(in: screen.axVisibleFrame, gaps: config.gaps) {
        let r = CGRect(
          x: exact.minX.rounded(), y: exact.minY.rounded(), width: exact.width.rounded(),
          height: exact.height.rounded())
        rects[id] = r
        guard let w = wins[id], !silent.contains(w.pid), let now = w.frame else { continue }
        if let s = settled[id], s.asked == r, s.got == now {  // as close as this window gets
          rects[id] = now
          continue
        }
        // only write when something differs: no write, no echo, no fight
        if abs(now.minX - r.minX) > 1 || abs(now.minY - r.minY) > 1 || abs(now.width - r.width) > 1
          || abs(now.height - r.height) > 1
        {
          w.setFrame(r)
          wrote[id] = r
        }
      }
    }
    lastLayout = Date()
    drawBorders()
    if !checking, !wrote.isEmpty {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.checkWrites() }
    }
  }

  /// The workspace the user is in: the focused window's display, else the pointer's.
  private func currentTree() -> Tree? {
    var point = CGPoint(x: NSEvent.mouseLocation.x, y: NSScreen.screens[0].frame.maxY - NSEvent.mouseLocation.y)
    if let f = focusedID().flatMap({ wins[$0]?.frame }) { point = CGPoint(x: f.midX, y: f.midY) }
    return (active.first { $0.screen.axFrame.contains(point) } ?? active.first)?.tree
  }

  var tilingHere: Bool { currentTree()?.enabled ?? true }
  /// Whether the focused window is in the layout; nil when no known window has focus.
  var focusedTiled: Bool? { focusedID().map { id in trees.values.contains { $0.contains(id) } } }

  // MARK: focus

  private func focusedID() -> Int? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let app = Win(el: AXUIElementCreateApplication(pid), pid: pid)
    guard let el: AXUIElement = app.get(kAXFocusedWindowAttribute) else { return nil }
    return ids[Win(el: el, pid: pid)]
  }

  private func focusChanged() {
    guard !paused, let id = focusedID(), let f = wins[id]?.frame else { return }
    // mid-split, picking a window that is already open (from the Dock, Cmd-Tab) brings it in
    if splitting, let s = armed, id != s.beside, !s.tree.contains(id) {
      userFloat.remove(id)
      stubborn.remove(id)
      userTile.insert(id)
      schedule()
    }
    for tree in trees.values where tree.contains(id) { tree.focused = id }
    drawBorders()
    let centre = CGPoint(x: f.midX, y: f.midY)
    guard let screen = NSScreen.screens.first(where: { $0.axFrame.contains(centre) }), screen != lastScreen else { return }
    let first = lastScreen == nil
    lastScreen = screen
    onChange()
    // lazily: only when the pointer isn't on that monitor already
    if !first, !screen.frame.contains(NSEvent.mouseLocation) {
      CGWarpMouseCursorPosition(CGPoint(x: screen.axFrame.midX, y: screen.axFrame.midY))
    }
  }

  private func activate(_ id: Int) {
    guard let w = wins[id] else { return }
    AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(w.el, kAXMainAttribute as CFString, kCFBooleanTrue)
    // through Accessibility rather than NSRunningApplication.activate(), which
    // macOS may ignore when the caller is a background app
    AXUIElementSetAttributeValue(
      AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
  }

  // MARK: commands

  /// Runs one AeroSpace-style command, e.g. "focus left" or "resize smart -50".
  func run(_ command: String) {
    let a = command.split(separator: " ").map(String.init)
    let dir = a.last.flatMap(Direction.init)
    let n = a.last.flatMap { Int($0) }
    let id = focusedID()
    let tree = id.flatMap { id in active.first { $0.tree.enabled && $0.tree.contains(id) }?.tree }

    switch a.first {
    case "mode":
      mode = a.last ?? "main"
      bind()
    case "press":
      Hotkeys.press(a.last ?? "")  // for testing: a key combination typed by the app itself
    case "enable-desktop-shortcuts":
      spaces.enableShortcuts()
      onChange()
    case "reload-config":
      reload()
    case "tiling":
      // off: this workspace is plain macOS until toggled back; windows stay where they are
      currentTree()?.enabled.toggle()
      schedule()
      onChange()
    case "workspace":
      if let n {
        goTo(n)
      } else if let now = spaces.current, spaces.desktops > 0, let step = ["next": 1, "prev": -1][a.last ?? ""] {
        goTo((now - 1 + step + spaces.desktops) % spaces.desktops + 1)
      }
    case "split":
      // the focused window gives up half its tile to whatever is opened or picked next
      guard let id, let tree else { break }
      armed = (id, tree, a.last == "down" ? .v : .h, Date())
      Hotkeys.press(config.launcher)
    case "workspace-back-and-forth":
      if let p = spaces.previous { goTo(p) }
    case "move-node-to-workspace":
      if let n, let f = id.flatMap({ wins[$0]?.frame }), !spaces.carry(f, to: n) { shortcutMissing(n) }
    case "move-workspace-to-monitor":
      // macOS has no public way to move a Space between displays, and Mission Control
      // lifts a desktop for a synthetic drag but won't take the drop on another
      // display (tried on 27.2): the tiled windows go instead
      guard let here = currentTree(), let i = active.firstIndex(where: { $0.tree === here }), active.count > 1
      else { break }
      for w in here.windows {
        here.remove(w)
        active[(i + 1) % active.count].tree.insert(w)
      }
      relayout()
    case "focus":
      // floating windows count too; a tiled one wins where they overlap
      if let dir, let from = id.flatMap({ seen[$0] }) {
        if let to = nearest(from: from, dir, in: rects) ?? nearest(from: from, dir, in: seen) { activate(to) }
      } else if let to = currentTree()?.focused ?? seen.keys.min() {
        // nothing focused here (the front app's windows are on another desktop): take any window
        activate(to)
      }
    case "snap":
      // Rectangle's named places. A tiled window leaves the layout to take one.
      guard let id, let w = wins[id], let f = w.frame,
        let screen = NSScreen.screens.first(where: { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) })
      else { break }
      if a.last == "restore" {
        if let was = before.removeValue(forKey: id) { w.setFrame(was) }
        break
      }
      guard let r = place(a.last ?? "", in: usable(screen), inner: config.gaps.inner, size: f.size) else { break }
      if before[id] == nil { before[id] = f }
      if tree != nil {
        userTile.remove(id)
        userFloat.insert(id)
        schedule()
      }
      w.setFrame(r)
    case "move" where tree == nil:
      // a floating window steps through halves and quarters, then on to the next display
      guard let dir, let w = id.flatMap({ wins[$0] }), let f = w.frame,
        let screen = NSScreen.screens.first(where: { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) })
      else { break }
      let others = Dictionary(uniqueKeysWithValues: NSScreen.screens.indices.map { ($0, NSScreen.screens[$0].axFrame) })
      let next = nearest(from: screen.axFrame, dir, in: others).map { usable(NSScreen.screens[$0]) }
      if before[id!] == nil { before[id!] = f }
      w.setFrame(snap(f, in: usable(screen), dir, inner: config.gaps.inner, next: next))
    case "fullscreen" where tree == nil:
      // a floating window fills its display; again puts it back
      guard let id, let w = wins[id], let f = w.frame,
        let screen = NSScreen.screens.first(where: { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) })
      else { break }
      let full = usable(screen)
      if abs(f.width - full.width) < 20, abs(f.height - full.height) < 20, let was = before[id] {
        w.setFrame(was)
      } else {
        before[id] = f
        w.setFrame(full)
      }
    case "layout" where a.contains("floating"):
      guard let id else { break }
      if tree != nil {
        userTile.remove(id)
        userFloat.insert(id)
      } else {
        userFloat.remove(id)
        stubborn.remove(id)
        userTile.insert(id)
      }
      schedule()
    default:
      guard let id, let tree else { break }
      switch a.first {
      case "move":
        guard let dir else { break }
        if !tree.move(id, dir) { send([id], from: tree, toward: dir) }
      case "join-with":
        if let dir { _ = tree.join(id, dir) }
      case "resize":
        tree.resize(id, by: CGFloat(n ?? 0), inner: config.gaps.inner)
      case "layout":
        tree.cycle(id, a.contains("accordion") ? .accordion : .tiles)
      case "fullscreen":
        tree.zoomed = tree.zoomed == id ? nil : id
        activate(id)
      case "flatten-workspace-tree":
        tree.flatten()
      case "close-all-windows-but-current":
        // presses each window's own close button, so apps still ask about unsaved work
        for other in tree.windows where other != id {
          if let button: AXUIElement = wins[other]?.get(kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
          }
        }
      default:
        problems.append("unknown command: \(command)")
      }
      relayout()
    }
  }

  /// A display's area for windows: below the menu bar, clear of the Dock, inside the outer gaps.
  private func usable(_ screen: NSScreen) -> CGRect {
    let g = config.gaps, r = screen.axVisibleFrame
    return CGRect(
      x: r.minX + g.left, y: r.minY + g.top, width: r.width - g.left - g.right, height: r.height - g.top - g.bottom)
  }

  /// At the edge of a workspace, "move" carries on to the monitor in that direction.
  private func send(_ windows: [Int], from tree: Tree, toward dir: Direction) {
    guard let here = active.first(where: { $0.tree === tree })?.screen else { return }
    let frames = Dictionary(uniqueKeysWithValues: active.indices.map { ($0, active[$0].screen.axFrame) })
    guard let i = nearest(from: here.axFrame, dir, in: frames) else { return }
    for w in windows {
      tree.remove(w)
      active[i].tree.insert(w)
    }
  }

  private func goTo(_ n: Int) {
    if !spaces.switchTo(n) { shortcutMissing(n) }
    onChange()
  }

  private func shortcutMissing(_: Int) {
    NSSound.beep()
    onShortcutMissing()
  }

  private func bind() {
    let table = paused ? [:] : config.modes[mode] ?? [:]
    let refused = hotkeys.set(
      table.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { key, commands in
        // hop off the Carbon callback first: a "mode" command re-registers every hotkey
        (key, { DispatchQueue.main.async { commands.forEach(self.run) } })
      })
    problems.removeAll { $0.hasPrefix("could not register") }
    if !refused.isEmpty { problems.append("could not register: \(refused.joined(separator: ", "))") }
    onChange()
  }

  // MARK: diagnostics

  func diagnostics() -> String {
    var out = [
      "tilespace on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
      "accessibility granted: \(AXIsProcessTrusted()), paused: \(paused), mode: \(mode)",
      spaces.describe(),
      "reconciles: \(stats.count), last \(String(format: "%.1f", stats.lastMs)) ms, slowest \(String(format: "%.1f", stats.maxMs)) ms",
      "windows known: \(wins.count), floated for refusing their tile: \(stubborn.compactMap { names[$0] }), apps observed: \(observers.count), Spaces with a tree: \(trees.count)",
    ]
    out.append(
      "slowest apps to answer: "
        + appMs.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \(String(format: "%.1f", $0.value)) ms" }
        .joined(separator: ", "))
    out += problems.map { "problem: \($0)" }
    for (screen, tree) in active {
      out.append(
        "\(screen.localizedName) \(screen.axVisibleFrame): \(tree.enabled ? "\(tree.windows.count) tiled" : "tiling off")")
      for id in tree.windows {
        out.append("  \(names[id] ?? "?") \(rects[id].map { "\($0)" } ?? "-")\(tree.focused == id ? " [focused]" : "")")
      }
    }
    return out.joined(separator: "\n") + "\n"
  }
}
