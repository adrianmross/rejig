import ServiceManagement
import SwiftUI
import TileCore

/// A window over the same config.json: each control writes only the key it
/// changes and reloads, so the file stays hand-editable.
final class Settings {
  private var window: NSWindow?

  func show(_ tab: String = "General") {
    window?.close()
    // toolbar tabs, the way macOS's own settings windows have them
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    let names = [
      ("General", "gearshape"), ("Appearance", "paintbrush"), ("Keybindings", "keyboard"),
      ("Apps", "macwindow.on.rectangle"),
    ]
    for (name, symbol) in names {
      let host = NSHostingController(rootView: SettingsView(tab: name))
      host.title = name  // the window takes the selected tab's title
      host.sizingOptions = []  // the window sets the size; otherwise it opens smaller than the form and crops it
      let item = NSTabViewItem(viewController: host)
      item.label = name
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
      tabs.addTabViewItem(item)
    }
    tabs.selectedTabViewItemIndex = names.firstIndex { $0.0 == tab } ?? 0
    let w = NSWindow(contentViewController: tabs)
    // resizable in height, for the long list of keys; that is also what makes it a window the focus keys reach
    w.styleMask = [.titled, .closable, .resizable]
    w.setContentSize(NSSize(width: 560, height: 600))
    w.contentMinSize = NSSize(width: 560, height: 400)
    w.contentMaxSize = NSSize(width: 560, height: 2000)
    w.toolbarStyle = .preference
    w.isReleasedWhenClosed = false
    w.center()
    window = w
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
    manager.look()
  }
}

private let builtIn = [("macos", "macOS  ⌃⌥ arrows"), ("vim", "Vim  ⌥ h j k l"), ("rex", "Rex  ⌃⌘ numbers, [ ], D")]

private struct SettingsView: View {
  let tab: String
  @State private var config = Config.load().0
  @State private var recording: String?  // the row waiting for a key press
  @State private var monitor: Any?
  @State private var wasPaused = false
  @State private var linked: Bool?  // edge gaps change together; nil until touched: linked when they are equal
  @State private var presetName = ""
  @State private var login = SMAppService.mainApp.status == .enabled

