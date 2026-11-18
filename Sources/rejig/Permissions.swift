import AppKit
import Combine
import ServiceManagement
import SwiftUI
import TileCore

/// The first-run welcome and the setup it leads into: a hello, the two things
/// Rejig needs (Accessibility, to move windows; macOS's "Switch to Desktop"
/// shortcuts, to change workspace), a choice of keys, three basics to try, and
/// a goodbye that offers a longer practice. Later on
/// the same window opens at the setup step whenever one of the two goes missing,
/// and closes by itself once both are back.
final class Onboarding: ObservableObject {
  enum Step: Int { case hello, setup, keys, play, done, deep }
  @Published var step = Step.hello { didSet { if step != oldValue { arrange() } } }
  @Published var done = Set<String>()  // the kinds of command tried on the practice windows
  private var practice: [NSWindow] = []
  @Published var trusted = AXIsProcessTrusted()
  @Published var shortcutsOn = true
  @Published var nudging = false  // Settings was opened: point at the drag
  @Published var keys = manager.config.keys
  var openSettings: () -> Void = {}
  private var touring = false
  private var window: NSWindow?
  private let spaces: Spaces
  private let granted: () -> Void
  private let changed: () -> Void

  init(_ spaces: Spaces, granted: @escaping () -> Void, changed: @escaping () -> Void) {
    self.spaces = spaces
    self.granted = granted
    self.changed = changed
    // macOS posts this whenever the Accessibility list changes: no polling
    DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
    ) { [unowned self] _ in
      // the trust flag flips a beat after the notification
      self.after(0.5) { self.check() }
    }
  }

  /// Desktops whose "Switch to Desktop N" shortcut is off.
  var missing: [Int] { (1...max(spaces.desktops, 1)).prefix(6).filter { spaces.shortcut($0) == nil } }

  func check() {
    trusted = AXIsProcessTrusted()
    shortcutsOn = missing.isEmpty
    if trusted { granted() }
    let ready = trusted && shortcutsOn
    if window == nil {
      if !UserDefaults.standard.bool(forKey: "welcomed") { show(.hello) } else if !ready { show(.setup) }
    } else if ready, step == .setup {
      // a beat to see both ticks
      after(0.8) { if self.step == .setup { self.touring ? self.next() : self.close() } }
    }
    changed()
  }

  /// `.hello` plays the whole welcome; `.setup` is only the two rows.
  func show(_ at: Step = .setup) {
    touring = at == .hello
    keys = manager.config.keys
    nudging = false
    step = at
    if window == nil {
      let host = NSHostingController(rootView: WelcomeView(o: self))
      host.sizingOptions = []  // `arrange` sizes the window: small beside the practice windows, full otherwise
      let w = NSWindow(contentViewController: host)
      w.styleMask = [.titled, .closable, .fullSizeContentView]
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      w.isMovableByWindowBackground = true
      w.isReleasedWhenClosed = false
      w.level = .floating  // stays beside System Settings while you work in it
      w.collectionBehavior = [.canJoinAllSpaces]  // and comes along when a workspace key is tried
      w.setContentSize(NSSize(width: 680, height: 480))
      w.center()
      NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) {
        [unowned self] _ in
        UserDefaults.standard.set(true, forKey: "welcomed")
        self.window = nil
        self.endPractice()
      }
      window = w
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    arrange()
  }

  func next() {
    guard step.rawValue < Step.done.rawValue, let following = Step(rawValue: step.rawValue + 1) else { return close() }
    // nothing to set up: straight to the keys
    step = following == .setup && trusted && shortcutsOn ? .keys : following
  }

  func close() { window?.close() }

  /// Every step is the full window, except the optional longer practice at the
  /// end, which shrinks it to a checklist in the corner over the user's windows.
  private func arrange() {
    guard let w = window, let v = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
    if step != .play || !practice.isEmpty { endPractice() }
    if step == .deep {
      w.setFrame(CGRect(x: v.maxX - 340, y: v.maxY - 420, width: 320, height: 400), display: true, animate: true)
      done = []
      // a split needs something to fill its new half: here a practice window, not the launcher
      manager.onSplit = { [unowned self] in self.addPractice() }
      addPractice()
      return
    }
    if w.frame.width != 680 {
      w.setFrame(CGRect(x: v.midX - 340, y: v.midY - 240, width: 680, height: 480), display: true, animate: true)
    }
    if step == .play {
      done = []
      addPractice()  // one window beside the welcome, to try the basics on
      w.makeKeyAndOrderFront(nil)  // focus starts here: moving it across is the first thing to try
    }
  }

  /// A spare window to try things on: it floats over the layout until asked into it.
  func addPractice() {
    practice.removeAll { !$0.isVisible }
    guard practice.count < 6, let v = (window?.screen ?? NSScreen.main)?.visibleFrame else { return }
    let n = practice.count
    let guide = step == .deep && window != nil && n == 0  // the longer practice's first one says what to try on it
    let w = NSWindow(
      // left of the welcome while it is full size, so the two don't cover each other
      contentRect: CGRect(
        x: (step == .play ? max(v.minX + 20, v.midX - 830) : v.midX - 300) + CGFloat(n) * 36,
        y: v.midY - 120 - CGFloat(n) * 36, width: 460, height: guide ? 360 : 300),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
      defer: false)
    w.title = "Practice \(n + 1)"
    w.titlebarAppearsTransparent = true
    w.isReleasedWhenClosed = false
    w.contentViewController = NSHostingController(
      rootView: PracticeView(o: self, n: n + 1, guide: guide, basics: step == .play && window != nil && n == 0))
    w.setContentSize(NSSize(width: 460, height: guide ? 360 : 300))
    practice.append(w)
    manager.practising = true
    w.makeKeyAndOrderFront(nil)
  }

  private func endPractice() {
    manager.onSplit = nil
    guard manager.practising else { return }
    practice.forEach { $0.close() }
    practice = []
    manager.practising = false
  }

  /// During the basics the keys reach only the welcome and its practice window, a
  /// workspace of their own: focus moves between the two, and nothing of the
  /// user's is focused, moved or switched away. True when the command stops here.
  func take(_ command: String) -> Bool {
    guard step == .play, let welcome = window, !command.contains("--") else { return false }
    let a = command.split(separator: " ").map(String.init)
    // queries and housekeeping touch no window
    if ["list-windows", "list-workspaces", "reload-config", "mode", "press", "enable-desktop-shortcuts"].contains(a.first) {
      return false
    }
    let mine = practice.filter(\.isVisible)
    let key = NSApp.isActive ? NSApp.keyWindow : nil
    if a.first == "focus" {
      let all = [welcome] + mine
      // top-left origin, as `nearest` expects
      let frames = Dictionary(
        uniqueKeysWithValues: all.indices.map { i -> (Int, CGRect) in
          let f = all[i].frame
          return (i, CGRect(x: f.minX, y: -f.maxY, width: f.width, height: f.height))
        })
      let from = all.firstIndex { $0 == key } ?? 0
      if let dir = a.last.flatMap(Direction.init), let to = nearest(from: frames[from]!, dir, in: frames), to != from {
        NSApp.activate(ignoringOtherApps: true)
        all[to].makeKeyAndOrderFront(nil)
        if to != 0 { done.insert("focus") } else if done.contains("move") { done.insert("back") }
      }
      return true
    }
    guard let key, mine.contains(key) else { return true }
    if a.first == "move" { done.insert("move") }
    return false  // on to the practice window, for real
  }

  /// A command just ran: tick it off the practice checklist.
  func ran(_ command: String) {
    guard step == .deep, window != nil, let word = command.split(separator: " ").first else { return }
    done.insert(word == "workspace-back-and-forth" ? "workspace" : String(word))
  }

  /// A keybinding preset, as Settings would choose it.
  func choose(_ preset: String) {
    guard preset != keys, Config.edit({
      $0["keys"] = preset
      $0["modes"] = nil
    })
    else { return }
    manager.reload()
    keys = preset
  }

  func openAccessibility() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    nudging = true
    // out of the way of the list the icon is dragged into
    if let w = window, let v = w.screen?.visibleFrame {
      w.setFrame(
        CGRect(origin: CGPoint(x: v.maxX - w.frame.width - 40, y: v.midY - w.frame.height / 2), size: w.frame.size),
        display: true, animate: true)
    }
  }

  func enableShortcuts() {
    spaces.enableShortcuts()
    // macOS takes a moment to apply them
    after(0.5) { self.check() }
  }

  private func after(_ seconds: Double, _ work: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }
}

