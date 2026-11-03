import QtQuick
import QtQuick.Effects
import qs.Commons
import "shortcuts.js" as Shortcuts

// Settings sheet shown inside the overlay. The overlay already inhibits
// compositor shortcuts while focused, so every chord (Super+…, Alt+Tab)
// reaches this item during capture instead of triggering its old action.
FocusScope {
    id: sheet
    property var controller: null
    signal dismissed()

    property string capturing: ""     // action id awaiting a chord
    property string heldModifiers: ""  // live feedback while capturing
    property string candidate: ""      // captured chord that would replace something
    property string candidateConflict: ""
    property string captureError: ""

    function startCapture(action) {
        capturing = action
        candidate = ""; candidateConflict = ""; captureError = ""; heldModifiers = ""
        sheet.forceActiveFocus()
    }
    function cancelCapture() {
        capturing = ""; candidate = ""; candidateConflict = ""; captureError = ""; heldModifiers = ""
    }
    function commit(action, chordValue) {
        controller.setBinding(action, chordValue)
        cancelCapture()
    }
    function modifierLabel(modifiers) {
        const names = []
        if (modifiers & Qt.MetaModifier) names.push("Super")
        if (modifiers & Qt.ControlModifier) names.push("Ctrl")
        if (modifiers & Qt.AltModifier) names.push("Alt")
        if (modifiers & Qt.ShiftModifier) names.push("Shift")
        return names.join("+")
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: event => {
        event.accepted = true
        if (!capturing) {
            if (event.key === Qt.Key_Escape) dismissed()
            return
        }
        if (event.key === Qt.Key_Escape && !event.modifiers) { cancelCapture(); return }
        if (event.isAutoRepeat) return
        const result = Shortcuts.chordFromKey(event.key, event.modifiers, event.nativeScanCode)
        if (result.pending) { heldModifiers = modifierLabel(event.modifiers); return }
        if (!result.chord) { captureError = "That key can't be bound"; return }
        // Bare keys would steal ordinary typing; function keys are fine alone.
        if (result.chord.indexOf(" + ") < 0 && !/^F\d+$/.test(result.chord)) {
            captureError = "Add a modifier such as Super, Ctrl or Alt"
            return
        }
        const conflict = controller.conflictFor(result.chord, capturing)
        if (conflict) { candidate = result.chord; candidateConflict = conflict; captureError = ""; return }
        commit(capturing, result.chord)
    }
    Keys.onReleased: event => {
        event.accepted = true
        if (capturing && !candidate) heldModifiers = modifierLabel(event.modifiers & ~(
            event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta ? Qt.MetaModifier
            : event.key === Qt.Key_Control ? Qt.ControlModifier
            : event.key === Qt.Key_Alt ? Qt.AltModifier
            : event.key === Qt.Key_Shift ? Qt.ShiftModifier : 0))
    }

    // Swallow clicks so they don't fall through and close the overlay.
    MouseArea { anchors.fill: parent; onClicked: sheet.capturing ? sheet.cancelCapture() : sheet.dismissed() }

    RectangularShadow {
        anchors.fill: card
        radius: card.radius; blur: 48; spread: 0; offset.y: 18
        color: Qt.rgba(0, 0, 0, 0.45)
    }
    Rectangle {
        id: card
        // Sits a little high, leaving room for the shortcut hints beneath.
        anchors { centerIn: parent; verticalCenterOffset: -30 }
        width: Math.min(600, parent.width - 48)
        height: Math.min(content.implicitHeight + 48, sheet.height - 160)
        radius: 18
        color: Color.popups.background
        border.width: 1; border.color: Qt.alpha(Color.foreground, 0.14)
        MouseArea { anchors.fill: parent; onClicked: if (sheet.capturing) sheet.cancelCapture() }

        // Scrolls when the sheet is taller than the screen.
        Flickable {
            id: scroller
            anchors { fill: parent; margins: 24 }
            contentHeight: content.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            Column {
                id: content
                width: scroller.width
                spacing: 18

                Item {
                    width: parent.width; height: 28
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "OmaGlide Settings"
                        color: Color.popups.text; font.family: Style.font.family
                        font.pixelSize: 18; font.weight: Font.DemiBold
                    }
                    Rectangle {
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        width: 28; height: 28; radius: 14
                        color: closeMouse.containsMouse ? Qt.alpha(Color.foreground, 0.12) : "transparent"
                        Text {
                            anchors.centerIn: parent; text: "✕"
                            color: Color.popups.text; opacity: 0.75
                            font.family: Style.font.family; font.pixelSize: 13
                        }
                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: sheet.dismissed()
                        }
                    }
                }

                SectionLabel { text: "KEYBOARD SHORTCUTS" }
                Column {
                    width: parent.width; spacing: 6
                    Repeater {
                        model: Shortcuts.ACTIONS
                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            readonly property bool active: sheet.capturing === modelData.id
                            readonly property var chords: sheet.controller ? sheet.controller.liveChords[modelData.id] || [] : []
                            width: parent.width; height: 52; radius: 10
                            color: active ? Qt.alpha(Color.accent, 0.10) : rowMouse.containsMouse ? Qt.alpha(Color.foreground, 0.05) : "transparent"
                            MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; onClicked: sheet.startCapture(row.modelData.id) }
                            Column {
                                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                width: parent.width - chordBox.width - 36
                                spacing: 2
                                Text {
                                    text: row.modelData.label
                                    color: Color.popups.text; font.family: Style.font.family
                                    font.pixelSize: 14; font.weight: Font.Medium
                                }
                                Text {
                                    width: parent.width; elide: Text.ElideRight
                                    text: row.active && sheet.candidate
                                        ? "Replaces “" + sheet.candidateConflict + "”"
                                        : row.active && sheet.captureError ? sheet.captureError : row.modelData.hint
                                    color: row.active && (sheet.candidate || sheet.captureError) ? Color.urgent : Color.popups.text
                                    opacity: row.active && (sheet.candidate || sheet.captureError) ? 1 : 0.55
                                    font.family: Style.font.family; font.pixelSize: 11
                                }
                            }
                            Row {
                                id: chordBox
                                anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                spacing: 6
                                // Live chord(s), or the capture prompt.
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(120, chordText.implicitWidth + 24); height: 32; radius: 8
                                    color: row.active ? Color.popups.background : Qt.alpha(Color.foreground, 0.07)
                                    border.width: row.active ? 2 : 1
                                    border.color: row.active ? Color.accent : Qt.alpha(Color.foreground, 0.12)
                                    Text {
                                        id: chordText
                                        anchors.centerIn: parent
                                        text: row.active
                                            ? (sheet.candidate ? Shortcuts.displayChord(sheet.candidate)
                                                : sheet.heldModifiers ? sheet.heldModifiers + "+…" : "Press shortcut…")
                                            : row.chords.length ? row.chords.map(Shortcuts.displayChord).join("  /  ") : "Not set"
                                        color: Color.popups.text
                                        opacity: !row.active && !row.chords.length ? 0.45 : 1
                                        font.family: Style.font.family; font.pixelSize: 13
                                        font.weight: row.active ? Font.Normal : Font.DemiBold
                                    }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: row.active ? sheet.cancelCapture() : sheet.startCapture(row.modelData.id)
                                    }
                                }
                                SmallButton {
                                    visible: row.active && !!sheet.candidate
                                    label: "Replace"; accent: true
                                    onClicked: sheet.commit(row.modelData.id, sheet.candidate)
                                }
                                SmallButton {
                                    visible: row.active && !sheet.candidate && row.chords.length > 0
                                    label: "Clear"
                                    onClicked: sheet.commit(row.modelData.id, "")
                                }
                            }
                        }
                    }
                }
                Text {
                    width: parent.width; wrapMode: Text.Wrap
                    text: "Click a shortcut, then press the new keys. Esc cancels. Changes apply immediately, "
                        + "and OmaGlide restores them whenever Hyprland reloads its config."
                    color: Color.popups.text; opacity: 0.5
                    font.family: Style.font.family; font.pixelSize: 11
                }

                SectionLabel { text: "TOUCHPAD GESTURES" }
                Column {
                    width: parent.width; spacing: 2
                    SwitchRow {
                        label: "Swipe up for Exposé, down for App Exposé"
                        checked: sheet.controller ? sheet.controller.gesturesEnabled : true
                        onToggled: sheet.controller.saveSetting("gesturesEnabled", !checked)
                    }
                    Rectangle {
                        width: parent.width; height: 44; radius: 10
                        color: "transparent"
                        opacity: sheet.controller && sheet.controller.gesturesEnabled ? 1 : 0.4
                        Text {
                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            text: "Fingers"
                            color: Color.popups.text; font.family: Style.font.family; font.pixelSize: 14
                        }
                        // Segmented 3 / 4 control.
                        Rectangle {
                            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            width: 112; height: 30; radius: 8
                            color: Qt.alpha(Color.foreground, 0.07)
                            Row {
                                anchors { fill: parent; margins: 2 }
                                Repeater {
                                    model: [3, 4]
                                    delegate: Rectangle {
                                        required property int modelData
                                        readonly property bool chosen: sheet.controller && sheet.controller.gestureFingers === modelData
                                        width: 54; height: 26; radius: 6
                                        color: chosen ? Color.accent : fingerMouse.containsMouse ? Qt.alpha(Color.foreground, 0.1) : "transparent"
                                        Text {
                                            anchors.centerIn: parent; text: parent.modelData
                                            color: parent.chosen ? Color.background : Color.popups.text
                                            font.family: Style.font.family; font.pixelSize: 13; font.weight: Font.DemiBold
                                        }
                                        MouseArea {
                                            id: fingerMouse
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            enabled: sheet.controller && sheet.controller.gesturesEnabled
                                            onClicked: if (!parent.chosen) sheet.controller.saveSetting("gestureFingers", parent.modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        readonly property var c: sheet.controller
                        width: parent.width - 24; x: 12; wrapMode: Text.Wrap
                        visible: text.length > 0
                        text: !c || !c.gesturesEnabled ? ""
                            : c.gestureConflicts.length
                                ? "Another gesture already uses " + c.gestureFingers + "-finger " + c.gestureConflicts.join(" and ")
                                  + " in your Hyprland config, so it wins. Pick the other finger count or remove that gesture."
                            : c.touchpadDragFingers === c.gestureFingers
                                ? "Three-finger drag (input:touchpad:drag_3fg) is using " + c.gestureFingers
                                  + " fingers, so these swipes may not arrive. Pick the other finger count or turn drag off."
                            : ""
                        color: Color.urgent
                        font.family: Style.font.family; font.pixelSize: 11
                    }
                }

                SectionLabel { text: "APPEARANCE & BEHAVIOR" }
                Column {
                    width: parent.width; spacing: 2
                    Rectangle {
                        width: parent.width; height: 44; radius: 10
                        color: "transparent"
                        Text {
                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            text: "Slider style"
                            color: Color.popups.text; font.family: Style.font.family; font.pixelSize: 14
                        }
                        // Thumbnails (live previews) or a Cmd+Tab-style row of app icons.
                        Rectangle {
                            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            width: styleRow.implicitWidth + 4; height: 30; radius: 8
                            color: Qt.alpha(Color.foreground, 0.07)
                            Row {
                                id: styleRow
                                anchors { left: parent.left; top: parent.top; margins: 2 }
                                Repeater {
                                    model: [{ id: "thumbnails", label: "Thumbnails" }, { id: "icons", label: "App icons" }]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool chosen: sheet.controller && sheet.controller.sliderStyle === modelData.id
                                        width: styleText.implicitWidth + 24; height: 26; radius: 6
                                        color: chosen ? Color.accent : styleMouse.containsMouse ? Qt.alpha(Color.foreground, 0.1) : "transparent"
                                        Text {
                                            id: styleText
                                            anchors.centerIn: parent; text: parent.modelData.label
                                            color: parent.chosen ? Color.background : Color.popups.text
                                            font.family: Style.font.family; font.pixelSize: 13; font.weight: Font.DemiBold
                                        }
                                        MouseArea {
                                            id: styleMouse
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: if (!parent.chosen) sheet.controller.saveSetting("sliderStyle", parent.modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    SwitchRow {
                        label: "Blur the desktop behind OmaGlide"
                        checked: sheet.controller ? sheet.controller.blurBackground : true
                        onToggled: sheet.controller.saveSetting("blurBackground", !checked)
                    }
                    SwitchRow {
                        label: "Group windows by app in the slider"
                        checked: sheet.controller ? sheet.controller.groupApps : true
                        onToggled: sheet.controller.setGroupApps(!checked)
                    }
                    SwitchRow {
                        label: "Move the pointer to the window you switch to"
                        checked: sheet.controller ? sheet.controller.pointerFollowsFocus : true
                        onToggled: sheet.controller.saveSetting("pointerFollowsFocus", !checked)
                    }
                }
            }
        }
    }

    component SectionLabel: Text {
        color: Color.popups.text; opacity: 0.5
        font.family: Style.font.family; font.pixelSize: 11; font.letterSpacing: 1.5
        font.weight: Font.DemiBold
    }
    component SmallButton: Rectangle {
        id: button
        property string label: ""
        property bool accent: false
        signal clicked()
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        width: buttonText.implicitWidth + 20; height: 32; radius: 8
        color: accent ? Color.accent : buttonMouse.containsMouse ? Qt.alpha(Color.foreground, 0.14) : Qt.alpha(Color.foreground, 0.07)
        Text {
            id: buttonText
            anchors.centerIn: parent; text: button.label
            color: button.accent ? Color.background : Color.popups.text
            font.family: Style.font.family; font.pixelSize: 12; font.weight: Font.Medium
        }
        MouseArea { id: buttonMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: button.clicked() }
    }
    component SwitchRow: Rectangle {
        id: switchRow
        property string label: ""
        property bool checked: false
        signal toggled()
        width: parent ? parent.width : 0; height: 44; radius: 10
        color: switchMouse.containsMouse ? Qt.alpha(Color.foreground, 0.05) : "transparent"
        Text {
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            text: switchRow.label
            color: Color.popups.text; font.family: Style.font.family; font.pixelSize: 14
        }
        Rectangle {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            width: 40; height: 22; radius: 11
            color: switchRow.checked ? Color.accent : Qt.alpha(Color.foreground, 0.18)
            Behavior on color { ColorAnimation { duration: 120 } }
            Rectangle {
                width: 18; height: 18; radius: 9; y: 2
                x: switchRow.checked ? parent.width - width - 2 : 2
                color: switchRow.checked ? Color.background : Color.popups.text
                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
        }
        MouseArea { id: switchMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: switchRow.toggled() }
    }
}
