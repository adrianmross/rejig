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
    // every resize themselves, slowly. Off while we write, as Rectangle does.
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
  let agentScreen = AgentScreen()
  private var agentTiling = false  // `agent-screen tile`: lay out the agent screen too, for demos and films
  private var parked: [Int: CGRect] = [:]  // windows on the agent screen, and the frame each left behind
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
  private(set) var problems: [String] = []

  private(set) var config = Config()
  private let hotkeys = Hotkeys()
  private var started = false
  private var ids: [Win: Int] = [:]
  private var wins: [Int: Win] = [:]
  private var names: [Int: String] = [:]
  private var userFloat = Set<Int>()
  private var userTile = Set<Int>()
  // `hold`: never tiled, resized or focused by us (a window an agent is filming), with who holds it
  private var ignored: [Int: String] = [:] {
    // a hold that is over no longer waits on its Rex session
    didSet { for id in waiting.keys where ignored[id] == nil { waiting.removeValue(forKey: id)?.terminate() } }
  }
  private var waiting: [Int: Process] = [:]  // `rex wait`, one per window held for a Rex session
  var held: [String] { ignored.values.sorted() }
  /// Things scripts can listen for (`rejig subscribe`): a name and a JSON-able payload.
  var onEvent: (String, [String: Any]) -> Void = { _, _ in }
  private var numbers: [Int: CGWindowID] = [:]  // CGWindowIDs already worked out, for events
  private var opened: [Int] = []  // new this reconcile, announced at its end
  private var announced: Int?  // the window the last focus-changed event named
  private var desktop: [Int: Int] = [:]  // the desktop each window was last seen on, or was sent to
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
  private var lit: CGRect?  // the focused window's mark, as last drawn
  private var leaving = Date.distantPast  // when a window was last seen starting to close or minimize
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
  // too slow to answer on the main thread: asked in the background instead, and not laid out meanwhile
  private var silent = Set<pid_t>()
  private var probing = Set<pid_t>()  // being asked in the background right now
  // While the screen is locked Accessibility says a window exists but not where it is, so
  // nothing can be laid out, found by number or moved: we wait, and say so when asked.
  private var locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true

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
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [unowned self] _ in
      if self.dragged {
        self.dragged = false
        self.adopt = true
        self.schedule()
      }
      // a click where the marked window keeps its close and minimize buttons: take the mark off now,
      // ahead of the animation. If the window stays after all, the mark is back within a second.
      // ponytail: by position, not by asking which button it was; a click there on anything else blinks the mark
      let at = CGPoint(x: NSEvent.mouseLocation.x, y: NSScreen.screens[0].frame.maxY - NSEvent.mouseLocation.y)
      if let lit = self.lit, CGRect(x: lit.minX, y: lit.minY, width: 64, height: 34).contains(at) { self.unmark() }
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
    case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
      // closed, or minimized from the keyboard: nothing of it should stay drawn while we catch up
      if let id = ids[Win(el: el, pid: pid)] { rects[id] = nil }
      if name == kAXUIElementDestroyedNotification { forget(Win(el: el, pid: pid)) }
      unmark()
    case kAXWindowMovedNotification, kAXWindowResizedNotification:
      if NSEvent.pressedMouseButtons != 0 {
        dragged = true
        drawBorders()  // the mark comes off a window being dragged
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
    opened.append(id)
    if born.remove(w) != nil || launched.contains(w.pid) || w.pid == getpid() { floatIfNew(id, w.pid) }
    if let o = observers[w.pid] { AXObserverAddNotification(o, w.el, kAXUIElementDestroyedNotification as CFString, nil) }
    return id
  }

  /// With `newWindows: float`, a new window stays as macOS opened it until asked into the layout.
  private func floatIfNew(_ id: Int, _ pid: pid_t) {
    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    if splitting {
      userTile.insert(id)
    } else if pid == getpid() || config.newWindows == "float" && !config.tile.contains(bundle) && !userTile.contains(id) {
      // a practice window always floats: it sits on top of the user's layout, not in it
      userFloat.insert(id)
    }
  }

  private func forget(_ w: Win) {
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

  /// Displays left entirely alone: the agent screen, and any the config names.
  private func unmanaged(_ screen: NSScreen) -> Bool {
    screen.localizedName == AgentScreen.name ? !agentTiling : config.unmanagedDisplays.contains(screen.localizedName)
  }

  /// Ends a hold: the window is ours to manage again, back where it was if it had been put on the agent screen.
  private func free(_ id: Int) {
    ignored[id] = nil
    if let was = parked.removeValue(forKey: id) { wins[id]?.setFrame(was) }
  }

  private typealias Raw = (el: AXUIElement, frame: CGRect, fullscreen: Bool, resizable: Bool, standard: Bool)

  /// An app's windows, straight from Accessibility. `patience` is how many seconds
  /// it gets to answer when the usual quarter second was not enough.
  private static func ask(_ pid: pid_t, patience: Float? = nil) -> (error: AXError, windows: [Raw], ms: Double) {
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

  private func adopt(_ windows: [Raw], _ app: NSRunningApplication) -> [Seen] {
    let pid = app.processIdentifier
    // of our own windows only the practice ones count: not the welcome, the borders or the markers
    return windows.filter { pid != getpid() || $0.resizable && $0.standard }.map {
      (identify(Win(el: $0.el, pid: pid), app), $0.frame, $0.fullscreen, $0.resizable, $0.standard)
    }
  }

  /// Asks a slow app off the main thread, with patience. Its windows become
  /// known, to list and to hold; it rejoins the layout once it answers promptly.
  private func probe(_ app: NSRunningApplication) {
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
  private func reconcile() {
    guard started, !paused, !locked, AXIsProcessTrusted() else { return }
    if dragged, NSEvent.pressedMouseButtons != 0 { return }  // mid-drag: the mouse coming up reconciles
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
    let apps = NSWorkspace.shared.runningApplications.filter {
      ($0.activationPolicy == .regular || practising && $0.processIdentifier == getpid()) && !$0.isHidden
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
        if f.width > 100, f.height > 100 { seen[id] = f }  // for focus; not tooltips and the like
        guard shouldTile(w, app) else { continue }
        if let screen = on {
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

  /// Drops the focused window's mark at once, then looks again when things have settled.
  private func unmark() {
    leaving = Date()
    drawBorders()
    schedule()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { self.schedule() }
  }

  private func drawBorders() {
    // a window on its way out (closing, minimizing) loses its mark at once, not when its animation ends
    let focused = Date().timeIntervalSince(leaving) < 0.6 ? nil : focusedID()
    var marked = rects.map { ($0.value, $0.key == focused) }
    // a floating window is marked too while it has focus: it is in front then, so its outline covers
    // nothing. Not mid-drag, when its frame is ahead of what we know.
    if let focused, rects[focused] == nil, !dragged, ignored[focused] == nil, let w = wins[focused],
      cache[w.pid]?.first(where: { $0.id == focused })?.fullscreen != true, let f = w.frame, f.width > 100, f.height > 100
    {
      marked.append((f, true))
    }
    lit = marked.first { $0.1 }?.0
    borders.update(config.style == "plain" ? [] : marked, config.border, glow: config.style == "shadow")
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

  /// Our windows by CGWindowID, the number `--window-id` and screen capture use.
  // ponytail: matched by owning app and frame, because the one direct link
  // (_AXUIElementGetWindow) is private; two windows of one app at exactly the
  // same frame can't be told apart.
  private func windowNumbers() -> [CGWindowID: Int] {
    // asked afresh, except of slow apps, whose windows count at the frame last heard
    var frames = wins.filter { !silent.contains($0.value.pid) }.compactMapValues(\.frame)
    for w in cache.values.joined() where frames[w.id] == nil { frames[w.id] = w.frame }
    var out: [CGWindowID: Int] = [:]
    var taken = Set<Int>()
    for w in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    where w[kCGWindowLayer as String] as? Int == 0 {
      guard let n = w[kCGWindowNumber as String] as? CGWindowID, let pid = w[kCGWindowOwnerPID as String] as? pid_t,
        let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
        let id = frames.first(where: { id, f in
          !taken.contains(id) && wins[id]?.pid == pid && abs(f.minX - b.minX) < 2 && abs(f.minY - b.minY) < 2
            && abs(f.width - b.width) < 2 && abs(f.height - b.height) < 2
        })?.key
      else { continue }
      out[n] = id
      taken.insert(id)
    }
    return out
  }

  /// A window as events name it.
  private func describe(_ id: Int) -> [String: Any] {
    if numbers[id] == nil { for (n, id) in windowNumbers() { numbers[id] = n } }
    let w = wins[id]
    let title: String? = w.flatMap { silent.contains($0.pid) ? nil : $0.get(kAXTitleAttribute) }
    return [
      "id": numbers[id].map { Int($0) as Any } ?? NSNull(), "pid": Int(w?.pid ?? 0), "app": names[id] ?? "",
      "title": title ?? "",
    ]
  }

  private func json(_ value: Any) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  }

  /// Takes window `id` to desktop `n`; `then` hears nil, or why it did not get there.
  private func carry(_ id: Int, to n: Int, then: @escaping (String?) -> Void) {
    guard let w = wins[id], let f = w.frame else { return then("no such window") }
    let here = NSScreen.screens.first { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) }
    if let here, spaces.shown[here] == n { return then(nil) }  // already there
    if let there = spaces.shown.first(where: { $0.value == n })?.key {
      // showing on another display: no Space has to change, the window is just put there
      let u = usable(there)
      let size = CGSize(width: min(f.width, u.width), height: min(f.height, u.height))
      w.setFrame(CGRect(x: u.midX - size.width / 2, y: u.midY - size.height / 2, width: size.width, height: size.height))
      desktop[id] = n
      everything = true
      schedule()
      return then(nil)
    }
    guard spaces.shortcut(n) != nil else {
      shortcutMissing(n)
      return then("the Switch to Desktop \(n) shortcut is off")
    }
    activate(id)  // its title bar has to be on top to be held
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      let started = self.spaces.carry(w.frame ?? f, to: n) { moved in
        if moved {
          self.desktop[id] = n
          w.setFrame(f)  // the carry dragged it a little: back to the frame it had
        }
        then(moved ? nil : "the window did not go to workspace \(n)")
      }
      if !started { then("another window is being moved") }
    }
  }

  /// Where the user was, for commands that travel and must leave no trace. Calling
  /// the result goes back there; `then` hears nil, or where it ended up instead.
  private func bookmark() -> (@escaping (String?) -> Void) -> Void {
    let screen = lastScreen ?? NSScreen.screens.first
    let (n, focus, pointer) = (screen.flatMap { spaces.shown[$0] }, focusedID(), CGEvent(source: nil)?.location)
    let (current, previous) = (spaces.current, spaces.previous)
    return { then in
      let settle = {
        if let focus { self.activate(focus) }
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        (self.spaces.current, self.spaces.previous) = (current, previous)  // back-and-forth is the user's
        let at = screen.flatMap { self.spaces.shown[$0] }
        then(n == nil || at == n ? nil : "ended on workspace \(at.map(String.init) ?? "?") instead of \(n!)")
      }
      guard let n, screen.flatMap({ self.spaces.shown[$0] }) != n else { return settle() }
      // macOS drops a desktop shortcut pressed while the last slide is still settling: wait, and try twice
      func go(_ tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          let sent = self.spaces.switchTo(n) { arrived in arrived || tries == 0 ? settle() : go(tries - 1) }
          if !sent { settle() }
        }
      }
      go(1)
    }
  }

  /// Runs one AeroSpace-style command, e.g. "focus left" or "resize smart -50".
  /// `reply` hears how it went, once it is over: false comes with the reason,
  /// true with any output. Flags: `--window-id <CGWindowID>` acts on that window
  /// instead of the focused one.
  func run(_ command: String, caller: pid_t = 0, reply: @escaping (Bool, String) -> Void = { _, _ in }) {
    if locked, !["list-workspaces", "reload-config", "mode", "agent-screen"].contains(command.split(separator: " ").first.map(String.init)) {
      return reply(false, "the screen is locked: windows can't be found or moved until it is unlocked")
    }
    if intercept(command) { return reply(true, "") }
    onRun(command)
    var a = command.split(separator: " ").map(String.init)
    var flags: [String: String] = [:]
    while let i = a.firstIndex(where: { $0.hasPrefix("--") && $0 != "--wrap-around" }) {
      let name = a.remove(at: i)
      flags[name] = ["--window-id", "--frame", "--workspace", "--by", "--owner-pid", "--rex-session"].contains(name) && i < a.count ? a.remove(at: i) : ""
    }
    let dir = a.last.flatMap(Direction.init)
    let n = a.last.flatMap { Int($0) }
    var id = focusedID()
    if let wanted = flags["--window-id"] {
      id = UInt32(wanted).flatMap { windowNumbers()[$0] }
      // not one we know: its app may have just opened it, or not answered when last asked. Ask now.
      if id == nil, let number = UInt32(wanted),
        let owner = (CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]])?.first?[
          kCGWindowOwnerPID as String] as? pid_t
      {
        // ponytail: waits on the main thread, up to 3 s for a slow app; only for a window named on purpose
        let answer = Manager.ask(owner, patience: 3)
        if answer.error != .cannotComplete, let app = NSRunningApplication(processIdentifier: owner) {
          cache[owner] = adopt(answer.windows, app)
          schedule()
        }
        id = windowNumbers()[number]
      }
      // `fetch` looks again once it is on the window's workspace
      if id == nil, a.first != "fetch" { return reply(false, "no such window: \(wanted)") }
    }
    if let label = flags["--rex-session"], flags["--window-id"] == nil {
      // Rex titles its macOS windows "<tab> - <session label>"
      // ponytail: by title, so only windows Rejig has watched; ask Rex for the window if it ever exposes one
      id = wins.first { id, w in
        names[id] == "Rex" && !silent.contains(w.pid) && (w.get(kAXTitleAttribute) as String?)?.hasSuffix(" - \(label)") == true
      }?.key
      if id == nil { return reply(false, "no Rex window showing session \(label) that Rejig has seen") }
    }
    let tree = id.flatMap { id in active.first { $0.tree.enabled && $0.tree.contains(id) }?.tree }
    // answered at the end unless a case takes it (nil) to answer later
    var result: (Bool, String)? = (true, "")
    defer { if let result { reply(result.0, result.1) } }

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
    case "workspace", "workspace-back-and-forth":
      var to = a.first == "workspace" ? n : spaces.previous
      if to == nil, let now = spaces.current, spaces.desktops > 0, let step = ["next": 1, "prev": -1][a.last ?? ""] {
        to = (now - 1 + step + spaces.desktops) % spaces.desktops + 1
      }
      guard let to else {
        result = (false, "no workspace to go to")
        break
      }
      if spaces.switchTo(to, then: { reply($0, $0 ? "" : "workspace \(to) did not appear") }) {
        result = nil
      } else {
        shortcutMissing(to)
        result = (false, "the Switch to Desktop \(to) shortcut is off")
      }
      onChange()
    case "split":
      // the focused window gives up half its tile to whatever is opened or picked next
      guard let id, let tree else { break }
      armed = (id, tree, a.last == "down" ? .v : .h, Date())
      if let onSplit { onSplit() } else { Hotkeys.press(config.launcher) }
    case "move-node-to-workspace":
      // --stay: the window goes, the user's workspace, focus and pointer come back
      guard let n, let id else {
        result = (false, "no window to move")
        break
      }
      result = nil
      let back = flags["--stay"] != nil ? bookmark() : { $0(nil) }
      carry(id, to: n) { error in back { reply(error ?? $0 == nil, error ?? $0 ?? "") } }
    case "fetch":
      // a window on a workspace that is not showing: go there, take it, come back with it
      guard let wanted = flags["--window-id"].flatMap({ UInt32($0) }),
        let home = (lastScreen ?? NSScreen.screens.first).flatMap({ spaces.shown[$0] })
      else {
        result = (false, "usage: fetch --window-id ID [--workspace N]")
        break
      }
      guard let from = flags["--workspace"].flatMap({ Int($0) }) ?? spaces.desktop(of: wanted) ?? id.flatMap({ desktop[$0] })
      else {
        result = (false, "which workspace is it on? pass --workspace N")
        break
      }
      let back = bookmark()
      let went = spaces.switchTo(from) { _ in
        // Accessibility only lists windows on showing Spaces: look again now that it is one
        self.everything = true
        self.reconcile()
        guard let id = self.windowNumbers()[wanted] else {
          return back { _ in reply(false, "no window \(wanted) on workspace \(from)") }
        }
        if !self.userTile.contains(id) { self.userFloat.insert(id) }  // it arrives as it is, not into the layout
        self.carry(id, to: home) { error in back { reply(error ?? $0 == nil, error ?? $0 ?? "") } }
      }
      result = went ? nil : (false, "the Switch to Desktop \(from) shortcut is off")
    case "hold", "ignore":
      // an agent takes a window: we never tile, resize or focus it until it is released.
      // `--by reel` names the holder, for the menu; `--workspace N` also sends it there, the user staying put
      guard let id else {
        result = (false, "no window to hold")
        break
      }
      var name = [CChar](repeating: 0, count: 256)
      let process = caller > 0 && proc_name(caller, &name, 256) > 0 ? String(cString: name) : "a script"
      // while the agent screen is being tiled, for a demo or a film, a window already there stays in its layout
      if flags["--agent-screen"] != nil, agentTiling, let f = wins[id]?.frame,
        agentScreen.screen?.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) == true
      {
        break
      }
      ignored[id] = flags["--by"] ?? flags["--rex-session"].map { "Rex session \($0)" } ?? process
      // the hold ends with whoever asked for it: a process, or a Rex session
      let letGo = { [unowned self] in
        guard self.ignored[id] != nil else { return }
        self.free(id)
        self.everything = true
        self.schedule()
        self.onChange()
        self.onEvent("held-changed", ["held": self.ignored.count])
      }
      if let pid = flags["--owner-pid"].flatMap({ pid_t($0) }) {
        guard kill(pid, 0) == 0 else {
          ignored[id] = nil
          result = (false, "no process \(pid) to hold it for")
          break
        }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler {
          exit.cancel()
          letGo()
        }
        exit.resume()
      }
      if let label = flags["--rex-session"] {
        // `rex wait` returns when the session ends
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        wait.arguments = ["-lc", "rex wait '\(label.replacingOccurrences(of: "'", with: "'\\''"))'"]
        wait.terminationHandler = { p in if p.terminationStatus == 0 { DispatchQueue.main.async(execute: letGo) } }
        try? wait.run()
        waiting[id] = wait
      }
      everything = true
      schedule()
      onChange()
      onEvent("held-changed", ["held": ignored.count])
      if flags["--agent-screen"] != nil {
        // onto the display with no monitor: no desktop slides, and release puts it back
        guard agentScreen.create() else {
          result = (false, "macOS would not make the agent screen")
          break
        }
        guard let w = wins[id], let f = w.frame ?? cache[w.pid]?.first(where: { $0.id == id })?.frame else {
          result = (false, "the window's app is not answering; try again")
          break
        }
        result = nil
        func park(_ tries: Int) {
          guard let area = agentScreen.screen?.axFrame else {
            // the screen list catches up a moment after the display is made
            if tries > 0 { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { park(tries - 1) } }
            return reply(false, "the agent screen did not appear")
          }
          if parked[id] == nil { parked[id] = f }
          let size = CGSize(width: min(f.width, area.width - 80), height: min(f.height, area.height - 80))
          let step = CGFloat(parked.count - 1) * 30
          lastLayout = Date()
          w.setFrame(CGRect(origin: CGPoint(x: area.minX + 40 + step, y: area.minY + 40 + step), size: size))
          schedule()
          onChange()
          reply(true, "")
        }
        park(10)
      } else if let n = flags["--workspace"].flatMap({ Int($0) }) {
        result = nil
        let back = bookmark()
        carry(id, to: n) { error in back { reply(error ?? $0 == nil, error ?? $0 ?? "") } }
      }
    case "release", "unignore":
      if flags["--window-id"] != nil || flags["--rex-session"] != nil, let id { free(id) } else { ignored.keys.forEach(free) }
      everything = true
      schedule()
      onChange()
      onEvent("held-changed", ["held": ignored.count])
    case "agent-screen":
      // makes it if need be and says where it is; "show" opens the viewer; "off" brings everything back and removes it
      switch a.last {
      case "off":
        parked.keys.forEach(free)
        agentTiling = false
        agentScreen.remove()
        onChange()
      case "tile":
        // windows there are laid out like on any display: for showing Rejig at work where nobody is working
        guard agentScreen.create() else {
          result = (false, "macOS would not make the agent screen")
          break
        }
        agentTiling = true
        everything = true
        schedule()
        onChange()
      case "show":
        guard agentScreen.create() else {
          result = (false, "macOS would not make the agent screen")
          break
        }
        agentScreen.show()
        onChange()
      default:
        guard agentScreen.create() else {
          result = (false, "macOS would not make the agent screen")
          break
        }
        result = nil
        onChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
          guard let screen = self.agentScreen.screen else { return reply(false, "the agent screen did not appear") }
          let f = screen.axFrame
          reply(
            true,
            self.json([
              "display": AgentScreen.name, "x": f.minX, "y": f.minY, "w": f.width, "h": f.height,
              "workspace": self.spaces.shown[screen].map { $0 as Any } ?? NSNull(),
            ]))
        }
      }
    case "style":
      // "highlight", "shadow" or "plain", until the config is next read: for trying one, or for a film
      config.style = a.last ?? config.style
      relayout()
    case "list-windows":
      let numbers = Dictionary(windowNumbers().map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
      let visible = Set(cache.values.joined().map(\.id))
      let known: [[String: Any]] =
          wins.keys.sorted().filter { numbers[$0] != nil || silent.contains(wins[$0]!.pid) == false }.map { id -> [String: Any] in
            let w = wins[id]!
            let f = silent.contains(w.pid) ? cache[w.pid]?.first { $0.id == id }?.frame : w.frame
            let screen = f.flatMap { f in NSScreen.screens.first { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) } }
            let title: String? = silent.contains(w.pid) ? nil : w.get(kAXTitleAttribute)
            return [
              "id": numbers[id].map { Int($0) as Any } ?? NSNull(), "pid": Int(w.pid), "app": names[id] ?? "",
              "title": title ?? "",
              "workspace": (numbers[id].flatMap { spaces.desktop(of: $0) } ?? desktop[id]).map { $0 as Any } ?? NSNull(),
              "display": screen.map { $0.localizedName as Any } ?? NSNull(), "visible": visible.contains(id),
              "frame": f.map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] as Any } ?? NSNull(),
              "state": ignored[id] != nil ? "held" : trees.values.contains { $0.contains(id) } ? "tiled" : "floating",
              "heldBy": ignored[id].map { $0 as Any } ?? NSNull(),
              "focused": id == focusedID(),
            ]
          }
      // windows on desktops that are not showing are beyond Accessibility, so Rejig may never have
      // met them (after a restart, say): listed from the window server, with what it knows
      let met = Set(numbers.values)
      let unseen: [[String: Any]] = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { w in
          guard w[kCGWindowLayer as String] as? Int == 0,
            let n = w[kCGWindowNumber as String] as? CGWindowID, !met.contains(n),
            let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
            NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
            let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
            b.width > 100, b.height > 100, w[kCGWindowAlpha as String] as? Double != 0
          else { return nil }
          return [
            "id": Int(n), "pid": Int(pid), "app": w[kCGWindowOwnerName as String] as? String ?? "", "title": "",
            "workspace": spaces.desktop(of: n).map { $0 as Any } ?? NSNull(), "display": NSNull(),
            "visible": w[kCGWindowIsOnscreen as String] as? Bool == true,
            "state": "unseen", "heldBy": NSNull(),
            "focused": false, "frame": ["x": b.minX, "y": b.minY, "w": b.width, "h": b.height],
          ]
        }
      result = (true, json(known + unseen))
    case "list-workspaces":
      let focused = lastScreen ?? NSScreen.screens.first
      result = (
        true,
        json(
          spaces.ranges.flatMap { screen, range in
            range.map { n -> [String: Any] in
              let showing = spaces.shown[screen] == n
              return ["number": n, "display": screen.localizedName, "visible": showing, "focused": showing && screen == focused]
            }
          }.sorted { ($0["number"] as! Int) < ($1["number"] as! Int) })
      )
    case "move" where flags["--frame"] != nil:
      // an exact frame, in screen points from the main display's top-left; the window floats to take it
      let v = flags["--frame"]!.split(separator: ",").compactMap { Double($0) }
      guard let id, let w = wins[id], v.count == 4 else {
        result = (false, "usage: move --frame x,y,w,h [--window-id ID]")
        break
      }
      let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
      userTile.remove(id)
      userFloat.insert(id)
      trees.values.forEach { $0.remove(id) }
      // a window still opening, or a display only just connected, can ignore the first write: try a few times
      result = nil
      func attempt(_ left: Int) {
        lastLayout = Date()
        w.setFrame(r)
        guard let got = w.frame, abs(got.minX - r.minX) > 2 || abs(got.minY - r.minY) > 2 || abs(got.width - r.width) > 2
            || abs(got.height - r.height) > 2
        else {
          schedule()
          return reply(true, "")
        }
        if left > 0 { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { attempt(left - 1) } }
        schedule()
        reply(false, "the window took \(Int(got.minX)),\(Int(got.minY)),\(Int(got.width)),\(Int(got.height)) instead")
      }
      attempt(4)
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
      // tiled and floating windows alike: whichever lies nearest that way
      if let dir, let from = id.flatMap({ seen[$0] }) {
        if let to = nearest(from: from, dir, in: seen) { activate(to) }
      } else if dir == nil, flags["--window-id"] != nil || flags["--rex-session"] != nil, let id {
        activate(id)  // a window named on purpose, and no direction: that window
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
        if let was = before.removeValue(forKey: id) { glide(w, from: f, to: was) }
        break
      }
      guard let r = place(a.last ?? "", in: usable(screen), inner: config.gaps.inner, size: f.size) else {
        result = (false, "no such place: \(a.last ?? "")")
        break
      }
      if before[id] == nil { before[id] = f }
      if tree != nil {
        userTile.remove(id)
        userFloat.insert(id)
        schedule()
      }
      glide(w, from: f, to: r)
    case "move" where tree == nil:
      // a floating window steps through halves and quarters, then on to the next display
      guard let dir, let id, let w = wins[id], let f = w.frame,
        let screen = NSScreen.screens.first(where: { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) })
      else { break }
      let others = Dictionary(uniqueKeysWithValues: NSScreen.screens.indices.map { ($0, NSScreen.screens[$0].axFrame) })
      let next = nearest(from: screen.axFrame, dir, in: others).map { usable(NSScreen.screens[$0]) }
      if before[id] == nil { before[id] = f }
      glide(w, from: f, to: snap(f, in: usable(screen), dir, inner: config.gaps.inner, next: next))
    case "fullscreen" where tree == nil:
      // a floating window fills its display; again puts it back
      guard let id, let w = wins[id], let f = w.frame,
        let screen = NSScreen.screens.first(where: { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) })
      else { break }
      let full = usable(screen)
      if abs(f.width - full.width) < 20, abs(f.height - full.height) < 20, let was = before[id] {
        glide(w, from: f, to: was)
      } else {
        before[id] = f
        glide(w, from: f, to: full)
      }
    case "layout" where a.contains("floating"):
      guard let id else {
        result = (false, "no window")
        break
      }
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
      let tiled = ["move", "join-with", "resize", "layout", "fullscreen", "flatten-workspace-tree", "close-all-windows-but-current"]
      guard let id, let tree else {
        result = (false, tiled.contains(a.first ?? "") ? "no tiled window to act on" : "unknown command: \(command)")
        break
      }
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
        result = (false, "unknown command: \(command)")
      }
      relayout()
    }
  }

  /// Moves a floating window to `to` over a few frames, the way macOS's own tiling does.
  private func glide(_ w: Win, from: CGRect, to: CGRect) {
    guard config.animate else {
      w.setFrame(to)
      return drawBorders()
    }
    let steps = 6
    for i in 1...steps {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) {
        let t = 1 - pow(1 - CGFloat(i) / CGFloat(steps), 3)  // ease out
        self.lastLayout = Date()  // these are our writes, not the user's
        if i == steps { DispatchQueue.main.async { self.drawBorders() } }  // the mark follows the window
        w.setFrame(
          i == steps
            ? to
            : CGRect(
              x: from.minX + (to.minX - from.minX) * t, y: from.minY + (to.minY - from.minY) * t,
              width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t))
      }
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

  private func shortcutMissing(_: Int) {
    NSSound.beep()
    onShortcutMissing()
  }

  private func bind() {
    let table = paused ? [:] : config.modes[mode] ?? [:]
    let refused = hotkeys.set(
      table.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { key, commands in
        // hop off the Carbon callback first: a "mode" command re-registers every hotkey
        (key, { DispatchQueue.main.async { commands.forEach { self.run($0) } } })
      })
    problems.removeAll { $0.hasPrefix("could not register") }
    if !refused.isEmpty { problems.append("could not register: \(refused.joined(separator: ", "))") }
    onChange()
  }

  func note(_ problem: String) {
    if !problems.contains(problem) { problems.append(problem) }
    onChange()
  }

  func resolve(_ about: String) {
    problems.removeAll { $0.contains(about) }
    onChange()
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