private let navy = Color(red: 0.05, green: 0.06, blue: 0.1)

private struct WelcomeView: View {
  @ObservedObject var o: Onboarding

  var body: some View {
    Group {
      switch o.step {
      case .hello: Hello(o: o)
      case .setup: Setup(o: o)
      case .keys: Keys(o: o)
      case .play: Play(o: o)
      case .done: Done(o: o)
      case .deep: Deep(o: o)
      }
    }
    .id(o.step)
    .transition(.opacity.combined(with: .offset(y: 14)))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    // behind, so its wide lights don't set the window's size; and up under the title bar
    .background { Backdrop().ignoresSafeArea() }
    .animation(.easeInOut(duration: 0.4), value: o.step)
    .foregroundStyle(.white)
    .preferredColorScheme(.dark)
  }
}

/// Two soft lights drifting behind everything.
private struct Backdrop: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30)) { time in
      let t = time.date.timeIntervalSinceReferenceDate / 6
      ZStack {
        navy
        Circle().fill(Color(red: 0.42, green: 0.36, blue: 0.98)).frame(width: 420)
          .offset(x: cos(t) * 170, y: sin(t * 1.3) * 90 - 60)
        Circle().fill(Color(red: 0.1, green: 0.55, blue: 0.95)).frame(width: 340)
          .offset(x: -cos(t * 0.8) * 190, y: sin(t) * 110 + 90)
      }
      .blur(radius: 110)
      .overlay(navy.opacity(0.45))
    }
    .ignoresSafeArea()
  }
}

