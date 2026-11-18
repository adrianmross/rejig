# Rejig

A small Swift/AppKit tiling window manager that keeps my AeroSpace bindings but
uses real macOS Spaces. Public APIs throughout, with one read-only private call
for desktop numbers (my choice; it falls back to public means if macOS drops it).
No scripting addition, SIP stays on.

## Setup

```sh
make install
```

This builds `Rejig.app`, signs it, copies it to `~/Applications` and opens it.
Then:

The first launch opens a welcome: a hello, the setup below, a choice of keys
(macOS or Vim first), a checklist to try them on your own windows, and a
goodbye. Replay it from Settings > General or with `rejig welcome`. `rejig
practice` opens a spare floating window to try things on. The setup step ticks off two things:

1. **Accessibility.** Open Settings from it, drag the icon into the list, switch
   it on. This is the only permission; no Screen Recording, no Input Monitoring.
2. **Desktop shortcuts.** "Turn On" ticks macOS's "Switch to Desktop 1" to "6"
   (Control-1 to Control-6 unless you chose other keys), which is how workspaces
   are switched. From a script: `rejig enable-desktop-shortcuts`. Add desktops
   in Mission Control if you want more workspaces; a shortcut does nothing until
   its desktop exists.

After the first run the setup step closes by itself when both are done, and
comes back from the menu or when you press a workspace key whose shortcut is off.

3. **Start at login** is in Settings > General.

Recommended in System Settings > Desktop & Dock: turn off "Automatically
rearrange Spaces based on most recent use" (otherwise desktop numbers shuffle),
and it is fine to leave macOS's own tiling on ("Drag windows to screen edges to
tile", Window > Move & Resize): Rejig never writes a floating window's frame,
so native tiling works on floating windows and on workspaces with tiling off. On
a tiled window, a native tile is treated like any mouse resize.

## Configuration

"Settings…" in the ▦ menu (or `rejig settings`) covers gaps, borders, float rules, the menu-bar readout,
new and fixed-size windows, borders, the direction-key preset, and every shortcut: click one, press
the new keys. It writes `~/.config/rejig/config.json`, which can also be edited
by hand; the file holds only the keys that differ from the defaults:

```json
{
  "gaps": { "inner": 5, "top": 7, "left": 5, "bottom": 5, "right": 5, "accordion": 30 },
  "float": ["keepassxc", "messages"],
  "tile": ["com.mitchellh.ghostty"],
  "border": { "active": "#E1E3E4", "inactive": "#494D64", "width": 5 },
  "fixedSize": "float",
  "menuBar": "all",
  "menuBarIcon": false,
  "keys": "macos",
  "newWindows": "float",
  "style": "highlight",
  "launcher": "cmd-space",
  "startup": [],
  "modes": { "main": { "alt-enter": ["fullscreen"] } }
}
```

`fixedSize` decides what happens to a window that won't take the size of its
tile, like System Settings with its fixed width: `"float"` (default) takes it out
of the layout, `"tile"` keeps it in at whatever size it does take. `menuBar` is
`"all"` (every display's workspace), `"focused"` (one number) or `"icon"`;
`menuBarIcon` adds the icon before the numbers. `animate` (default on) glides
floating windows to where the snap keys send them; turn it off if an app stutters. `style` is `"highlight"` (borders),
`"shadow"` (a glow round the focused window) or `"plain"`. `keys` picks the
keybinding preset: `"macos"` (default) is Control-Option-arrows to focus and
Control-Option-Shift-arrows to move, `"vim"` is Option-h/j/k/l as in AeroSpace,
`"rex"` puts everything on Control-Command (numbers, `[` `]`, `D`), and presets
saved from Settings live under `presets`. `newWindows` is what happens to a window opened after Rejig started:
`"float"` (default) leaves it where and at the size macOS restored it until you
toggle it into the layout (`Option-Control-F`), `"tile"` lays it out at once, which
shows as a jump because a window can only be resized after it appears. Windows
already open at launch, and apps in `tile`, are tiled either way. `highlight`
turns the borders off. In
`modes`, an empty list (`"alt-tab": []`) unbinds a default key.

Bindings and commands use AeroSpace's names (`alt-shift-h`, `move left`,
`resize smart -50`, ...). Reload from Settings > General, or `Option-Shift-;` then `Esc`.

