import AppKit
import TileCore

/// Defaults mirror my AeroSpace config, except the direction keys (see `keys`);
/// ~/.config/tilespace/config.json overrides any key.
/// Commands use AeroSpace's names so bindings can be copied across.
struct Config: Decodable {
  var gaps = Gaps()
  /// Case-insensitive regex substrings of app names that float.
  var float = ["keepassxc", "messages", "cisco secure client", "authenticator", "facetime"]
  /// Bundle IDs that always tile, even when their windows don't look standard.
  var tile = ["com.mitchellh.ghostty"]
  /// Shell commands run once at launch.
  var startup: [String] = []
  var border = Border()
  /// A window that won't take its tile's size: "float" it, or "tile" it anyway at the size it keeps.
  var fixedSize = "float"
  /// Menu bar: "all" shows every display's workspace ("3|2*|5"), "focused" only
  /// the focused display's, "icon" just ▦. `menuBarIcon` puts ▦ before the numbers.
  var menuBar = "all"
  var menuBarIcon = false
  /// A window opened after launch: "float" leaves it at the size macOS restored, "tile" lays it out at once.
  var newWindows = "float"
  /// Moving or resizing a tiled window with the mouse: "float" takes it out of the layout as you left it,
  /// "adjust" keeps it tiled (a resize moves its neighbours, a drop onto another window swaps them).
  var drag = "float"
  /// Tiled windows: "highlight" draws borders, "shadow" a glow round the focused one, "plain" nothing.
  var style = "highlight"
  /// Pressed after `split`, to pick what fills the new half. Anything unparseable ("none") presses nothing.
  var launcher = "cmd-space"
  /// Keybinding preset: "macos" (Control-Option-arrows), "vim" (Option-h/j/k/l as
  /// in AeroSpace), "rex" (Control-Command throughout), or the name of a saved one.
  var keys = "macos"
  /// Presets saved from Settings: name -> a whole `modes` table.
  var presets: [String: Modes] = [:]
  typealias Modes = [String: [String: [String]]]

  /// Colours are "#RRGGBB". A width of 0 turns borders off.
  struct Border: Decodable {
    var active = "#E1E3E4"
    var inactive = "#494D64"
    var width: CGFloat = 5

