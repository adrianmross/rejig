import AppKit
import ServiceManagement

// `tilespace focus left`: hand a command to the running app, like the `aerospace` CLI
let commandName = Notification.Name("com.adrianmross.tilespace.command")
if CommandLine.arguments.count > 1 {
  DistributedNotificationCenter.default().postNotificationName(
    commandName, object: CommandLine.arguments.dropFirst().joined(separator: " "), userInfo: nil,
    deliverImmediately: true)
  exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private lazy var shortcuts = ShortcutSetup(manager.spaces) { [unowned self] in self.refresh() }
  private lazy var permissions = Permissions { [unowned self] in
    manager.start()
    if !self.shortcuts.missing.isEmpty { self.shortcuts.show() }
  }
  private let settings = Settings()
  private var signal: DispatchSourceSignal?
  private let report = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/tilespace-diagnostics.txt")

  func applicationDidFinishLaunching(_: Notification) {
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    manager.onChange = { [unowned self] in self.refresh() }
    manager.onShortcutMissing = { [unowned self] in self.shortcuts.show() }
    refresh()
    permissions.check()
    DistributedNotificationCenter.default().addObserver(forName: commandName, object: nil, queue: .main) {
      guard let command = $0.object as? String else { return }
      // "settings", or "settings Keybindings" to open on a tab
      let words = command.split(separator: " ").map(String.init)
      if words.first == "settings" { self.settings.show(words.count > 1 ? words[1] : "General") } else { manager.run(command) }
    }

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
    let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
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
    item.button?.title = [c.menuBarIcon || numbers.isEmpty ? "▦" : "", numbers, state]
      .filter { !$0.isEmpty }.joined(separator: " ")
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
    add("Tilespace – v\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))", nil)
    if !AXIsProcessTrusted() { add("Grant Accessibility Access…", #selector(grant)) }
    if !shortcuts.missing.isEmpty { add("Set Up Desktop Shortcuts…", #selector(setUpShortcuts)) }
    for problem in manager.problems { add(problem, nil) }
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
    add("Settings…", #selector(openSettings), key: "cmd-comma")
    add("Reload Configuration", #selector(reload))
    add("Start at Login", #selector(login), on: SMAppService.mainApp.status == .enabled)
    add("Copy Diagnostics", #selector(copyDiagnostics))
    add("Quit", #selector(quit), key: "cmd-q")
  }

  @objc private func grant() { permissions.check() }
  @objc private func setUpShortcuts() { shortcuts.show() }
  @objc private func floating() { manager.run("layout floating tiling") }
  @objc private func tiling() { manager.run("tiling toggle") }
  @objc private func pause() { manager.paused.toggle() }
  @objc private func openSettings() { settings.show() }
  @objc private func reload() { manager.reload() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func login() {
    let service = SMAppService.mainApp
    do { try service.status == .enabled ? service.unregister() : service.register() } catch { NSSound.beep() }
  }

  @objc private func copyDiagnostics() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(manager.diagnostics(), forType: .string)
  }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApp.setActivationPolicy(.accessory)
NSApp.run()