/// The icon, drawn live so its tiles can slide into place.
private struct Logo: View {
  var assembled = true
  var size: CGFloat = 132

  var body: some View {
    let (x, y) = (size * 0.182, size * 0.17)
    let (w, h, gap) = (size - 2 * x, size - 2 * y, size * 0.044)
    let (stem, arm) = (w * 0.42, h * 0.42)
    let bright = LinearGradient(colors: [.white, Color(red: 0.8, green: 0.82, blue: 0.87)], startPoint: .top, endPoint: .bottom)
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color(red: 0.21, green: 0.23, blue: 0.33), Color(red: 0.06, green: 0.07, blue: 0.1)],
            startPoint: .top, endPoint: .bottom)
        )
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.5), radius: size * 0.12, y: size * 0.06)
        .scaleEffect(assembled ? 1 : 0.7)
        .opacity(assembled ? 1 : 0)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: assembled)
      tile(Color(red: 0.32, green: 0.34, blue: 0.46), w - stem - gap, h - arm - gap, x + stem + gap, y + arm + gap)
        .opacity(assembled ? 1 : 0)
        .animation(.easeOut(duration: 0.5).delay(0.75), value: assembled)
      tile(bright, stem, h, x, y).shadow(color: .black.opacity(0.4), radius: size * 0.04, y: size * 0.02)
        .offset(x: assembled ? 0 : -size * 0.5)
        .opacity(assembled ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.72).delay(0.3), value: assembled)
      tile(bright, w - stem - gap, arm, x + stem + gap, y).shadow(color: .black.opacity(0.4), radius: size * 0.04, y: size * 0.02)
        .offset(y: assembled ? 0 : -size * 0.5)
        .opacity(assembled ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.72).delay(0.5), value: assembled)
    }
    .frame(width: size, height: size)
  }

  private func tile<S: ShapeStyle>(_ fill: S, _ w: CGFloat, _ h: CGFloat, _ x: CGFloat, _ y: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: size * 0.055, style: .continuous).fill(fill).frame(width: w, height: h)
      .padding(.leading, x).padding(.top, y)
  }
}

