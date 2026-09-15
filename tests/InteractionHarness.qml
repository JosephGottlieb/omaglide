// Copy beside Carousel.qml in a disposable /tmp/od.XXXXXX test root only.
import QtQuick
import Quickshell
import Quickshell.Io
import "./" as Switcher

ShellRoot {
    id: harness
    readonly property bool armed: /^\/tmp\/od\.[A-Za-z0-9]{6}\/r$/.test(Quickshell.env("XDG_RUNTIME_DIR"))
        && Quickshell.env("OMADESKTOP_TEST_RUNTIME") === Quickshell.env("XDG_RUNTIME_DIR")
    property int writes: 0
    property var saved: ({})
    property int appKeys: 0
    Component.onCompleted: if (!armed) Qt.quit()
    Timer { interval: 120000; running: true; onTriggered: Qt.quit() }
    QtObject {
        id: memoryShell
        function updateEntryInline(id, settings) {
            if (!harness.armed || id !== "omaglide-isolated-test") throw new Error("Fixture not armed")
            harness.saved = Object.assign({}, settings)
            harness.writes++
            return true
        }
    }
    Switcher.Carousel {
        id: carousel
        shell: memoryShell
        shortAppId: "omaglide-isolated-test"
    }
    Variants {
        model: ["Alpha", "Beta", "Gamma"]
        delegate: FloatingWindow {
            id: application
            required property string modelData
            title: "OmaGlide fixture " + modelData
            implicitWidth: 640; implicitHeight: 480; visible: harness.armed
            color: modelData === "Alpha" ? "#274e67" : modelData === "Beta" ? "#684245" : "#496841"
            Text { anchors.centerIn: parent; text: application.title; color: "white"; font.pixelSize: 32 }
            Item { anchors.fill: parent; focus: true; Keys.onPressed: harness.appKeys++ }
        }
    }
    IpcHandler {
        target: "fixture"
        function status(): string {
            return JSON.stringify({ synthetic: true, open: carousel.open, opening: carousel.opening,
                resizing: carousel.resizing, preferredWidth: carousel.preferredWidth,
                selected: carousel.selected, position: carousel.position,
                count: carousel.windows.length, writes: harness.writes, saved: harness.saved,
                appKeys: harness.appKeys })
        }
        function done(): void { Qt.quit() }
    }
}
