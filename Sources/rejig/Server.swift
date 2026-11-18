import AppKit

/// The control socket, the way Rex has one. `rejig <command>` connects, sends
/// one JSON line `{"command": "focus left", "caller": <pid>}` and reads one
/// back, `{"ok": true, "out": "..."}`, when the command has finished.
/// `subscribe` keeps the connection and is sent one event per line. The socket
/// file is the user's alone, and the kernel is asked who is on the other end.
enum Socket {
  static let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/rejig/server.sock").path

  static func open() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))  // a vanished peer is an error, not a signal
    return fd
  }

  /// `bind` or `connect`, on the socket's path.
  static func attach(_ fd: Int32, _ call: (Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int32) -> Bool {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { to in
      to.copyBytes(from: path.utf8.prefix(to.count - 1))
    }
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { call(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    } == 0
  }

  /// Everything up to the first newline, or to the end.
  static func line(_ fd: Int32) -> Data {
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !data.contains(10) {
      let n = read(fd, &chunk, chunk.count)
      if n <= 0 { break }
      data.append(contentsOf: chunk[0..<n])
    }
    return data
  }

  @discardableResult static func send(_ fd: Int32, _ object: [String: Any]) -> Bool {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
    data.append(10)
    return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
  }

  /// The command-line side: one request, one answer, the exit status to match.
  static func call(_ command: String) -> Never {
    let fd = open()
    guard attach(fd, connect) else {
      fputs("rejig is not running\n", stderr)
      exit(1)
    }
    send(fd, ["command": command, "caller": Int(getppid())])
    if command == "events" || command == "subscribe" {
      // one JSON object per line, for as long as this runs: {"event": "focus-changed", ...}
      var chunk = [UInt8](repeating: 0, count: 65536)
      while case let n = read(fd, &chunk, chunk.count), n > 0 { fwrite(chunk, 1, n, stdout); fflush(stdout) }
      exit(0)
    }
    var wait = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    guard let answer = (try? JSONSerialization.jsonObject(with: line(fd))) as? [String: Any] else {
      fputs("no answer from Rejig\n", stderr)
      exit(1)
    }
    let ok = answer["ok"] as? Bool ?? false
    let out = answer["out"] as? String ?? ""
    if !out.isEmpty { fputs(out + "\n", ok ? stdout : stderr) }
    exit(ok ? 0 : 1)
  }
}

final class Server {
  typealias Handler = (_ command: String, _ caller: pid_t, _ reply: @escaping (Bool, String) -> Void) -> Void
  private var source: DispatchSourceRead?
  private var subscribers: [Int32] = []

  /// Nil, or why the socket could not be opened.
  func start(_ handle: @escaping Handler) -> String? {
    try? FileManager.default.createDirectory(
      atPath: (Socket.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    unlink(Socket.path)  // ponytail: a second copy of the app takes the socket from the first
    let fd = Socket.open()
    guard Socket.attach(fd, bind), listen(fd, 16) == 0 else { return String(cString: strerror(errno)) }
    chmod(Socket.path, 0o600)
    let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    s.setEventHandler { [unowned self] in self.accept(fd, handle) }
    s.resume()
    source = s
    return nil
  }

  private func accept(_ listener: Int32, _ handle: @escaping Handler) {
    let fd = Darwin.accept(listener, nil, nil)
    guard fd >= 0 else { return }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var peer = xucred()
    var size = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &peer, &size) == 0, peer.cr_uid == getuid() else {
      close(fd)
      return
    }
    // the request is read off the main thread, so a slow client can't stall the window manager
    DispatchQueue.global(qos: .userInitiated).async {
      var wait = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
      let request = (try? JSONSerialization.jsonObject(with: Socket.line(fd))) as? [String: Any]
      DispatchQueue.main.async {
        guard let command = request?["command"] as? String else {
          Socket.send(fd, ["ok": false, "out": "expected {\"command\": \"...\"}"])
          close(fd)
          return
        }
        if command == "events" || command == "subscribe" {
          // never wait on a listener that has stopped reading
          _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
          self.subscribers.append(fd)
          return
        }
        handle(command, pid_t(request?["caller"] as? Int ?? 0)) { ok, out in
          Socket.send(fd, ["ok": ok, "out": out])
          close(fd)
        }
      }
    }
  }

  /// One event to every `subscribe`; a listener that is gone or not keeping up is dropped.
  func emit(_ event: [String: Any]) {
    subscribers = subscribers.filter { fd in
      if Socket.send(fd, event) { return true }
      close(fd)
      return false
    }
  }
}

/// Every command, once: `--help` and `rejig api` are both made from this.
let commands: [(usage: String, does: String)] = [
  ("focus left|down|up|right", "focus the window on that side; with a window flag and no direction, that window"),
  ("move left|down|up|right", "move the window: a tile within the layout, a floating one through halves and displays"),
  ("move --frame x,y,w,h", "float the window at an exact frame, in points from the main display's top-left"),
  ("snap <place>|restore", "top-left, top-right, bottom-left, bottom-right, left-third, center-third, right-third, left-two-thirds, right-two-thirds, center, maximize"),
  ("layout floating tiling", "float the window, or put it in the layout"),
  ("layout tiles|accordion horizontal vertical", "change the layout the window is in"),
  ("fullscreen", "fill the workspace, or go back"),
  ("split right|down", "the next window opened or picked takes half of this one's tile"),
  ("resize smart <n>", "grow or shrink the tile by n points"),
  ("workspace <n>|next|prev", "switch desktop; returns when it has arrived"),
  ("workspace-back-and-forth", "switch to the desktop you were on before"),
  ("move-node-to-workspace <n> [--stay]", "send the window to a desktop; --stay puts your desktop, focus and pointer back"),
  ("fetch [--workspace <n>]", "bring a window from a hidden desktop to this one"),
  ("hold [--by <name>] [--agent-screen | --workspace <n>] [--owner-pid <pid>]", "an agent takes the window: never tiled, resized or focused until released, or until that process exits; --agent-screen also moves it to the display with no monitor"),
  ("agent-screen [show|tile|off]", "make the agent screen and print where it is as JSON; show opens a live view of it; tile lays its windows out too; off removes it"),
  ("practice [--agent-screen] [--tile] | practice close", "open a spare window and print its number; close them all"),
  ("style highlight|shadow|plain", "how tiled windows are marked, until the config is next read"),
  ("release", "give held windows back, to where they were: one with a window flag, otherwise all"),
  ("list-windows", "JSON: id, pid, app, title, workspace, display, frame, state, heldBy, visible, focused"),
  ("list-workspaces", "JSON: number, display, visible, focused"),
  ("events", "events as JSON lines until interrupted: window-opened, window-closed, focus-changed, workspace-changed, held-changed, screen-locked, screen-unlocked"),
  ("tiling toggle", "tiling on or off for this workspace"),
  ("reload-config", "read the config file again"),
  ("settings [tab] | welcome [step] | onboarding", "open Settings, the tutorial, or the setup step"),
  ("api", "this list as JSON"),
  ("skill show|install", "the guide for agents, or put it where Claude Code finds it"),
]

let usage =
  """
  rejig <command> [--window-id <CGWindowID> | --rex-session <label>]
  Acts on the focused window unless told which. Exit status 1 comes with the reason on stderr.


  """ + commands.map { "  \($0.usage)\n      \($0.does)" }.joined(separator: "\n")

/// What an agent needs to know to use Rejig, as `rex skill show` is for Rex.
let skill = """
  ---
  name: rejig
  description: Use the rejig CLI to arrange macOS windows, send them to other desktops, hold windows for automation, and listen for window events.
  ---

  # Rejig

  Rejig is the window manager on this Mac. Workspaces are real macOS desktops,
  numbered as Mission Control counts them. `rejig <command>` talks to the app,
  waits until the command has finished, and exits 1 with the reason on stderr
  if it failed. `rejig api` lists every command as JSON.

  ## Rules

  - Name your window. Without `--window-id <CGWindowID>` (or `--rex-session
    <label>` for a Rex window) a command acts on whatever the user has focused,
    which is theirs, not yours.
  - Take what you automate: `rejig hold --window-id ID --by <your name>
    --owner-pid $$`. A held window is never tiled, resized or focused by Rejig,
    and is released when that process exits. `rejig release --window-id ID`
    when you are done. The user sees held windows in the menu and can take
    them back; `held-changed` tells you.
  - Work on the agent screen when you can: `rejig hold --window-id ID
    --agent-screen` moves the window to a display with no monitor. Nothing
    slides and the user is not interrupted; `release` puts it back where it was.
    The user can watch it with "Show Agent Screen" in the menu.
  - Changing desktop is visible: the screen slides. `move-node-to-workspace N
    --stay` and `fetch` each slide twice and hold the title bar for half a
    second. Batch such work and ask before a long run of it.
  - Read state, don't assume it: `rejig list-windows` and `rejig
    list-workspaces` print JSON. A window on a hidden desktop that Rejig has
    never watched has state `unseen` and no title.

  ## Recipes

  Find a window:

      rejig list-windows | jq '.[] | select(.app == "Safari") | {id, title, workspace}'

  Park a window out of the user's way, work on it, bring it back:

      rejig hold --window-id "$id" --by me --owner-pid $$ --agent-screen
      rejig release --window-id "$id"

  The same on a real desktop the user can switch to (this one slides):

      rejig hold --window-id "$id" --by me --owner-pid $$ --workspace 4
      rejig fetch --window-id "$id"
      rejig release --window-id "$id"

  Give a window an exact size for a recording:

      rejig move --frame 100,100,1600,1000 --window-id "$id"

  Wait for something instead of sleeping:

      rejig events | jq -c 'select(.event == "window-opened")'

  The window showing a Rex session:

      rejig move-node-to-workspace 3 --rex-session "$label" --stay

  A harmless window to test on: `rejig practice`.
  """