## Controls

The same keys as my AeroSpace config (with `"keys": "vim"`; the default swaps
h/j/k/l for Control-Option-arrows), with workspaces 1 to 6. Service mode
(`Option-Shift-;`) shows `▦ service` in the menu bar; every service key returns
to main mode.

`Option-Control-T` (or "Tile This Workspace" in the menu) turns tiling off for
the workspace you are in: its windows stay where they are and macOS handles them
as usual until you turn it back on, when the previous layout returns. Other
workspaces are unaffected.

The menu bar shows the workspace on each display, left to right, with a star on
the display that has keyboard focus: `3|2*|5`. A `?` appears only if the private call for desktop numbers stops working
and a desktop's number hasn't been learned yet.

Split: `Option-D` (right) or `Option-Shift-D` (down) halves the focused tile and
opens the launcher (`launcher`, Command-Space by default); whatever window opens
next, or whichever open window you pick from the Dock or Cmd-Tab within 30
seconds, takes the new half. `Option-[` and `Option-]` step through workspaces.

Floating windows: the focus keys reach them like any other window. The move keys
step a floating window around its display the way Rectangle does: each press moves
it one step along that axis through near half, full span, far half. So left then
up is the top-left quarter, right from there is the top half, right again the
top-right quarter, and one more carries on to the next display. `fullscreen` on a
floating window fills the display; again puts it back.

Rectangle's named places work on any window, on Rectangle's keys: Control-Option
with `U` `I` `J` `K` for the quarters, `D` `S` `G` for thirds, `E` `R` for two
thirds, `C` to centre, Return to maximise and Delete to restore the size from
before the first snap. (`F` and `T` are already taken here, hence `S` and `R`.)
A tiled window leaves the layout to take a place.
macOS's own keys work on them too (Cmd-Tab, Cmd-`, and Window > Move & Resize).

With the mouse: moving or resizing a tiled window takes it out of the layout,
floating exactly as you left it (`"drag": "float"`, the default). With
`"drag": "adjust"` it stays tiled instead: resize it and its neighbours give way,
drop it onto another tiled window and they trade places. The ▦ menu has "Float
This Window" / "Tile This Window" for the focused window; macOS gives no way to
add that to a window's own right-click menu. A window that will not take the size
of its tile (System Settings has a fixed width) floats automatically, unless
`fixedSize` is `"tile"`; `Option-Control-F` forces one back into the layout.

Any command can also be sent from a terminal, like the `aerospace` CLI:

```sh
rejig focus left
```

`Backspace` in service mode closes every other tiled window on the
workspace by pressing each window's own close button, so apps still show their
unsaved-changes prompts and nothing is discarded silently.

## Scripting

`rejig <command>` talks to the running app over a Unix socket
(`~/Library/Application Support/rejig/server.sock`, readable by you alone) and
waits for its answer: output on stdout, or the reason on stderr with exit
status 1. It returns when the command has finished, including a workspace
slide. `rejig --help` lists the commands, `rejig api` gives the same list as
JSON, and `rejig skill show` prints a guide for agents (`rejig skill install`
puts it in `~/.claude/skills/rejig`).

The socket speaks JSON lines: send `{"command": "focus left"}`, read
`{"ok": true, "out": ""}`. `{"command": "subscribe"}` keeps the connection
open and receives one event per line.

- `--window-id <CGWindowID>` on any window command acts on that window instead
  of the focused one. The number is matched to a window by owning app and frame.
