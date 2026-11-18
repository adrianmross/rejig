import AppKit

// `rejig focus left`: hand a command to the running app over its socket, like
// the `rex` CLI, and wait for the answer: output on stdout, or the reason on
// stderr and exit 1.
if CommandLine.arguments.count > 1 {
  let words = Array(CommandLine.arguments.dropFirst())
  switch words[0] {
  case "--help", "-h", "help":
    print(usage)
  case "api":
    let list = commands.map { ["usage": $0.usage, "does": $0.does] }
    print(String(data: try! JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]), encoding: .utf8)!)
  case "skill" where words.last == "install":
    // where Claude Code looks for a user's skills
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/rejig")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! skill.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    print(dir.appendingPathComponent("SKILL.md").path)
  case "skill":
    print(skill)
  default:
    Socket.call(words.joined(separator: " "))
  }
  exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private lazy var onboarding = Onboarding(manager.spaces, granted: { manager.start() }) { [unowned self] in
    self.refresh()
  }
  private let settings = Settings()
  private var signal: DispatchSourceSignal?
  private let server = Server()
  private let report = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/rejig-diagnostics.txt")

  func applicationDidFinishLaunching(_: Notification) {
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    manager.onChange = { [unowned self] in self.refresh() }
    manager.onShortcutMissing = { [unowned self] in self.onboarding.show() }
    manager.onRun = { [unowned self] in self.onboarding.ran($0) }
    manager.onEvent = { [unowned self] event, info in
      var line = info
      line["event"] = event
      self.server.emit(line)
    }
    manager.intercept = { [unowned self] in self.onboarding.take($0) }
    manager.agentScreen.onProblem = { manager.note($0) }
    manager.agentScreen.onShown = { manager.resolve("agent screen") }
    onboarding.openSettings = { [unowned self] in self.settings.show("Keybindings") }
    refresh()
    onboarding.check()
    let failure = server.start { [unowned self] command, caller, reply in
      // "settings", or "settings Keybindings" to open on a tab; "welcome" replays
      // the first-run welcome; "onboarding" shows its setup step
      let words = command.split(separator: " ").map(String.init)
      switch words.first {
      case "welcome":
        // "welcome play" opens it at one step
        let steps: [String: Onboarding.Step] = ["setup": .setup, "keys": .keys, "play": .play, "done": .done, "deep": .deep]
        self.onboarding.show(words.count > 1 ? steps[words[1]] ?? .hello : .hello)
        if words.last == "presets" {  // the keys step, with its full list open
          self.onboarding.show(.keys)
          self.onboarding.allPresets = true
        }
      case "onboarding": self.onboarding.show()
      case "practice":
        // a spare window to try things on; prints its window number. "--agent-screen" opens it there,
        // "--tile" puts it in the layout, "close" closes them all
        if words.last == "close" {
          self.onboarding.endPractice()
          break
        }
        func open(_ tries: Int) {
          let away = words.contains("--agent-screen")
          if away, manager.agentScreen.create(), manager.agentScreen.screen == nil, tries > 0 {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { open(tries - 1) }
          }
          guard let w = self.onboarding.addPractice(on: away ? manager.agentScreen.screen : nil) else {
            return reply(false, "no more practice windows: six are open")
          }
          let number = w.windowNumber
          let tile = {
            guard words.contains("--tile") else { return reply(true, "\(number)") }
            manager.run("layout floating tiling --window-id \(number)") { ok, out in reply(ok, ok ? "\(number)" : out) }
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // macOS opens an app's new window on the display in use, wherever it was asked for: moved after
            guard away, let area = manager.agentScreen.screen?.axFrame else { return tile() }
            // each a step further in, so no two share a frame, which is how windows are told apart
            let step = (Int(w.title.split(separator: " ").last ?? "1") ?? 1) * 40
            manager.run(
              "move --frame \(Int(area.minX) + 40 + step),\(Int(area.minY) + 40 + step),460,300 --window-id \(number)"
            ) { ok, out in
              // the window server's own record of the frame trails the move by a moment
              ok ? DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: tile) : reply(false, out)
            }
          }
        }
        return open(10)
      case "settings": self.settings.show(words.count > 1 ? words[1] : "General")
      default: return manager.run(command, caller: caller, reply: reply)
      }
      reply(true, "")
    }
    if let failure { manager.note("the command socket could not be opened: \(failure)") }

    // `kill -USR1` writes the same report the menu copies, for use from a terminal
    Darwin.signal(SIGUSR1, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler { [unowned self] in
      try? manager.diagnostics().write(to: self.report, atomically: true, encoding: .utf8)
    }
    source.resume()
    signal = source
  }

  private func refresh() {
    // each display's workspace, left to right, the focused display starred: "3|2*|5"
    let spaces = manager.spaces
    // the agent screen has no monitor to be at: it is not in the readout
    let screens = NSScreen.screens.filter { $0.localizedName != AgentScreen.name }.sorted { $0.frame.minX < $1.frame.minX }
    let focused = manager.lastScreen ?? screens.first
    let c = manager.config
    let numbers =
      c.menuBar == "icon"
      ? ""
      : c.menuBar == "focused"
        ? focused.map { spaces.shown[$0].map(String.init) ?? "?" } ?? "?"
        : screens.map { s in
          (spaces.shown[s].map(String.init) ?? "?") + (s == focused && screens.count > 1 ? "*" : "")
        }.joined(separator: "|")
    let state = manager.paused ? "paused" : manager.mode == "main" ? "" : manager.mode
    // a template symbol, so it follows the menu bar's colour like every other item
    item.button?.image =
      c.menuBarIcon || numbers.isEmpty
      ? NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Rejig") : nil
    item.button?.imagePosition = .imageLeading
    item.button?.title = [numbers, state].filter { !$0.isEmpty }.joined(separator: " ")
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    // `key` is a binding in the config's spelling, e.g. "cmd-q" or "ctrl-alt-t"
    func add(_ title: String, _ action: Selector?, on: Bool = false, key: String? = nil) {
      let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      i.target = self
      i.state = on ? .on : .off
      let parts = (key ?? "").split(separator: "-").map(String.init)
      guard let last = parts.last, let char = ["comma": ",", "tab": "\t", "enter": "\r"][last] ?? (last.count == 1 ? last : nil)
      else { return }
      i.keyEquivalent = char
      i.keyEquivalentModifierMask = NSEvent.ModifierFlags(
        parts.dropLast().compactMap { ["cmd": .command, "alt": .option, "ctrl": .control, "shift": .shift][$0] })
    }
    let info = Bundle.main.infoDictionary
    add("Rejig – v\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))", nil)
    if !AXIsProcessTrusted() || !onboarding.missing.isEmpty { add("Finish Setup…", #selector(setUp)) }
    for problem in manager.problems { add(problem, nil) }
    menu.addItem(.separator())
    let main = manager.config.modes["main"] ?? [:]
    add(
      "Tile This Workspace", #selector(tiling), on: manager.tilingHere,
      key: main.first { $0.value == ["tiling toggle"] }?.key)
    if let tiled = manager.focusedTiled {
      add(
        tiled ? "Float This Window" : "Tile This Window", #selector(floating),
        key: main.first { $0.value == ["layout floating tiling"] }?.key)
    }
    add("Pause", #selector(pause), on: manager.paused)
    // windows an agent has taken over, and the way to take them back
    let held = manager.held
    if !held.isEmpty {
      let who = Set(held).sorted().joined(separator: ", ")
      add("Release \(held.count) Window\(held.count == 1 ? "" : "s") Held by \(who)", #selector(releaseHeld))
    }
    if manager.agentScreen.exists { add("Show Agent Screen", #selector(showAgentScreen)) }
    menu.addItem(.separator())
    add("Settings…", #selector(openSettings), key: "cmd-comma")
    add("Copy Diagnostics", #selector(copyDiagnostics))
    menu.addItem(.separator())
    add("Quit", #selector(quit), key: "cmd-q")
  }

  @objc private func setUp() { onboarding.show() }
  @objc private func floating() { manager.run("layout floating tiling") }
  @objc private func tiling() { manager.run("tiling toggle") }
  @objc private func pause() { manager.paused.toggle() }
  @objc private func showAgentScreen() { manager.agentScreen.show() }
  @objc private func releaseHeld() { manager.run("release") }
  @objc private func openSettings() { settings.show() }
  func tour() { onboarding.show(.hello) }
  func practice() { onboarding.addPractice() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func copyDiagnostics() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(manager.diagnostics(), forType: .string)
  }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApp.setActivationPolicy(.accessory)
NSApp.run()
