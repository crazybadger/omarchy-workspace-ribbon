# Workspace Ribbon

A macOS Mission-Control-style strip of workspaces across the top of the
screen — deliberately just the "Spaces bar" part, not the window-tiling part.
Hyprland already manages windows within a workspace better than macOS does,
so this doesn't try to preview or tile window contents; it just shows which
workspaces exist, what's roughly on each (by app icon), and lets you click
to jump.

## Install

```bash
omarchy plugin add https://github.com/crazybadger/omarchy-workspace-ribbon.git
omarchy plugin enable crazybadger.workspace-ribbon
```

That installs and enables it, but nothing triggers it yet — add the gesture
(or a keybind) from **Trigger it** below, then `omarchy restart shell`.

## Trigger it

Bound to 3-finger swipes in `~/.config/hypr/input.lua`: swipe up toggles it
open/closed, swipe down always closes (mirrors macOS Mission Control):

```lua
hl.gesture({ fingers = 3, direction = "up", action = function()
  hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell toggle crazybadger.workspace-ribbon"))
end })
hl.gesture({ fingers = 3, direction = "down", action = function()
  hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell hide crazybadger.workspace-ribbon"))
end })
```

Independent of the stock 3-finger horizontal swipe (left/right workspace
switching) — the three coexist fine since they're separate `direction`
registrations.

Or drive it directly, from anywhere:

```bash
omarchy-shell shell toggle crazybadger.workspace-ribbon
omarchy-shell shell summon crazybadger.workspace-ribbon   # open only
omarchy-shell shell hide crazybadger.workspace-ribbon     # close only
```

Bind it to a key instead/as well, in `bindings.lua`:

```lua
o.bind("SUPER + TAB", "Workspace ribbon", "omarchy-shell shell toggle crazybadger.workspace-ribbon")
```

## Using it

- Click a tile to jump to that workspace (dismisses the ribbon).
- Number keys `1`-`9` while it's open jump directly.
- `Esc`, or clicking outside the strip, dismisses without switching.
- Workspaces 1-9 always show; any higher-numbered workspace in use is
  appended. The focused workspace is highlighted. Each tile shows up to 5
  small icons for the apps open on it (+N if there are more), and dims
  slightly when empty.

## How it's built

- `kinds: ["overlay"]` — a fullscreen transparent `PanelWindow`
  (`WlrLayershell.layer: Overlay`, exclusive keyboard focus while open),
  same architecture as the built-in emoji picker/clipboard overlays.
- Workspace + window data comes from `Quickshell.Hyprland`
  (`Hyprland.workspaces`, `Hyprland.focusedWorkspace`) — reactive, no
  polling. Hyprland's own per-workspace toplevel objects only carry
  `title`/`address`/`workspace` — no WM class, despite `hyprctl clients -j`
  calling that field `class`. The WM class only lives on the generic Wayland
  toplevel type (`ToplevelManager.toplevels`, the foreign-toplevel-protocol
  object `ActiveWindow.qml` also uses), which shares no id with Hyprland's
  own toplevels — so icon lookup cross-references the two by matching
  `title` (`appIdForToplevel()`).
- Icons, three-tier fallback per window:
  1. Qt's themed lookup (`Quickshell.iconPath`) misses plenty of apps even
     with an exact WM-class/Icon= match — the active icon theme's index
     doesn't reach every file on disk. So, same fix the shell's own app
     library uses internally: walk the XDG icon directories once at startup
     (`find … -path "*/apps/*" -o -path "*/devices/*"`) and index every icon
     by filename, preferring that exact hit before falling back to the
     themed lookup. Self-contained — doesn't depend on the shell's internal
     `AppLibrary`/`PluginAppLibraryApi`, which third-party overlay plugins
     aren't granted anyway.
  2. Some apps' running WM class has no relation to their installed icon at
     all — most webapps (Chrome derives the class from the URL, e.g.
     `chrome-web.omnifocus.com__-Default` for a desktop entry with
     `Icon=omnifocus`), and occasionally a native app too (Obsidian runs as
     `md.obsidian.Obsidian`, desktop entry says `Icon=obsidian`). Their
     window titles do carry the app name though, so as a last resort match
     the title against installed `.desktop` entries (`DesktopEntries`) and
     borrow that entry's `Icon=` — then run it back through step 1.
  3. A generic icon if nothing above matched — a tile never renders blank.
- Clicking a tile dispatches `hl.dsp.focus({ workspace = "<id>" })`, the
  same call the stock workspace bar-widget uses.
- `keepLoaded: true`, matching the built-in overlays — instantiated once at
  shell start and kept alive rather than rebuilt on every toggle. **Note for
  future edits:** because of this, live-editing this QML while the shell is
  already running doesn't reliably refresh an already-open instance — run
  `omarchy restart shell` after changes here, don't rely on hot-reload alone.

## Uninstall

```bash
omarchy plugin disable crazybadger.workspace-ribbon
rm -rf ~/.config/omarchy/plugins/crazybadger.workspace-ribbon
```
Then remove the `hl.gesture({ fingers = 3, direction = "up", ... })` block
from `~/.config/hypr/input.lua`.

## Credits

Built by [Claude](https://claude.com/claude-code) (Anthropic) — the idea,
testing and this repo's owner are [crazybadger](https://github.com/crazybadger)'s,
but every line of QML, the icon-resolution digging, and this README were
written by Claude Code in conversation with them. Seemed worth saying
plainly rather than taking the credit.
