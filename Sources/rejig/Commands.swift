import AppKit
import TileCore

/// What Rejig can be told to do: the hotkeys, the menu and the control socket all end in `run`.
extension Manager {
  /// Our windows by CGWindowID, the number `--window-id` and screen capture use.
  // ponytail: matched by owning app and frame, because the one direct link
  // (_AXUIElementGetWindow) is private; two windows of one app at exactly the
  // same frame can't be told apart.
  func windowNumbers() -> [CGWindowID: Int] {
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
  func describe(_ id: Int) -> [String: Any] {
    if numbers[id] == nil { for (n, id) in windowNumbers() { numbers[id] = n } }
    let w = wins[id]
    let title: String? = w.flatMap { silent.contains($0.pid) ? nil : $0.get(kAXTitleAttribute) }
    return [
      "id": numbers[id].map { Int($0) as Any } ?? NSNull(), "pid": Int(w?.pid ?? 0), "app": names[id] ?? "",
      "title": title ?? "",
    ]
  }

  func json(_ value: Any) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  }

  /// Takes window `id` to desktop `n`; `then` hears nil, or why it did not get there.
  func carry(_ id: Int, to n: Int, then: @escaping (String?) -> Void) {
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
  func bookmark() -> (@escaping (String?) -> Void) -> Void {
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
        // the marks belong to the desktop being left: off before the slide, not after it
        rects = [:]
        seen = [:]
        drawBorders()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.schedule() }  // back, if nothing changed after all
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
        let existed = agentScreen.exists
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
              "display": AgentScreen.name, "x": f.minX, "y": f.minY, "w": f.width, "h": f.height, "new": !existed,
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
      if let dir, let id, let from = seen[id] {
        if let to = nearest(from: from, dir, in: seen) {
          activate(to)
        } else {
          // nothing that way. A window lying over or under this one has no direction to it: step through those
          let over = seen.filter { $0.key != id && $0.value.intersects(from) }.keys.sorted()
          if let to = over.first(where: { $0 > id }) ?? over.first { activate(to) }
        }
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
        snappedTo[id] = nil
        if let was = before.removeValue(forKey: id) { glide(w, from: f, to: was) }
        break
      }
      let area = usable(screen)
      func at(_ name: String) -> CGRect? { place(name, in: area, inner: config.gaps.inner, size: f.size) }
      var name = a.last ?? ""
      // pressed again where the window already is, a half goes on to two thirds, then a third, then round
      if config.cycle, name == "left-half" || name == "right-half" {
        let sizes = [name, name.replacingOccurrences(of: "half", with: "two-thirds"), name.replacingOccurrences(of: "half", with: "third")]
        let here = sizes.firstIndex {
          at($0).map { abs($0.minX - f.minX) < 20 && abs($0.width - f.width) < 20 && abs($0.height - f.height) < 20 } ?? false
        }
        if let here { name = sizes[(here + 1) % sizes.count] }
      }
      // the full height, where it stands
      let to = name == "maximize-height" ? CGRect(x: f.minX, y: area.minY, width: f.width, height: area.height) : at(name)
      guard let r = to else {
        result = (false, "no such place: \(name)")
        break
      }
      if before[id] == nil { before[id] = f }
      snappedTo[id] = r
      if tree != nil {
        userTile.remove(id)
        userFloat.insert(id)
        schedule()
      }
      glide(w, from: f, to: r)
    case "resize" where tree == nil:
      // a floating window grows or shrinks about its centre, within its display
      guard let id, let w = wins[id], let f = w.frame, let n,
        let screen = NSScreen.screens.first(where: { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) })
      else { break }
      let r = f.insetBy(dx: -CGFloat(n) / 2, dy: -CGFloat(n) / 2).intersection(usable(screen))
      if r.width >= 200, r.height >= 150 { glide(w, from: f, to: r) }
    case "move-to-display":
      // next or prev, left to right and round again
      guard let id, let w = wins[id], let f = w.frame else { break }
      let screens = NSScreen.screens.filter { !unmanaged($0) }.sorted { $0.frame.minX < $1.frame.minX }
      guard screens.count > 1, let i = screens.firstIndex(where: { $0.axFrame.contains(CGPoint(x: f.midX, y: f.midY)) })
      else {
        result = (false, "no other display")
        break
      }
      let to = screens[(i + (a.last == "prev" ? screens.count - 1 : 1)) % screens.count]
      var r = f
      if let tree, let target = active.first(where: { $0.screen == to })?.tree, target.enabled {
        tree.remove(id)
        target.insert(id)
        relayout()
        r = rects[id] ?? f
      } else {
        // the same place on the other display, in proportion
        let from = usable(screens[i]), into = usable(to)
        let (sx, sy) = (into.width / from.width, into.height / from.height)
        r = CGRect(
          x: into.minX + (f.minX - from.minX) * sx, y: into.minY + (f.minY - from.minY) * sy, width: f.width * sx,
          height: f.height * sy)
        w.setFrame(r)
        schedule()
      }
      if config.cursorFollows { CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: r.midY)) }
    case "stack":
      // windows piled on the same spot, as snapping several to one place leaves them: next or prev of the pile
      guard let id, let f = seen[id] else { break }
      let pile = seen.filter {
        abs($0.value.minX - f.minX) < 20 && abs($0.value.minY - f.minY) < 20 && abs($0.value.width - f.width) < 20
          && abs($0.value.height - f.height) < 20
      }.keys.sorted()
      if pile.count > 1, let i = pile.firstIndex(of: id) {
        activate(pile[(i + (a.last == "prev" ? pile.count - 1 : 1)) % pile.count])
      }
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
  func glide(_ w: Win, from: CGRect, to: CGRect) {
    guard config.animate else {
      w.setFrame(to)
      return drawBorders()
    }
    borders.dim()  // the mark waits for the window to arrive rather than chase it
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

  /// Below the menu bar and clear of the Dock; and of Stage Manager's strip, when asked and it is showing.
  func workArea(_ screen: NSScreen) -> CGRect {
    let r = screen.axVisibleFrame, strip = config.stageStrip
    guard strip > 0, windowManager?.bool(forKey: "GloballyEnabled") == true, windowManager?.bool(forKey: "AutoHide") != true
    else { return r }
    // the strip is on the left, or on the right when the Dock has the left
    let dockLeft = screen.visibleFrame.minX > screen.frame.minX
    return CGRect(x: r.minX + (dockLeft ? 0 : strip), y: r.minY, width: r.width - strip, height: r.height)
  }

  /// A display's area for windows: below the menu bar, clear of the Dock, inside the outer gaps.
  func usable(_ screen: NSScreen) -> CGRect {
    let g = config.gaps, r = workArea(screen)
    return CGRect(
      x: r.minX + g.left, y: r.minY + g.top, width: r.width - g.left - g.right, height: r.height - g.top - g.bottom)
  }

  /// At the edge of a workspace, "move" carries on to the monitor in that direction.
  func send(_ windows: [Int], from tree: Tree, toward dir: Direction) {
    guard let here = active.first(where: { $0.tree === tree })?.screen else { return }
    let frames = Dictionary(uniqueKeysWithValues: active.indices.map { ($0, active[$0].screen.axFrame) })
    guard let i = nearest(from: here.axFrame, dir, in: frames) else { return }
    for w in windows {
      tree.remove(w)
      active[i].tree.insert(w)
    }
  }

  func shortcutMissing(_: Int) {
    NSSound.beep()
    onShortcutMissing()
  }

  func bind() {
    let table = paused ? [:] : config.modes[mode] ?? [:]
    let refused = hotkeys.set(
      table.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { key, commands in
        // hop off the Carbon callback first: a "mode" command re-registers every hotkey
        (key, { DispatchQueue.main.async { commands.forEach { self.run($0) } } })
      },
      // growing and shrinking go on for as long as the keys are held
      held: Set(table.filter { !$0.value.isEmpty && $0.value.allSatisfy { $0.hasPrefix("resize") } }.keys))
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
}