- `rejig list-windows` and `rejig list-workspaces` print JSON.
- `rejig move-node-to-workspace 3 --window-id ID --stay` sends a window away and
  puts your workspace, focus and pointer back. `rejig fetch --window-id ID
  --workspace 3` goes and gets it. Each plays the Space slide twice.
- `rejig hold --window-id ID --by NAME` hands a window to an agent: Rejig never
  tiles, resizes or focuses it until `rejig release` (all, or one with
  `--window-id`). Add `--workspace N` to send it there in the same step. While
  anything is held the menu shows "Release N Windows Held by NAME".
  `--owner-pid PID` ends the hold when that process exits, so a crashed agent
  leaves nothing held.
- `--rex-session LABEL` in place of `--window-id` names the macOS window showing
  that Rex session (matched by its title). On `hold` it also ends the hold when
  the session ends.
- `rejig subscribe` prints events as JSON lines until interrupted:
  `window-opened`, `window-closed`, `focus-changed` (each with id, pid, app,
  title), `workspace-changed` (the desktop showing on each display) and
  `held-changed`.
- `list-windows` also lists windows Rejig has never met (state `unseen`), such
  as those on hidden desktops after a restart, with what the window server
  knows: id, pid, app, frame and workspace, but no title.
- `rejig move --frame x,y,w,h --window-id ID` floats a window at an exact frame,
  in points from the main display's top-left; it fails if the window refuses it.
- `"unmanagedDisplays": ["name"]` in the config keeps Rejig off a display.

## What is public API and what is not

| Capability | Mechanism | Kind |
|---|---|---|
| Hotkeys | Carbon `RegisterEventHotKey` | documented public API |
| Find, focus, move, resize, close windows | Accessibility (`AXUIElement`, `AXObserver`) | documented public API |
| App, Space, wake, display events | `NSWorkspace` and `NSApplication` notifications | documented public API |
| Which Space is showing | the id in `CGSCopyManagedDisplaySpaces` (below). Without it: own invisible marker window per Space, `NSWindow.isOnActiveSpace` | **private API**, with a public fallback |
| Switch to Space N | posts your "Switch to Desktop N" shortcut (`CGEvent`) | user-configured shortcut |
| Move a window to Space N | holds the title bar with a synthetic mouse press, then posts the shortcut | UI automation |
| Desktop numbers | `CGSCopyManagedDisplaySpaces`, marked `HACK` in `Spaces.swift`; read-only, found by name at run time. Without it: learned when switching by number, and read from the `com.apple.spaces` preferences at launch | **private API**, with a public fallback |
| Which desktop a window is on, when it is not showing | `CGSCopySpacesForWindows`, marked `HACK` in `Spaces.swift`; read-only, found by name at run time. Without it: only for windows Rejig has watched | **private API**, with a public fallback |
| Turning on the desktop shortcuts | writes `com.apple.symbolichotkeys`, then runs macOS's `activateSettings -u` so it applies without logging out | public call, undocumented keys and tool |
| Move a Space to another display | not possible | private API only; Mission Control lifts a desktop for a synthetic drag but refuses the drop on another display |
| Permission-granted event | `com.apple.accessibility.api` distributed notification | public API, undocumented name |
| Borders | own click-through overlay windows below and above normal windows | documented public API |

macOS's own window tiling can only be driven through menu items and covers
halves and quarters, not n-way splits, gaps or accordions, so placement here is
custom, through Accessibility.

Nothing polls. A reconcile runs only after an event, coalesced over 50 ms, asks
only the app that raised it (every app after a Space, display or configuration
change), and writes a window's frame only when it differs from the layout.

## Compared with the AeroSpace config

Status as of 2026-11-17 on macOS 27.2.1. "Working" was exercised live on this
Mac through the CLI. "Built" means implemented, and unit-tested where it is pure
logic, but not yet exercised live.