    init() {}
    private enum Key: String, CodingKey { case active, inactive, width }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Key.self)
      active = try c.decodeIfPresent(String.self, forKey: .active) ?? active
      inactive = try c.decodeIfPresent(String.self, forKey: .inactive) ?? inactive
      width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? width
    }

    var activeColor: NSColor { Border.color(active) }
    var inactiveColor: NSColor { Border.color(inactive) }
    private static func color(_ hex: String) -> NSColor {
      let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x808080
      return NSColor(
        srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255,
        alpha: 1)
    }
  }
  /// key -> commands, per mode. An empty command list unbinds a default key.
  var modes = Config.defaultModes("macos")

  static let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/tilespace/config.json")

  static func defaultModes(_ keys: String, _ saved: [String: Modes] = [:]) -> Modes {
    if let preset = saved[keys] { return preset }
    // Rex's shape (numbers, [ ], D) on Control-Command: bare Command would take those keys from every app
    let mod = keys == "rex" ? "cmd-ctrl" : "alt"
    var main: [String: [String]] = [
      "alt-ctrl-shift-f": ["fullscreen"],
      "alt-ctrl-f": ["layout floating tiling"],
      "alt-slash": ["layout tiles horizontal vertical"],
      "alt-comma": ["layout accordion horizontal vertical"],
      "alt-minus": ["resize smart -50"],
      "alt-equal": ["resize smart +50"],
      "alt-tab": ["workspace-back-and-forth"],
      "alt-shift-tab": ["move-workspace-to-monitor --wrap-around next"],
      "alt-shift-semicolon": ["mode service"],
      "alt-ctrl-t": ["tiling toggle"],
      "\(mod)-leftSquareBracket": ["workspace prev"],
      "\(mod)-rightSquareBracket": ["workspace next"],
      "\(mod)-d": ["split right"],
      "\(mod)-shift-d": ["split down"],
    ]
    // Rectangle's keys, except where Control-Option-F and -T are already taken here
    for (key, place) in [
      ("u", "top-left"), ("i", "top-right"), ("j", "bottom-left"), ("k", "bottom-right"), ("d", "left-third"),
      ("s", "center-third"), ("g", "right-third"), ("e", "left-two-thirds"), ("r", "right-two-thirds"),
      ("c", "center"), ("enter", "maximize"), ("backspace", "restore"),
    ] { main["ctrl-alt-\(key)"] = ["snap \(place)"] }
    var service: [String: [String]] = [
      "esc": ["reload-config", "mode main"],
      "r": ["flatten-workspace-tree", "mode main"],
      "f": ["layout floating tiling", "mode main"],
      "backspace": ["close-all-windows-but-current", "mode main"],
    ]
    // Option-arrows belong to text editing, so the arrow preset adds Control
    for (key, dir) in [("h", "left"), ("j", "down"), ("k", "up"), ("l", "right")] {
      let (focus, move) =
        keys == "vim"
        ? ("alt-\(key)", "alt-shift-\(key)")
        : keys == "rex" ? ("cmd-ctrl-\(dir)", "cmd-ctrl-shift-\(dir)") : ("ctrl-alt-\(dir)", "ctrl-alt-shift-\(dir)")
      main[focus] = ["focus \(dir)"]
      main[move] = ["move \(dir)"]
      service[move] = ["join-with \(dir)", "mode main"]
    }
    for n in 1...6 {
      main["\(mod)-\(n)"] = ["workspace \(n)"]
      main["\(mod)-shift-\(n)"] = ["move-node-to-workspace \(n)"]
    }
    return ["main": main, "service": service]
  }

  init() {}

  private enum Key: String, CodingKey { case gaps, float, tile, startup, border, modes, fixedSize, showWorkspaces, keys, newWindows, highlight
    case style, menuBar, menuBarIcon, launcher, presets, drag
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    border = try c.decodeIfPresent(Border.self, forKey: .border) ?? border
    if let g = try c.decodeIfPresent([String: CGFloat].self, forKey: .gaps) {
      gaps.inner = g["inner"] ?? gaps.inner
      gaps.top = g["top"] ?? gaps.top
      gaps.left = g["left"] ?? gaps.left
      gaps.bottom = g["bottom"] ?? gaps.bottom
      gaps.right = g["right"] ?? gaps.right
      gaps.accordion = g["accordion"] ?? gaps.accordion
    }
    fixedSize = try c.decodeIfPresent(String.self, forKey: .fixedSize) ?? fixedSize
    // older files: showWorkspaces and highlight were switches
    if try c.decodeIfPresent(Bool.self, forKey: .showWorkspaces) == false { menuBar = "icon" }
    if try c.decodeIfPresent(Bool.self, forKey: .highlight) == false { style = "plain" }
    menuBar = try c.decodeIfPresent(String.self, forKey: .menuBar) ?? menuBar
    menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? menuBarIcon
    style = try c.decodeIfPresent(String.self, forKey: .style) ?? style
    drag = try c.decodeIfPresent(String.self, forKey: .drag) ?? drag
    launcher = try c.decodeIfPresent(String.self, forKey: .launcher) ?? launcher
    presets = try c.decodeIfPresent([String: Modes].self, forKey: .presets) ?? presets
    float = try c.decodeIfPresent([String].self, forKey: .float) ?? float
    tile = try c.decodeIfPresent([String].self, forKey: .tile) ?? tile
    startup = try c.decodeIfPresent([String].self, forKey: .startup) ?? startup
    keys = try c.decodeIfPresent(String.self, forKey: .keys) ?? keys
    newWindows = try c.decodeIfPresent(String.self, forKey: .newWindows) ?? newWindows
    modes = Config.defaultModes(keys, presets)
    // per-mode merge: a file that rebinds one key keeps the rest
    for (mode, keys) in try c.decodeIfPresent([String: [String: [String]]].self, forKey: .modes) ?? [:] {
      modes[mode, default: [:]].merge(keys) { $1 }
    }
  }

  /// A missing file means defaults. A broken file also means defaults, plus the error to show.
  static func load() -> (Config, String?) {
    guard let data = try? Data(contentsOf: url) else { return (Config(), nil) }
    do { return (try JSONDecoder().decode(Config.self, from: data), nil) } catch {
      return (Config(), "\(url.path): \(error)")
    }
  }
}
