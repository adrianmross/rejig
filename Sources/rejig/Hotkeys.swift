import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey: public, event-driven,
/// needs no permission, and only ever sees the combinations registered here.
final class Hotkeys {
  private var refs: [EventHotKeyRef?] = []
  private var actions: [UInt32: () -> Void] = [:]

  init() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, ctx in
        var id = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &id)
        Unmanaged<Hotkeys>.fromOpaque(ctx!).takeUnretainedValue().actions[id.id]?()
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
  }

  /// Replaces every registered hotkey. Returns the bindings that could not be
  /// registered: unknown key names, or combinations something else already owns.
  func set(_ bindings: [(String, () -> Void)]) -> [String] {
    refs.forEach { UnregisterEventHotKey($0) }
    refs = []
    actions = [:]
    var refused: [String] = []
    for (i, (name, action)) in bindings.enumerated() {
      var ref: EventHotKeyRef?
      if let (key, mods) = Hotkeys.parse(name),
        RegisterEventHotKey(
          key, mods, EventHotKeyID(signature: 0x544C_5350, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
          == noErr
      {
        refs.append(ref)
        actions[UInt32(i)] = action
      } else {
        refused.append(name)
      }
    }
    return refused
  }

  /// "alt-shift-h" -> (virtual key code, Carbon modifier mask), AeroSpace's key names.
  static func parse(_ binding: String) -> (UInt32, UInt32)? {
    var parts = binding.split(separator: "-").map(String.init)
    guard let key = parts.popLast().flatMap({ keys[$0] }) else { return nil }
    var mods = 0
    for m in parts {
      guard let bit = ["alt": optionKey, "ctrl": controlKey, "shift": shiftKey, "cmd": cmdKey][m] else { return nil }
      mods |= bit
    }
    return (UInt32(key), UInt32(mods))
  }

  /// Presses a combination as if typed, e.g. the launcher's.
  static func press(_ binding: String) {
    guard let (key, mods) = parse(binding) else { return }
    var flags = CGEventFlags()
    for (bit, flag) in [
      (cmdKey, CGEventFlags.maskCommand), (optionKey, .maskAlternate), (controlKey, .maskControl),
      (shiftKey, .maskShift),
    ] where Int(mods) & bit != 0 { flags.insert(flag) }
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
      e?.flags = down ? flags : []
      e?.post(tap: .cghidEventTap)
    }
  }

  // ANSI virtual key codes: positions on a QWERTY board, like AeroSpace's qwerty preset
  static let keys: [String: Int] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24,
    "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29, "rightSquareBracket": 30, "o": 31, "u": 32,
    "leftSquareBracket": 33, "i": 34, "p": 35, "enter": 36, "l": 37, "j": 38, "quote": 39, "k": 40,
    "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47, "tab": 48,
    "space": 49, "backtick": 50, "backspace": 51, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
  ]
}