| Feature | Status | Notes |
|---|---|---|
| Tiles, auto root orientation | built | |
| Accordion, 30 pt padding | built | |
| Gaps 5 / top 7 | built | unit-tested |
| Flatten and opposite-orientation normalization | built | unit-tested |
| Focus h/j/k/l | working, partial | geometric nearest window, not AeroSpace's tree walk; includes floating windows |
| Move h/j/k/l, across monitors at the edge | built | unit-tested |
| Smart resize | built | unit-tested |
| Fullscreen | built | fills the workspace like AeroSpace, not a native full-screen Space |
| Float toggle, float rules, Ghostty tile rule | built | |
| Move a floating window | working | not in AeroSpace: steps through halves, quarters and displays (unit-tested; left, up, right seen live) |
| Workspace 1 to 6 | working, partial | needs the desktop shortcuts on (one button); plays the Space slide animation; this Mac has 5 desktops, so 6 does nothing yet |
| Move window to workspace | working, partial | UI automation: grabs a bare part of the title bar and moves the pointer briefly. Carried a Rex window there and back; a QuickTime video window (no title bar) stayed behind |
| Back and forth | working | |
| Split right / down | working | not in AeroSpace; split-down with the real hotkey put a newly launched app under the focused tile |
| Quarters, thirds, two thirds, centre, maximise, restore | built | not in AeroSpace; `snap <place>`; top-left, right third and restore seen with the real hotkeys |
| Workspaces in the menu bar | working | not in AeroSpace; exact numbers from the window server, seen across a switch and back |
| Move workspace to next monitor | partial | sends the workspace's tiled windows to the next monitor; the Space itself cannot move. Automating the Mission Control drag was tried and macOS refused the drop |
| Workspace to monitor assignment | unsupported | arrange desktops per display in Mission Control once; macOS remembers per display |
| Persistent workspaces | working | native Spaces persist by themselves |
| Service mode | working | entered and left with the real hotkeys (`rejig press <keys>` types them from the app) |
| Mouse follows focus to another monitor | built | |
| Borders | working | exact colours and width measured on screen; tiled windows only, floating windows have none |
| Per-workspace tiling on/off | working | not in AeroSpace; exercised through the CLI |
| Fixed-size windows | working | floated automatically, or tiled at their own size with `fixedSize: tile` (both seen with System Settings and QuickTime Player) |
| Start at login | built | `SMAppService`, toggled from the menu |
| Hotkey registration | working | all combinations register on macOS 27.2.1 |
| Windows on other Spaces | by design | Accessibility only lists visible Spaces; hidden workspaces keep their layout untouched |
| Manual move and resize with the mouse | built | on mouse-up: floats the window, or with `drag: adjust` resizes neighbours and swaps; not tried by hand |
| Full-screen apps | by design | a full-screen Space is left alone |

## Diagnostics

"Copy Diagnostics" in the menu, or from a terminal:

```sh
pkill -USR1 -x rejig
```

```sh
cat "$HOME/Library/Logs/rejig-diagnostics.txt"
```

The report shows permission state, which desktop shortcuts are on, hotkeys that
could not be registered, reconcile timings, and every tiled window per display.

## Troubleshooting

- **Nothing tiles.** Accessibility is off, or Rejig is paused (it starts
  paused if AeroSpace is running). Check the menu.
- **Beep on Option-number.** That desktop's shortcut is off; the setup panel opens.
- **Option-number does nothing.** That desktop doesn't exist; add it in Mission Control.
- **Permission asked again after a rebuild.** The build was ad-hoc signed. Pass
  an identity: `make install SIGN_ID="Developer ID Application: ..."`.
- **Reconciles are slow.** The diagnostics name the slowest apps to answer. An
  app that times out is skipped until it next does something.

## Rollback

Pause from the menu to stop all hotkeys and window writes at once, or quit.
To remove it completely:

```sh
make uninstall
```

AeroSpace's config is untouched. Start AeroSpace again after quitting Rejig;
if both are running, Rejig starts paused.

## Development

```sh
make test
```
