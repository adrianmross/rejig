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
    // Assistive tools (Shortcat, VoiceOver) switch this on, and apps then animate
    // every resize themselves, slowly. Off while we write.
    let app = AXUIElementCreateApplication(pid)
    var enhanced: CFTypeRef?
    AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &enhanced)
    let wasEnhanced = enhanced as? Bool == true
    if wasEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
    // each write is a visible step, so only the ones that change something
    let now = frame
    let resize = now.map { abs($0.width - r.width) > 1 || abs($0.height - r.height) > 1 } ?? true
    if now.map({ abs($0.minX - r.minX) > 1 || abs($0.minY - r.minY) > 1 }) ?? true {
      AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, p)
    }
    if resize {
      AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, s)
      // a window can't outgrow its display, so the size may only have taken once it had moved; and
      // growing can push it back off the edge
      if let got = frame, abs(got.minX - r.minX) > 1 || abs(got.minY - r.minY) > 1 {
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, s)
      }
    }
    if wasEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
  }
}

extension NSScreen {
  /// Frames in Accessibility coordinates: origin at the primary display's top-left.
  func flipped(_ r: CGRect) -> CGRect {
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
  let agentScreen = AgentScreen()
  var agentTiling = false  // `agent-screen tile`: lay out the agent screen too, for demos and films
  var parked: [Int: CGRect] = [:]  // windows on the agent screen, and the frame each left behind
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
  var onRun: (String) -> Void = { _ in }  // every command, for the welcome's checklist
  var intercept: (String) -> Bool = { _ in false }  // the welcome's basics keep commands off the user's windows
  var onSplit: (() -> Void)?  // what fills the new half, in place of the launcher
  /// The welcome's practice windows are ours; while they are up, our own app is managed like any other.
  var practising = false {
    didSet {
      if !practising { ids.keys.filter { $0.pid == getpid() }.forEach(forget) }
      cache[getpid()] = nil
      everything = true
      schedule()
    }
  }
  var problems: [String] = []

  var config = Config()
  let hotkeys = Hotkeys()
  var started = false
  var ids: [Win: Int] = [:]
  var wins: [Int: Win] = [:]
  var names: [Int: String] = [:]
  var userFloat = Set<Int>()
  var userTile = Set<Int>()
  // `hold`: never tiled, resized or focused by us (a window an agent is filming), with who holds it
  var ignored: [Int: String] = [:] {
    // a hold that is over no longer waits on its Rex session
    didSet { for id in waiting.keys where ignored[id] == nil { waiting.removeValue(forKey: id)?.terminate() } }
  }
  var waiting: [Int: Process] = [:]  // `rex wait`, one per window held for a Rex session
  var held: [String] { ignored.values.sorted() }
  /// Things scripts can listen for (`rejig subscribe`): a name and a JSON-able payload.
  var onEvent: (String, [String: Any]) -> Void = { _, _ in }
  var numbers: [Int: CGWindowID] = [:]  // CGWindowIDs already worked out, for events
  var opened: [Int] = []  // new this reconcile, announced at its end
  var announced: Int?  // the window the last focus-changed event named
  var desktop: [Int: Int] = [:]  // the desktop each window was last seen on, or was sent to
  var before: [Int: CGRect] = [:]  // a window's frame before it was first snapped, for "snap restore"
  // `split` was just pressed: the next window to appear or be chosen lands beside this one
  var armed: (beside: Int, tree: Tree, axis: Orientation, at: Date)?
  var splitting: Bool { armed.map { Date().timeIntervalSince($0.at) < 30 } ?? false }
  // what each app last said about its windows; only apps that raised an event are asked again
  typealias Seen = (id: Int, frame: CGRect, fullscreen: Bool, resizable: Bool, standard: Bool)
  var cache: [pid_t: [Seen]] = [:]
  var dirty = Set<pid_t>()
  var everything = true  // ask every app: Space, display or configuration changed
  var born = Set<Win>()  // just created, not yet numbered
  var launched = Set<pid_t>()  // apps started after us: all their windows are new
  var stubborn = Set<Int>()  // refused their tile (fixed or minimum size): floated
  var wrote: [Int: CGRect] = [:]  // frames asked for, awaiting a check
  var settled: [Int: (asked: CGRect, got: CGRect)] = [:]  // fixed-size windows kept in the layout
  var seen: [Int: CGRect] = [:]  // every window on the visible Spaces, tiled or not
  var adopt = false  // a manual drag just ended: take its result into the layout
  let borders = Borders()
  var lit: CGRect?  // the focused window's mark, as last drawn
  var pressed = false  // the button is down where the marked window keeps its close and minimize
  var leavingID: Int?  // which window that was
  var litID: Int?  // the window wearing the mark
  var leaving = Date.distantPast  // when a window was last seen starting to close or minimize
  var trees: [Int: Tree] = [:]  // by Space marker
  var active: [(screen: NSScreen, tree: Tree)] = []
  var rects: [Int: CGRect] = [:]
  var observers: [pid_t: AXObserver] = [:]
  var pending = false
  var dragged = false
  var snappedTo: [Int: CGRect] = [:]  // where a snap last put a window, to know it is still there
  let windowManager = UserDefaults(suiteName: "com.apple.WindowManager")  // Stage Manager's switches
  var draggedID: Int?  // the window being moved by its title bar
  var drop: String?  // the place it would snap to if let go now
  let footprint = Footprint()
  var putOff = false  // a reconcile was put off until the mouse button comes up
  var followDrop = false  // the next reconcile follows a drop: focus goes with a window that changed display
  var lastLayout = Date.distantPast
  var lastScreen: NSScreen?  // the display with keyboard focus
  var stats = (count: 0, lastMs: 0.0, maxMs: 0.0)
  var appMs: [String: Double] = [:]  // time spent asking each app, last reconcile
  // too slow to answer on the main thread: asked in the background instead, and not laid out meanwhile
  var silent = Set<pid_t>()
  var probing = Set<pid_t>()  // being asked in the background right now
  // While the screen is locked Accessibility says a window exists but not where it is, so
  // nothing can be laid out, found by number or moved: we wait, and say so when asked.
  var locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true

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
      self.spaces.hiddenDisplay = self.agentScreen.uuid  // and the desktop numbers are worked out again
      self.everything = true
      self.schedule()
      self.onChange()
    }
    for (name, state) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
      DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
        [unowned self] _ in
        self.locked = state
        self.silent = []
        self.everything = true
        self.schedule()
        self.onEvent(state ? "screen-locked" : "screen-unlocked", [:])
      }
    }
    // a manual drag or resize is left alone until the button comes up
    // a window dragged to a screen edge or corner: show where it would land
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [unowned self] _ in
      guard self.config.edgeSnap, !self.paused, self.draggedID != nil else { return }
      let p = NSEvent.mouseLocation
      guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) else { return }
      let f = screen.frame
      // an edge with another display beyond it is a way through, not a wall
      func wall(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        !NSScreen.screens.contains { $0.frame.contains(CGPoint(x: p.x + dx, y: p.y + dy)) }
      }
      let left = p.x <= f.minX + 3 && wall(-8, 0), right = p.x >= f.maxX - 4 && wall(8, 0)
      let top = p.y >= f.maxY - 4 && wall(0, 8), bottom = p.y <= f.minY + 3 && wall(0, -8)
      let high = p.y > f.maxY - 120, low = p.y < f.minY + 120, west = p.x < f.minX + 120, east = p.x > f.maxX - 120
      var place: String?
      if (left && high) || (top && west) { place = "top-left" }
      else if (right && high) || (top && east) { place = "top-right" }
      else if (left && low) || (bottom && west) { place = "bottom-left" }
      else if (right && low) || (bottom && east) { place = "bottom-right" }
      else if left { place = "left-half" }
      else if right { place = "right-half" }
      else if top { place = "maximize" }
      guard place != self.drop else { return }
      self.drop = place
      if place != nil, self.config.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
      self.footprint.show(place.flatMap { TileCore.place($0, in: self.usable(screen), inner: self.config.gaps.inner, size: .zero) })
    }
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [unowned self] _ in
      if let place = self.drop, let id = self.draggedID {
        self.footprint.show(nil)
        // run() wants the window server's number, not ours; a dragged window nearly always has focus anyway
        let number = self.windowNumbers().first { $0.value == id }?.key
        self.run("snap \(place)" + (number.map { " --window-id \($0)" } ?? ""))
      }
      self.drop = nil
      self.draggedID = nil
      if self.dragged {
        self.dragged = false
        self.adopt = true
        self.schedule()
      }
      if self.putOff {
        self.putOff = false
        // not at once: a window dropped on another desktop is still on its way there
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          self.everything = true
          self.followDrop = true
          self.schedule()
        }
      }
      // a click where the marked window keeps its close and minimize buttons: take the mark off now,
      // ahead of the animation. If the window stays after all, the mark is back within a second.
      // ponytail: by position, not by asking which button it was; a click there on anything else blinks the mark
      let at = CGPoint(x: NSEvent.mouseLocation.x, y: NSScreen.screens[0].frame.maxY - NSEvent.mouseLocation.y)
      if let lit = self.lit, CGRect(x: lit.minX, y: lit.minY, width: 64, height: 34).contains(at) {
        self.unmark()
      } else if self.pressed {
        self.drawBorders()  // let go somewhere else: the mark is back
      }
      self.pressed = false
    }
    // and already on the way down, so the mark is gone before the window starts to move
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [unowned self] _ in
      let at = CGPoint(x: NSEvent.mouseLocation.x, y: NSScreen.screens[0].frame.maxY - NSEvent.mouseLocation.y)
      // the same for its edges, where a resize starts
      guard let lit = self.lit, lit.insetBy(dx: -8, dy: -8).contains(at),
        CGRect(x: lit.minX, y: lit.minY, width: 64, height: 34).contains(at) || !lit.insetBy(dx: 8, dy: 8).contains(at)
      else { return }
      self.pressed = true
      self.borders.dim()
    }
    // Command-M: the same, for a window minimized from the keyboard
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [unowned self] e in
      if e.keyCode == 46, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command { self.unmark() }
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

  /// Reads the config file. `changedOnly` is for Settings, which saves on every click: only what the
  /// change touches is redone, so a menu bar switch doesn't re-register every key and re-ask every app.
  func reload(changedOnly: Bool = false) {
    let old = config
    let (loaded, error) = Config.load()
    config = loaded
    problems = error.map { [$0] } ?? []
    // what the layout depends on, as text: a few of these types have no == of their own
    func layout(_ c: Config) -> String {
      "\(c.gaps) \(c.float) \(c.tile) \(c.fixedSize) \(c.newWindows) \(c.drag) \(c.unmanagedDisplays)"
    }
    if !changedOnly || old.modes != config.modes { bind() }
    if !changedOnly || layout(old) != layout(config) {
      everything = true
      stubborn = []  // fixedSize may have changed: judge every window afresh
      settled = [:]
      schedule()
    } else {
      drawBorders()
      onChange()
    }
  }

  /// One of our own windows opened or closed: nothing tells us, since we don't watch ourselves until asked.
  func look() {
    cache[getpid()] = nil
    everything = true
    schedule()
  }

  // MARK: events

  func axEvent(_ el: AXUIElement, _ name: String) {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    silent.remove(pid)
    dirty.insert(pid)
    switch name {
    case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
      // closed, or minimized from the keyboard: nothing of it should stay drawn while we catch up
      let id = ids[Win(el: el, pid: pid)]
      if let id { rects[id] = nil }
      if name == kAXUIElementDestroyedNotification { forget(Win(el: el, pid: pid)) }
      unmark(id ?? 0)
    case kAXWindowMovedNotification, kAXWindowResizedNotification:
      if NSEvent.pressedMouseButtons != 0 {
        // the mark comes off a window being dragged: once, and without asking the app anything mid-drag
        if !dragged { borders.dim() }
        dragged = true
        if name == kAXWindowMovedNotification, draggedID == nil {
          draggedID = ids[Win(el: el, pid: pid)]
          // a snapped window pulled away takes back the size it had, under the pointer where it was held
          if config.restoreOnDrag, let id = draggedID, let to = snappedTo.removeValue(forKey: id),
            let was = before.removeValue(forKey: id), let w = wins[id], let f = w.frame,
            abs(f.width - to.width) < 20, abs(f.height - to.height) < 20
          {
            let x = NSEvent.mouseLocation.x
            w.setFrame(CGRect(x: x - was.width * (x - f.minX) / f.width, y: f.minY, width: was.width, height: was.height))
          }
        }
      } else if Date().timeIntervalSince(lastLayout) > 0.5 {  // not the echo of our own write
        schedule()
      }
    case kAXFocusedWindowChangedNotification:
      focusChanged()
    case kAXWindowCreatedNotification:
      let w = Win(el: el, pid: pid)
      if born.count > 100 { born = [] }  // ponytail: created things that never became windows (popovers) pile up here
      if let id = ids[w] { floatIfNew(id, pid) } else { born.insert(w) }
      // not at once: the app is busy opening it, and asking now slows the opening. Then once more when it
      // has settled, since apps often size a window just after creating it
      for wait in [0.25, 0.8] {
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
          self.dirty.insert(pid)
          self.schedule()
        }
      }
    default:
      schedule()
    }
  }

  func workspaceEvent(_ note: Notification) {
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
      // what was marked belongs to the desktop just left: gone now, redrawn for this one in a moment
      rects = [:]
      seen = [:]
      drawBorders()
      onChange()
      onEvent(
        "workspace-changed",
        ["visible": spaces.shown.map { ["display": $0.key.localizedName, "number": $0.value] as [String: Any] }])
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
  func schedule() {
    guard started, !pending else { return }
    pending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      self.pending = false
      self.reconcile()
    }
  }

  func observe(_ app: NSRunningApplication) {
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

  func identify(_ w: Win, _ app: NSRunningApplication) -> Int {
    if let id = ids[w] { return id }
    let id = (wins.keys.max() ?? 0) + 1
    ids[w] = id
    wins[id] = w
    names[id] = app.localizedName ?? "?"
    opened.append(id)
    if born.remove(w) != nil || launched.contains(w.pid) || w.pid == getpid() { floatIfNew(id, w.pid) }
    if let o = observers[w.pid] { AXObserverAddNotification(o, w.el, kAXUIElementDestroyedNotification as CFString, nil) }
    return id
  }

  /// With `newWindows: float`, a new window stays as macOS opened it until asked into the layout.
  func floatIfNew(_ id: Int, _ pid: pid_t) {
    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    if splitting {
      userTile.insert(id)
    } else if pid == getpid() || config.newWindows == "float" && !config.tile.contains(bundle) && !userTile.contains(id) {
      // a practice window always floats: it sits on top of the user's layout, not in it
      userFloat.insert(id)
    }
  }

  func forget(_ w: Win) {
    guard let id = ids.removeValue(forKey: w) else { return }
    onEvent("window-closed", ["id": numbers[id].map { Int($0) as Any } ?? NSNull(), "pid": Int(w.pid), "app": names[id] ?? ""])
    numbers[id] = nil
    if ignored.removeValue(forKey: id) != nil { onChange() }
    parked[id] = nil
    wins[id] = nil
    names[id] = nil
    userFloat.remove(id)
    userTile.remove(id)
    desktop[id] = nil
    before[id] = nil
    stubborn.remove(id)
    settled[id] = nil
    trees.values.forEach { $0.remove(id) }
  }

  // MARK: reconcile

  func shouldTile(_ w: Seen, _ app: NSRunningApplication) -> Bool {
    let id = w.id
    if w.fullscreen { return false }
    if userFloat.contains(id) { return false }
    if userTile.contains(id) { return true }
    // a menu-bar-only app's window can be focused, snapped and put in the layout by hand, never tiled unasked
    if app.activationPolicy != .regular, app.processIdentifier != getpid() { return false }
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

  /// Displays left entirely alone: the agent screen, and any the config names.
  func unmanaged(_ screen: NSScreen) -> Bool {
    screen.localizedName == AgentScreen.name ? !agentTiling : config.unmanagedDisplays.contains(screen.localizedName)
  }

  /// Ends a hold: the window is ours to manage again, back where it was if it had been put on the agent screen.
  func free(_ id: Int) {
    ignored[id] = nil
    if let was = parked.removeValue(forKey: id) { wins[id]?.setFrame(was) }
  }

  typealias Raw = (el: AXUIElement, frame: CGRect, fullscreen: Bool, resizable: Bool, standard: Bool)

  /// An app's windows, straight from Accessibility. `patience` is how many seconds
  /// it gets to answer when the usual quarter second was not enough.
  static func ask(_ pid: pid_t, patience: Float? = nil) -> (error: AXError, windows: [Raw], ms: Double) {
    let asked = Date()
    let app = AXUIElementCreateApplication(pid)
    if let patience { AXUIElementSetMessagingTimeout(app, patience) }
    var list: CFTypeRef?
    var error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list)
    let windows: [Raw] = (list as? [AXUIElement] ?? []).compactMap { el in
      if let patience { AXUIElementSetMessagingTimeout(el, patience) }
      defer { if patience != nil { AXUIElementSetMessagingTimeout(el, 0) } }  // back to the usual for later use
      let win = Win(el: el, pid: pid)
      if win.get(kAXMinimizedAttribute) == true { return nil }
      guard let f = win.frame else {
        error = .cannotComplete  // listed its window but not where it is: as good as no answer
        return nil
      }
      var resizable: DarwinBoolean = false
      AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &resizable)
      return (
        el, f, win.get("AXFullScreen") == true, resizable.boolValue,
        win.get(kAXSubroleAttribute) == kAXStandardWindowSubrole
      )
    }
    return (error, windows, Date().timeIntervalSince(asked) * 1000)
  }

  /// Settings is open: a window of ours the focus keys should reach like any other.
  var ownWindows: Bool { NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.resizable) } }

  func adopt(_ windows: [Raw], _ app: NSRunningApplication) -> [Seen] {
    let pid = app.processIdentifier
    // of our own windows only Settings and the practice ones count: not the welcome, the borders or the markers
    return windows.filter { pid != getpid() || $0.resizable && $0.standard }.map {
      (identify(Win(el: $0.el, pid: pid), app), $0.frame, $0.fullscreen, $0.resizable, $0.standard)
    }
  }

  /// Asks a slow app off the main thread, with patience. Its windows become
  /// known, to list and to hold; it rejoins the layout once it answers promptly.
  func probe(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard probing.insert(pid).inserted else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let answer = Manager.ask(pid, patience: 3)
      DispatchQueue.main.async {
        self.probing.remove(pid)
        guard answer.error != .cannotComplete, !app.isTerminated else { return }
        self.cache[pid] = self.adopt(answer.windows, app)
        if answer.ms < 250 {
          self.silent.remove(pid)
          self.observe(app)
        }
        self.schedule()
      }
    }
  }

  /// Brings the trees in line with the windows that exist right now, then lays out.
  /// The Accessibility API only lists windows on the visible Spaces, so trees for
  /// other Spaces are kept as they were until their Space is shown again.
  func reconcile() {
    guard started, !paused, !locked, AXIsProcessTrusted() else { return }
    // while a mouse button is held nothing is laid out: a window may be mid-drag, on the desktop or in
    // Mission Control, and writing its frame then pulls it out of the user's hand. The button coming up reconciles.
    if NSEvent.pressedMouseButtons != 0 {
      putOff = true
      return
    }
    let t0 = Date()
    let (full, ask) = (everything, dirty)
    everything = false
    dirty = []
    active = spaces.active().filter { !unmanaged($0.0) }.map { screen, key in
      let orientation: Orientation = screen.frame.width >= screen.frame.height ? .h : .v
      let tree = trees[key] ?? Tree(orientation: orientation)
      tree.defaultOrientation = orientation
      trees[key] = tree
      return (screen, tree)
    }

    var home: [Int: Tree] = [:]
    appMs = [:]
    seen = [:]
    // a menu-bar-only app is asked only while the window server shows a window of its own: most never have one
    let windowed = Set(
      (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap {
        w -> pid_t? in
        guard w[kCGWindowLayer as String] as? Int == 0,
          let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
          b.width > 100, b.height > 100
        else { return nil }
        return w[kCGWindowOwnerPID as String] as? pid_t
      })
    let apps = NSWorkspace.shared.runningApplications.filter {
      ($0.processIdentifier == getpid()
        ? practising || ownWindows
        : $0.activationPolicy == .regular
          || $0.activationPolicy == .accessory && windowed.contains($0.processIdentifier)) && !$0.isHidden
        && !$0.isTerminated && !silent.contains($0.processIdentifier)
    }
    // the apps that need asking are asked all at once: the wait is the slowest of them, not their sum
    let stale = apps.filter { full || ask.contains($0.processIdentifier) || cache[$0.processIdentifier] == nil }
    let pids = stale.map(\.processIdentifier)
    var answers = [(error: AXError, windows: [Raw], ms: Double)](repeating: (.success, [], 0), count: pids.count)
    answers.withUnsafeMutableBufferPointer { out in
      DispatchQueue.concurrentPerform(iterations: pids.count) { i in
        // our own app answers on the main thread, which is waiting here: asked below instead
        if pids[i] != getpid() { out[i] = Manager.ask(pids[i]) }
      }
    }
    if let i = pids.firstIndex(of: getpid()) { answers[i] = Manager.ask(getpid()) }
    for (app, answer) in zip(stale, answers) {
      let pid = app.processIdentifier
      appMs[app.localizedName ?? "?"] = answer.ms
      // an app that can't answer in time (napping, still starting, or the Mac is busy) would cost the
      // full timeout on every pass, and again per notification if observed: what we knew of it is
      // kept, and it is asked again in the background
      if answer.error == .cannotComplete {
        silent.insert(pid)
        probe(app)
        continue
      }
      observe(app)
      cache[pid] = adopt(answer.windows, app)
    }
    if full {
      for app in NSWorkspace.shared.runningApplications where silent.contains(app.processIdentifier) { probe(app) }
    }
    for app in apps {
      let pid = app.processIdentifier
      for w in cache[pid] ?? [] {
        let (id, f) = (w.id, w.frame)
        let centre = CGPoint(x: f.midX, y: f.midY)
        let on = NSScreen.screens.first { $0.axFrame.contains(centre) }
        if let n = on.flatMap({ spaces.shown[$0] }) { desktop[id] = n }
        if ignored[id] != nil { continue }
        // for focus; not tooltips and the like, nor the Finder's desktop, which covers a display, menu bar and all
        if f.width > 100, f.height > 100, w.fullscreen || on.map({ f.height < $0.frame.height }) ?? true { seen[id] = f }
        guard shouldTile(w, app) else { continue }
        if let screen = on {
          home[id] = active.first { $0.screen == screen }?.tree  // nil on a full-screen Space
        } else {
          home[id] = active.first?.tree  // stranded off every display: bring it back
        }
      }
    }

    // a window the user just dropped on another display (in Mission Control, say) takes the focus with it
    let dropped = followDrop ? home.first { id, to in trees.values.contains { $0 !== to && $0.contains(id) } }?.key : nil
    followDrop = false
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
    if let dropped { activate(dropped) }

    if !opened.isEmpty {
      for (n, id) in windowNumbers() { numbers[id] = n }
      for id in opened where wins[id] != nil { onEvent("window-opened", describe(id)) }
      opened = []
    }
    let ms = Date().timeIntervalSince(t0) * 1000
    stats = (stats.count + 1, ms, max(stats.maxMs, ms))
  }

  /// After a mouse drag: a resized window keeps its new size (its neighbours
  /// give way), and a window dropped onto another trades places with it.
  func adoptManualChanges() {
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
  func checkWrites() {
    let asked = wrote
    wrote = [:]
    for (id, r) in asked {
      guard let now = wins[id]?.frame, abs(now.width - r.width) > 10 || abs(now.height - r.height) > 10 else { continue }
      if config.fixedSize == "tile" || userTile.contains(id) { settled[id] = (r, now) } else { stubborn.insert(id) }
      schedule()
    }
  }

  /// Drops the focused window's mark at once, then looks again when things have settled.
  func unmark(_ id: Int? = nil) {
    leaving = Date()
    leavingID = id ?? litID
    // drawn before anything is asked of the app: it answers nothing until its animation is over
    lit = nil
    borders.update(config.style == "plain" ? [] : rects.map { ($0.value, false) }, config.border, glow: config.style == "shadow")
    borders.dim()
    // told by the app that it is gone: lay out now. Otherwise it is busy animating and would only keep us waiting
    if id != nil { schedule() }
    for wait in [0.7, 1.55] { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.schedule() } }
  }

  func drawBorders() {
    // a window on its way out (closing, minimizing) loses its mark at once, not when its animation ends
    // by window, and for as long as the slowest animation: macOS still calls it focused on the way down
    let front = focusedID()
    let focused = front == leavingID && Date().timeIntervalSince(leaving) < 1.5 ? nil : front
    var marked = rects.map { ($0.value, $0.key == focused) }
    // a floating window is marked too while it has focus: it is in front then, so its outline covers
    // nothing. Not mid-drag, when its frame is ahead of what we know; and only a real window, not a
    // preview or a panel, which come and go faster than we hear of it.
    if let focused, rects[focused] == nil, seen[focused] != nil, !dragged, ignored[focused] == nil, let w = wins[focused],
      let known = cache[w.pid]?.first(where: { $0.id == focused }), known.standard, !known.fullscreen,
      let f = w.frame, f.width > 100, f.height > 100,
      // not the Finder's desktop, a window too: it covers a whole display, menu bar and all, where a
      // zoomed window stops under the menu bar
      !NSScreen.screens.contains(where: { f.width >= $0.frame.width && f.height >= $0.frame.height })
    {
      marked.append((f, true))
    }
    lit = marked.first { $0.1 }?.0
    litID = lit == nil ? nil : focused
    borders.update(config.style == "plain" ? [] : marked, config.border, glow: config.style == "shadow")
  }

  func relayout() {
    rects = [:]
    let checking = !wrote.isEmpty
    for (screen, tree) in active where tree.enabled {
      for (id, exact) in tree.layout(in: workArea(screen), gaps: config.gaps) {
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
  func currentTree() -> Tree? {
    var point = CGPoint(x: NSEvent.mouseLocation.x, y: NSScreen.screens[0].frame.maxY - NSEvent.mouseLocation.y)
    if let f = focusedID().flatMap({ wins[$0]?.frame }) { point = CGPoint(x: f.midX, y: f.midY) }
    return (active.first { $0.screen.axFrame.contains(point) } ?? active.first)?.tree
  }

  var tilingHere: Bool { currentTree()?.enabled ?? true }
  /// Whether the focused window is in the layout; nil when no known window has focus.
  var focusedTiled: Bool? { focusedID().map { id in trees.values.contains { $0.contains(id) } } }

  // MARK: focus

  func focusedID() -> Int? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let app = Win(el: AXUIElementCreateApplication(pid), pid: pid)
    guard let el: AXUIElement = app.get(kAXFocusedWindowAttribute) else { return nil }
    return ids[Win(el: el, pid: pid)]
  }

  func focusChanged() {
    guard !paused, let id = focusedID(), let f = wins[id]?.frame else { return }
    // mid-split, picking a window that is already open (from the Dock, Cmd-Tab) brings it in
    if splitting, let s = armed, id != s.beside, !s.tree.contains(id) {
      userFloat.remove(id)
      stubborn.remove(id)
      userTile.insert(id)
      schedule()
    }
    for tree in trees.values where tree.contains(id) { tree.focused = id }
    if id != announced {
      announced = id
      onEvent("focus-changed", describe(id))
    }
    drawBorders()
    let centre = CGPoint(x: f.midX, y: f.midY)
    guard let screen = NSScreen.screens.first(where: { $0.axFrame.contains(centre) }), screen != lastScreen else { return }
    let first = lastScreen == nil
    lastScreen = screen
    onChange()
    // lazily: only when the pointer isn't on that monitor already
    if !first, !screen.frame.contains(NSEvent.mouseLocation), !unmanaged(screen) {
      CGWarpMouseCursorPosition(CGPoint(x: screen.axFrame.midX, y: screen.axFrame.midY))
    }
  }

  func activate(_ id: Int) {
    guard let w = wins[id] else { return }
    AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(w.el, kAXMainAttribute as CFString, kCFBooleanTrue)
    // through Accessibility rather than NSRunningApplication.activate(), which
    // macOS may ignore when the caller is a background app
    AXUIElementSetAttributeValue(
      AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
  }

  // MARK: diagnostics

  func diagnostics() -> String {
    var out = [
      "rejig on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
      "accessibility granted: \(AXIsProcessTrusted()), paused: \(paused), mode: \(mode), screen locked: \(locked)",
      spaces.describe(),
      "reconciles: \(stats.count), last \(String(format: "%.1f", stats.lastMs)) ms, slowest \(String(format: "%.1f", stats.maxMs)) ms",
      "apps too slow to answer: \(silent.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName }.sorted())",
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