private struct Hello: View {
  let o: Onboarding
  @State private var assembled = false
  @State private var words = false

  var body: some View {
    VStack(spacing: 18) {
      Logo(assembled: assembled, size: 148)
      // the logo builds first, then the words rise under it
      Group {
        Text("Rejig").font(.system(size: 52, weight: .bold, design: .rounded))
        Text("Every window in its place.").font(.title3).foregroundStyle(.white.opacity(0.7))
        Button("Get Started") { o.next() }.controlSize(.large).keyboardShortcut(.defaultAction).padding(.top, 14)
      }
      .opacity(words ? 1 : 0)
      .offset(y: words ? 0 : 16)
    }
    .onAppear {
      assembled = true
      withAnimation(.easeOut(duration: 0.6).delay(1.1)) { words = true }
    }
  }
}

private struct Setup: View {
  @ObservedObject var o: Onboarding
  @State private var bob = false

  var body: some View {
    VStack(spacing: 16) {
      DragApp().frame(width: 112, height: 112)
        .offset(y: o.nudging && !o.trusted && bob ? -10 : 0)
        .animation(o.nudging ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default, value: bob)
        .onChange(of: o.nudging) { bob = $0 }
      Text("Drag this icon into the Accessibility list")
        .font(.system(size: 13, weight: o.nudging ? .semibold : .regular))
        .foregroundStyle(o.nudging ? Color.accentColor : .white.opacity(0.6))
        .opacity(o.trusted ? 0 : 1)
      VStack(spacing: 1) {
        row(o.trusted, "Accessibility", "Open Settings", o.openAccessibility)
        row(o.shortcutsOn, "Desktop shortcuts", "Turn On", o.enableShortcuts)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .frame(width: 380)
    }
  }

  private func row(_ done: Bool, _ title: String, _ button: String, _ action: @escaping () -> Void) -> some View {
    HStack(spacing: 10) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(done ? Color.green : .white.opacity(0.35))
        .font(.system(size: 17))
      Text(title)
      Spacer()
      if !done { Button(button, action: action) }
    }
    .padding(.horizontal, 14)
    .frame(height: 46)
    .background(.white.opacity(0.08))
    .animation(.default, value: done)
  }
}

private struct Keys: View {
  @ObservedObject var o: Onboarding

  var body: some View {
    VStack(spacing: 18) {
      Text("Pick your keys").font(.system(size: 30, weight: .bold, design: .rounded))
      HStack(spacing: 16) {
        card("macos", "macOS", ["⌃", "⌥", "←", "→"], "Control-Option and the arrows")
        card("vim", "Vim", ["⌥", "H", "J", "K", "L"], "Option and the home row")
      }
      // the rest, under a line: Rex's, and any saved in Settings
      Rectangle().fill(.white.opacity(0.15)).frame(width: 300, height: 1).padding(.top, 4)
      HStack(spacing: 8) {
        ForEach(["rex"] + manager.config.presets.keys.sorted(), id: \.self) { name in
          Button(name == "rex" ? "Rex  ⌃⌘" : name) { o.choose(name) }
            .buttonStyle(.bordered).tint(o.keys == name ? .accentColor : nil)
        }
      }
      Text("Every key can be changed later in Settings.").font(.callout).foregroundStyle(.white.opacity(0.5))
      Button("Continue") { o.next() }.controlSize(.large).keyboardShortcut(.defaultAction).padding(.top, 6)
    }
  }

