pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons // qmllint disable import
import qs.Commons as Commons // qmllint disable import

// Windows 11-style snap layouts for floating Hyprland windows.
//
// Three ways in:
//   - Super+Z (Hyprland event "io.github.n0rthstar88.snap-layouts:toggle") opens the layout
//     picker for the focused window.
//   - Dragging a window to the top edge of a screen shows the same picker;
//     releasing over a zone snaps the window there. The plugin installs the
//     mouse binds for this itself (hook.lua); see "Drag-to-snap setting".
//   - omarchy-shell snaplayouts toggle
//
// After the first window is placed, "snap assist" offers the other open
// windows for each remaining zone of the chosen layout.
Item {
    id: root

    property var shell: null
    property var manifest: null
    readonly property string pluginId: "io.github.n0rthstar88.snap-layouts"

    // outerGap: space between snapped windows and the screen edge.
    // innerGap: space between snapped windows (0 = flush, borders touching).
    // borderSize must match Hyprland's general.border_size. Hyprland's Lua
    // config doesn't report these through `hyprctl getoption`, so they are set here.
    readonly property int outerGap: 10
    readonly property int innerGap: 0
    readonly property int borderSize: 2
    // titleBarHeight must match hyprbars' bar_height. The bar is drawn above
    // the window's own area, so when hyprbars is loaded windows are placed
    // this much lower to keep the bar inside the zone.
    readonly property int titleBarHeight: 24
    property bool hasTitleBars: false

    // How close (logical px) to the top of a screen the pointer must be while
    // dragging a window before the picker appears.
    readonly property int dragTriggerDistance: 30

    // Zones are [x, y, width, height] as fractions of the usable screen area.
    readonly property var layouts: [
        [[0, 0, 0.5, 1], [0.5, 0, 0.5, 1]],
        [[0, 0, 2 / 3, 1], [2 / 3, 0, 1 / 3, 1]],
        [[0, 0, 1 / 3, 1], [1 / 3, 0, 2 / 3, 1]],
        [[0, 0, 1 / 3, 1], [1 / 3, 0, 1 / 3, 1], [2 / 3, 0, 1 / 3, 1]],
        [[0, 0, 0.5, 1], [0.5, 0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]],
        [[0, 0, 0.5, 0.5], [0.5, 0, 0.5, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]]
    ]

    // "" hidden, "picker" (Super+Z), "drag" (window held at the top edge),
    // "assist" (choosing windows for the remaining zones).
    property string mode: ""
    readonly property bool opened: mode !== ""

    // Monitor the overlay is on: { name, x, y, w, h, reserved: [l, t, r, b],
    // workspaceId }. Logical pixels, global coordinates.
    property var monitor: null
    property var monitors: []
    property var clients: []
    property string targetAddress: ""

    property int hoverLayout: -1
    property int hoverZone: -1

    property int assistLayout: -1
    property var assistZones: []
    property var placedAddresses: []
    readonly property int assistZone: assistZones.length > 0 ? assistZones[0] : -1
    property var candidates: []

    // Drag tracking between the left-button press and release events.
    property bool buttonDown: false
    property var dragStart: null
    property bool dragging: false
    property double pressedAt: 0

    // ---------- Geometry ----------

    function monitorFromIpc(m) {
        var scale = Number(m.scale) || 1;
        var rotated = Number(m.transform) % 2 === 1;
        var w = (rotated ? m.height : m.width) / scale;
        var h = (rotated ? m.width : m.height) / scale;
        return {
            name: String(m.name),
            x: Number(m.x),
            y: Number(m.y),
            w: w,
            h: h,
            reserved: m.reserved && m.reserved.length === 4 ? m.reserved : [0, 0, 0, 0],
            workspaceId: m.activeWorkspace ? Number(m.activeWorkspace.id) : 1
        };
    }

    function monitorAt(x, y) {
        for (var i = 0; i < root.monitors.length; i++) {
            var m = root.monitors[i];
            if (x >= m.x && x < m.x + m.w && y >= m.y && y < m.y + m.h)
                return m;
        }
        return null;
    }

    function monitorById(id) {
        for (var i = 0; i < root.monitorsIpc.length; i++)
            if (Number(root.monitorsIpc[i].id) === Number(id))
                return root.monitorFromIpc(root.monitorsIpc[i]);
        return null;
    }
    property var monitorsIpc: []

    // Where a zone lands on screen, in global logical pixels, already inset
    // for gaps and the window border.
    function zoneScreenRect(layoutIndex, zoneIndex) {
        var m = root.monitor;
        var res = m.reserved;
        var wx = m.x + res[0] + root.outerGap;
        var wy = m.y + res[1] + root.outerGap;
        var ww = m.w - res[0] - res[2] - 2 * root.outerGap;
        var wh = m.h - res[1] - res[3] - 2 * root.outerGap;
        var z = root.layouts[layoutIndex][zoneIndex];
        var half = root.innerGap / 2;
        var x1 = wx + z[0] * ww + (z[0] > 0.001 ? half : 0);
        var x2 = wx + (z[0] + z[2]) * ww - (z[0] + z[2] < 0.999 ? half : 0);
        var y1 = wy + z[1] * wh + (z[1] > 0.001 ? half : 0);
        var y2 = wy + (z[1] + z[3]) * wh - (z[1] + z[3] < 0.999 ? half : 0);
        // Round the edges, not the sizes, so neighbours share an exact edge.
        var b = root.borderSize;
        var left = Math.round(x1) + b;
        var right = Math.round(x2) - b;
        var topEdge = Math.round(y1) + b;
        var bottom = Math.round(y2) - b;
        return { x: left, y: topEdge, w: right - left, h: bottom - topEdge };
    }

    // The picker card, in coordinates local to the monitor's overlay.
    readonly property int cardPadding: 14
    readonly property int thumbGap: 12
    readonly property int thumbHeight: 64

    function thumbWidth() {
        var aspect = root.monitor ? root.monitor.w / root.monitor.h : 16 / 9;
        return Math.round(root.thumbHeight * Math.max(1.3, Math.min(aspect, 2.4)));
    }

    function cardRect() {
        var n = root.layouts.length;
        var w = 2 * root.cardPadding + n * root.thumbWidth() + (n - 1) * root.thumbGap;
        var h = 2 * root.cardPadding + root.thumbHeight;
        var mw = root.monitor ? root.monitor.w : w;
        var top = root.monitor ? root.monitor.reserved[1] : 0;
        return { x: Math.round((mw - w) / 2), y: top + 12, w: w, h: h };
    }

    function thumbRect(i) {
        var c = root.cardRect();
        var tw = root.thumbWidth();
        return {
            x: c.x + root.cardPadding + i * (tw + root.thumbGap),
            y: c.y + root.cardPadding,
            w: tw,
            h: root.thumbHeight
        };
    }

    // A zone inside a layout thumbnail, relative to that thumbnail.
    function zoneThumbRect(layoutIndex, zoneIndex, tw, th) {
        var inset = 4;
        var half = 1.5;
        var iw = tw - 2 * inset;
        var ih = th - 2 * inset;
        var z = root.layouts[layoutIndex][zoneIndex];
        var x1 = inset + z[0] * iw + (z[0] > 0.001 ? half : 0);
        var x2 = inset + (z[0] + z[2]) * iw - (z[0] + z[2] < 0.999 ? half : 0);
        var y1 = inset + z[1] * ih + (z[1] > 0.001 ? half : 0);
        var y2 = inset + (z[1] + z[3]) * ih - (z[1] + z[3] < 0.999 ? half : 0);
        return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
    }

    function hitTest(lx, ly) {
        for (var i = 0; i < root.layouts.length; i++) {
            var t = root.thumbRect(i);
            if (lx < t.x || lx >= t.x + t.w || ly < t.y || ly >= t.y + t.h)
                continue;
            for (var j = 0; j < root.layouts[i].length; j++) {
                var z = root.zoneThumbRect(i, j, t.w, t.h);
                // Generous hit boxes: the gaps between zones count too.
                if (lx >= t.x + z.x - 2 && lx < t.x + z.x + z.w + 2
                        && ly >= t.y + z.y - 2 && ly < t.y + z.y + z.h + 2)
                    return { layout: i, zone: j };
            }
        }
        return { layout: -1, zone: -1 };
    }

    // ---------- Window helpers ----------

    function clientByAddress(address) {
        for (var i = 0; i < root.clients.length; i++)
            if (root.clients[i].address === address)
                return root.clients[i];
        return null;
    }

    function toplevelFor(address) {
        var all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (var i = 0; i < all.length; i++)
            if ("0x" + String(all[i].address) === address)
                return all[i];
        return null;
    }

    property var iconCache: ({})
    function iconFor(client) {
        var cls = String(client.class || client.initialClass || "").toLowerCase();
        if (Object.prototype.hasOwnProperty.call(root.iconCache, cls))
            return root.iconCache[cls];
        var entries = DesktopEntries.applications ? DesktopEntries.applications.values : [];
        var icon = cls;
        for (var i = 0; i < entries.length; i++) {
            var e = entries[i];
            if (String(e.id || "").toLowerCase().replace(/\.desktop$/, "") === cls
                    || String(e.startupClass || "").toLowerCase() === cls) {
                icon = String(e.icon || cls);
                break;
            }
        }
        var path = Quickshell.iconPath(icon, true) || Quickshell.iconPath("application-x-executable", true);
        root.iconCache[cls] = path;
        return path;
    }

    function isSnappable(c) {
        if (!c || !c.address || c.mapped === false || c.hidden === true)
            return false;
        var ws = c.workspace || {};
        var name = String(ws.name || "");
        return Number(ws.id) > 0 || name === "special:omarchy-minimized";
    }

    function refreshCandidates() {
        var list = [];
        for (var i = 0; i < root.clients.length; i++) {
            var c = root.clients[i];
            if (root.isSnappable(c) && root.placedAddresses.indexOf(c.address) === -1)
                list.push(c);
        }
        var wsId = root.monitor ? root.monitor.workspaceId : -1;
        list.sort(function(a, b) {
            var aHere = Number(a.workspace.id) === wsId ? 0 : 1;
            var bHere = Number(b.workspace.id) === wsId ? 0 : 1;
            if (aHere !== bHere)
                return aHere - bHere;
            return Number(a.focusHistoryID) - Number(b.focusHistoryID);
        });
        root.candidates = list;
    }

    function placeWindow(address, layoutIndex, zoneIndex) {
        var r = root.zoneScreenRect(layoutIndex, zoneIndex);
        var c = root.clientByAddress(address);
        var sel = "address:" + address;
        var bar = root.hasTitleBars ? root.titleBarHeight : 0;
        var lua = [];
        if (c && c.workspace && Number(c.workspace.id) !== root.monitor.workspaceId)
            lua.push("hl.dispatch(hl.dsp.window.move({ workspace = '" + root.monitor.workspaceId
                + "', follow = false, window = '" + sel + "' }))");
        if (c && c.fullscreen && Number(c.fullscreen) > 0) {
            lua.push("hl.dispatch(hl.dsp.focus({ window = '" + sel + "' }))");
            lua.push("hl.dispatch(hl.dsp.window.fullscreen({ mode = 'fullscreen' }))");
        }
        if (c && c.floating === false)
            lua.push("hl.dispatch(hl.dsp.window.float({ action = 'toggle', window = '" + sel + "' }))");
        lua.push("hl.dispatch(hl.dsp.window.resize({ x = " + r.w + ", y = " + (r.h - bar) + ", window = '" + sel + "' }))");
        lua.push("hl.dispatch(hl.dsp.window.move({ x = " + r.x + ", y = " + (r.y + bar) + ", window = '" + sel + "' }))");
        lua.push("hl.dispatch(hl.dsp.focus({ window = '" + sel + "' }))");
        lua.push("hl.dispatch(hl.dsp.window.bring_to_top())");
        Quickshell.execDetached(["hyprctl", "eval", lua.join("; ")]);
        root.placedAddresses = root.placedAddresses.concat([address]);
    }

    // ---------- Flow ----------

    function toggle() {
        if (root.opened)
            root.close();
        else
            root.requestSnapshot("picker");
    }

    // Shell overlay contract (omarchy-shell shell summon io.github.n0rthstar88.snap-layouts).
    function open(payload) {
        if (!root.opened)
            root.requestSnapshot("picker");
    }

    function close() {
        if (root.mode === "")
            return;
        root.mode = "";
        root.hoverLayout = -1;
        root.hoverZone = -1;
        root.assistLayout = -1;
        root.assistZones = [];
        root.placedAddresses = [];
        root.candidates = [];
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide(root.pluginId);
    }

    function startPicker() {
        var active = root.activeIpc;
        if (!active || !active.address || (active.fullscreen && Number(active.fullscreen) > 0))
            return;
        var m = root.monitorById(active.monitor);
        if (!m)
            return;
        root.monitor = m;
        root.targetAddress = active.address;
        root.hoverLayout = -1;
        root.hoverZone = -1;
        root.mode = "picker";
    }

    // The first window is placed: snap it, then offer windows for the rest.
    function chooseZone(layoutIndex, zoneIndex) {
        if (layoutIndex < 0 || zoneIndex < 0 || !root.targetAddress) {
            root.close();
            return;
        }
        root.placedAddresses = [];
        root.placeWindow(root.targetAddress, layoutIndex, zoneIndex);
        var rest = [];
        for (var j = 0; j < root.layouts[layoutIndex].length; j++)
            if (j !== zoneIndex)
                rest.push(j);
        root.assistLayout = layoutIndex;
        root.assistZones = rest;
        root.hoverLayout = -1;
        root.hoverZone = -1;
        root.refreshCandidates();
        if (root.assistZones.length === 0 || root.candidates.length === 0) {
            root.close();
            return;
        }
        root.mode = "assist";
    }

    function assistPick(address) {
        if (root.assistZone < 0)
            return;
        root.placeWindow(address, root.assistLayout, root.assistZone);
        root.assistZones = root.assistZones.slice(1);
        root.refreshCandidates();
        if (root.assistZones.length === 0 || root.candidates.length === 0)
            root.close();
    }

    // Skip the current empty zone in snap assist.
    function assistSkip() {
        root.assistZones = root.assistZones.slice(1);
        if (root.assistZones.length === 0)
            root.close();
    }

    // ---------- Hyprland state ----------

    property string snapshotReason: ""
    property var activeIpc: null

    function requestSnapshot(reason) {
        root.snapshotReason = reason;
        if (!snapshotProc.running)
            snapshotProc.running = true;
    }

    function parseSections(text) {
        var parts = String(text).split("\n@@SNAP@@\n");
        var out = [];
        for (var i = 0; i < parts.length; i++) {
            try {
                out.push(JSON.parse(parts[i]));
            } catch (e) {
                out.push(null);
            }
        }
        return out;
    }

    Process {
        id: snapshotProc
        command: ["sh", "-c", "hyprctl -j monitors; printf '\\n@@SNAP@@\\n'; hyprctl -j clients; printf '\\n@@SNAP@@\\n'; hyprctl -j activewindow; printf '\\n@@SNAP@@\\n'; hyprctl -j plugin list"]
        stdout: StdioCollector {
            onStreamFinished: {
                var s = root.parseSections(text);
                root.monitorsIpc = s[0] || [];
                var mons = [];
                for (var i = 0; i < root.monitorsIpc.length; i++)
                    mons.push(root.monitorFromIpc(root.monitorsIpc[i]));
                root.monitors = mons;
                root.clients = s[1] || [];
                root.activeIpc = s[2] && s[2].address ? s[2] : null;
                root.hasTitleBars = (s[3] || []).some(function(p) {
                    return p.name === "hyprbars";
                });
                if (root.snapshotReason === "picker")
                    root.startPicker();
                else if (root.snapshotReason === "press" && root.buttonDown) {
                    root.dragStart = root.positionsOf(root.clients);
                    dragPoll.start();
                }
            }
        }
    }

    Process {
        id: pollProc
        command: ["sh", "-c", "hyprctl -j clients; printf '\\n@@SNAP@@\\n'; hyprctl -j cursorpos"]
        stdout: StdioCollector {
            onStreamFinished: root.handleDragSample(root.parseSections(text))
        }
    }

    // While a mouse button is held: is a window being moved (title-bar drag,
    // Super+drag, or Window controls' right-drag), and is the pointer at the
    // top of a screen?
    Timer {
        id: dragPoll
        interval: 60
        repeat: true
        onTriggered: {
            var held = Date.now() - root.pressedAt;
            // A plain click never moves the window; stop polling quickly. A
            // missed release event can't leave this running forever either.
            if ((!root.dragging && held > 1500) || held > 60000) {
                stop();
                if (root.mode === "drag")
                    root.close();
                return;
            }
            if (!pollProc.running)
                pollProc.running = true;
        }
    }

    property string dragAddress: ""

    function positionsOf(list) {
        var map = {};
        for (var i = 0; i < (list || []).length; i++)
            map[list[i].address] = { at: list[i].at, size: list[i].size };
        return map;
    }

    function handleDragSample(s) {
        if (!root.buttonDown || !root.dragStart)
            return;
        var list = s[0];
        var cur = s[1];
        if (!list || !cur)
            return;
        var win = null;
        for (var i = 0; i < list.length; i++) {
            var c = list[i];
            if (root.dragAddress) {
                if (c.address === root.dragAddress)
                    win = c;
                continue;
            }
            var start = root.dragStart[c.address];
            if (!start || !c.floating || Number(c.fullscreen) > 0)
                continue;
            var moved = Math.abs(c.at[0] - start.at[0]) > 4 || Math.abs(c.at[1] - start.at[1]) > 4;
            var sameSize = c.size[0] === start.size[0] && c.size[1] === start.size[1];
            if (moved && sameSize) {
                win = c;
                break;
            }
        }
        if (!win)
            return;
        root.dragAddress = win.address;
        root.dragging = true;

        var m = root.monitorAt(cur.x, cur.y);
        if (!m)
            return;
        var nearTop = cur.y - m.y <= root.dragTriggerDistance;
        if (root.mode === "" && nearTop) {
            root.monitor = m;
            root.targetAddress = win.address;
            root.mode = "drag";
        } else if (root.mode === "drag" && nearTop && m.name !== root.monitor.name) {
            root.monitor = m;
        }
        if (root.mode !== "drag")
            return;

        var lx = cur.x - root.monitor.x;
        var ly = cur.y - root.monitor.y;
        var cr = root.cardRect();
        if (ly > cr.y + cr.h + 120 || m.name !== root.monitor.name) {
            root.mode = "";
            root.hoverLayout = -1;
            root.hoverZone = -1;
            return;
        }
        var hit = root.hitTest(lx, ly);
        root.hoverLayout = hit.layout;
        root.hoverZone = hit.zone;
    }

    function handlePress() {
        if (!root.dragEnabled || root.mode === "picker" || root.mode === "assist")
            return;
        root.buttonDown = true;
        root.dragging = false;
        root.dragStart = null;
        root.dragAddress = "";
        root.pressedAt = Date.now();
        root.requestSnapshot("press");
    }

    function handleRelease() {
        if (!root.buttonDown)
            return;
        root.buttonDown = false;
        dragPoll.stop();
        root.dragging = false;
        if (root.mode !== "drag")
            return;
        var layoutIndex = root.hoverLayout;
        var zoneIndex = root.hoverZone;
        if (layoutIndex < 0 || zoneIndex < 0) {
            root.close();
            return;
        }
        // Wait for the window list so snap assist can offer the other windows.
        root.pendingDrop = { layout: layoutIndex, zone: zoneIndex };
        dropProc.running = true;
    }

    property var pendingDrop: null
    Process {
        id: dropProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.clients = JSON.parse(text);
                } catch (e) {}
                var drop = root.pendingDrop;
                root.pendingDrop = null;
                if (drop && root.mode === "drag")
                    root.chooseZone(drop.layout, drop.zone);
            }
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            // A config reload drops runtime binds; put drag-to-snap back.
            if (event && event.name === "configreloaded") {
                reloadCheck.restart();
                return;
            }
            if (!event || event.name !== "custom")
                return;
            if (event.data === "io.github.n0rthstar88.snap-layouts:toggle")
                root.toggle();
            // Title-bar drags (hyprbars) swallow the mouse button, so the
            // press/release binds never fire; hyprbars reports them itself.
            else if (event.data === "io.github.n0rthstar88.snap-layouts:press" || event.data === "hyprbars:dragstart")
                root.handlePress();
            else if (event.data === "io.github.n0rthstar88.snap-layouts:release" || event.data === "hyprbars:dragend")
                root.handleRelease();
        }
    }

    IpcHandler {
        target: "snaplayouts"
        function toggle(): string {
            root.toggle();
            return "ok";
        }
        function close(): string {
            root.close();
            return "ok";
        }
        // Drag-to-snap: `drag on`, `drag off`, or `drag status`.
        function drag(state: string): string {
            if (state === "on" || state === "off")
                root.setDragToSnap(state === "on");
            else if (state !== "status")
                return "expected on, off, or status";
            return root.dragEnabled ? "on" : "off";
        }
        // Pick a zone in the open picker, e.g. `choose 0 0` = left half.
        function choose(layout: int, zone: int): string {
            if (root.mode !== "picker")
                return "picker not open";
            if (layout < 0 || layout >= root.layouts.length || zone < 0 || zone >= root.layouts[layout].length)
                return "no such zone";
            root.chooseZone(layout, zone);
            return "ok";
        }
    }

    // ---------- Drag-to-snap setting ----------

    // Saved in ~/.config/omarchy/shell.json as { "id": "io.github.n0rthstar88.snap-layouts",
    // "dragToSnap": true|false }. Missing means the user hasn't chosen yet:
    // drag-to-snap starts on and a one-time prompt asks whether to keep it.
    readonly property string pluginDir: String((root.manifest && root.manifest.__sourceDir)
        || (Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId))
    readonly property string hookPath: root.pluginDir + "/hook.lua"
    property bool settingsLoaded: false
    property var settingsEntry: null
    // Set by setDragToSnap() so the choice applies before shell.json is rewritten.
    property var dragOverride: null
    readonly property var dragSetting: root.dragOverride !== null ? root.dragOverride
        : (root.settingsEntry && typeof root.settingsEntry.dragToSnap === "boolean"
            ? root.settingsEntry.dragToSnap : null)
    readonly property bool dragEnabled: root.dragSetting !== false
    readonly property bool askAboutDrag: root.settingsLoaded && root.dragSetting === null
    readonly property string bindDescription: "io.github.n0rthstar88.snap-layouts drag"
    readonly property var dragButtons: ["mouse:272", "mouse:273"]

    onDragEnabledChanged: root.ensureDragBinds()
    onSettingsLoadedChanged: root.ensureDragBinds()

    // Adds the drag binds for any button that lacks them. Binds are only ever
    // added, never removed (see hook.lua for why). When drag-to-snap is off
    // they stay put and handlePress() ignores them.
    function ensureDragBinds() {
        if (!root.settingsLoaded || !root.dragEnabled)
            return;
        if (!bindsProc.running)
            bindsProc.running = true;
    }

    Process {
        id: bindsProc
        command: ["hyprctl", "-j", "binds"]
        stdout: StdioCollector {
            onStreamFinished: {
                var binds;
                try {
                    binds = JSON.parse(text);
                } catch (e) {
                    console.warn(root.pluginId + ": could not read hyprctl binds: " + e);
                    return;
                }
                var missing = [];
                for (var i = 0; i < root.dragButtons.length; i++) {
                    var press = false;
                    var release = false;
                    for (var j = 0; j < binds.length; j++) {
                        var b = binds[j];
                        if (b.key !== root.dragButtons[i] || b.description !== root.bindDescription)
                            continue;
                        if (b.release)
                            release = true;
                        else
                            press = true;
                    }
                    if (!press || !release)
                        missing.push(root.dragButtons[i]);
                }
                if (missing.length === 0 || !root.dragEnabled)
                    return;
                Quickshell.execDetached(["hyprctl", "eval", "snap_layouts_buttons = "
                    + JSON.stringify(missing).replace("[", "{").replace("]", "}")
                    + "; dofile(" + JSON.stringify(root.hookPath) + ")"]);
            }
        }
    }

    // Other plugins' Keybind:remove() also deletes these binds when they share
    // a button (Window controls does on startup), so check again now and then.
    Timer {
        interval: 30000
        repeat: true
        running: root.settingsLoaded && root.dragEnabled
        onTriggered: root.ensureDragBinds()
    }

    // Lets a config reload finish before checking which binds survived it.
    Timer {
        id: reloadCheck
        interval: 500
        onTriggered: root.ensureDragBinds()
    }

    function setDragToSnap(enabled) {
        root.dragOverride = enabled;
        if (!root.shell || typeof root.shell.updateEntryInline !== "function") {
            console.warn(root.pluginId + ": can't save the drag-to-snap choice; it lasts until the shell restarts");
            return;
        }
        var settings = Object.assign({}, root.settingsEntry || {});
        delete settings.id;
        settings.dragToSnap = enabled;
        root.shell.updateEntryInline(root.pluginId, settings);
    }

    function loadSettings(raw) {
        try {
            var config = JSON.parse(raw);
            var plugins = Array.isArray(config.plugins) ? config.plugins : [];
            var entry = null;
            for (var i = 0; i < plugins.length; i++)
                if (plugins[i] && plugins[i].id === root.pluginId)
                    entry = plugins[i];
            root.settingsEntry = entry;
            if (entry && entry.dragToSnap === root.dragOverride)
                root.dragOverride = null;
        } catch (e) {
            console.warn(root.pluginId + ": could not read shell.json: " + e);
        }
        root.settingsLoaded = true;
    }

    FileView {
        // The shell reads this path directly, not via XDG_CONFIG_HOME.
        path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
        watchChanges: true
        printErrors: false
        onLoaded: root.loadSettings(text())
        onLoadFailed: root.settingsLoaded = true
        onFileChanged: reload()
    }

    // ---------- UI ----------

    function withAlpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    Loader {
        active: root.opened && root.monitor !== null
        sourceComponent: overlayComponent
    }

    Loader {
        active: root.askAboutDrag
        sourceComponent: askComponent
    }

    Component {
        id: askComponent

        PanelWindow { // qmllint disable uncreatable-type
            screen: {
                var screens = Quickshell.screens;
                var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
                for (var i = 0; i < screens.length; i++)
                    if (screens[i].name === focused)
                        return screens[i];
                return screens.length > 0 ? screens[0] : null;
            }
            anchors.top: true
            margins.top: 12
            implicitWidth: 470
            implicitHeight: askCard.implicitHeight
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "snap-layouts-ask"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            Rectangle {
                id: askCard
                anchors.fill: parent
                implicitHeight: askColumn.implicitHeight + 32
                radius: Style.cornerRadius + 4
                color: Commons.Color.popups.background
                border.color: Commons.Color.popups.border
                border.width: 1

                Column {
                    id: askColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 16
                    spacing: 10

                    Text {
                        width: parent.width
                        text: "Snap layouts is ready"
                        color: Commons.Color.popups.text
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.heading
                        font.bold: true
                    }

                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Drag any window to the top of the screen to pick a layout, or press Super+Z. "
                            + "Keep drag-to-snap turned on? You can change this later with "
                            + "\"omarchy-shell snaplayouts drag on/off\"."
                        color: root.withAlpha(Commons.Color.popups.text, 0.8)
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.body
                    }

                    Row {
                        anchors.right: parent.right
                        spacing: 8

                        Repeater {
                            model: [
                                { label: "Turn it off", value: false },
                                { label: "Keep it on", value: true }
                            ]

                            Rectangle {
                                id: askButton
                                required property var modelData
                                width: buttonText.implicitWidth + 28
                                height: 30
                                radius: Style.cornerRadius
                                color: modelData.value
                                    ? (buttonMouse.containsMouse ? Qt.lighter(Commons.Color.accent, 1.15) : Commons.Color.accent)
                                    : (buttonMouse.containsMouse ? root.withAlpha(Commons.Color.popups.text, 0.14) : root.withAlpha(Commons.Color.popups.text, 0.07))
                                border.color: root.withAlpha(Commons.Color.popups.text, 0.2)
                                border.width: modelData.value ? 0 : 1

                                Text {
                                    id: buttonText
                                    anchors.centerIn: parent
                                    text: askButton.modelData.label
                                    color: askButton.modelData.value ? Commons.Color.background : Commons.Color.popups.text
                                    font.family: Style.font.menuFamily
                                    font.pixelSize: Style.font.body
                                }

                                MouseArea {
                                    id: buttonMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.setDragToSnap(askButton.modelData.value)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: overlayComponent

        PanelWindow { // qmllint disable uncreatable-type
            id: surface

            screen: {
                var screens = Quickshell.screens;
                for (var i = 0; i < screens.length; i++)
                    if (screens[i].name === root.monitor.name)
                        return screens[i];
                return screens.length > 0 ? screens[0] : null;
            }
            anchors {
                top: true
                right: true
                bottom: true
                left: true
            }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "snap-layouts"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.mode === "drag" ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
            // While a window is being dragged the overlay must not take the pointer.
            mask: root.mode === "drag" ? noInput : null

            Region {
                id: noInput
            }

            Item {
                id: content
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: root.close()
                Keys.onPressed: function(event) {
                    if (root.mode === "assist" && event.key === Qt.Key_Tab) {
                        root.assistSkip();
                        event.accepted = true;
                    }
                }

                // Click outside the card or the assist panel to cancel.
                MouseArea {
                    anchors.fill: parent
                    enabled: root.mode !== "drag"
                    onClicked: root.close()
                }

                // Snap assist dims the screen; filled zones stay outlined.
                Rectangle {
                    anchors.fill: parent
                    visible: root.mode === "assist"
                    color: "black"
                    opacity: 0.35
                }

                // Preview of where the window will land.
                Rectangle {
                    readonly property var r: root.hoverZone >= 0 && root.hoverLayout >= 0
                        ? root.zoneScreenRect(root.hoverLayout, root.hoverZone) : null
                    visible: r !== null && root.mode !== "assist"
                    x: r ? r.x - root.monitor.x : 0
                    y: r ? r.y - root.monitor.y : 0
                    width: r ? r.w : 0
                    height: r ? r.h : 0
                    radius: Style.cornerRadius
                    color: root.withAlpha(Commons.Color.accent, 0.18)
                    border.color: root.withAlpha(Commons.Color.accent, 0.8)
                    border.width: 2
                }

                // ----- Layout picker card -----
                Rectangle {
                    id: card
                    readonly property var r: root.cardRect()
                    visible: root.mode === "picker" || root.mode === "drag"
                    x: r.x
                    y: r.y
                    width: r.w
                    height: r.h
                    radius: Style.cornerRadius + 4
                    color: Commons.Color.popups.background
                    border.color: Commons.Color.popups.border
                    border.width: 1

                    // Swallow clicks on the card background.
                    MouseArea {
                        anchors.fill: parent
                    }

                    Repeater {
                        model: root.layouts.length

                        Rectangle {
                            id: thumb
                            required property int index
                            readonly property var r: root.thumbRect(index)
                            x: r.x - card.r.x
                            y: r.y - card.r.y
                            width: r.w
                            height: r.h
                            radius: Style.cornerRadius
                            color: root.withAlpha(Commons.Color.popups.text, 0.06)
                            border.color: root.withAlpha(Commons.Color.popups.text, root.hoverLayout === index ? 0.5 : 0.18)
                            border.width: 1

                            Repeater {
                                model: root.layouts[thumb.index].length

                                Rectangle {
                                    id: zone
                                    required property int index
                                    readonly property var zr: root.zoneThumbRect(thumb.index, index, thumb.width, thumb.height)
                                    readonly property bool hot: root.hoverLayout === thumb.index && root.hoverZone === index
                                    x: zr.x
                                    y: zr.y
                                    width: zr.w
                                    height: zr.h
                                    radius: Math.max(2, Style.cornerRadius / 2)
                                    color: hot ? Commons.Color.accent : root.withAlpha(Commons.Color.popups.text, 0.22)

                                    Behavior on color {
                                        ColorAnimation { duration: 80 }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -2
                                        enabled: root.mode === "picker"
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: {
                                            root.hoverLayout = thumb.index;
                                            root.hoverZone = zone.index;
                                        }
                                        onExited: {
                                            if (root.hoverLayout === thumb.index && root.hoverZone === zone.index) {
                                                root.hoverLayout = -1;
                                                root.hoverZone = -1;
                                            }
                                        }
                                        onClicked: root.chooseZone(thumb.index, zone.index)
                                    }
                                }
                            }
                        }
                    }
                }

                // ----- Snap assist -----
                Repeater {
                    model: root.mode === "assist" ? root.placedAddresses.length : 0

                    // Outline the zones that are already filled.
                    Rectangle {
                        required property int index
                        readonly property var r: {
                            var all = root.layouts[root.assistLayout];
                            var filled = [];
                            for (var j = 0; j < all.length; j++)
                                if (root.assistZones.indexOf(j) === -1)
                                    filled.push(j);
                            return index < filled.length ? root.zoneScreenRect(root.assistLayout, filled[index]) : null;
                        }
                        visible: r !== null
                        x: r ? r.x - root.monitor.x : 0
                        y: r ? r.y - root.monitor.y : 0
                        width: r ? r.w : 0
                        height: r ? r.h : 0
                        color: "transparent"
                        radius: Style.cornerRadius
                        border.color: root.withAlpha(Commons.Color.popups.text, 0.35)
                        border.width: 1
                    }
                }

                Rectangle {
                    id: assistPanel
                    readonly property var r: root.mode === "assist" && root.assistZone >= 0
                        ? root.zoneScreenRect(root.assistLayout, root.assistZone) : null
                    visible: r !== null
                    x: r ? r.x - root.monitor.x : 0
                    y: r ? r.y - root.monitor.y : 0
                    width: r ? r.w : 0
                    height: r ? r.h : 0
                    radius: Style.cornerRadius + 4
                    color: root.withAlpha(Commons.Color.popups.background, 0.94)
                    border.color: Commons.Color.accent
                    border.width: 2

                    MouseArea {
                        anchors.fill: parent
                    }

                    Text {
                        id: assistTitle
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 14
                        text: "Choose a window for this space · Tab to skip · Esc to finish"
                        color: root.withAlpha(Commons.Color.popups.text, 0.75)
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                    }

                    GridView {
                        id: grid
                        readonly property int columns: Math.max(1, Math.floor(width / 210))
                        anchors.top: assistTitle.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 10
                        anchors.topMargin: 10
                        clip: true
                        cellWidth: Math.floor(width / columns)
                        cellHeight: Math.round(cellWidth * 0.62) + 34
                        model: root.candidates
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Item {
                            id: cell
                            required property var modelData
                            width: grid.cellWidth
                            height: grid.cellHeight

                            Rectangle {
                                id: tile
                                anchors.fill: parent
                                anchors.margins: 6
                                radius: Style.cornerRadius + 2
                                color: tileMouse.containsMouse
                                    ? root.withAlpha(Commons.Color.accent, 0.2)
                                    : root.withAlpha(Commons.Color.popups.text, 0.05)
                                border.color: tileMouse.containsMouse ? Commons.Color.accent : root.withAlpha(Commons.Color.popups.text, 0.15)
                                border.width: tileMouse.containsMouse ? 2 : 1

                                Item {
                                    id: previewBox
                                    anchors.top: parent.top
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: label.top
                                    anchors.margins: 6
                                    clip: true

                                    ScreencopyView {
                                        id: preview
                                        readonly property var source: root.toplevelFor(cell.modelData.address)
                                        anchors.centerIn: parent
                                        readonly property real aspect: cell.modelData.size && cell.modelData.size[1] > 0
                                            ? cell.modelData.size[0] / cell.modelData.size[1] : 1.6
                                        width: Math.min(parent.width, parent.height * aspect)
                                        height: width / aspect
                                        captureSource: source && source.wayland ? source.wayland : null
                                        live: false
                                        paintCursor: false
                                    }

                                    // Windows with no capture (e.g. minimized) show their icon.
                                    Image {
                                        anchors.centerIn: parent
                                        visible: !preview.hasContent
                                        width: Math.min(48, parent.height * 0.6)
                                        height: width
                                        source: root.iconFor(cell.modelData)
                                        sourceSize.width: 96
                                        sourceSize.height: 96
                                    }
                                }

                                Row {
                                    id: label
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.margins: 8
                                    height: 20
                                    spacing: 6

                                    Image {
                                        width: 18
                                        height: 18
                                        anchors.verticalCenter: parent.verticalCenter
                                        source: root.iconFor(cell.modelData)
                                        sourceSize.width: 36
                                        sourceSize.height: 36
                                    }

                                    Text {
                                        width: label.width - 24
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: String(cell.modelData.title || cell.modelData.class || "Window")
                                        color: Commons.Color.popups.text
                                        font.family: Style.font.menuFamily
                                        font.pixelSize: Style.font.body
                                        elide: Text.ElideRight
                                    }
                                }

                                MouseArea {
                                    id: tileMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.assistPick(cell.modelData.address)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
