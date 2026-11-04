import QtQuick
import QtQuick.Effects
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.Commons
import "logic.js" as Logic
import "workspace.js" as Workspace
import "shortcuts.js" as Shortcuts

Item {
    id: root
    property var shell: null
    property string shortAppId: "josephgottlieb.omaglide"
    property bool open: false
    readonly property int entranceDuration: 50
    readonly property int exposeDuration: 240
    property real entranceProgress: 0
    property bool entrancePending: false
    readonly property bool entranceRunning: entrance.running
    function previewMetrics() { return loader.item ? loader.item.metrics() : null }
    onOpenChanged: {
        entrance.stop()
        entranceProgress = 0
        entrancePending = open
    }
    NumberAnimation {
        id: entrance
        target: root; property: "entranceProgress"
        // Exposé flies windows from their desktop positions; the carousel
        // keeps its quick 50ms slide.
        to: 1; duration: root.exposed ? root.glideDuration : root.entranceDuration; easing.type: Easing.OutCubic
    }
    // A released swipe finishes only the distance the fingers left, so
    // these shrink with it; untracked opens and closes use the full length.
    property int glideDuration: exposeDuration
    property int exitDuration: 220
    // Leaving Exposé plays the fly-in backwards: windows on the desktop glide
    // back to where they really are and the rest fade, before the layer
    // unmaps. Input is ignored meanwhile; reopening either Exposé reverses it.
    property bool closing: false
    property var closingEntry: null
    NumberAnimation {
        id: exitAnimation
        target: root; property: "entranceProgress"
        to: 0; duration: root.exitDuration; easing.type: Easing.InOutCubic
        onFinished: if (root.closing) root.finishClose(root.closingEntry)
    }
    function cancelClosing() {
        if (!closing) return
        exitAnimation.stop()
        closing = false
        closingEntry = null
    }
    // Swipes follow the fingers. Hyprland streams each gesture's progress
    // (see Shortcuts.gestureLua); while one is "open" or "close" tracking,
    // entranceProgress is the fingers' position instead of an animation, and
    // releasing finishes or cancels from wherever they stopped.
    property string tracking: ""
    property real trackBase: 0
    property real trackProgress: 0
    property real trackVelocity: 0
    property real trackStamp: 0
    function trackedValue() {
        return tracking === "close" ? trackBase * (1 - trackProgress) : trackBase + (1 - trackBase) * trackProgress
    }
    function swipeStart(direction) {
        tracking = ""
        trackProgress = 0
        trackVelocity = 0
        trackStamp = Date.now()
        const showing = (open || opening) && exposed && !closing
        if (direction === "up" ? showing && !appExposed : showing && appExposed) return // Already there.
        if (!showing && (open || opening) && !closing && !exposed) { close(false); return } // The slider.
        if (showing) {
            // Exposé is on screen: the swipe takes it back to the desktop.
            if (!open || opening) { close(false); return }
            closing = true
            closingEntry = null
            quickLook = false
            settingsOpen = false
            entrance.stop()
            trackBase = entranceProgress
            tracking = "close"
            return
        }
        // Opening, or turning a glide back to the desktop around mid-way.
        trackBase = closing ? entranceProgress : 0
        exitAnimation.stop()
        tracking = "open"
        showExpose(direction === "down")
    }
    function swipeEvent(data) {
        const swipe = Shortcuts.parseSwipeEvent(shortAppId, data)
        if (!swipe) return
        if (swipe.phase === "start") swipeStart(swipe.direction)
        if (swipe.phase === "end") swipeEnd(swipe.progress)
        else swipeUpdate(swipe.progress)
    }
    function swipeUpdate(progress) {
        if (!tracking) return
        const now = Date.now(), value = Math.max(0, Math.min(1, progress))
        const elapsed = Math.max(1, now - trackStamp)
        // Smoothed progress per second, for flicks released early. Resting
        // fingers send nothing, so after a pause only the latest motion counts.
        const instant = (value - trackProgress) * 1000 / elapsed
        trackVelocity = elapsed > 100 ? instant : 0.6 * trackVelocity + 0.4 * instant
        trackStamp = now
        trackProgress = value
        if (open && !entrancePending) entranceProgress = trackedValue()
    }
    function swipeEnd(progress) {
        if (!tracking) return
        swipeUpdate(progress)
        const kind = tracking
        tracking = ""
        // Far enough, or quick enough toward the end: macOS commits both.
        const commit = trackProgress + Math.max(0, trackVelocity) * 0.12 >= 0.3
        if (kind === "open") {
            if (!commit) {
                if (!open || opening || entrancePending) { finishClose(null); return }
                closing = true
                closingEntry = null
                exitDuration = Math.max(80, Math.round(220 * entranceProgress))
                exitAnimation.restart()
            } else if (open && !entrancePending) {
                glideDuration = Math.max(80, Math.round(exposeDuration * (1 - entranceProgress)))
                entrance.restart()
            } // Still mapping: the first frame starts the full glide.
        } else if (commit) {
            exitDuration = Math.max(80, Math.round(220 * entranceProgress))
            exitAnimation.restart()
        } else {
            closing = false
            glideDuration = Math.max(80, Math.round(exposeDuration * (1 - entranceProgress)))
            entrance.restart()
        }
    }
    property bool opening: false
    property bool holdMode: true
    property bool resizing: false
    property string mode: "windows"
    property string carouselMode: "windows"
    property bool exposed: false
    property point hoverPosition: Qt.point(NaN, NaN)
    property bool settingsOpen: false
    // App Exposé: Exposé limited to the focused app's windows (by full class).
    property bool appExposed: false
    property string appExposeClass: ""
    readonly property bool gesturesEnabled: settings.gesturesEnabled !== false
    readonly property int gestureFingers: Number(settings.gestureFingers) === 4 ? 4 : 3
    property var gestureConflicts: []
    // libinput's three-finger drag (input:touchpad:drag_3fg: 1 = three
    // fingers, 2 = four) takes those fingers away from swipe gestures.
    property int touchpadDragFingers: 0
    property string dragOptionResponse: ""
    Process {
        id: dragOptionProc
        command: ["hyprctl", "-j", "getoption", "input:touchpad:drag_3fg"]
        stdout: StdioCollector { onStreamFinished: root.dragOptionResponse = text }
        onExited: (exitCode, exitStatus) => {
            try {
                const value = Number(JSON.parse(root.dragOptionResponse).int)
                root.touchpadDragFingers = value === 1 ? 3 : value === 2 ? 4 : 0
            } catch (error) { root.touchpadDragFingers = 0 }
        }
    }
    property string gestureStatus: ""
    // Exposé Quick Look: the selected window enlarged to nearly full screen.
    property bool quickLook: false
    // Drawn while zooming in, previewing, or zooming back into the tile.
    property bool quickLookShown: false
    property real quickLookProgress: 0
    onQuickLookChanged: {
        quickLookAnimation.stop()
        if (quickLook || (open && quickLookShown)) {
            // Reverses smoothly from wherever an unfinished zoom left off.
            if (!quickLookShown) quickLookProgress = 0
            quickLookShown = true
            quickLookAnimation.to = quickLook ? 1 : 0
            quickLookAnimation.duration = quickLook ? 260 : 220
            quickLookAnimation.start()
        } else {
            // The overlay closed: no one is watching a zoom-out.
            quickLookShown = false
            quickLookProgress = 0
        }
    }
    NumberAnimation {
        id: quickLookAnimation
        target: root; property: "quickLookProgress"
        easing.type: Easing.OutCubic
        onFinished: if (!root.quickLook) root.quickLookShown = false
    }
    function toggleQuickLook() {
        quickLook = !quickLook && exposed && (open || opening) && windows.length > 0
    }
    // Desktop workspace shown when Exposé opened: its windows fly into place.
    property int originWorkspaceId: 0
    property int originMonitorId: -1
    // The workspace Exposé glides back to: where the chosen window lives when
    // leaving to it on this monitor, otherwise the one Exposé opened over.
    readonly property int desktopWorkspaceId: closing && closingEntry && closingEntry.monitor === originMonitorId
        && Number.isInteger(closingEntry.workspaceId) && closingEntry.workspaceId > 0 ? closingEntry.workspaceId : originWorkspaceId
    onExposedChanged: {
        quickLook = false
        if (!exposed) appExposed = false
        hoverPosition = Qt.point(NaN, NaN)
        if (exposed) holdMode = false
        if (mode === "windows" && rawWindows.length) rebuildEntries()
    }
    property string searchQuery: ""
    property var allWindows: []
    property var rawWindows: []
    property string activeAddress: ""
    property bool groupApps: true
    readonly property bool groupingActive: groupApps && mode === "windows" && !exposed
    property var groupSelections: ({})
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
    property int initialStep: 0
    property bool activateAfterOpen: false
    property string shortcutText: "Reading shortcuts…"
    property string shortcutResponse: ""
    property var liveBinds: []
    property var liveChords: Shortcuts.currentChords([], shortAppId)
    readonly property bool blurBackground: settings.blurBackground !== false
    readonly property bool pointerFollowsFocus: settings.pointerFollowsFocus !== false
    // Every surface is liquid glass (GlassPanel), so text is light everywhere.
    readonly property color glassInk: "white"
    // The theme's color singleton can be unresolved while delegates are
    // created; a fallback keeps outlines and badges from going blank.
    readonly property color accentColor: Color.accent ? Color.accent : "#5aa9ff"
    // Slider style: "icons" (the default, a Cmd+Tab-style row of app icons)
    // or "thumbnails" (live previews). Workspace mode always uses thumbnails.
    readonly property string sliderStyle: settings.sliderStyle === "thumbnails" ? "thumbnails" : "icons"
    readonly property bool iconStyle: sliderStyle === "icons" && mode === "windows" && !exposed
    property string appliedSignature: ""
    property bool pendingApply: false
    property bool pendingFresh: false
    // Also covers a missing settings file, whose FileView never loads.
    Component.onCompleted: applyBindings(true)
    property var iconCache: ({})
    function iconFor(cls, title) {
        const key = String(cls || "") + "\n" + String(title || "")
        if (Object.prototype.hasOwnProperty.call(iconCache, key)) return iconCache[key]
        const path = Logic.iconPathFor(DesktopEntries, Quickshell, cls, title)
        // Window titles can change frequently; bound the session cache.
        if (Object.keys(iconCache).length >= 256) iconCache = ({})
        iconCache[key] = path
        return path
    }
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() { root.iconCache = ({}) }
    }
    readonly property string controlsText: (exposed
            ? "Click or Enter to switch   ·   Space: Quick Look"
            : (holdMode ? "Release to switch" : "Enter to switch") + "   ·   `: apps / workspaces")
        + "   ·   Type to search   ·   1–9: workspace"
        + (mode === "windows" && !exposed ? "   ·   Ctrl+G: " + (groupApps ? "ungroup" : "group apps") : "")
        + (groupingActive ? "   ·   ↑/↓: app windows" : "")
        + "   ·   Esc " + (searchQuery ? "clear" : "cancel")
    // Signal handlers can run before dependent property bindings update.
    function appsGrouped() { return groupApps && mode === "windows" && !exposed }
    function entriesForQuery(query) {
        if (mode === "workspaces") return Logic.filterEntries(allWindows, query)
        const scoped = exposed && appExposed && appExposeClass
            ? rawWindows.filter(w => Logic.appClassKey(w.cls) === appExposeClass) : rawWindows
        const matches = Logic.filterEntries(scoped, query)
        if (!appsGrouped()) return matches
        return Logic.groupAppEntries(matches, activeAddress).map(group => {
            const member = group.windows.find(w => w.address === groupSelections[group.key])
            return member ? Object.assign({}, group, member, {
                key: group.key, appKey: group.appKey, grouped: true, count: group.count, windows: group.windows
            }) : group
        })
    }
    function rebuildEntries() {
        const previous = windows.length ? windows[selected] : null
        if (mode === "windows") allWindows = appsGrouped() ? Logic.groupAppEntries(rawWindows, activeAddress) : rawWindows
        if (appsGrouped() && previous) {
            const group = allWindows.find(w => (w.windows || []).some(member => member.address === previous.address))
            if (group) groupSelections[group.key] = previous.address
        }
        windows = entriesForQuery(searchQuery)
        animate = false
        position = Math.max(0, windows.findIndex(w => previous && (w.key === previous.key || w.address === previous.address
            || (w.windows || []).some(member => member.address === previous.address))))
        visualPosition = position
        Qt.callLater(() => { root.animate = true })
    }
    function toggleGroups() {
        if (mode !== "windows" || exposed || resizing) return
        setGroupApps(!groupApps)
    }
    function setGroupApps(value) {
        if (groupApps === !!value) return
        groupApps = !!value
        if (mode === "windows" && rawWindows.length) rebuildEntries()
        saveSetting("groupApps", groupApps)
    }
    // Write only our entry through the scoped shell API.
    function saveSetting(key, value) {
        const next = Object.assign({}, settings)
        next[key] = value
        settings = next
        if (shell && shell.updateEntryInline) shell.updateEntryInline(shortAppId, next)
        if (["blurBackground", "gesturesEnabled", "gestureFingers"].indexOf(key) >= 0) applyBindings(false)
    }
    function openSettings() {
        if (!open && !opening) show()
        holdMode = false
        settingsOpen = true
        refreshShortcuts() // Fresh conflict data for the capture UI.
        if (!dragOptionProc.running) dragOptionProc.running = true
    }
    function closeSettings() {
        settingsOpen = false
        if (loader.item) loader.item.refocus()
    }
    function conflictFor(chordValue, action) {
        return Shortcuts.conflictFor(chordValue, liveBinds, shortAppId, action)
    }
    // Store the chord ("" unbinds) and rebind immediately. Optimistically show
    // the new chord; the post-apply binds query confirms it.
    function setBinding(action, chordValue) {
        const bindings = Object.assign({}, settings.keybindings || {})
        bindings[action] = Shortcuts.normalizeChord(chordValue)
        saveSetting("keybindings", bindings)
        const chords = Object.assign({}, liveChords)
        chords[action] = bindings[action] ? [bindings[action]] : []
        liveChords = chords
        applyBindings(false)
    }
    // Managed keybindings and the blur layer rule live only in the running
    // compositor, so re-apply them on startup and after every config reload.
    function applyBindings(fresh) {
        pendingApply = true
        pendingFresh = pendingFresh || !!fresh
        refreshShortcuts()
    }
    function runApply() {
        pendingApply = false
        const lua = [Shortcuts.bindingLua(shortAppId, settings.keybindings || {}, liveBinds),
            Shortcuts.blurLua(shortAppId, blurBackground, pendingFresh)].filter(Boolean).join("\n")
        pendingFresh = false
        appliedSignature = applySignature()
        applyProc.command = ["hyprctl", "eval", lua]
        applyProc.running = true
    }
    function applySignature() {
        return JSON.stringify([settings.keybindings || {}, blurBackground, gesturesEnabled, gestureFingers])
    }
    Process {
        id: applyProc
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) console.warn("[omaglide] Could not apply keybindings")
            root.gestureResponse = ""
            gestureProc.command = ["hyprctl", "repl", Shortcuts.gestureLua(root.shortAppId, root.gesturesEnabled, root.gestureFingers)]
            gestureProc.running = true
        }
    }
    property string gestureResponse: ""
    property string configErrorResponse: ""
    Process {
        id: gestureProc
        stdout: StdioCollector { onStreamFinished: root.gestureResponse = text }
        onExited: (exitCode, exitStatus) => {
            const result = String(root.gestureResponse).trim()
            if (result.indexOf("reload") >= 0) {
                // Different swipes are registered; only a reload removes them
                // safely. configreloaded then re-applies everything.
                root.gestureStatus = "reloading"
                reloadProc.running = true
                return
            }
            if (result.indexOf("registered") >= 0) {
                root.configErrorResponse = ""
                configErrorsProc.running = true
            } else if (result.indexOf("same") < 0) root.gestureStatus = "unavailable"
            else if (!root.gestureStatus || root.gestureStatus === "reloading") root.gestureStatus = "active"
            root.refreshShortcuts()
        }
    }
    Process { id: reloadProc; command: ["hyprctl", "reload", "config-only"] }
    Process {
        id: configErrorsProc
        command: ["hyprctl", "configerrors"]
        stdout: StdioCollector { onStreamFinished: root.configErrorResponse = text }
        onExited: (exitCode, exitStatus) => {
            root.gestureConflicts = Shortcuts.gestureConflicts(root.configErrorResponse)
            root.gestureStatus = root.gesturesEnabled ? (root.gestureConflicts.length ? "conflict" : "active") : "off"
            root.refreshShortcuts()
        }
    }
    function cycleGroup(delta) {
        if (!appsGrouped() || !windows.length) return
        const group = windows[selected]
        const members = group.windows || []
        if (members.length < 2) return
        const member = members[Logic.wrapIndex(members.findIndex(w => w.address === group.address) + delta, members.length)]
        groupSelections[group.key] = member.address
        const updated = windows.slice()
        updated[selected] = Object.assign({}, group, member, {
            key: group.key, appKey: group.appKey, grouped: true, count: group.count, windows: members
        })
        windows = updated
    }
    function selectWorkspace(number) {
        if ((!open && !opening) || !Number.isInteger(number) || number < 1 || number > 9) return
        // Number keys are navigation even when the search field has focus.
        // Cancel any snapshot/activation, then jump without waiting for Enter.
        close(false, true)
        holdMode = false
        pendingWorkspace = String(number)
        focusTimer.restart()
    }
    function search(query) {
        holdMode = false
        quickLook = false
        searchQuery = String(query).slice(0, 256)
        const previous = windows.length ? windows[selected].key : ""
        windows = entriesForQuery(searchQuery)
        animate = false
        position = Math.max(0, windows.findIndex(w => w.key === previous))
        visualPosition = position
        Qt.callLater(() => { root.animate = true })
    }
    function expose() { showExpose(false) }
    function appExpose() { showExpose(true) }
    // Both Exposés share one view; App Exposé narrows it to the focused app.
    // When opening from closed, the class is read from the fresh snapshot.
    function showExpose(app) {
        const reversing = closing
        cancelClosing()
        glideDuration = exposeDuration
        exitDuration = 220
        const live = (open || opening) && mode === "windows"
        appExposed = !!app
        if (app && live) {
            const active = rawWindows.find(w => w.address === activeAddress)
            appExposeClass = active ? Logic.appClassKey(active.cls) : ""
        }
        if (exposed && live) rebuildEntries()
        exposed = true
        if (!live) openSwitcher(false, "windows", 0)
        else if (reversing && tracking !== "open") entrance.restart() // Glide back out from where the exit stopped.
        else if (reversing) entranceProgress = trackedValue()
        holdMode = false
    }
    // Mission Control swipes. Up opens Exposé; down from Exposé glides back
    // to the desktop, and down again opens App Exposé (even mid-glide). Up
    // from App Exposé returns to the desktop. Repeating a view's own opening
    // swipe leaves it open; down dismisses the slider.
    function swipe(direction) {
        const showing = (open || opening) && exposed && !closing
        if (direction === "up") {
            if (!showing) expose()
            else if (appExposed) close(false)
        } else if (showing) {
            if (!appExposed) close(false)
        } else if ((open || opening) && !closing && !exposed) close(false)
        else appExpose()
    }
    function toggleMode() {
        if (resizing || exposed) return
        const nextMode = mode === "windows" ? "workspaces" : "windows"
        rememberMode(nextMode)
        openSwitcher(holdMode, nextMode, 0)
    }
    function rememberMode(nextMode) {
        carouselMode = nextMode === "workspaces" ? "workspaces" : "windows"
        if (settings.carouselMode === carouselMode) return
        const next = Object.assign({}, settings, { carouselMode: carouselMode })
        settings = next
        if (shell && shell.updateEntryInline) shell.updateEntryInline(shortAppId, next)
    }
    function cycleSwitcher(delta) {
        if (closing) close(false, true)
        exposed = false
        if ((open || opening) && mode === carouselMode) { holdMode = true; step(delta) }
        else openSwitcher(true, carouselMode, delta)
    }
    function cycleWorkspaces() {
        rememberMode("workspaces")
        cycleSwitcher(1)
    }
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
                const binds = JSON.parse(root.shortcutResponse)
                root.shortcutText = Shortcuts.summarize(binds, root.shortAppId)
                    || "No OmaGlide shortcuts — set them in Settings (gear icon)"
                root.liveBinds = binds
                root.liveChords = Shortcuts.currentChords(binds, root.shortAppId)
            } catch (error) { root.shortcutText = "Shortcuts unavailable" }
            if (root.pendingApply) root.runApply()
        }
    }
    // Refreshed on each opening, after config reloads, and after OmaGlide
    // applies its own bindings. No polling while open: that spawned hyprctl
    // every two seconds for changes that almost never happen.
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
                root.carouselMode = root.settings.carouselMode === "workspaces" ? "workspaces" : "windows"
                const grouping = root.settings.groupApps !== false
                if (root.groupApps !== grouping) {
                    root.groupApps = grouping
                    if (root.mode === "windows") root.rebuildEntries()
                }
                if (!root.resizing && !saveSize.running)
                    root.preferredWidth = Math.round(Logic.clamp(root.settings.tileWidth, 240, 1200, 560))
                const signature = root.applySignature()
                if (signature !== root.appliedSignature) root.applyBindings(!root.appliedSignature)
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
        if (exposed) return // The grid always fits the screen automatically.
        preferredWidth = Math.round(Logic.clamp(width, 240, 1200, 560))
        holdMode = false
        if (!resizing) saveSize.restart()
    }
    function resizeBy(amount) { setSize(preferredWidth + amount) }
    function step(delta) {
        if (closing) return
        if (opening) { earlySteps += delta; return }
        if (windows.length > 1) position += delta
    }
    function selectIndex(index) {
        if (closing) return
        if (windows.length) position += Logic.signedDistance(index, position, windows.length)
    }
    function openSwitcher(hold, requestedMode, direction) {
        const nextMode = requestedMode === "workspaces" ? "workspaces" : "windows"
        if ((open || opening) && mode === nextMode) return
        focusTimer.stop()
        pendingAddr = ""
        pendingWorkspace = ""
        groupSelections = ({})
        if (mode !== nextMode) {
            windows = []
            allWindows = []
        }
        mode = nextMode
        searchQuery = ""
        holdMode = hold && !exposed
        opening = true
        initialStep = direction === undefined ? (holdMode ? 1 : 0) : direction
        activateAfterOpen = false
        earlySteps = 0
        errorMessage = ""
        refreshShortcuts()
        monitorName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        originMonitorId = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.id : -1
        originWorkspaceId = Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace
            ? Hyprland.focusedMonitor.activeWorkspace.id : 0
        Hyprland.refreshToplevels()
        querySnapshot()
    }
    function show() {
        if (closing) close(false, true) // The slider never shares the glide.
        exposed = false; holdMode = false; openSwitcher(false, carouselMode, 0)
    }
    function showWindows() { rememberMode("windows"); show() }
    function showWorkspaces() { rememberMode("workspaces"); show() }
    function hide() { close(false) }
    function toggle() { (open || opening) && !closing ? close(false) : show() }
    function confirmSelection() {
        if ((open || opening) && holdMode && !resizing && Date.now() - lastCloseRequest > 250)
            close(true)
    }
    // immediate skips Exposé's return animation (number-key jumps, a revoked
    // shortcut inhibitor, or a close that is already animating).
    function close(activate, immediate) {
        if (activate && !open && !opening) return
        // A quick modifier release can precede the asynchronous snapshot.
        // Commit as soon as its selection exists, without waiting for animation.
        if (activate && opening) { activateAfterOpen = true; return }
        if (closing) {
            if (immediate) { exitAnimation.stop(); finishClose(closingEntry) }
            return
        }
        const entry = activate && open && !errorMessage && windows.length ? windows[selected] : null
        if (exposed && open && !opening && !immediate) {
            closing = true
            closingEntry = entry
            tracking = ""
            exitDuration = 220
            // The chosen window's workspace slides in under the glide, so its
            // windows land on themselves instead of popping in after unmapping.
            if (entry && /^0x[0-9a-f]+$/i.test(entry.address))
                Hyprland.dispatch('hl.dsp.focus({ window = "address:' + entry.address + '" })')
            quickLook = false
            settingsOpen = false
            entrance.stop()
            exitAnimation.restart()
            return
        }
        finishClose(entry)
    }
    function finishClose(entry) {
        closing = false
        closingEntry = null
        tracking = ""
        focusTimer.stop()
        pendingAddr = ""
        pendingWorkspace = ""
        opening = false
        activateAfterOpen = false
        open = false
        settingsOpen = false
        quickLook = false
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
            if (root.pointerFollowsFocus) pointerTimer.restart()
        }
    }
    // Your config may disable Hyprland's own cursor warps (cursor:no_warps),
    // so move the pointer explicitly once the switch has landed. Asking for
    // the active window covers windows, workspaces and number-key jumps alike.
    Timer {
        id: pointerTimer
        interval: 120
        onTriggered: if (!activeWindowProc.running) { root.activeWindowResponse = ""; activeWindowProc.running = true }
    }
    property string activeWindowResponse: ""
    Process {
        id: activeWindowProc
        command: ["hyprctl", "-j", "activewindow"]
        stdout: StdioCollector { onStreamFinished: root.activeWindowResponse = text }
        onExited: (exitCode, exitStatus) => {
            try {
                const active = JSON.parse(root.activeWindowResponse)
                if (exitCode !== 0 || !Array.isArray(active.at) || !Array.isArray(active.size)) return
                const x = Math.round(active.at[0] + active.size[0] / 2), y = Math.round(active.at[1] + active.size[1] / 2)
                if (isFinite(x) && isFinite(y)) Hyprland.dispatch("hl.dsp.cursor.move({ x = " + x + ", y = " + y + " })")
            } catch (error) {} // Empty workspace: nothing to follow.
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
            activateAfterOpen = false
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
        const wasOpen = open && !opening
        refreshHandles()
        const activeClient = clients.find(c => Number(c.focusHistoryID) === 0)
        activeAddress = activeClient ? activeClient.address : ""
        if (!wasOpen && appExposed)
            appExposeClass = activeClient ? Logic.appClassKey(activeClient.class || activeClient.initialClass) : ""
        if (mode === "windows") rawWindows = Logic.orderClients(clients).map(c => ({
            key: c.address, address: c.address, cls: c.class || c.initialClass || "",
            title: c.title || "Untitled window", workspaceId: c.workspace ? c.workspace.id : -1,
            workspaceName: c.workspace ? c.workspace.name : "?",
            sourceAspectRatio: c.size && c.size[0] > 0 && c.size[1] > 0 ? c.size[0] / c.size[1] : 1.6,
            // Desktop geometry for the Exposé fly-in (layout coordinates).
            at: Array.isArray(c.at) ? c.at : null, size: Array.isArray(c.size) ? c.size : null,
            monitor: c.monitor
        }))
        allWindows = mode === "workspaces" ? Workspace.buildWorkspaces(clients, workspaces, monitors)
            : (appsGrouped() ? Logic.groupAppEntries(rawWindows, activeAddress) : rawWindows)
        const records = entriesForQuery(searchQuery)
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
        // Held cycling starts one step from the current entry. Persistent
        // browsing and changing views start on the current app/workspace.
        const isWorkspaces = mode === "workspaces"
        const rawActive = isWorkspaces && focused
            ? records.findIndex(w => focused.activeWorkspace && w.workspaceId === focused.activeWorkspace.id)
            : records.findIndex(w => activeClient && w.address === activeClient.address)
        const baseIndex = rawActive >= 0 ? rawActive + initialStep : (initialStep < 0 ? records.length - 1 : 0)
        position = wasOpen && retained >= 0 ? retained : Logic.wrapIndex(baseIndex + earlySteps, records.length)
        visualPosition = position
        opening = false
        if (activateAfterOpen) {
            // close() consumes the selected record, and the layer never maps.
            activateAfterOpen = false
            const entry = records[selected]
            if (entry) {
                if (isWorkspaces) pendingWorkspace = entry.workspaceId > 0 ? String(entry.workspaceId) : "name:" + entry.workspaceName
                else pendingAddr = entry.address
                focusTimer.restart()
            }
            open = false
            return
        }
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
            if (event.name === "custom") { root.swipeEvent(event.data); return }
            if (event.name === "configreloaded") root.applyBindings(true)
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
        onPressed: root.cycleSwitcher(1)
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "previous"
        onPressed: root.cycleSwitcher(-1)
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "workspaces"
        onPressed: root.cycleWorkspaces()
    }
    GlobalShortcut { appid: root.shortAppId; name: "toggle"; onPressed: root.toggle() }
    // The compositor forwards Alt release even when a quick tap ends before
    // the layer receives keyboard focus. Either shortcut edge is sufficient.
    GlobalShortcut {
        appid: root.shortAppId; name: "release"
        onPressed: root.confirmSelection()
        onReleased: root.confirmSelection()
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "expose"
        onPressed: {
            if (root.closing) root.expose()
            else if ((root.open || root.opening) && !root.exposed) root.toggleMode()
            else if ((root.open || root.opening) && !root.appExposed) root.step(1)
            else root.expose()
        }
    }
    GlobalShortcut {
        appid: root.shortAppId; name: "appExpose"
        onPressed: (root.open || root.opening) && root.exposed && root.appExposed && !root.closing ? root.step(1) : root.appExpose()
    }
    GlobalShortcut { appid: root.shortAppId; name: "gesture-up"; onPressed: root.swipe("up") }
    GlobalShortcut { appid: root.shortAppId; name: "gesture-down"; onPressed: root.swipe("down") }
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
        function windows(): void { root.showWindows() }
        function workspaces(): void { root.showWorkspaces() }
        function hide(): void { root.hide() }
        function activate(): void {
            root.confirmSelection()
        }
        function toggle(): void { root.toggle() }
        function expose(): void { root.expose() }
        function appExpose(): void { root.appExpose() }
        function swipe(direction: string): void { root.swipe(direction) }
        // A tracked swipe phase, as Hyprland's gesture callbacks send it:
        // swipeTrack up start 0 / swipeTrack up update 0.4 / swipeTrack up end 0.6
        function swipeTrack(direction: string, phase: string, progress: real): void {
            root.swipeEvent(root.shortAppId + ":swipe:" + direction + ":" + phase + ":" + progress)
        }
        // sliderStyle icons / sliderStyle thumbnails
        function sliderStyle(style: string): string {
            if (style !== "icons" && style !== "thumbnails") return "use icons or thumbnails"
            root.saveSetting("sliderStyle", style)
            return "ok"
        }
        // gestures on 4 / gestures off
        function gestures(state: string, fingers: int): string {
            if (state !== "on" && state !== "off") return "use on or off"
            root.saveSetting("gestureFingers", fingers === 4 ? 4 : 3)
            root.saveSetting("gesturesEnabled", state === "on")
            return "ok"
        }
        function settings(): void { root.openSettings() }
        function quickLook(): void { root.toggleQuickLook() }
        // bind expose "SUPER + E"; an empty chord unbinds the action.
        function bind(action: string, chord: string): string {
            if (!Shortcuts.ACTIONS.some(a => a.id === action)) return "unknown action"
            if (chord && !Shortcuts.normalizeChord(chord)) return "invalid chord"
            root.setBinding(action, chord)
            return "ok"
        }
        function toggleMode(): void { root.toggleMode() }
        function toggleGroups(): void { root.toggleGroups() }
        function cycleGroup(delta: int): void { root.cycleGroup(delta) }
        function selectWorkspace(number: int): void { root.selectWorkspace(number) }
        function search(query: string): void { root.search(query) }
        function next(): void { root.step(1) }
        function previous(): void { root.step(-1) }
        function resize(action: string): void {
            if (action === "larger") root.resizeBy(48)
            else if (action === "smaller") root.resizeBy(-48)
            else if (action === "reset") root.setSize(560)
        }
        function status(): string {
            return JSON.stringify({ open: root.open, mode: root.mode, count: root.windows.length, selected: root.selected,
                carouselMode: root.carouselMode,
                accentColor: String(root.accentColor),
                exposed: root.exposed, closing: root.closing, tracking: root.tracking, desktopWorkspaceId: root.desktopWorkspaceId, sliderStyle: root.sliderStyle, iconStyle: root.iconStyle, appExposed: root.appExposed, appExposeClass: root.appExposeClass,
                gestures: { enabled: root.gesturesEnabled, fingers: root.gestureFingers, status: root.gestureStatus,
                    conflicts: root.gestureConflicts },
                settingsOpen: root.settingsOpen, quickLook: root.quickLook, searchQuery: root.searchQuery, totalCount: root.allWindows.length,
                groupApps: root.groupApps, groupingActive: root.groupingActive,
                entries: root.windows.map(w => ({ key: w.key, address: w.address, workspaceId: w.workspaceId, windowCount: w.count })),
                preferredWidth: root.preferredWidth, holdMode: root.holdMode, resizing: root.resizing,
                entranceDuration: root.entranceDuration, entranceProgress: root.entranceProgress,
                entranceRunning: root.entranceRunning,
                shortcutText: root.shortcutText, controlsText: root.controlsText,
                preview: loader.item ? loader.item.metrics() : null })
        }
    }
    // Unmap the layer on close, retaining QML delegates and native frames.
    // Captures and refresh timers pause while hidden.
    LazyLoader {
        id: loader
        active: true
        PanelWindow {
            id: panel
            visible: root.open
            screen: Quickshell.screens.find(s => s.name === root.monitorName) || Quickshell.screens[0]
            // Fullscreen geometry stays stable while the layer is unmapped.
            // A hidden PanelWindow reports its small initial surface size.
            readonly property real layoutWidth: screen ? screen.width : 1920
            readonly property real layoutHeight: screen ? screen.height : 1080
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            WlrLayershell.namespace: root.shortAppId
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            Connections {
                target: viewport.Window.window
                // Start after the first presented frame, so capture setup
                // cannot consume the slide before anything reaches the screen.
                function onFrameSwapped() {
                    if (root.open && root.entrancePending) {
                        root.entrancePending = false
                        if (root.tracking === "open") root.entranceProgress = root.trackedValue()
                        else entrance.restart()
                    }
                }
            }
            // Keyboard exclusivity alone does not stop Hyprland's Super+mouse
            // bindings: they target the application behind this layer before
            // Qt sees the press. Inhibit compositor shortcuts for this focused
            // surface only; destruction/closing releases the guard automatically.
            ShortcutInhibitor {
                id: shortcutGuard
                window: panel
                enabled: root.open
                onCancelled: if (root.open) root.close(false, true)
            }
            readonly property real tileWidth: Math.min(Logic.effectiveTileWidth(root.preferredWidth, layoutWidth, layoutHeight),
                Math.max(1, (overviewStrip.y - 144 - 54) * 16 / 10))
            readonly property real cardHeight: tileWidth * 0.625 + 54
            readonly property real carouselY: Math.max(120, Math.min((layoutHeight - cardHeight) / 2,
                overviewStrip.y - 24 - cardHeight))
            // Reserve the ring at the smallest size so resizing cannot destroy
            // the selected delegate (and its active pointer grab) mid-drag.
            readonly property int slotCount: root.exposed ? root.windows.length : Logic.carouselSpan(root.windows.length, layoutWidth, Math.min(240, tileWidth))
            readonly property real gridLeft: 48
            readonly property real gridTop: root.appExposed ? 130 : 96
            readonly property real gridWidth: Math.max(1, layoutWidth - 2 * gridLeft)
            readonly property real gridHeight: Math.max(1, layoutHeight - gridTop - 36)
            // Row-packed by each window's real shape; computed only for Exposé.
            readonly property var grid: Logic.exposeLayout(root.exposed ? root.windows.map(w => w.sourceAspectRatio) : [],
                gridWidth, gridHeight, { caption: 50 })
            readonly property real screenX: screen ? screen.x : 0
            readonly property real screenY: screen ? screen.y : 0
            function cardAt(index) { return cards.itemAt(index) }
            function refocus() { viewport.forceActiveFocus() }
            function metrics() {
                const card = cards.itemAt(Logic.wrapIndex(root.position, slotCount))
                let loaded = 0
                for (let i = 0; i < cards.count; i++) if (cards.itemAt(i).captureActive) loaded++
                return { monitor: root.monitorName, width: width, height: height, dpr: devicePixelRatio,
                    entranceOffset: viewport.x, entranceOpacity: viewport.opacity,
                    grid: root.exposed ? { rows: grid.rows, rowHeight: grid.rowHeight, left: gridLeft, top: gridTop,
                        width: gridWidth, height: gridHeight } : null,
                    tiles: root.exposed ? Array.from({length: cards.count}, (_, i) => {
                        const c = cards.itemAt(i)
                        return {x: c.x, y: c.y, width: c.width, height: c.height, selected: c.isSelected,
                            frameColor: String(c.frameColor), frameWidth: c.frameWidth,
                            previewWidth: c.width, previewHeight: c.previewHeight, sourceAspectRatio: c.win.sourceAspectRatio,
                            emphasis: c.geometry.emphasis, scale: c.scale, z: c.z, address: c.win.address, opacity: c.opacity}
                    }) : [],
                    overview: { visible: overviewStrip.visible, x: overviewStrip.x, y: overviewStrip.y,
                        width: overviewStrip.width, height: overviewStrip.height,
                        items: Array.from({length: overviewItems.count}, (_, i) => {
                            const item = overviewItems.itemAt(i)
                            return {key: item.win.key, x: item.x, y: item.y, width: item.width,
                                height: item.height, selected: item.isSelected, capture: item.captureMetrics()}
                        }) },
                    quickLook: { open: root.quickLook, shown: root.quickLookShown, progress: root.quickLookProgress, x: quickLookFrame.x, y: quickLookFrame.y,
                        width: quickLookFrame.width, height: quickLookFrame.height,
                        hasContent: !!(quickLookLayer.lookCard && quickLookLayer.lookCard.captureMetrics().hasContent) },
                    hintsVisible: footer.visible,
                    iconSwitcher: { visible: iconSwitcher.visible, x: iconSwitcher.x, y: iconSwitcher.y,
                        width: iconSwitcher.width, height: iconSwitcher.height, iconSize: iconSwitcher.iconSize,
                        count: iconItems.count, selected: Array.from({length: iconItems.count}, (_, i) => iconItems.itemAt(i))
                            .findIndex(item => item && item.isSelected) },
                    carouselY: carouselY, cardHeight: cardHeight,
                    tileWidth: tileWidth, shortcutsInhibited: shortcutGuard.active,
                    capture: card ? card.captureMetrics() : null, loadedPreviews: loaded }
            }
            // Modifier release is delivered to this keyboard-exclusive surface.
            // Do not poll compositor key state: shortcut inhibition can clear
            // its pressed-key bookkeeping while Alt is physically still held.
            // Translucent dim over the live desktop; the compositor blurs what
            // is behind it (runtime layer rule). Exposé fades it in as the
            // windows fly into place.
            Rectangle {
                anchors.fill: parent
                color: "black"
                opacity: (root.blurBackground ? (root.exposed ? 0.30 : 0.42) : (root.exposed ? 0.50 : 0.62))
                    * (root.exposed ? root.entranceProgress : root.iconStyle ? 0 : 1)
            }
            MouseArea { anchors.fill: parent; onClicked: root.close(false) }
            Item {
                id: viewport
                x: root.exposed ? 0 : (1 - root.entranceProgress) * Math.min(160, panel.layoutWidth * 0.12)
                width: panel.layoutWidth; height: panel.layoutHeight
                clip: true
                focus: true
                Connections {
                    target: root
                    function onOpenChanged() {
                        if (root.open) {
                            root.hoverPosition = Qt.point(NaN, NaN)
                            viewport.forceActiveFocus()
                        }
                    }
                }
                Keys.priority: Keys.BeforeItem
                // The overlay inhibits compositor shortcuts, so the view's own
                // shortcut arrives here: Exposé's advances the selection (Shift
                // reverses), the slider's dismisses it. The other view's
                // shortcut does nothing; views no longer toggle into each other.
                function matchesOwnChord(event) {
                    const pressed = Shortcuts.chordFromKey(event.key, event.modifiers, event.nativeScanCode).chord
                    if (!pressed) return false
                    if (root.exposed) {
                        // The other Exposé's shortcut switches scope in place.
                        const other = root.appExposed ? (root.liveChords.expose || []) : (root.liveChords.appExpose || [])
                        if (other.indexOf(pressed) >= 0) { root.appExposed ? root.expose() : root.appExpose(); return true }
                        const own = root.appExposed ? root.liveChords.appExpose : root.liveChords.expose
                        const chords = own && own.length ? own : root.appExposed ? [] : ["ALT + grave"]
                        const unshifted = pressed.replace(" + SHIFT", "")
                        if (chords.indexOf(pressed) < 0 && chords.indexOf(unshifted) < 0) return false
                        if (!event.isAutoRepeat) root.step(chords.indexOf(pressed) < 0 ? -1 : 1)
                        return true
                    }
                    if ((root.liveChords.toggle || []).indexOf(pressed) < 0) return false
                    root.close(false)
                    return true
                }
                function handleKey(event, editing) {
                    if (root.closing) return true
                    const ctrl = event.modifiers & Qt.ControlModifier
                    const plain = !(event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))
                    // Space previews in Exposé; while searching it stays a space.
                    if (event.key === Qt.Key_Space && plain && root.exposed && root.windows.length
                        && (root.quickLook || !editing || !root.searchQuery)) {
                        if (!event.isAutoRepeat) root.toggleQuickLook()
                    }
                    else if (event.key === Qt.Key_Escape && root.quickLook) root.quickLook = false
                    else if (event.key === Qt.Key_Escape) {
                        if (root.searchQuery) root.search("")
                        else root.close(false)
                    }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (root.windows.length) root.close(true)
                    }
                    else if (matchesOwnChord(event)) {}
                    else if (event.key === Qt.Key_Comma && ctrl) root.openSettings()
                    else if (event.key === Qt.Key_G && ctrl && !(event.modifiers & Qt.MetaModifier)) root.toggleGroups()
                    else if (event.key === Qt.Key_F && ctrl) {
                        root.holdMode = false
                        searchInput.forceActiveFocus()
                        searchInput.selectAll()
                    }
                    else if (event.key === Qt.Key_W && (event.modifiers & Qt.AltModifier)
                        && root.mode !== "workspaces") root.cycleWorkspaces()
                    else if ([Qt.Key_QuoteLeft, Qt.Key_AsciiTilde].indexOf(event.key) >= 0 && !root.exposed
                        && (!editing || (event.modifiers & Qt.AltModifier))) {
                        if (!event.isAutoRepeat) root.toggleMode()
                    }
                    else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) root.step(-1)
                    else if (!ctrl && !(event.modifiers & Qt.MetaModifier)
                        && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                        if (!event.isAutoRepeat) root.selectWorkspace(event.key - Qt.Key_0)
                    }
                    else if ([Qt.Key_Down, Qt.Key_Up].indexOf(event.key) >= 0) {
                        const delta = event.key === Qt.Key_Down ? 1 : -1
                        if (root.exposed) root.selectIndex(Logic.exposeMove(panel.grid, root.selected, delta))
                        else if (root.groupingActive) root.cycleGroup(delta)
                        else root.step(delta)
                    }
                    else if (event.key === Qt.Key_Tab || (!editing && event.key === Qt.Key_Right)) root.step(1)
                    else if (!editing && event.key === Qt.Key_Left) root.step(-1)
                    else if ((!editing || ctrl) && [Qt.Key_Plus, Qt.Key_Equal].indexOf(event.key) >= 0) root.resizeBy(48)
                    else if ((!editing || ctrl) && event.key === Qt.Key_Minus) root.resizeBy(-48)
                    else if (ctrl && event.key === Qt.Key_0) root.setSize(560)
                    else if (event.key === Qt.Key_Q && (event.modifiers & Qt.MetaModifier)) root.quitSelected()
                    else return false
                    return true
                }
                Keys.onPressed: event => {
                    event.accepted = handleKey(event, false)
                    if (!event.accepted && event.text && !(event.modifiers & (Qt.ControlModifier | Qt.MetaModifier))
                        && event.text.charCodeAt(0) >= 32) {
                        root.search(root.searchQuery + event.text)
                        searchInput.forceActiveFocus()
                        searchInput.cursorPosition = searchInput.length
                        event.accepted = true
                    }
                }
                Keys.onReleased: event => {
                    if (!root.exposed && root.holdMode && !root.resizing && Date.now() - root.lastCloseRequest > 250
                        && [Qt.Key_Alt, Qt.Key_AltGr, Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_Meta, Qt.Key_Control].indexOf(event.key) >= 0) root.confirmSelection()
                }
                // Exposé reads like Mission Control: no header unless there is
                // something to say. The carousel keeps its position counter.
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: root.exposed ? panel.gridTop + panel.gridHeight / 2 - height / 2 : Math.max(92, panel.carouselY - 44)
                    visible: (!root.exposed && !root.iconStyle) || !!root.errorMessage || !root.windows.length
                    width: headerText.implicitWidth + 28; height: 28; radius: 14
                    color: "transparent"
                    GlassPanel { anchors.fill: parent; radius: parent.radius; density: 0.45; blurred: root.blurBackground }
                    Text {
                        id: headerText
                        anchors.centerIn: parent
                        text: root.errorMessage || (root.windows.length ? (root.mode === "workspaces" ? "WORKSPACES" : root.groupingActive ? "APPS" : "WINDOWS") + "  ·  " + (root.selected + 1) + " / " + root.windows.length : (root.searchQuery ? "No matches" : "Nothing to preview"))
                        color: root.glassInk; font.family: Style.font.family
                        font.pixelSize: 12; font.letterSpacing: 2; opacity: 0.85
                    }
                }
                // App Exposé names the app it is showing, beneath the search bar.
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 84
                    visible: root.exposed && root.appExposed && root.windows.length > 0
                    opacity: root.entranceProgress
                    width: appHeaderRow.implicitWidth + 28; height: 32; radius: 16
                    color: "transparent"
                    GlassPanel { anchors.fill: parent; radius: parent.radius; density: 0.45; blurred: root.blurBackground }
                    Row {
                        id: appHeaderRow
                        anchors.centerIn: parent
                        spacing: 8
                        readonly property var app: root.windows.length ? root.windows[0] : null
                        Image {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 20; height: 20
                            sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                            source: appHeaderRow.app ? root.iconFor(appHeaderRow.app.cls, appHeaderRow.app.title) : ""
                            fillMode: Image.PreserveAspectFit
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: appHeaderRow.app ? appHeaderRow.app.cls + "   ·   " + root.windows.length
                                + (root.windows.length === 1 ? " window" : " windows") : ""
                            textFormat: Text.PlainText
                            color: root.glassInk; font.family: Style.font.family
                            font.pixelSize: 13; font.weight: Font.Medium
                        }
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 28
                    // Cmd+Tab style keeps the screen clear until you type.
                    visible: !root.iconStyle || !!root.searchQuery || root.settingsOpen
                    spacing: 10
                    Rectangle {
                        width: Math.max(100, Math.min(460, panel.layoutWidth - 200)); height: 44; radius: 22
                        color: "transparent"
                        GlassPanel { anchors.fill: parent; radius: parent.radius; density: 0.4; blurred: root.blurBackground }
                        border.width: searchInput.activeFocus ? 1 : 0
                        border.color: Qt.alpha(root.accentColor, 0.8)
                        Text {
                            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                            text: "󰍉"
                            color: root.glassInk; opacity: 0.55
                            font.family: Style.font.family; font.pixelSize: 17
                        }
                        TextInput {
                            id: searchInput
                            anchors { fill: parent; leftMargin: 42; rightMargin: 16; topMargin: 12; bottomMargin: 12 }
                            color: root.glassInk; selectionColor: Qt.rgba(1, 1, 1, 0.3)
                            selectedTextColor: root.glassInk
                            font.family: Style.font.family; font.pixelSize: 15
                            clip: true; maximumLength: 256; selectByMouse: true
                            text: root.searchQuery
                            onTextEdited: root.search(text)
                            onActiveFocusChanged: if (activeFocus) root.holdMode = false
                            Keys.priority: Keys.BeforeItem
                            Keys.onPressed: event => { event.accepted = viewport.handleKey(event, true) }
                            Text {
                                anchors.fill: parent
                                text: "Search windows or apps…"
                                visible: !searchInput.text
                                color: root.glassInk; opacity: 0.5
                                font: searchInput.font
                            }
                        }
                    }
                    Rectangle {
                        id: gearButton
                        width: 44; height: 44; radius: 22
                        color: "transparent"
                        GlassPanel {
                            anchors.fill: parent; radius: parent.radius; density: 0.4; blurred: root.blurBackground
                            highlighted: gearMouse.containsMouse || root.settingsOpen
                        }
                        Text {
                            anchors.centerIn: parent
                            text: "󰒓"
                            color: root.glassInk; opacity: gearMouse.containsMouse ? 1 : 0.75
                            font.family: Style.font.family; font.pixelSize: 20
                            rotation: gearMouse.containsMouse ? 45 : 0
                            Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        }
                        MouseArea {
                            id: gearMouse
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.settingsOpen ? root.closeSettings() : root.openSettings()
                        }
                    }
                }
                Repeater {
                    id: cards
                    model: panel.slotCount
                    delegate: Item {
                        id: card
                        required property int index
                        readonly property var win: root.windows[index % root.windows.length]
                        readonly property var sourceHandle: win ? root.captureHandles[win.address] || null : null
                        readonly property real distance: root.exposed ? 0 : Logic.signedDistance(index, root.visualPosition, panel.slotCount)
                        readonly property bool isSelected: index === Logic.wrapIndex(root.position, panel.slotCount)
                        readonly property var geometry: root.exposed
                            ? ({ emphasis: isSelected ? 1 : 0, offset: 0 })
                            : Logic.cardGeometry(distance, panel.tileWidth)
                        // Exposé: the packed tile (preview only; caption hangs below).
                        readonly property var target: {
                            const cell = root.exposed ? panel.grid.cards[index] : null
                            return cell ? { x: panel.gridLeft + cell.x, y: panel.gridTop + cell.y, width: cell.width, height: cell.height }
                                : { x: 0, y: 0, width: 0, height: 0 }
                        }
                        // Windows on the desktop being covered fly from where they
                        // really are, so opening reads as the desktop spreading out.
                        readonly property var origin: root.exposed && win && win.at && win.size && root.desktopWorkspaceId !== 0
                            && win.workspaceId === root.desktopWorkspaceId
                            ? { x: win.at[0] - panel.screenX, y: win.at[1] - panel.screenY, width: win.size[0], height: win.size[1] } : null
                        readonly property bool flying: root.exposed && root.entranceProgress < 1
                        // Quick Look grows this very tile (same live capture) toward the
                        // preview rectangle and shrinks it back: one continuous element.
                        readonly property bool looking: root.exposed && isSelected && root.quickLookShown
                        readonly property real lookProgress: looking ? root.quickLookProgress : 0
                        readonly property var exposeRect: looking ? Logic.mixRect(target, quickLookLayer.to, lookProgress)
                            : flying && origin ? Logic.mixRect(origin, target, root.entranceProgress) : target
                        // Menu selection borders can be transparent, while popup
                        // borders use the accent. Neither role describes a tile.
                        readonly property color frameColor: isSelected ? Qt.alpha(root.accentColor, 1)
                            : Qt.rgba(1, 1, 1, root.exposed ? 0.14 : 0.22)
                        readonly property int frameWidth: isSelected ? 3 : 1
                        readonly property real cornerRadius: root.exposed ? 12 + 4 * lookProgress : 14
                        readonly property bool nearViewport: !root.iconStyle
                            && (root.exposed || Math.abs(geometry.offset) < panel.layoutWidth / 2 + panel.tileWidth)
                        readonly property bool captureActive: captureLoader.active || workspaceLoader.active
                        x: root.exposed ? exposeRect.x : panel.layoutWidth / 2 + geometry.offset - width / 2
                        y: root.exposed ? exposeRect.y : panel.carouselY + (panel.cardHeight - height) / 2
                        width: root.exposed ? exposeRect.width : geometry.width
                        height: root.exposed ? exposeRect.height : geometry.height + 54
                        readonly property real captionHeight: root.exposed ? 0 : 54
                        readonly property real previewHeight: height - captionHeight
                        // Search re-packs the grid; glide there. Never during the fly-in,
                        // whose bindings already change every frame.
                        readonly property bool glide: root.exposed && root.animate && root.open && !flying && !looking
                        Behavior on x { enabled: card.glide; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        Behavior on y { enabled: card.glide; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        Behavior on width { enabled: card.glide; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        Behavior on height { enabled: card.glide; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        // The window being left to glides above the rest.
                        readonly property bool chosen: root.closing && !!root.closingEntry && !!win && win.key === root.closingEntry.key
                        z: looking ? 950 : chosen ? 940 : isSelected ? 110 : 100 - Math.abs(distance)
                        visible: nearViewport
                        // Off-desktop windows fade and settle in. Carousel neighbours are
                        // dimmed by an overlay, not opacity, so the desktop never shows through.
                        opacity: root.exposed ? (origin ? 1 : root.entranceProgress) : 1
                        // The selection zooms up to 18%, as far as the screen sides and the
                        // grid allow: its title pill (inside the 50px caption, scaled too)
                        // must stay clear of the hints below and the search bar above.
                        readonly property real zoom: {
                            if (!root.exposed || !isSelected || target.width <= 0) return 1
                            const cx = target.x + target.width / 2, cy = target.y + target.height / 2
                            const halfW = target.width / 2, halfH = target.height / 2
                            const gridBottom = panel.gridTop + panel.gridHeight
                            return Math.max(1, Math.min(1.18, (cx - 12) / halfW, (panel.layoutWidth - 12 - cx) / halfW,
                                (cy - panel.gridTop + 16) / halfH, (gridBottom + 4 - cy) / (halfH + 50)))
                        }
                        // While looking, the hover zoom blends out so both ends match exactly.
                        // Flying, the selection's zoom grows and shrinks with the glide
                        // rather than jumping when it starts or lands.
                        scale: root.exposed ? (isSelected ? (flying ? 1 + (zoom - 1) * root.entranceProgress
                                : zoom + (1 - zoom) * lookProgress)
                            : origin || !flying ? 1 : 0.94 + 0.06 * root.entranceProgress) : 1
                        Behavior on scale { enabled: card.glide; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
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
                        // Analytic shadow: one cheap SDF pass, no offscreen layer.
                        RectangularShadow {
                            anchors.fill: parent
                            radius: card.cornerRadius
                            blur: root.exposed ? (card.isSelected ? 40 + 24 * card.lookProgress : 26) : 30
                            offset.y: root.exposed ? 10 : 12
                            color: Qt.rgba(0, 0, 0, root.exposed ? 0.42 : 0.35)
                            visible: card.width > 0
                        }
                        // Smoked glass behind the capture; only the slider's caption strip
                        // shows. A single rectangle: the ring builds many of these at once.
                        Rectangle {
                            anchors.fill: parent; radius: card.cornerRadius
                            color: Qt.rgba(0.07, 0.07, 0.09, root.blurBackground ? 0.46 : 0.8)
                            border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.2)
                        }
                        Rectangle {
                            anchors.fill: parent; radius: card.cornerRadius
                            z: 1 // Keep the selection outline above captured content.
                            color: "transparent"
                            border.width: card.frameWidth
                            border.color: card.frameColor
                            opacity: 1 - card.lookProgress // No selection outline on the preview.
                        }
                        // Rounded clip, so captured window corners follow the frame.
                        ClippingRectangle {
                            id: imageBounds
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.exposed ? 0 : 3 }
                            height: card.previewHeight - (root.exposed ? 0 : 3)
                            radius: root.exposed ? card.cornerRadius : card.cornerRadius - 3
                            color: Qt.rgba(1, 1, 1, 0.04)
                            Image {
                                id: fallbackIcon
                                anchors.centerIn: parent; width: 64; height: 64
                                sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                                source: root.iconFor(card.win.cls, card.win.title)
                                fillMode: Image.PreserveAspectFit
                                visible: root.mode === "windows" && status === Image.Ready && (!captureLoader.item || !captureLoader.item.hasContent)
                            }
                            Text {
                                anchors.centerIn: parent
                                text: (card.win.cls || "?").charAt(0).toUpperCase()
                                font.family: Style.font.family; font.pixelSize: 48
                                color: root.glassInk; opacity: 0.55
                                visible: root.mode === "windows" && fallbackIcon.status !== Image.Ready && (!captureLoader.item || !captureLoader.item.hasContent)
                            }
                            Loader {
                                id: captureLoader
                                anchors.fill: parent
                                property var requestedHandle: card.sourceHandle
                                property var mountedHandle: null
                                // Recreate the native view when MRU ordering assigns
                                // a different source, releasing the old render node.
                                onRequestedHandleChanged: {
                                    mountedHandle = null
                                    Qt.callLater(() => { mountedHandle = requestedHandle })
                                }
                                active: root.mode === "windows" && card.nearViewport && !!requestedHandle
                                    && mountedHandle === requestedHandle
                                sourceComponent: Component {
                                    Item {
                                        readonly property size sourceSize: preview.sourceSize
                                        readonly property bool hasContent: preview.hasContent
                                        readonly property real renderedWidth: preview.width
                                        readonly property real renderedHeight: preview.height
                                        ScreencopyView {
                                            id: preview
                                            captureSource: captureLoader.mountedHandle
                                            live: card.isSelected && root.open
                                            paintCursor: false
                                            visible: hasContent
                                            // Keep the native buffer, draw directly at actual
                                            // display geometry; no fixed thumbnail or raster layer.
                                            // Exposé frames already have the window's shape:
                                            // fill them edge to edge, never letterbox.
                                            readonly property real sourceRatio: sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 1.6
                                            width: root.exposed ? parent.width : Math.min(parent.width, parent.height * sourceRatio)
                                            height: root.exposed ? parent.height : width / sourceRatio
                                            anchors.centerIn: parent
                                            Connections {
                                                target: root
                                                function onOpenChanged() {
                                                    if (root.open && !card.isSelected && preview.hasContent)
                                                        preview.captureFrame()
                                                }
                                            }
                                            // Exposé keeps every window mounted, so refresh the
                                            // unselected ones less often and stagger them so the
                                            // copies don't all land on the same frame.
                                            Timer {
                                                interval: (root.exposed ? 1000 : 450) + (card.index % 7) * 23; repeat: true
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
                                active: root.mode === "workspaces" && card.nearViewport
                                sourceComponent: Component {
                                    WorkspacePreview {
                                        entry: card.win
                                        handles: root.captureHandles
                                        selected: card.isSelected
                                        opened: root.open
                                        retainFrames: true
                                        dpr: panel.devicePixelRatio
                                    }
                                }
                            }
                        }
                        Rectangle {
                            anchors.fill: parent; radius: card.cornerRadius; z: 1
                            color: "black"
                            opacity: root.exposed ? 0 : 0.34 * (1 - card.geometry.emphasis)
                            visible: opacity > 0
                        }
                        // Exposé caption, Mission Control style: the app icon sits on
                        // the window's lower edge; the title appears under the selection.
                        Image {
                            id: badgeIcon
                            visible: root.exposed && status === Image.Ready && card.width >= 72
                            anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.bottom }
                            width: 40; height: 40; z: 2
                            sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                            source: root.exposed ? root.iconFor(card.win.cls, card.win.title) : ""
                            fillMode: Image.PreserveAspectFit
                            opacity: (card.flying ? root.entranceProgress : 1) * (1 - card.lookProgress)
                        }
                        Rectangle {
                            visible: root.exposed && card.isSelected && !card.flying && !root.settingsOpen && !card.looking
                            anchors { horizontalCenter: parent.horizontalCenter; top: parent.bottom; topMargin: badgeIcon.visible ? 24 : 8 }
                            width: Math.min(Math.max(card.width + 80, 160), titleText.implicitWidth + 24, panel.layoutWidth - 32); height: 26; radius: 13
                            z: 2
                            color: "transparent"
                            GlassPanel { anchors.fill: parent; radius: parent.radius; density: 0.55; blurred: root.blurBackground }
                            Text {
                                id: titleText
                                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
                                text: card.win.title; elide: Text.ElideRight; textFormat: Text.PlainText
                                color: root.glassInk; font.family: Style.font.family
                                font.pixelSize: 12; font.weight: Font.Medium
                            }
                        }
                        Row {
                            anchors { left: parent.left; leftMargin: 14; bottom: parent.bottom; bottomMargin: 13 }
                            visible: !root.exposed
                            spacing: 10
                            Item {
                                id: captionIcon
                                visible: card.width >= 160
                                width: 26; height: 26
                                Image {
                                    id: appIcon
                                    anchors.fill: parent
                                    sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                                    source: root.iconFor(card.win.cls, card.win.title)
                                    fillMode: Image.PreserveAspectFit
                                    visible: root.mode === "windows" && status === Image.Ready
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: root.mode === "workspaces" ? "▦" : (card.win.cls || "?").charAt(0).toUpperCase()
                                    font.family: Style.font.family; font.pixelSize: 19; font.bold: true
                                    color: root.glassInk; visible: root.mode === "workspaces" || appIcon.status !== Image.Ready
                                }
                            }
                            Column {
                                width: Math.max(1, card.width - (captionIcon.visible ? 70 : 20)); spacing: 2
                                Text {
                                    width: parent.width; elide: Text.ElideRight; text: card.win.title
                                    color: root.glassInk; font.family: Style.font.family
                                    font.pixelSize: 13; font.weight: Font.DemiBold
                                }
                                Text {
                                    visible: !root.exposed || card.captionHeight >= 38
                                    width: parent.width; elide: Text.ElideRight
                                    text: root.mode === "workspaces"
                                        ? card.win.count + (card.win.count === 1 ? " window" : " windows") + "  ·  " + card.win.monitorName
                                        : card.win.cls + (card.win.grouped ? "  ·  " + card.win.count + (card.win.count === 1 ? " window" : " windows") : "")
                                            + "  ·  Workspace " + card.win.workspaceName
                                    color: root.glassInk; opacity: 0.58
                                    font.family: Style.font.family; font.pixelSize: 10
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: root.exposed
                            onPositionChanged: mouse => {
                                if (!root.exposed || pressed) return
                                const point = mapToItem(panel.contentItem, mouse.x, mouse.y)
                                const moved = isFinite(root.hoverPosition.x)
                                    && (Math.abs(point.x - root.hoverPosition.x) > 1 || Math.abs(point.y - root.hoverPosition.y) > 1)
                                root.hoverPosition = point
                                // Geometry changes move local coordinates too;
                                // only actual pointer movement changes selection.
                                if (moved) root.selectIndex(card.index)
                            }
                            onClicked: { root.selectIndex(card.index % root.windows.length); root.close(true) }
                            onWheel: wheel => {
                                if (wheel.modifiers & Qt.ControlModifier) root.resizeBy(wheel.angleDelta.y > 0 ? 32 : -32)
                                else root.step((wheel.angleDelta.y || wheel.angleDelta.x) > 0 ? -1 : 1)
                                wheel.accepted = true
                            }
                        }
                        Item {
                            visible: card.isSelected && !root.exposed
                            anchors { right: parent.right; bottom: parent.bottom; margins: 7 }
                            width: 30; height: 30
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
                // Cmd+Tab-style slider: one frosted panel of app icons, no live
                // captures at all. The selected icon sits on a soft highlight and
                // its window title shows underneath.
                Item {
                    id: iconSwitcher
                    visible: root.iconStyle && root.windows.length > 0 && !root.errorMessage
                    anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter }
                    readonly property int count: root.windows.length
                    readonly property real gap: 10
                    readonly property real iconSize: Math.max(28, Math.min(96,
                        (panel.layoutWidth - 120 - Math.max(0, count - 1) * gap) / Math.max(1, count) - 24))
                    readonly property real cell: iconSize + 24
                    width: count * cell + Math.max(0, count - 1) * gap + 36
                    height: cell + 36 + 30
                    opacity: root.open ? 1 : 0
                    // Lighter than the chrome: the icons carry it, like Cmd+Tab.
                    GlassPanel { anchors.fill: parent; radius: 30; density: 0.3; blurred: root.blurBackground }
                    Row {
                        x: 18; y: 18
                        spacing: iconSwitcher.gap
                        Repeater {
                            id: iconItems
                            model: iconSwitcher.visible ? iconSwitcher.count : 0
                            delegate: Item {
                                id: iconItem
                                required property int index
                                readonly property var win: root.windows[index] || ({})
                                readonly property bool isSelected: index === root.selected
                                width: iconSwitcher.cell; height: iconSwitcher.cell
                                Rectangle {
                                    anchors.fill: parent; radius: 20
                                    visible: iconItem.isSelected
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.34) }
                                        GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.16) }
                                    }
                                    border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.45)
                                }
                                Image {
                                    id: bigIcon
                                    anchors.centerIn: parent
                                    width: iconSwitcher.iconSize; height: width
                                    sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                                    source: root.iconFor(iconItem.win.cls, iconItem.win.title)
                                    fillMode: Image.PreserveAspectFit
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: bigIcon.status !== Image.Ready
                                    text: (iconItem.win.cls || "?").charAt(0).toUpperCase()
                                    color: "white"; font.family: Style.font.family
                                    font.pixelSize: iconSwitcher.iconSize * 0.5; font.weight: Font.DemiBold
                                }
                                // Window count for grouped apps with several windows.
                                Rectangle {
                                    visible: root.groupingActive && iconItem.win.count > 1
                                    anchors { right: parent.right; top: parent.top; margins: 4 }
                                    width: Math.max(18, iconCount.implicitWidth + 8); height: 18; radius: 9
                                    color: root.accentColor
                                    Text {
                                        id: iconCount
                                        anchors.centerIn: parent; text: iconItem.win.count || ""
                                        color: root.glassInk; font.family: Style.font.family
                                        font.pixelSize: 10; font.weight: Font.DemiBold
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    // Like Cmd+Tab: moving the pointer over an icon selects it;
                                    // an icon appearing under a resting pointer does not.
                                    onPositionChanged: mouse => {
                                        const point = mapToItem(panel.contentItem, mouse.x, mouse.y)
                                        const moved = isFinite(root.hoverPosition.x)
                                            && (Math.abs(point.x - root.hoverPosition.x) > 1 || Math.abs(point.y - root.hoverPosition.y) > 1)
                                        root.hoverPosition = point
                                        if (moved) { root.holdMode = false; root.selectIndex(iconItem.index) }
                                    }
                                    onClicked: { root.selectIndex(iconItem.index); root.close(true) }
                                    onWheel: wheel => {
                                        root.step((wheel.angleDelta.y || wheel.angleDelta.x) > 0 ? -1 : 1)
                                        wheel.accepted = true
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 14 }
                        width: Math.min(parent.width - 36, implicitWidth)
                        readonly property var win: root.windows.length ? root.windows[root.selected] : null
                        text: win ? win.title : ""
                        textFormat: Text.PlainText; elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        // Light text with a faint shadow reads over any blurred wallpaper.
                        color: "white"; style: Text.Raised; styleColor: Qt.rgba(0, 0, 0, 0.35)
                        font.family: Style.font.family; font.pixelSize: 14; font.weight: Font.DemiBold
                    }
                }
                Item {
                    id: overviewStrip
                    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
                    visible: !root.exposed && !root.iconStyle && root.windows.length > 0 && !root.errorMessage
                    z: 200
                    readonly property real availableWidth: Math.max(1, parent.width - 96)
                    readonly property real gap: Math.min(12, availableWidth / (Math.max(1, root.windows.length) * 4))
                    readonly property real cellWidth: Math.min(220,
                        (availableWidth - Math.max(0, root.windows.length - 1) * gap) / Math.max(1, root.windows.length))
                    readonly property real thumbnailHeight: cellWidth * 9 / 16
                    width: root.windows.length * cellWidth + Math.max(0, root.windows.length - 1) * gap
                    height: root.windows.length ? thumbnailHeight + 28 : 0
                    Repeater {
                        id: overviewItems
                        model: !root.exposed && !root.iconStyle && !root.errorMessage ? root.windows.length : 0
                        delegate: Item {
                            id: overviewItem
                            required property int index
                            readonly property var win: root.windows[index]
                            readonly property bool isSelected: index === root.selected
                            readonly property var sourceHandle: win ? root.captureHandles[win.address] || null : null
                            readonly property var apps: root.mode === "workspaces"
                                ? (win.windows || []).filter((w, i, list) => list.findIndex(other => other.cls === w.cls) === i) : [win]
                            readonly property real iconGap: Math.min(3, width / (Math.max(1, apps.length) * 4))
                            readonly property real iconSize: Math.min(14,
                                (width - Math.max(0, apps.length - 1) * iconGap) / Math.max(1, apps.length))
                            x: index * (width + overviewStrip.gap)
                            width: overviewStrip.cellWidth; height: overviewStrip.height

                            function captureMetrics() {
                                if (root.mode === "workspaces")
                                    return workspaceThumbnail.item ? workspaceThumbnail.item.metrics()
                                        : {workspaceId: win.workspaceId, count: win.count, windows: []}
                                const image = windowThumbnail.item
                                return {address: win.address, hasContent: image ? image.hasContent : false,
                                    nativeWidth: image ? image.sourceSize.width : 0,
                                    nativeHeight: image ? image.sourceSize.height : 0,
                                    renderedWidth: image ? image.renderedWidth * panel.devicePixelRatio : 0,
                                    renderedHeight: image ? image.renderedHeight * panel.devicePixelRatio : 0}
                            }
                            ClippingRectangle {
                                id: thumbnail
                                width: parent.width; height: overviewStrip.thumbnailHeight
                                radius: 6
                                color: Qt.rgba(0.07, 0.07, 0.09, 0.45)
                                Image {
                                    id: thumbnailFallback
                                    anchors.centerIn: parent
                                    width: Math.min(32, parent.width / 2); height: width
                                    sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                                    source: root.mode === "windows"
                                        ? root.iconFor(overviewItem.win.cls, overviewItem.win.title) : ""
                                    fillMode: Image.PreserveAspectFit
                                    visible: root.mode === "windows" && (!windowThumbnail.item || !windowThumbnail.item.hasContent)
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: (overviewItem.win.cls || "?").charAt(0).toUpperCase()
                                    color: root.glassInk; font.family: Style.font.family
                                    font.pixelSize: Math.min(32, parent.height / 2)
                                    visible: root.mode === "windows" && thumbnailFallback.status !== Image.Ready
                                        && (!windowThumbnail.item || !windowThumbnail.item.hasContent)
                                }
                                Loader {
                                    id: windowThumbnail
                                    anchors.fill: parent
                                    property var requestedHandle: overviewItem.sourceHandle
                                    property var mountedHandle: null
                                    onRequestedHandleChanged: {
                                        mountedHandle = null
                                        Qt.callLater(() => { mountedHandle = requestedHandle })
                                    }
                                    active: root.mode === "windows" && !!requestedHandle && mountedHandle === requestedHandle
                                    sourceComponent: Component {
                                        Item {
                                            readonly property size sourceSize: thumbnailCapture.sourceSize
                                            readonly property bool hasContent: thumbnailCapture.hasContent
                                            readonly property real renderedWidth: thumbnailCapture.width
                                            readonly property real renderedHeight: thumbnailCapture.height
                                            ScreencopyView {
                                                id: thumbnailCapture
                                                captureSource: windowThumbnail.mountedHandle
                                                live: root.open && overviewItem.isSelected
                                                paintCursor: false; visible: hasContent
                                                readonly property real sourceRatio: sourceSize.width > 0 && sourceSize.height > 0
                                                    ? sourceSize.width / sourceSize.height : 1.6
                                                width: Math.min(parent.width, parent.height * sourceRatio)
                                                height: width / sourceRatio
                                                anchors.centerIn: parent
                                                Connections {
                                                    target: root
                                                    function onOpenChanged() {
                                                        if (root.open && !overviewItem.isSelected && thumbnailCapture.hasContent)
                                                            thumbnailCapture.captureFrame()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                Loader {
                                    id: workspaceThumbnail
                                    anchors.fill: parent
                                    active: root.mode === "workspaces"
                                    sourceComponent: Component {
                                        WorkspacePreview {
                                            entry: overviewItem.win; handles: root.captureHandles
                                            selected: overviewItem.isSelected; opened: root.open
                                            retainFrames: true
                                            dpr: panel.devicePixelRatio; refreshInterval: 0
                                        }
                                    }
                                }
                                Rectangle {
                                    anchors.fill: parent; z: 2; radius: 6; color: "black"
                                    opacity: overviewItem.isSelected || overviewMouse.containsMouse ? 0 : 0.4
                                    Behavior on opacity { NumberAnimation { duration: 100 } }
                                }
                                Rectangle {
                                    anchors.fill: parent; color: "transparent"; z: 2; radius: 6
                                    border.width: 1
                                    border.color: Qt.rgba(1, 1, 1, overviewItem.isSelected ? 0.4 : 0.12)
                                }
                                Text {
                                    anchors.fill: parent; z: 3
                                    text: root.mode === "workspaces" ? overviewItem.win.workspaceName : ""
                                    textFormat: Text.PlainText; elide: Text.ElideRight
                                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                                    color: root.accentColor; opacity: 0.85
                                    font.family: Style.font.family; font.pixelSize: parent.height * 0.7
                                    font.weight: Font.Medium
                                }
                                Rectangle {
                                    anchors { top: parent.top; right: parent.right; margins: 5 }
                                    visible: root.groupingActive && overviewItem.win.count > 1
                                    width: groupCount.implicitWidth + 10; height: 20; radius: 5; z: 4
                                    color: Qt.rgba(0.07, 0.07, 0.09, 0.7)
                                    Text {
                                        id: groupCount
                                        anchors.centerIn: parent; text: overviewItem.win.count || 1
                                        color: root.glassInk; font.family: Style.font.family; font.pixelSize: 11
                                    }
                                }
                            }
                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: overviewStrip.thumbnailHeight + 4; height: 14; spacing: overviewItem.iconGap
                                visible: !selectedBar.visible
                                Repeater {
                                    model: overviewItem.apps
                                    delegate: Item {
                                        required property var modelData
                                        width: overviewItem.iconSize; height: width
                                        Image {
                                            id: smallIcon
                                            anchors.fill: parent
                                            sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                                            source: root.iconFor(modelData.cls, modelData.title)
                                            fillMode: Image.PreserveAspectFit
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            text: (modelData.cls || "?").charAt(0).toUpperCase()
                                            visible: smallIcon.status !== Image.Ready
                                            font.family: Style.font.family; font.pixelSize: parent.width
                                            color: root.glassInk
                                        }
                                    }
                                }
                            }
                            // The selection bar names what is selected: app icon and
                            // window title, or the workspace and its window count.
                            Rectangle {
                                id: selectedBar
                                visible: overviewItem.isSelected
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                height: 22; radius: 11
                                color: "transparent"
                                GlassPanel { anchors.fill: parent; radius: parent.radius; density: 0.5; blurred: root.blurBackground; highlighted: true; raised: false }
                                Row {
                                    anchors { fill: parent; leftMargin: 6; rightMargin: 8 }
                                    spacing: 5
                                    Image {
                                        id: barIcon
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: root.mode === "windows" && status === Image.Ready
                                        width: 14; height: 14
                                        sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                                        source: overviewItem.isSelected && root.mode === "windows"
                                            ? root.iconFor(overviewItem.win.cls, overviewItem.win.title) : ""
                                        fillMode: Image.PreserveAspectFit
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - (barIcon.visible ? barIcon.width + parent.spacing : 0)
                                        visible: width >= 24
                                        text: root.mode === "workspaces"
                                            ? "Workspace " + overviewItem.win.workspaceName + "  ·  " + overviewItem.win.count
                                            : overviewItem.win.title
                                        textFormat: Text.PlainText; elide: Text.ElideRight
                                        horizontalAlignment: barIcon.visible ? Text.AlignLeft : Text.AlignHCenter
                                        color: root.glassInk
                                        font.family: Style.font.family; font.pixelSize: 11; font.weight: Font.DemiBold
                                    }
                                }
                            }
                            MouseArea {
                                id: overviewMouse
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.selectIndex(overviewItem.index); root.close(true) }
                                onWheel: wheel => {
                                    if (wheel.modifiers & Qt.ControlModifier) root.resizeBy(wheel.angleDelta.y > 0 ? 32 : -32)
                                    else root.step((wheel.angleDelta.y || wheel.angleDelta.x) > 0 ? -1 : 1)
                                    wheel.accepted = true
                                }
                            }
                        }
                    }
                }
                Item {
                    id: quickLookLayer
                    anchors.fill: parent
                    z: 900
                    visible: root.quickLookShown
                    readonly property var win: root.exposed && root.windows.length ? root.windows[root.selected] : null
                    readonly property real ratio: win && win.sourceAspectRatio > 0 ? win.sourceAspectRatio : 1.6
                    readonly property real availableWidth: width * 0.92
                    readonly property real availableHeight: height - 180
                    readonly property var to: {
                        const w = Math.min(availableWidth, availableHeight * ratio), h = w / ratio
                        return { x: (width - w) / 2, y: 84 + (availableHeight - h) / 2, width: w, height: h }
                    }
                    readonly property var lookCard: root.quickLookShown ? cards.itemAt(root.selected) : null
                    Rectangle { anchors.fill: parent; color: "black"; opacity: 0.5 * root.quickLookProgress }
                    MouseArea {
                        anchors.fill: parent; enabled: root.quickLook
                        onClicked: root.quickLook = false
                        onWheel: wheel => { root.step((wheel.angleDelta.y || wheel.angleDelta.x) > 0 ? -1 : 1); wheel.accepted = true }
                    }
                    Rectangle {
                        anchors { horizontalCenter: parent.horizontalCenter; bottom: quickLookFrame.top; bottomMargin: 14 }
                        visible: !!quickLookLayer.win
                        opacity: root.quickLookProgress
                        width: Math.min(parent.width - 48, quickLookTitle.implicitWidth + 64); height: 36; radius: 18
                        color: "transparent"
                        GlassPanel { anchors.fill: parent; radius: parent.radius; density: 0.55; blurred: root.blurBackground }
                        Image {
                            id: quickLookIcon
                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            width: 22; height: 22
                            sourceSize: Qt.size(width * panel.devicePixelRatio, height * panel.devicePixelRatio)
                            source: quickLookLayer.win ? root.iconFor(quickLookLayer.win.cls, quickLookLayer.win.title) : ""
                            fillMode: Image.PreserveAspectFit
                        }
                        Text {
                            id: quickLookTitle
                            anchors { left: quickLookIcon.right; leftMargin: 10; right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                            text: quickLookLayer.win ? quickLookLayer.win.title + "   ·   Workspace " + quickLookLayer.win.workspaceName : ""
                            elide: Text.ElideRight; textFormat: Text.PlainText
                            color: root.glassInk; font.family: Style.font.family
                            font.pixelSize: 14; font.weight: Font.Medium
                        }
                    }
                    // The enlarging tile's own footprint, for the labels around it.
                    Item {
                        id: quickLookFrame
                        readonly property var c: quickLookLayer.lookCard
                        x: c ? c.x : quickLookLayer.to.x; y: c ? c.y : quickLookLayer.to.y
                        width: c ? c.width : quickLookLayer.to.width; height: c ? c.height : quickLookLayer.to.height
                    }
                    Rectangle {
                        anchors { horizontalCenter: parent.horizontalCenter; top: quickLookFrame.bottom; topMargin: 14 }
                        opacity: root.quickLookProgress
                        width: quickLookHint.implicitWidth + 28; height: 28; radius: 14
                        color: "transparent"
                        GlassPanel { anchors.fill: parent; radius: parent.radius; density: 0.45; blurred: root.blurBackground }
                        Text {
                            id: quickLookHint
                            anchors.centerIn: parent
                            text: "Space or Esc to close   ·   ←/→ browse   ·   Enter or click to switch"
                            color: root.glassInk; opacity: 0.75
                            font.family: Style.font.family; font.pixelSize: 12
                        }
                    }
                }
                // Shortcut hints appear only with Settings, below the sheet, so
                // the views themselves stay uncluttered. Floats over the layout.
                Item {
                    id: footer
                    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 20 }
                    width: Math.min(parent.width - 48, hints.implicitWidth + 32)
                    height: hints.implicitHeight + 16
                    z: 1001
                    visible: opacity > 0
                    opacity: root.settingsOpen ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    GlassPanel { anchors.fill: parent; radius: Math.min(18, height / 2); density: 0.5; blurred: root.blurBackground }
                    Column {
                        id: hints
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, footer.parent.width - 80)
                        spacing: 4
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.min(implicitWidth, footer.parent.width - 80); horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap; textFormat: Text.PlainText
                            text: root.shortcutText
                            color: root.glassInk; opacity: 0.9
                            font.family: Style.font.family; font.pixelSize: 12
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.min(implicitWidth, footer.parent.width - 80); horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap; textFormat: Text.PlainText
                            text: root.controlsText
                            color: root.glassInk; opacity: 0.65
                            font.family: Style.font.family; font.pixelSize: 12
                        }
                    }
                }
                Loader {
                    anchors.fill: parent
                    z: 1000
                    active: root.settingsOpen && root.open
                    sourceComponent: Component {
                        SettingsPanel {
                            controller: root
                            onDismissed: root.closeSettings()
                        }
                    }
                    onLoaded: item.forceActiveFocus()
                }
                Component.onCompleted: forceActiveFocus()
            }
        }
    }
}