  private func card(_ preset: String, _ title: String, _ caps: [String], _ detail: String) -> some View {
    let chosen = o.keys == preset
    return VStack(spacing: 12) {
      Text(title).font(.system(size: 19, weight: .semibold, design: .rounded))
      HStack(spacing: 5) { ForEach(caps, id: \.self) { Keycap(text: $0, height: 34) } }
      Text(detail).font(.callout).foregroundStyle(.white.opacity(0.6))
    }
    .frame(width: 250, height: 150)
    .background(.white.opacity(chosen ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(chosen ? Color.accentColor : .white.opacity(0.15), lineWidth: chosen ? 2 : 1)
    )
    .contentShape(Rectangle())
    .onTapGesture { o.choose(preset) }
    .animation(.default, value: chosen)
  }
}

/// Three basics, in the welcome itself, on one practice window beside it.
private struct Play: View {
  @ObservedObject var o: Onboarding

  var body: some View {
    let focused = o.done.contains("focus")
    VStack(spacing: 16) {
      Text("The basics").font(.system(size: 30, weight: .bold, design: .rounded))
      Text("Only this window and the practice one respond. Yours stay put.").foregroundStyle(.white.opacity(0.65))
      VStack(spacing: 1) {
        row("focus", "Focus the practice window", "focus left")
        row("move", "Move it to the left of the screen", "move left").opacity(focused ? 1 : 0.45)
        row("back", "Come back to this window", "focus right").opacity(o.done.contains("move") ? 1 : 0.45)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .frame(width: 440)
      .padding(.vertical, 6)
      Button(o.done.contains("back") ? "Continue" : "Skip") { o.next() }
        .controlSize(.large).keyboardShortcut(.defaultAction)
    }
    .animation(.default, value: o.done)
  }

  private func row(_ kind: String, _ title: String, _ command: String) -> some View {
    Check(o: o, kind: kind, title: title, command: command, cap: 32)
      .padding(.horizontal, 14).frame(height: 52).background(.white.opacity(0.08))
  }
}

/// The optional longer practice: a checklist in the corner, over real windows.
private struct Deep: View {
  @ObservedObject var o: Onboarding

  var body: some View {
    let tasks = [
      ("snap", "Snap to a corner", "snap top-left"), ("fullscreen", "Fill the screen", "fullscreen"),
      ("layout", "Float or tile", "layout floating tiling"), ("split", "Split it", "split right"),
      ("resize", "Grow a tile", "resize smart +50"),
    ]
    VStack(alignment: .leading, spacing: 13) {
      Text("Practice").font(.system(size: 22, weight: .bold, design: .rounded))
      Text("On any window, yours or a practice one.").font(.callout).foregroundStyle(.white.opacity(0.6))
      ForEach(tasks, id: \.0) { Check(o: o, kind: $0.0, title: $0.1, command: $0.2, cap: 26) }
      HStack {
        Button("Done") { o.close() }
        Spacer()
        Button("Practice Window") { o.addPractice() }.help("Opens another spare window")
      }
      .padding(.top, 6)
    }
    .padding(.horizontal, 22)
    .padding(.top, 30)
    .animation(.default, value: o.done)
  }
}

/// One line of a checklist: ticked once that kind of command has run.
private struct Check: View {
  @ObservedObject var o: Onboarding
  let kind: String
  let title: String
  let command: String
  let cap: CGFloat

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: o.done.contains(kind) ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(o.done.contains(kind) ? Color.green : .white.opacity(0.35))
      Text(title)
      Spacer()
      HStack(spacing: 3) {
        let binding = (manager.config.modes["main"] ?? [:]).first { $0.value == [command] }?.key
        ForEach(Array(keys(binding).enumerated()), id: \.offset) { Keycap(text: $0.element, height: cap) }
      }
    }
  }
}

/// A window with nothing in it to lose: something to move. Each has its own
/// colour and number; the tour's first one lists what to try on it.
private struct PracticeView: View {
  @ObservedObject var o: Onboarding
  let n: Int
  let guide: Bool  // the longer practice's list of things to try
  var basics = false  // the tutorial's: says what to do next, one step at a time
  @Environment(\.controlActiveState) private var active