  var body: some View {
    Form {
      switch tab {
      case "Appearance": appearance
      case "Keybindings": keybindings
      case "Apps": apps
      default: general
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { config = Config.load().0 }  // another tab may have changed it
    .onDisappear(perform: stop)
  }

  // MARK: General

  @ViewBuilder private var general: some View {
    Section {
      Toggle("Start at login", isOn: $login)
        .onChange(of: login) { on in
          let service = SMAppService.mainApp
          do { try on ? service.register() : service.unregister() } catch { login = service.status == .enabled }
        }
      Toggle("Check for updates daily", isOn: setting("updates", config.updates))
    }
    Section("Windows") {
      Picker("New windows", selection: setting("newWindows", config.newWindows)) {
        Text("Float at the size macOS restores").tag("float")
        Text("Tile at once").tag("tile")
      }
      Picker("Windows that won't fit their tile", selection: setting("fixedSize", config.fixedSize)) {
        Text("Float").tag("float")
        Text("Tile at their own size").tag("tile")
      }
      Picker("Dragging or resizing a tiled window", selection: setting("drag", config.drag)) {
        Text("Floats it where you left it").tag("float")
        Text("Adjusts the layout").tag("adjust")
      }
      Toggle("Glide floating windows into place", isOn: setting("animate", config.animate))
      Picker("After a split", selection: setting("launcher", config.launcher)) {
        Text("Open the launcher (⌘Space)").tag("cmd-space")
        Text("Wait for a window").tag("none")
      }
    }
    Section("Snapping") {
      Toggle(isOn: setting("edgeSnap", config.edgeSnap)) {
        Text("Snap windows dragged to a screen edge")
        Text("Turn off “Drag windows to screen edges to tile” in System Settings › Desktop & Dock, or both will act.")
      }
      Toggle("A tap from the trackpad when a dragged window reaches a place", isOn: setting("haptics", config.haptics))
        .disabled(!config.edgeSnap)
      Toggle("A snapped window dragged away takes back its size", isOn: setting("restoreOnDrag", config.restoreOnDrag))
      Toggle("Snapping to a half again goes on to two thirds, then a third", isOn: setting("cycle", config.cycle))
      Toggle("The pointer goes with a window sent to another display", isOn: setting("cursorFollows", config.cursorFollows))
      Stepper(
        config.stageStrip > 0
          ? "Room kept for Stage Manager's strip: \(Int(config.stageStrip))" : "Room kept for Stage Manager's strip: none",
        value: setting("stageStrip", config.stageStrip), in: 0...400, step: 10)
    }
    Section("Menu Bar") {
      Picker("Show", selection: setting("menuBar", config.menuBar)) {
        Text("Every display's workspace").tag("all")
        Text("The focused display's workspace").tag("focused")
        Text("Icon only").tag("icon")
      }
      Toggle("Icon beside the numbers", isOn: setting("menuBarIcon", config.menuBarIcon))
        .disabled(config.menuBar == "icon")
      LabeledContent("Looks like") {
        let numbers = ["all": "3|2*|5", "focused": "2"][config.menuBar] ?? ""
        HStack(spacing: 4) {
          if config.menuBarIcon || numbers.isEmpty { Image(systemName: "rectangle.split.2x1") }
          Text(numbers).monospaced()
        }
      }
    }
    Section("Learn") {
      LabeledContent("The welcome and its tour of the keys") { Button("Relaunch Tutorial") { delegate.tour() } }
      LabeledContent("A spare window to try things on") { Button("Open Practice Window") { delegate.practice() } }
    }
    Section("Configuration File") {
      LabeledContent("~/.config/rejig/config.json, after editing it by hand") {
        Button("Reload") {
          manager.reload()
          config = Config.load().0
        }
      }
      LabeledContent("Take it to another Mac, or bring one in") {
        Button("Export…") {
          let panel = NSSavePanel()
          panel.nameFieldStringValue = "rejig-config.json"
          guard panel.runModal() == .OK, let to = panel.url else { return }
          try? ((try? Data(contentsOf: Config.url)) ?? Data("{}".utf8)).write(to: to)
        }
        Button("Import…") {
          let panel = NSOpenPanel()
          panel.allowedContentTypes = [.json]
          // only a file that reads as a config; the one it replaces is kept beside it
          guard panel.runModal() == .OK, let from = panel.url, let data = try? Data(contentsOf: from),
            (try? JSONDecoder().decode(Config.self, from: data)) != nil
          else { return NSSound.beep() }
          try? FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
          let backup = Config.url.deletingPathExtension().appendingPathExtension("backup.json")
          try? FileManager.default.removeItem(at: backup)
          try? FileManager.default.copyItem(at: Config.url, to: backup)
          try? data.write(to: Config.url)
          manager.reload()
          config = Config.load().0
        }
      }
    }
  }

  // MARK: Appearance

  @ViewBuilder private var appearance: some View {
    let active = Color(nsColor: config.border.activeColor)
    Section("Style") {
      HStack(spacing: 14) {
        ForEach([("highlight", "Highlight"), ("plain", "Plain"), ("shadow", "Shadow")], id: \.0) { style, name in
          Button {
            save { $0["style"] = style }
          } label: {
            VStack(spacing: 6) {
              StyleThumb(style: style, colour: active)
                .overlay(
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: config.style == style ? 2.5 : 0))
              Text(name).font(.callout).foregroundStyle(config.style == style ? .primary : .secondary)
            }
          }
          .buttonStyle(.plain)
        }
      }
      .frame(maxWidth: .infinity)
    }
    Section("Spacing") {
      Blueprint(gaps: config.gaps, border: config.border.width, style: config.style, colour: active)
        .frame(height: 210)
      Stepper(
        "Between windows: \(Int(config.gaps.inner))", value: nested("gaps", ["inner"], config.gaps.inner), in: 0...60)
      edges
      // ponytail: 8 is macOS's tiled-window margin from memory, not measured
      Button("Match macOS Spacing") {
        linked = nil
        save { $0["gaps"] = ["inner": 8, "top": 8, "left": 8, "bottom": 8, "right": 8] }
      }
      Button("Restore Default Spacing") {
        linked = nil
        save { $0["gaps"] = nil }
      }
    }
    Section {
      DisclosureGroup("Advanced") {
        Stepper(
          "\(config.style == "shadow" ? "Shadow size" : "Border width"): \(Int(config.border.width))", value: nested("border", ["width"], config.border.width),
          in: 1...12)
        ColorPicker("Focused window", selection: colour("active", config.border.activeColor), supportsOpacity: false)
        ColorPicker("Other windows", selection: colour("inactive", config.border.inactiveColor), supportsOpacity: false)
        Stepper(
          "Accordion peek: \(Int(config.gaps.accordion))", value: nested("gaps", ["accordion"], config.gaps.accordion),
          in: 0...120, step: 5)
        Button("Restore Default Borders") { save { $0["border"] = nil } }
      }
    }
  }

  /// The four edge gaps: one number while the lock is closed, four while it is open.
  @ViewBuilder private var edges: some View {
    let g = config.gaps
    let isLinked = linked ?? (g.top == g.left && g.left == g.bottom && g.bottom == g.right)
    let each: [(String, String, CGFloat)] = [
      ("Top", "top", g.top), ("Left", "left", g.left), ("Bottom", "bottom", g.bottom), ("Right", "right", g.right),
    ]
    HStack(alignment: .top) {
      Button {
        linked = !isLinked
        if !isLinked { nested("gaps", ["top", "bottom", "right"], g.left).wrappedValue = g.left }
      } label: {
        Image(systemName: isLinked ? "lock.fill" : "lock.open")
      }
      .help(isLinked ? "All four edges change together" : "Each edge is set on its own")
      VStack(alignment: .trailing) {
        if isLinked {
          Stepper(
            "Screen edges: \(Int(g.left))", value: nested("gaps", ["top", "left", "bottom", "right"], g.left),
            in: 0...60)
        } else {
          ForEach(each, id: \.1) { label, key, value in
            Stepper("\(label) edge: \(Int(value))", value: nested("gaps", [key], value), in: 0...60)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  // MARK: Keybindings

  @ViewBuilder private var keybindings: some View {
    let saved = config.presets.keys.sorted()
    let name = presetName.trimmingCharacters(in: .whitespaces)
    Section("Preset") {
      Picker("Start from", selection: Binding(get: { config.keys }, set: { choose($0) })) {
        ForEach(builtIn, id: \.0) { Text($0.1).tag($0.0) }
        ForEach(saved, id: \.self) { Text($0).tag($0) }
      }
      if config.modes != Config.defaultModes(config.keys, config.presets) {
        LabeledContent("Customized") { Button("Back to the Preset") { save { $0["modes"] = nil } } }
      }
      HStack {
        TextField("Save these keys as", text: $presetName, prompt: Text("preset name"))
        Button("Save") { savePreset(name) }.disabled(name.isEmpty || builtIn.contains { $0.0 == name })
        if saved.contains(config.keys) { Button("Delete") { deletePreset(config.keys) } }
      }
    }
    let main = commands("main")
    ForEach(["Focus", "Move", "Snap", "Split", "Workspaces", "Layout"], id: \.self) { group in
      Section(group) { ForEach(main.filter { category($0) == group }, id: \.self) { row("main", $0) } }
    }
    Section("Service mode, after \(glyphs(key("main", ["mode service"])))") {
      ForEach(commands("service"), id: \.self) { row("service", $0) }
    }
  }

  private func choose(_ preset: String) {
    save {
      $0["keys"] = preset
      $0["modes"] = nil
    }
  }

  private func savePreset(_ name: String) {
    let table = config.modes.mapValues { $0.filter { !$0.value.isEmpty } }
    save { json in
      var presets = json["presets"] as? [String: Any] ?? [:]
      presets[name] = table
      json["presets"] = presets
      json["keys"] = name
      json["modes"] = nil
    }
    presetName = ""
  }

  private func deletePreset(_ name: String) {
    save { json in
      var presets = json["presets"] as? [String: Any] ?? [:]
      presets[name] = nil
      json["presets"] = presets
      json["keys"] = "macos"
    }
  }

  private func row(_ mode: String, _ cmds: [String]) -> some View {
    let id = "\(mode)/\(cmds)"
    let bound = (config.modes[mode] ?? [:]).filter { $0.value == cmds }.keys
    return LabeledContent {
      Button(recording == id ? "Press keys…  Esc cancels" : glyphs(key(mode, cmds))) { record(id, mode, cmds) }
      Button {
        save { json in
          var modes = json["modes"] as? [String: [String: [String]]] ?? [:]
          for old in bound { modes[mode, default: [:]][old] = [] }
          json["modes"] = modes
        }
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("Remove this shortcut")
      .opacity(bound.isEmpty ? 0 : 0.6)
      .disabled(bound.isEmpty)
    } label: {
      HStack(spacing: 8) {
        if let icon = placeIcon(cmds) { Image(nsImage: icon).renderingMode(.template) }
        Text(title(cmds))
      }
    }
  }

  /// Every command any preset or the file binds, including ones left without a key.
  private func commands(_ mode: String) -> [[String]] {
    let tables = [Config.defaultModes("macos"), Config.defaultModes(config.keys, config.presets), config.modes]
    // and the ones no preset gives a key
    let unbound = ["snap almost-maximize", "snap maximize-height", "stack next", "stack prev", "snap left-half",
      "snap right-half", "snap top-half", "snap bottom-half"].map { [$0] }
    let all = tables.flatMap { Array(($0[mode] ?? [:]).values) } + (mode == "main" ? unbound : [])
    return Set(all.filter { !$0.isEmpty }).sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
  }

  private func key(_ mode: String, _ cmds: [String]) -> String? {
    config.modes[mode]?.filter { $0.value == cmds }.keys.min()
  }

  private func record(_ id: String, _ mode: String, _ cmds: [String]) {
    stop()
    recording = id
    // paused, so a combination that is already a hotkey reaches this window
    wasPaused = manager.paused
    manager.paused = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
      defer { stop() }
      if e.keyCode == 53 { return nil }
      let mods = [(NSEvent.ModifierFlags.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd")]
        .filter { e.modifierFlags.contains($0.0) }.map(\.1)
      // a bare key in main mode would be taken from every app
      guard let name = Hotkeys.keys.first(where: { $0.value == Int(e.keyCode) })?.key,
        mode != "main" || !mods.isEmpty
      else {
        NSSound.beep()
        return nil
      }
      let new = (mods + [name]).joined(separator: "-")
      save { json in
        var modes = json["modes"] as? [String: [String: [String]]] ?? [:]
        for old in (config.modes[mode] ?? [:]).filter({ $0.value == cmds }).keys { modes[mode, default: [:]][old] = [] }
        modes[mode, default: [:]][new] = cmds
        json["modes"] = modes
      }
      return nil
    }
  }

  private func stop() {
    guard let m = monitor else { return }
    NSEvent.removeMonitor(m)
    monitor = nil
    recording = nil
    manager.paused = wasPaused
  }

  // MARK: Apps

  @ViewBuilder private var apps: some View {
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
      .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    Section {
      ForEach(config.float, id: \.self) { name in
        rule(name.replacingOccurrences(of: "\\", with: ""), "Always floats", icon(named: name)) {
          save { $0["float"] = config.float.filter { $0 != name } }
        }
      }
      ForEach(config.tile, id: \.self) { bundle in
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        rule(
          url?.deletingPathExtension().lastPathComponent ?? bundle, "Always tiles",
          url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        ) {
          save { $0["tile"] = config.tile.filter { $0 != bundle } }
        }
      }
      Menu("Add an Open App") {
        ForEach(running, id: \.processIdentifier) { app in
          Menu(app.localizedName ?? "?") {
            Button("Always Float") { add(app, float: true) }
            Button("Always Tile") { add(app, float: false) }
          }
        }
      }
    } header: {
      Text("Rules")
    } footer: {
      Text(
        "A floating app stays out of the layout. A tiling app always joins it, even when new windows float. "
          + "Any single window can be switched with \(glyphs(key("main", ["layout floating tiling"]))).")
    }
  }

  private func add(_ app: NSRunningApplication, float: Bool) {
    if float {
      let name = NSRegularExpression.escapedPattern(for: app.localizedName ?? "").lowercased()
      save { $0["float"] = config.float.filter { $0 != name } + [name] }
    } else if let bundle = app.bundleIdentifier {
      save { $0["tile"] = config.tile.filter { $0 != bundle } + [bundle] }
    }
  }

  private func rule(_ name: String, _ does: String, _ icon: NSImage?, remove: @escaping () -> Void) -> some View {
    HStack {
      if let icon {
        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
      } else {
        Image(systemName: "macwindow").frame(width: 20, height: 20)
      }
      Text(name.capitalized)
      Spacer()
      Text(does).foregroundStyle(.secondary)
      Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain)
    }
  }

  private func icon(named pattern: String) -> NSImage? {
    NSWorkspace.shared.runningApplications.first {
      $0.localizedName?.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }?.icon
  }

  // MARK: saving

  private func setting<T>(_ name: String, _ value: T) -> Binding<T> {
    Binding(get: { value }, set: { new in save { $0[name] = new } })
  }

  /// One value written to several keys of a group, e.g. all four edge gaps.
  private func nested<T>(_ group: String, _ names: [String], _ value: T) -> Binding<T> {
    Binding(
      get: { value },
      set: { new in
        save { json in
          var g = json[group] as? [String: Any] ?? [:]
          for name in names { g[name] = new }
          json[group] = g
        }
      })
  }

  private func colour(_ name: String, _ value: NSColor) -> Binding<Color> {
    Binding(
      get: { Color(nsColor: value) },
      set: { new in
        guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
        let hex = String(
          format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
          Int(round(c.blueComponent * 255)))
        nested("border", [name], hex).wrappedValue = hex
      })
  }

  private func save(_ change: (inout [String: Any]) -> Void) {
    guard Config.edit(change) else { return NSSound.beep() }
    manager.reload(changedOnly: true)
    config = Config.load().0
  }
}

/// Two little windows drawn in one of the three styles.
private struct StyleThumb: View {
  let style: String
  let colour: Color

  var body: some View {
    HStack(spacing: 5) {
      pane.overlay(RoundedRectangle(cornerRadius: 4).stroke(colour, lineWidth: style == "highlight" ? 2 : 0))
        .shadow(color: style == "shadow" ? colour : .clear, radius: 5)
      pane.overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray, lineWidth: style == "highlight" ? 1 : 0))
    }
    .padding(10)
    .frame(width: 130, height: 78)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
  }

  private var pane: some View { RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.45)) }
}

/// One display with two tiled windows. Each space being set is shaded and
/// outlined in blue, the way a layout inspector shows padding, with its value on it.
private struct Blueprint: View {
  let gaps: Gaps
  let border: CGFloat
  let style: String
  let colour: Color

  var body: some View {
    Canvas { ctx, size in
      let blue = Color(red: 0.2, green: 0.55, blue: 1)
      func px(_ gap: CGFloat) -> CGFloat { 12 + min(gap, 60) * 0.7 }  // larger than life, and never too thin to see
      let h = size.height - 8, w = min(size.width - 8, h * 1.75)
      let screen = CGRect(x: (size.width - w) / 2, y: 4, width: w, height: h)
      let outline = Path(roundedRect: screen, cornerRadius: 9)
      ctx.fill(outline, with: .color(.black.opacity(0.35)))
      ctx.stroke(outline, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
      ctx.clip(to: outline)
      let bar: CGFloat = 9  // the menu bar
      ctx.fill(Path(CGRect(x: screen.minX, y: screen.minY, width: w, height: bar)), with: .color(.white.opacity(0.12)))

      let work = CGRect(x: screen.minX, y: screen.minY + bar, width: w, height: h - bar)
      let t = px(gaps.top), l = px(gaps.left), b = px(gaps.bottom), r = px(gaps.right), i = px(gaps.inner)
      let area = CGRect(x: work.minX + l, y: work.minY + t, width: work.width - l - r, height: work.height - t - b)
      let left = CGRect(x: area.minX, y: area.minY, width: (area.width - i) / 2, height: area.height)
      let right = left.offsetBy(dx: left.width + i, dy: 0)

      for (rect, focused) in [(left, true), (right, false)] {
        let path = Path(roundedRect: rect, cornerRadius: 6)
        if focused, style == "shadow" {
          ctx.drawLayer { glow in
            glow.addFilter(.shadow(color: colour, radius: 6))
            glow.fill(path, with: .color(Color(white: 0.3)))
          }
        }
        ctx.fill(path, with: .color(Color(white: 0.3)))
        if style == "highlight" {
          ctx.stroke(path, with: .color(focused ? colour : .gray), lineWidth: max(1.5, border * 0.5))
        }
        for (n, dot) in [Color.red, .yellow, .green].enumerated() {
          let c = CGRect(x: rect.minX + 7 + CGFloat(n) * 7, y: rect.minY + 7, width: 4, height: 4)
          ctx.fill(Path(ellipseIn: c), with: .color(dot.opacity(0.7)))
        }
      }

      let bands = [
        (CGRect(x: work.minX, y: work.minY, width: work.width, height: t), gaps.top),
        (CGRect(x: work.minX, y: area.maxY, width: work.width, height: b), gaps.bottom),
        (CGRect(x: work.minX, y: area.minY, width: l, height: area.height), gaps.left),
        (CGRect(x: area.maxX, y: area.minY, width: r, height: area.height), gaps.right),
        (CGRect(x: left.maxX, y: area.minY, width: i, height: area.height), gaps.inner),
      ]
      for (band, _) in bands {
        ctx.fill(Path(band), with: .color(blue.opacity(0.22)))
        ctx.stroke(Path(band.insetBy(dx: 0.5, dy: 0.5)), with: .color(blue), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
      }
      for (band, value) in bands {
        let text = ctx.resolve(
          Text("\(Int(value))").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundColor(.white))
        let s = text.measure(in: size)
        let pill = CGRect(
          x: band.midX - s.width / 2 - 5, y: band.midY - s.height / 2 - 2, width: s.width + 10, height: s.height + 4)
        ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(blue))
        ctx.draw(text, at: CGPoint(x: band.midX, y: band.midY))
      }
    }
  }
}

private func category(_ cmds: [String]) -> String {
  switch cmds[0].split(separator: " ").first.map(String.init) ?? "" {
  case "focus", "stack": return "Focus"
  case "move", "move-to-display": return "Move"
  case "snap": return "Snap"
  case "split", "join-with": return "Split"
  case "workspace", "workspace-back-and-forth", "move-node-to-workspace", "move-workspace-to-monitor":
    return "Workspaces"
  default: return "Layout"
  }
}

/// A command in plain words, e.g. "move-node-to-workspace 3" -> "Move window to workspace 3".
func title(_ cmds: [String]) -> String {
  let a = cmds[0].split(separator: " ").map(String.init)
  let last = a.last ?? ""
  switch a[0] {
  case "focus": return "Focus \(last)"
  case "move": return "Move \(last)"
  case "join-with": return "Join with the window \(last)"
  case "stack": return last == "prev" ? "Previous window in the pile" : "Next window in the pile"
  case "move-to-display": return last == "prev" ? "Move to previous display" : "Move to next display"
  case "split": return "Split \(last)"
  case "snap":
    return [
      "top-left": "Top left quarter", "top-right": "Top right quarter", "bottom-left": "Bottom left quarter",
      "bottom-right": "Bottom right quarter", "left-third": "Left third", "center-third": "Center third",
      "right-third": "Right third", "left-two-thirds": "Left two thirds", "right-two-thirds": "Right two thirds",
      "center": "Center", "maximize": "Maximize", "restore": "Restore size", "left-half": "Left half",
      "right-half": "Right half", "top-half": "Top half", "bottom-half": "Bottom half",
      "almost-maximize": "Almost maximize", "maximize-height": "Maximize height",
    ][last] ?? cmds[0]
  case "workspace": return Int(last) != nil ? "Workspace \(last)" : last == "next" ? "Next workspace" : "Previous workspace"
  case "workspace-back-and-forth": return "Last workspace"
  case "move-node-to-workspace": return "Move window to workspace \(last)"
  case "move-workspace-to-monitor": return "Send workspace to the next display"
  case "layout":
    return a.contains("floating") ? "Float or tile window" : a.contains("accordion") ? "Accordion layout" : "Tiles layout"
  case "resize": return last.hasPrefix("-") ? "Shrink" : "Grow"
  case "fullscreen": return "Fill"
  case "mode": return "Service mode"
  case "tiling": return "Tiling on or off here"
  case "reload-config": return "Reload configuration"
  case "flatten-workspace-tree": return "Reset layout"
  case "close-all-windows-but-current": return "Close other windows"
  default: return cmds[0]
  }
}

/// "ctrl-alt-left" -> "⌃⌥←"
private func glyphs(_ binding: String?) -> String { binding == nil ? "—" : keys(binding).joined() }

/// "ctrl-alt-left" -> ["⌃", "⌥", "←"], one entry per key
func keys(_ binding: String?) -> [String] {
  let g = [
    "ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "left": "←", "right": "→", "up": "↑", "down": "↓",
    "enter": "↩", "tab": "⇥", "backspace": "⌫", "esc": "⎋", "space": "Space", "minus": "-", "equal": "=",
    "comma": ",", "slash": "/", "semicolon": ";", "period": ".", "quote": "'", "backslash": "\\", "backtick": "`",
    "leftSquareBracket": "[", "rightSquareBracket": "]",
  ]
  guard let binding else { return [] }
  // modifiers in the order macOS writes them
  let parts = binding.split(separator: "-").map(String.init)
  let mods = ["ctrl", "alt", "shift", "cmd"].filter(parts.dropLast().contains)
  return (mods + [parts.last ?? ""]).map { g[$0] ?? $0.uppercased() }
}

/// A little display showing what a command does to the window: where a snap puts it, which side a
/// move takes it, the empty half a split leaves. Drawn from the same sums the snap uses. Nil for a
/// command with nothing to picture.
func placeIcon(_ cmds: [String]) -> NSImage? {
  let a = cmds[0].split(separator: " ").map(String.init)
  let name = a.last ?? ""
  if cmds[0] == "snap restore" { return NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil) }
  let size = NSSize(width: 20, height: 14)
  let screen = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
  let area = screen.insetBy(dx: 2.25, dy: 2.25)
  func at(_ place: String) -> CGRect {
    TileCore.place(place, in: area, inner: 1.5, size: CGSize(width: 8, height: 5)) ?? area
  }
  let side = ["left": "left", "right": "right", "up": "top", "down": "bottom"]
  let across = ["left": "right", "right": "left", "top": "bottom", "bottom": "top"]
  // the window itself solid, its neighbours faint, a place waiting to be filled only outlined
  var solid: [CGRect] = [], faint: [CGRect] = [], empty: [CGRect] = [], lines: [(CGPoint, CGPoint)] = []
  switch a[0] {
  case "stack": return NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
  case "move-to-display":
    return NSImage(systemSymbolName: name == "prev" ? "arrow.left.square" : "arrow.right.square", accessibilityDescription: nil)
  case "snap" where name == "maximize-height": solid = [at("center-third")]
  case "snap":
    guard TileCore.place(name, in: area, inner: 1.5, size: .zero) != nil else { return nil }
    solid = [at(name)]
  case "move":
    guard let s = side[name], let o = across[s] else { return nil }
    (solid, faint) = ([at("\(s)-half")], [at("\(o)-half")])
  case "split":
    guard let s = side[name], let o = across[s] else { return nil }
    (solid, empty) = ([at("\(o)-half")], [at("\(s)-half").insetBy(dx: 0.5, dy: 0.5)])
  case "join-with":
    // the two of them sharing that side, one above the other or side by side
    guard let s = side[name], let o = across[s] else { return nil }
    let pair = s == "left" || s == "right" ? ["top-\(s)", "bottom-\(s)"] : ["\(s)-left", "\(s)-right"]
    (solid, faint) = (pair.map(at), [at("\(o)-half")])
  case "layout" where a.contains("floating"): (solid, faint) = ([at("center")], [area])
  case "layout" where a.contains("accordion"):
    (solid, faint) = ([area.insetBy(dx: 2.5, dy: 0)], [area])
  case "layout": solid = [at("left-half"), at("right-half")]
  case "fullscreen": solid = [area]
  case "resize":
    let c = CGPoint(x: area.midX, y: area.midY)
    lines = [(CGPoint(x: c.x - 3, y: c.y), CGPoint(x: c.x + 3, y: c.y))]
    if !name.hasPrefix("-") { lines.append((CGPoint(x: c.x, y: c.y - 3), CGPoint(x: c.x, y: c.y + 3))) }
  default: return nil
  }
  let image = NSImage(size: size, flipped: true) { _ in
    let outline = NSBezierPath(roundedRect: screen, xRadius: 3.5, yRadius: 3.5)
    NSColor.black.withAlphaComponent(0.45).setStroke()
    outline.stroke()
    func pane(_ r: CGRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5) }
    NSColor.black.withAlphaComponent(0.3).setFill()
    faint.forEach { pane($0).fill() }
    NSColor.black.setFill()
    solid.forEach { pane($0).fill() }
    NSColor.black.setStroke()
    empty.forEach { pane($0).stroke() }
    for (from, to) in lines {
      let line = NSBezierPath()
      line.move(to: from)
      line.line(to: to)
      line.lineWidth = 1.5
      line.lineCapStyle = .round
      line.stroke()
    }
    return true
  }
  image.isTemplate = true
  return image
}
