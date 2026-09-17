import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// A macOS Mission-Control-style strip across the top of the screen: one tile
// per workspace, click to jump. Deliberately just the "Spaces bar" part —
// Hyprland already tiles windows within a workspace better than macOS does,
// so this doesn't try to preview/tile window contents, just which apps (by
// icon) are on each workspace.
//
// Driven by the shell's generic overlay IPC (open/close/toggle), same
// contract as the built-in overlays (emojis, clipboard, image-picker):
// `omarchy-shell crazybadger.workspace-ribbon toggle`
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  function open(payloadJson) {
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "crazybadger.workspace-ribbon")
  }

  function toggle() { root.opened ? root.dismiss() : root.open("{}") }

  IpcHandler {
    target: (root.manifest && root.manifest.id) || "crazybadger.workspace-ribbon"
    function open(): void { root.open("{}") }
    function close(): void { root.dismiss() }
    function toggle(): void { root.toggle() }
  }

  // -------------------------------------------------------------- icons
  //
  // Qt's themed icon lookup (Quickshell.iconPath) misses plenty of apps even
  // when their .desktop Icon= exactly matches the WM class — the running
  // icon theme's index doesn't reach every icon file on disk. So, same fix
  // the shell's own app library uses: walk the XDG icon dirs ourselves and
  // index every app/device icon by filename, then prefer that exact hit
  // before falling back to the themed lookup and finally a generic icon.
  property var iconIndex: ({})
  property var _pendingIconIndex: ({})

  function iconIndexScanCommand() {
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length > 0 && root._pendingIconIndex[name] === undefined)
      root._pendingIconIndex[name] = value
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root._pendingIconIndex = ({})
    onExited: root.iconIndex = root._pendingIconIndex
  }

  Component.onCompleted: iconIndexScan.running = true

  // The index above is a snapshot from whenever this scan last ran — for a
  // keepLoaded overlay that's shell-start, once, forever. An icon installed
  // afterwards (e.g. a webapp added via `omarchy webapp add` after login)
  // then shows the generic fallback until `omarchy restart shell`. Rather
  // than require that, rescan on demand: whenever an icon genuinely fails to
  // resolve, ask for a rescan. Cooldown-gated (not per-name-gated) so it
  // stays cheap and simple — worst case, an app with truly no icon anywhere
  // costs one extra background `find` every `_rescanCooldownMs` while it's
  // on screen, which is negligible next to the win of new icons just
  // appearing next time the ribbon (re-)renders that tile.
  readonly property int _rescanCooldownMs: 8000
  property bool _rescanCoolingDown: false

  Timer {
    id: rescanCooldown
    interval: root._rescanCooldownMs
    onTriggered: root._rescanCoolingDown = false
  }

  function requestIconRescan() {
    if (root._rescanCoolingDown || iconIndexScan.running) return
    root._rescanCoolingDown = true
    rescanCooldown.restart()
    iconIndexScan.running = true
  }

  // Hyprland's own per-workspace toplevel objects (Hyprland.workspaces.values
  // [i].toplevels.values[j]) only carry title/address/workspace — NOT the WM
  // class, despite `hyprctl clients -j` calling it "class". The class/appId
  // only lives on the generic Wayland toplevel type (ToplevelManager.toplevels,
  // from the foreign-toplevel protocol). Neither type shares an id with the
  // other (no "address" on the Wayland side), so cross-reference by title —
  // good enough for icon lookup; a title collision just means two windows
  // briefly share an icon guess.
  function titleToAppId() {
    var map = ({})
    var values = ToplevelManager.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var t = values[i]
      var title = String(t.title || "")
      var appId = String(t.appId || "")
      if (title.length > 0 && appId.length > 0 && map[title] === undefined) map[title] = appId
    }
    return map
  }

  function appIdForToplevel(toplevel) {
    if (!toplevel) return ""
    var direct = String(toplevel.class || toplevel.appId || "")
    if (direct.length > 0) return direct
    var map = root.titleToAppId()
    return map[String(toplevel.title || "")] || ""
  }

  // Resolve one icon NAME (a WM class, or a .desktop Icon= value) to a
  // usable Image source: our own filename index first, then Qt's themed
  // lookup, retrying lowercased (WM classes are sometimes capitalised —
  // "Google-chrome" — where the icon name is lowercase). Returns "" if
  // nothing matched, so callers can chain further fallbacks before finally
  // giving up to a generic icon.
  function lookupIconName(name) {
    var id = String(name || "")
    if (id.length === 0) return ""
    var indexed = root.iconIndex[id]
    if (indexed) return Util.fileUrl(indexed)
    var themed = Quickshell.iconPath(id, true)
    if (themed.length > 0) return themed
    var lower = id.toLowerCase()
    if (lower !== id) {
      var indexedLower = root.iconIndex[lower]
      if (indexedLower) return Util.fileUrl(indexedLower)
      var themedLower = Quickshell.iconPath(lower, true)
      if (themedLower.length > 0) return themedLower
    }
    // Icon filenames commonly use hyphens where a WM class uses spaces or
    // different casing (e.g. class "Emby Theater" vs the installed icon
    // file "emby-theater.png") -- normalize once more before giving up.
    var normalized = lower.replace(/\s+/g, "-")
    if (normalized !== lower) {
      var indexedNorm = root.iconIndex[normalized]
      if (indexedNorm) return Util.fileUrl(indexedNorm)
      var themedNorm = Quickshell.iconPath(normalized, true)
      if (themedNorm.length > 0) return themedNorm
    }
    return ""
  }

  // Some apps' running WM class has no relation at all to their installed
  // icon — most webapps (Chrome derives the class from the URL, e.g.
  // "chrome-web.omnifocus.com__-Default" for a desktop entry with
  // Icon=omnifocus), and occasionally a native app too (Obsidian runs as
  // "md.obsidian.Obsidian" but its desktop entry says Icon=obsidian). Their
  // window titles do carry the app name, though ("OmniFocus for the Web",
  // "...- Obsidian - Obsidian 1.13.7"), so as a last resort, match against
  // installed .desktop entries' Name= — tried against both the class and
  // the title, since either can carry it. Bidirectional substring match:
  // usually the window text is the longer, more verbose one, but sometimes
  // it's shorter than the full app name (Emby Theater's window title is
  // just "Emby", shorter than its .desktop Name "Emby Theater") — check
  // both directions, each with a minimum length to avoid junk matches off a
  // short/generic string. Longest matching name wins.
  function desktopIconForText(text) {
    var t = String(text || "").toLowerCase()
    if (t.length < 3) return ""
    var entries = DesktopEntries.applications.values || []
    var bestIcon = ""
    var bestLen = 0
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      var name = String((e && e.name) || "").toLowerCase()
      if (name.length < 3) continue
      if (t.indexOf(name) === -1 && name.indexOf(t) === -1) continue
      if (name.length > bestLen) { bestLen = name.length; bestIcon = String((e && e.icon) || "") }
    }
    return bestIcon
  }

  function resolveIconForToplevel(toplevel) {
    if (!toplevel) return Quickshell.iconPath("application-x-executable", true)
    var appId = root.appIdForToplevel(toplevel)
    var found = root.lookupIconName(appId)
    if (found.length === 0) {
      var deIcon = root.desktopIconForText(appId) || root.desktopIconForText(toplevel.title)
      if (deIcon.length > 0) found = root.lookupIconName(deIcon)
    }
    if (found.length === 0) {
      // Falling through to the generic icon — ask for a rescan in case this
      // one's just new since our last index (see requestIconRescan above).
      // Deferred: don't mutate Process state mid-binding-evaluation.
      Qt.callLater(root.requestIconRescan)
      return Quickshell.iconPath("application-x-executable", true)
    }
    return found
  }

  // ------------------------------------------------------------ workspaces

  // Always show 1-9 (the standard row every Omarchy keybind reaches) plus
  // whatever extra/higher-numbered workspaces are actually in use.
  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && ids.indexOf(id) === -1) ids.push(id)
    }
    ids.sort(function(a, b) { return a - b })
    return ids
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function isFocused(id) {
    return Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === id
  }

  Process { id: focusProcess; running: false }

  function focusWorkspace(id) {
    // Same dispatcher the stock workspaces bar-widget uses.
    focusProcess.command = ["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"" + id + "\" })"]
    focusProcess.running = true
    root.dismiss()
  }

  // ---------------------------------------------------------------- style

  property color scrim: Color.menu.scrim
  property color surfaceColor: Color.menu.background
  readonly property int cornerRadius: Style.cornerRadius
  property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  readonly property int tileWidth: Style.space(104)
  readonly property int tileHeight: Style.space(84)

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "workspace-ribbon"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: strip
      width: row.implicitWidth + Style.spacing.xxl * 2
      height: row.implicitHeight + Style.spacing.xl * 2
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(28)
      color: root.surfaceColor
      borderSpec: root.borderSpec
      padding: 0

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            root.focusWorkspace(event.key - Qt.Key_0)
            event.accepted = true
          }
        }
      }

      RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.md

        Repeater {
          model: root.workspaceIds()

          delegate: Rectangle {
            id: tile
            required property int modelData

            readonly property var ws: root.workspaceById(modelData)
            readonly property var toplevels: ws ? ws.toplevels.values : []
            readonly property bool focused: root.isFocused(modelData)
            readonly property bool occupied: toplevels.length > 0

            Layout.preferredWidth: root.tileWidth
            Layout.preferredHeight: root.tileHeight
            radius: root.cornerRadius
            color: focused ? Color.menu.selectedBackground : "transparent"
            border.width: focused ? 2 : 1
            border.color: focused ? Color.accent : Color.menu.border
            opacity: occupied || focused ? 1 : 0.55

            Behavior on opacity { NumberAnimation { duration: 120 } }

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: String(tile.modelData)
                color: tile.focused ? Color.menu.selectedText : Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.title
                font.bold: tile.focused
              }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.spacing.xs
                visible: tile.toplevels.length > 0

                Repeater {
                  model: tile.toplevels.slice(0, 5)
                  delegate: Image {
                    required property var modelData
                    // Re-evaluates once the icon index scan finishes (iconIndex
                    // changing invalidates this binding), so tiles upgrade from
                    // the generic fallback to the real icon automatically.
                    readonly property var _indexReady: root.iconIndex
                    source: root.resolveIconForToplevel(modelData)
                    sourceSize.width: Style.space(16)
                    sourceSize.height: Style.space(16)
                    width: Style.space(16)
                    height: Style.space(16)
                    fillMode: Image.PreserveAspectFit
                  }
                }

                Text {
                  visible: tile.toplevels.length > 5
                  text: "+" + (tile.toplevels.length - 5)
                  color: tile.focused ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Math.max(8, Style.font.title - 4)
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.focusWorkspace(tile.modelData)
            }
          }
        }
      }
    }
  }
}
