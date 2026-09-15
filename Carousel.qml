import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "logic.js" as Logic
import "workspace.js" as Workspace
import "shortcuts.js" as Shortcuts

Item {
    id: root
    property var shell: null
    property string shortAppId: "hjklcc.omaglide"
    property bool open: false
    property bool opening: false
    property bool holdMode: true
    property bool resizing: false
    property string mode: "windows"
    property var windows: []
    property var captureHandles: ({})
    property real position: 0
    property real visualPosition: 0
    onPositionChanged: visualPosition = position
    readonly property int selected: Logic.wrapIndex(position, windows.length)
    property bool animate: false
    property int preferredWidth: 560
    property var settings: ({})
    property string monitorName: ""
    property string pendingAddr: ""
    property string pendingWorkspace: ""
    property string clientResponse: ""
    property string workspaceResponse: ""
    property string monitorResponse: ""
    property var queryResults: ({})
    property int pendingQueries: 0
    property string queryMode: "windows"
    property bool queryFailed: false
    property string errorMessage: ""
    property real lastCloseRequest: 0
    property int earlySteps: 0
    property string shortcutText: "Reading shortcuts…"
    property string shortcutResponse: ""
    readonly property string controlsText: (holdMode ? "Release Alt or Enter to switch" : "Enter to switch")
        + "   ·   Alt+W: workspaces   ·   Tab / ← / → browse   ·   + / − resize   ·   Drag ◢   ·   Esc cancel"
    function refreshShortcuts() {
        if (!bindingsProc.running) {
            shortcutResponse = ""
            bindingsProc.running = true
        }
    }
    Process {
        id: bindingsProc
        command: ["hyprctl", "-j", "binds"]
        stdout: StdioCollector { onStreamFinished: root.shortcutResponse = text }
        onExited: (exitCode, exitStatus) => {
            try {
                if (exitCode !== 0) throw new Error("Keybinding query failed")
                root.shortcutText = Shortcuts.summarize(JSON.parse(root.shortcutResponse), root.shortAppId)
                    || "No recognized global shortcuts"
            } catch (error) { root.shortcutText = "Shortcuts unavailable" }
        }
    }
    // Refresh each opening, after config reload, and while visible for runtime
    // bind/unbind changes that do not emit a config reload event. Never poll idle.
    Timer { interval: 2000; repeat: true; running: root.open; onTriggered: root.refreshShortcuts() }
    Behavior on visualPosition {
        enabled: root.animate && root.open
        NumberAnimation { id: slide; duration: 190; easing.type: Easing.OutCubic }
    }

    // Read existing settings; write only our entry through the scoped shell API.
    FileView {
        id: configFile
        path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const config = JSON.parse(text())
                root.settings = (config.plugins || []).find(e => e.id === root.shortAppId) || {}
                if (!root.resizing && !saveSize.running)
                    root.preferredWidth = Math.round(Logic.clamp(root.settings.tileWidth, 240, 1200, 560))
            } catch (error) { console.warn("[omaglide] Cannot read size settings:", error) }
        }
    }
    function persistSize() {
        if (!shell || !shell.updateEntryInline) return
        const next = Object.assign({}, settings, { tileWidth: preferredWidth })
        shell.updateEntryInline(shortAppId, next)
        settings = next
    }
    Timer { id: saveSize; interval: 350; onTriggered: root.persistSize() }
    function setSize(width) {
        preferredWidth = Math.round(Logic.clamp(width, 240, 1200, 560))
        holdMode = false
        if (!resizing) saveSize.restart()
    }
    function resizeBy(amount) { setSize(preferredWidth + amount) }
    function step(delta) {
        if (opening) { earlySteps += delta; return }
        if (windows.length > 1) position += delta
    }
    function selectIndex(index) {
        if (windows.length) position += Logic.signedDistance(index, position, windows.length)
    }
    function openSwitcher(hold, requestedMode) {
        const nextMode = requestedMode === "workspaces" ? "workspaces" : "windows"
        if ((open || opening) && mode === nextMode) return
        if (open || opening) close(false)
        focusTimer.stop()
        pendingAddr = ""
        pendingWorkspace = ""
        mode = nextMode
        windows = []
        holdMode = hold
        opening = true
        earlySteps = 0
        errorMessage = ""
        refreshShortcuts()
        monitorName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        Hyprland.refreshToplevels()
        querySnapshot()
    }
    function show() { openSwitcher(false, "windows") }
    function showWorkspaces() { openSwitcher(false, "workspaces") }
    function hide() { close(false) }
    function toggle() { (open || opening) ? close(false) : show() }
    function close(activate) {
        focusTimer.stop()
        pendingAddr = ""
        pendingWorkspace = ""
        const entry = activate && open && !errorMessage && windows.length ? windows[selected] : null
        opening = false
        open = false
        animate = false
        if (saveSize.running) { saveSize.stop(); persistSize() }
        if (entry && mode === "workspaces" && Number.isInteger(entry.workspaceId) && entry.workspaceId !== 0) {
            pendingWorkspace = entry.workspaceId > 0 ? String(entry.workspaceId) : "name:" + entry.workspaceName
            focusTimer.restart()
        } else if (entry && /^0x[0-9a-f]+$/i.test(entry.address)) {
            pendingAddr = entry.address
            focusTimer.restart()
        }
    }
    Timer {
        id: focusTimer
        interval: 90
        onTriggered: {
            if (root.pendingWorkspace)
                Hyprland.dispatch('hl.dsp.focus({ workspace = ' + JSON.stringify(root.pendingWorkspace) + ' })')
            else if (root.pendingAddr)
                Hyprland.dispatch('hl.dsp.focus({ window = "address:' + root.pendingAddr + '" })')
            root.pendingAddr = ""
            root.pendingWorkspace = ""
        }
    }
    function refreshWindows() {
        if (open || opening) querySnapshot()
    }
    function querySnapshot() {
        if (pendingQueries > 0) return
        queryMode = mode
        queryResults = ({})
        queryFailed = false
        pendingQueries = mode === "workspaces" ? 3 : 1
        clientResponse = ""; workspaceResponse = ""; monitorResponse = ""
        clientsProc.running = true
        if (mode === "workspaces") {
            workspacesProc.running = true
            monitorsProc.running = true
        }
    }
    function queryFinished(part, response, exitCode) {
        try {
            const parsed = JSON.parse(response)
            if (exitCode !== 0 || !Array.isArray(parsed)) throw new Error(part + " query failed")
            queryResults[part] = parsed
        } catch (error) { queryFailed = true; console.warn("[omaglide]", error) }
        pendingQueries--
        if (pendingQueries > 0 || (!open && !opening)) return
        if (queryMode !== mode) { querySnapshot(); return }
        if (queryFailed) {
            opening = false
            errorMessage = "Could not read " + mode + ". Press Esc and try again."
            open = true
            holdMode = false
            return
        }
        fillWindows(queryResults.clients, queryResults.workspaces || [], queryResults.monitors || [])
    }
    function fillWindows(clients, workspaces, monitors) {
        if (!open && !opening) return // Cancelled async opens stay closed.
        errorMessage = ""
        const previous = windows.length ? windows[selected].key : ""
        const wasOpen = open
        refreshHandles()
        const records = mode === "workspaces" ? Workspace.buildWorkspaces(clients, workspaces, monitors)
            : Logic.orderClients(clients).map(c => ({
            key: c.address, address: c.address, cls: c.class || c.initialClass || "",
            title: c.title || "Untitled window", workspaceId: c.workspace ? c.workspace.id : -1,
            workspaceName: c.workspace ? c.workspace.name : "?"
        }))
        // Keep virtual-ring positions and active drags stable during geometry
        // refreshes. A fresh array must not reset the slide to its base index.
        if (wasOpen && records.length === windows.length && records.every((w, i) => w.key === windows[i].key)) {
            windows = records
            handleRefresh.restart()
            return
        }
        animate = false
        windows = records
        const retained = records.findIndex(w => w.key === previous)
        const focused = monitors.find(m => m.name === monitorName)
        const activeIndex = mode === "workspaces" && focused
            ? records.findIndex(w => focused.activeWorkspace && w.workspaceId === focused.activeWorkspace.id) : 0
        position = wasOpen && retained >= 0 ? retained : Logic.wrapIndex(Math.max(0, activeIndex) + earlySteps, records.length)
        visualPosition = position
        opening = false
        open = true
        Qt.callLater(() => { root.animate = true })
        handleRefresh.restart()
    }
    function refreshHandles() {
        const handles = {}
        for (const top of Hyprland.toplevels.values || [])
            if (top.lastIpcObject && top.lastIpcObject.address) handles[top.lastIpcObject.address] = top.wayland
        captureHandles = handles
    }
    Timer { id: handleRefresh; interval: 120; onTriggered: root.refreshHandles() }
    Timer { id: refreshDebounce; interval: 100; onTriggered: root.refreshWindows() }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded" && (root.open || root.opening)) root.refreshShortcuts()
            if (["openwindow", "closewindow", "movewindow", "windowtitle", "movewindowv2", "createworkspace",
                "destroyworkspace", "moveworkspace", "monitoradded", "monitorremoved", "changefloatingmode", "fullscreen"].indexOf(event.name) < 0) return
            Hyprland.refreshToplevels()
            if (root.open || root.opening) refreshDebounce.restart()
        }
    }
    // Window coordinates can change without a dedicated IPC event. Refresh only
    // while workspace previews are visible, keeping the real layout up to date.
    Timer { interval: 1200; repeat: true; running: root.open && root.mode === "workspaces" && !root.resizing; onTriggered: root.refreshWindows() }
    Process {
        id: clientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector { onStreamFinished: root.clientResponse = text }
        onExited: (exitCode, exitStatus) => root.queryFinished("clients", root.clientResponse, exitCode)
    }
    Process {
        id: workspacesProc
        command: ["hyprctl", "-j", "workspaces"]
        stdout: StdioCollector { onStreamFinished: root.workspaceResponse = text }
        onExited: (exitCode, exitStatus) => root.queryFinished("workspaces", root.workspaceResponse, exitCode)
    }
    Process {
        id: monitorsProc
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector { onStreamFinished: root.monitorResponse = text }
        onExited: (exitCode, exitStatus) => root.queryFinished("monitors", root.monitorResponse, exitCode)
    }
    function quitSelected() {
        if (mode === "workspaces" || !windows.length || quitProc.running) return
        const addr = windows[selected].address
        if (!/^0x[0-9a-f]+$/i.test(addr)) return
        lastCloseRequest = Date.now()
        quitProc.command = ["hyprctl", "dispatch", 'hl.dsp.window.close({ window = "address:' + addr + '" })']
        quitProc.running = true
    }
    Process { id: quitProc; onExited: refreshDebounce.restart() }
    GlobalShortcut {
        appid: root.shortAppId; name: "next"
        onPressed: (root.open || root.opening) && root.mode === "windows" ? root.step(1) : root.openSwitcher(true, "windows")
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "previous"
        onPressed: (root.open || root.opening) && root.mode === "windows" ? root.step(-1) : root.openSwitcher(true, "windows")
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "workspaces"
        onPressed: (root.open || root.opening) && root.mode === "workspaces" ? root.step(1) : root.openSwitcher(true, "workspaces")
    }
    GlobalShortcut { appid: root.shortAppId; name: "toggle"; onPressed: root.toggle() }
    // Compatibility with the optional upstream arrow-key bindings.
    GlobalShortcut {
        appid: root.shortAppId; name: "focus-left"
        onPressed: root.open ? root.step(-1) : Hyprland.dispatch('hl.dsp.focus({ direction = "l" })')
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "focus-right"
        onPressed: root.open ? root.step(1) : Hyprland.dispatch('hl.dsp.focus({ direction = "r" })')
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "focus-up"
        onPressed: root.open ? root.step(-1) : Hyprland.dispatch('hl.dsp.focus({ direction = "u" })')
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "focus-down"
        onPressed: root.open ? root.step(1) : Hyprland.dispatch('hl.dsp.focus({ direction = "d" })')
    }
    IpcHandler {
        target: "omaglide"
        function show(): void { root.show() }
        function workspaces(): void { root.showWorkspaces() }
        function hide(): void { root.hide() }
        function toggle(): void { root.toggle() }
        function next(): void { root.step(1) }
        function previous(): void { root.step(-1) }
        function resize(action: string): void {
            if (action === "larger") root.resizeBy(48)
            else if (action === "smaller") root.resizeBy(-48)
            else if (action === "reset") root.setSize(560)
        }
        function status(): string {
            return JSON.stringify({ open: root.open, mode: root.mode, count: root.windows.length, selected: root.selected,
                entries: root.windows.map(w => ({ key: w.key, workspaceId: w.workspaceId, windowCount: w.count })),
                preferredWidth: root.preferredWidth, holdMode: root.holdMode, resizing: root.resizing,
                shortcutText: root.shortcutText, controlsText: root.controlsText,
                preview: loader.item ? loader.item.metrics() : null })
        }
    }
    LazyLoader {
        id: loader
        active: root.open
        PanelWindow {
            id: panel
            screen: Quickshell.screens.find(s => s.name === root.monitorName) || Quickshell.screens[0]
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            WlrLayershell.namespace: root.shortAppId
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            // Keyboard exclusivity alone does not stop Hyprland's Super+mouse
            // bindings: they target the application behind this layer before
            // Qt sees the press. Inhibit compositor shortcuts for this focused
            // surface only; destruction/closing releases the guard automatically.
            ShortcutInhibitor {
                id: shortcutGuard
                window: panel
                enabled: root.open
                onCancelled: if (root.open) root.close(false)
            }
            readonly property real tileWidth: Logic.effectiveTileWidth(root.preferredWidth, width, height)
            readonly property real cardHeight: tileWidth * 0.625 + 54
            // Reserve the ring at the smallest size so resizing cannot destroy
            // the selected delegate (and its active pointer grab) mid-drag.
            readonly property int slotCount: Logic.carouselSpan(root.windows.length, width, Math.min(240, tileWidth))
            function cardAt(index) { return cards.itemAt(index) }
            function metrics() {
                const card = cards.itemAt(Logic.wrapIndex(root.position, slotCount))
                let loaded = 0
                for (let i = 0; i < cards.count; i++) if (cards.itemAt(i).captureActive) loaded++
                return { monitor: root.monitorName, width: width, height: height, dpr: devicePixelRatio,
                    tileWidth: tileWidth, shortcutsInhibited: shortcutGuard.active,
                    capture: card ? card.captureMetrics() : null, loadedPreviews: loaded }
            }
            // Modifier release is delivered to this keyboard-exclusive surface.
            // Do not poll compositor key state: shortcut inhibition can clear
            // its pressed-key bookkeeping while Alt is physically still held.
            Rectangle { anchors.fill: parent; color: Color.menu.scrim }
            Rectangle { anchors.fill: parent; color: Color.popups.background; opacity: 0.42 }
            MouseArea { anchors.fill: parent; onClicked: root.close(false) }
            Item {
                id: viewport
                anchors.fill: parent
                clip: true
                focus: true
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) root.close(false)
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.close(true)
                    else if (event.key === Qt.Key_W && (event.modifiers & Qt.AltModifier)
                        && root.mode !== "workspaces") root.openSwitcher(true, "workspaces")
                    else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) root.step(-1)
                    else if ([Qt.Key_Tab, Qt.Key_Right, Qt.Key_Down].indexOf(event.key) >= 0) root.step(1)
                    else if ([Qt.Key_Left, Qt.Key_Up].indexOf(event.key) >= 0) root.step(-1)
                    else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) root.resizeBy(48)
                    else if (event.key === Qt.Key_Minus) root.resizeBy(-48)
                    else if (event.key === Qt.Key_0) root.setSize(560)
                    else if (event.key === Qt.Key_Q && (root.holdMode || (event.modifiers & Qt.MetaModifier))) root.quitSelected()
                    else return
                    event.accepted = true
                }
                Keys.onReleased: event => {
                    if (root.holdMode && !root.resizing && Date.now() - root.lastCloseRequest > 250
                        && [Qt.Key_Alt, Qt.Key_AltGr].indexOf(event.key) >= 0) root.close(true)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: (panel.height - panel.cardHeight) / 2 - 58
                    text: root.errorMessage || (root.windows.length ? (root.mode === "workspaces" ? "WORKSPACES" : "WINDOWS") + "  ·  " + (root.selected + 1) + " / " + root.windows.length : "Nothing to preview")
                    color: Color.popups.text; font.family: Style.font.family
                    font.pixelSize: 13; font.letterSpacing: 2; opacity: 0.8
                }
                Repeater {
                    id: cards
                    model: panel.slotCount
                    delegate: Item {
                        id: card
                        required property int index
                        readonly property var win: root.windows[index % root.windows.length]
                        readonly property var sourceHandle: win ? root.captureHandles[win.address] || null : null
                        readonly property real distance: Logic.signedDistance(index, root.visualPosition, panel.slotCount)
                        readonly property var geometry: Logic.cardGeometry(distance, panel.tileWidth)
                        readonly property bool isSelected: index === Logic.wrapIndex(root.position, panel.slotCount)
                        readonly property bool nearViewport: Math.abs(geometry.offset) < panel.width / 2 + panel.tileWidth
                        readonly property bool captureActive: captureLoader.active || workspaceLoader.active
                        x: panel.width / 2 + geometry.offset - width / 2
                        y: (panel.height - height) / 2
                        width: geometry.width
                        height: geometry.height + 54
                        z: 100 - Math.abs(distance)
                        visible: nearViewport
                        opacity: 0.72 + 0.28 * geometry.emphasis
                        function captureMetrics() {
                            if (root.mode === "workspaces")
                                return workspaceLoader.item ? workspaceLoader.item.metrics() : { workspaceId: win.workspaceId, count: win.count }
                            const image = captureLoader.item
                            return { address: win.address, frameWidth: width, frameHeight: height,
                                nativeWidth: image ? image.sourceSize.width : 0,
                                nativeHeight: image ? image.sourceSize.height : 0,
                                renderedWidth: image ? image.renderedWidth * panel.devicePixelRatio : 0,
                                renderedHeight: image ? image.renderedHeight * panel.devicePixelRatio : 0,
                                hasContent: image ? image.hasContent : false }
                        }
                        Rectangle {
                            anchors.fill: parent; radius: 14
                            color: Color.popups.background
                            border.width: card.isSelected ? 2 : 1
                            border.color: card.isSelected ? Color.menu.selectedBorder : Color.popups.border
                        }
                        Item {
                            id: imageBounds
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 3 }
                            height: card.geometry.height - 3
                            clip: true
                            Rectangle { anchors.fill: parent; color: Qt.alpha(Color.foreground, 0.04) }
                            Image {
                                id: fallbackIcon
                                anchors.centerIn: parent; width: 64; height: 64
                                sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                                source: Logic.iconPathFor(DesktopEntries, Quickshell, card.win.cls, card.win.title)
                                fillMode: Image.PreserveAspectFit
                                visible: root.mode === "windows" && status === Image.Ready && (!captureLoader.item || !captureLoader.item.hasContent)
                            }
                            Text {
                                anchors.centerIn: parent
                                text: (card.win.cls || "?").charAt(0).toUpperCase()
                                font.family: Style.font.family; font.pixelSize: 48
                                color: Color.popups.text; opacity: 0.55
                                visible: root.mode === "windows" && fallbackIcon.status !== Image.Ready && (!captureLoader.item || !captureLoader.item.hasContent)
                            }
                            Loader {
                                id: captureLoader
                                anchors.fill: parent
                                active: root.mode === "windows" && root.open && card.nearViewport && !!card.sourceHandle
                                sourceComponent: Component {
                                    Item {
                                        readonly property size sourceSize: preview.sourceSize
                                        readonly property bool hasContent: preview.hasContent
                                        readonly property real renderedWidth: preview.width
                                        readonly property real renderedHeight: preview.height
                                        ScreencopyView {
                                            id: preview
                                            captureSource: card.sourceHandle
                                            live: card.isSelected && root.open
                                            paintCursor: false
                                            visible: hasContent
                                            // Keep the native buffer, draw directly at actual
                                            // display geometry; no fixed thumbnail or raster layer.
                                            readonly property real sourceRatio: sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 1.6
                                            width: Math.min(parent.width, parent.height * sourceRatio)
                                            height: width / sourceRatio
                                            anchors.centerIn: parent
                                            Timer {
                                                interval: 450; repeat: true
                                                running: preview.hasContent && root.open && card.nearViewport && !card.isSelected
                                                onTriggered: preview.captureFrame()
                                            }
                                        }
                                    }
                                }
                            }
                            Loader {
                                id: workspaceLoader
                                anchors.fill: parent
                                active: root.mode === "workspaces" && root.open && card.nearViewport
                                sourceComponent: Component {
                                    WorkspacePreview {
                                        entry: card.win
                                        handles: root.captureHandles
                                        selected: card.isSelected
                                        opened: root.open
                                        dpr: panel.devicePixelRatio
                                    }
                                }
                            }
                        }
                        Row {
                            anchors { left: parent.left; leftMargin: 14; bottom: parent.bottom; bottomMargin: 13 }
                            spacing: 10
                            Item {
                                width: 26; height: 26
                                Image {
                                    id: appIcon
                                    anchors.fill: parent
                                    sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                                    source: Logic.iconPathFor(DesktopEntries, Quickshell, card.win.cls, card.win.title)
                                    fillMode: Image.PreserveAspectFit
                                    visible: root.mode === "windows" && status === Image.Ready
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: root.mode === "workspaces" ? "▦" : (card.win.cls || "?").charAt(0).toUpperCase()
                                    font.family: Style.font.family; font.pixelSize: 19; font.bold: true
                                    color: Color.popups.text; visible: root.mode === "workspaces" || appIcon.status !== Image.Ready
                                }
                            }
                            Column {
                                width: card.width - 94; spacing: 2
                                Text {
                                    width: parent.width; elide: Text.ElideRight; text: card.win.title
                                    color: Color.popups.text; font.family: Style.font.family
                                    font.pixelSize: 13; font.weight: Font.DemiBold
                                }
                                Text {
                                    width: parent.width; elide: Text.ElideRight
                                    text: root.mode === "workspaces"
                                        ? card.win.count + (card.win.count === 1 ? " window" : " windows") + "  ·  " + card.win.monitorName
                                        : card.win.cls + "  ·  Workspace " + card.win.workspaceName
                                    color: Color.popups.text; opacity: 0.58
                                    font.family: Style.font.family; font.pixelSize: 10
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.selectIndex(card.index % root.windows.length); root.close(true) }
                            onWheel: wheel => {
                                if (wheel.modifiers & Qt.ControlModifier) root.resizeBy(wheel.angleDelta.y > 0 ? 32 : -32)
                                else root.step((wheel.angleDelta.y || wheel.angleDelta.x) > 0 ? -1 : 1)
                                wheel.accepted = true
                            }
                        }
                        Rectangle {
                            visible: card.isSelected
                            anchors { right: parent.right; bottom: parent.bottom; margins: 7 }
                            width: 30; height: 30; radius: 7
                            color: grip.containsMouse || grip.pressed ? Color.menu.selectedBackground : "transparent"
                            Text { anchors.centerIn: parent; text: "◢"; color: Color.popups.text; opacity: 0.65; font.pixelSize: 17 }
                            MouseArea {
                                id: grip
                                anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.SizeFDiagCursor
                                property real startX: 0
                                property real startWidth: 0
                                onPressed: mouse => {
                                    saveSize.stop()
                                    root.holdMode = false; root.resizing = true
                                    startX = mapToItem(viewport, mouse.x, mouse.y).x
                                    startWidth = panel.tileWidth
                                }
                                onPositionChanged: mouse => {
                                    if (pressed) root.setSize(startWidth + 2 * (mapToItem(viewport, mouse.x, mouse.y).x - startX))
                                }
                                onReleased: { root.resizing = false; saveSize.restart() }
                                onCanceled: { root.resizing = false; saveSize.restart() }
                            }
                        }
                    }
                }
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: (panel.height + panel.cardHeight) / 2 + 26
                    width: Math.max(1, parent.width - 48)
                    spacing: 6
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap; textFormat: Text.PlainText
                        text: root.shortcutText
                        color: Color.popups.text; opacity: 0.9
                        font.family: Style.font.family; font.pixelSize: 12
                    }
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap; textFormat: Text.PlainText
                        text: root.controlsText
                        color: Color.popups.text; opacity: 0.7
                        font.family: Style.font.family; font.pixelSize: 12
                    }
                }
                Component.onCompleted: forceActiveFocus()
            }
        }
    }
}