  var body: some View {
    let hue = [0.72, 0.58, 0.45, 0.08, 0.92, 0.3][(n - 1) % 6]
    let main = manager.config.modes["main"] ?? [:]
    let tries = [
      ("Snap me to a side", "move right"), ("Top-left quarter", "snap top-left"), ("Fill the screen", "fullscreen"),
      ("Put me in the layout", "layout floating tiling"), ("Then split me", "split right"),
    ]
    VStack(spacing: guide ? 9 : 6) {
      if guide {
        Text("Try these on me").font(.system(size: 20, weight: .bold, design: .rounded)).padding(.bottom, 4)
        ForEach(tries, id: \.1) { title, command in
          HStack(spacing: 8) {
            Text(title)
            Spacer()
            HStack(spacing: 3) {
              ForEach(Array(keys(main.first { $0.value == [command] }?.key).enumerated()), id: \.offset) {
                Keycap(text: $0.element, height: 24)
              }
            }
          }
          .frame(width: 300)
        }
      } else if basics {
        let (say, command) =
          !o.done.contains("focus")
          ? ("Focus this window", "focus left")
          : !o.done.contains("move")
            ? ("Move me to the left of the screen", "move left") : ("Now go back to the tutorial", "focus right")
        Text(say).font(.system(size: 22, weight: .bold, design: .rounded))
        HStack(spacing: 4) {
          ForEach(Array(keys(main.first { $0.value == [command] }?.key).enumerated()), id: \.offset) {
            Keycap(text: $0.element, height: 38)
          }
        }
        .padding(.vertical, 8)
        Button("Skip") { o.next() }
      } else {
        Text("\(n)").font(.system(size: 84, weight: .bold, design: .rounded))
        Text(active == .key ? "Focused" : "Practice window").font(.title3).opacity(0.7)
      }
    }
    .foregroundStyle(.white)
    .opacity(active == .key || basics ? 1 : 0.55)
    .animation(.default, value: o.done)
    .frame(minWidth: 200, maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
    .background(
      LinearGradient(
        colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55), Color(hue: hue, saturation: 0.7, brightness: 0.25)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    .clipped()
    .ignoresSafeArea()
    .preferredColorScheme(.dark)
  }
}

private struct Keycap: View {
  let text: String
  var height: CGFloat = 40

  var body: some View {
    Text(text).font(.system(size: height * 0.44, weight: .medium, design: .rounded))
      .frame(minWidth: height * 0.5).padding(.horizontal, height * 0.22).frame(height: height)
      .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: height * 0.24, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: height * 0.24, style: .continuous).strokeBorder(.white.opacity(0.22)))
  }
}

private struct Done: View {
  let o: Onboarding
  @State private var login = SMAppService.mainApp.status == .enabled

  var body: some View {
    VStack(spacing: 16) {
      Logo(size: 96)
      Text("You're set").font(.system(size: 34, weight: .bold, design: .rounded))
      Text("Rejig lives in the menu bar, showing each display's workspace.").foregroundStyle(.white.opacity(0.65))
      Toggle("Start at login", isOn: $login).toggleStyle(.checkbox)
        .onChange(of: login) { on in
          let service = SMAppService.mainApp
          do { try on ? service.register() : service.unregister() } catch { login = service.status == .enabled }
        }
      HStack(spacing: 12) {
        Button("Change Keys…") {
          o.close()
          o.openSettings()
        }
        Button("Keep Practicing") { o.step = .deep }.help("Snaps, splits and layouts, on your own windows")
        Button("Done") { o.close() }.keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
      .padding(.top, 8)
    }
  }
}

private struct DragApp: NSViewRepresentable {
  func makeNSView(context _: Context) -> DragIcon {
    let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    image.size = NSSize(width: 112, height: 112)  // it comes at 32 pt and an image view won't scale it up
    let icon = DragIcon(image: image)
    icon.toolTip = "Drag me into the Accessibility list"
    return icon
  }

  func updateNSView(_: DragIcon, context _: Context) {}
}

/// The app's icon, draggable as the app itself, for dropping into the Settings list.
private final class DragIcon: NSImageView, NSDraggingSource {
  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
    item.setDraggingFrame(bounds, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation {
    .copy
  }
}
