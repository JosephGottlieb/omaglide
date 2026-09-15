// Disposable nested-compositor fixture; no production settings writes.
import QtQuick
import Quickshell
import Quickshell.Io
import "./" as Switcher

ShellRoot {
    id: harness
    readonly property bool armed: /^\/tmp\/od\.[A-Za-z0-9]{6}\/r$/.test(Quickshell.env("XDG_RUNTIME_DIR"))
        && Quickshell.env("OMADESKTOP_TEST_RUNTIME") === Quickshell.env("XDG_RUNTIME_DIR")
    property int appKeys: 0
    property var saved: ({})
    Component.onCompleted: if (!armed) Qt.quit()
    Timer { interval: 240000; running: true; onTriggered: Qt.quit() }
    QtObject {
        id: memoryShell
        function updateEntryInline(id, settings) {
            if (!harness.armed || id !== "omaglide-workspace-test") throw new Error("Fixture not armed")
            harness.saved = Object.assign({}, settings)
            return true
        }
    }
    Switcher.Carousel { id: carousel; shell: memoryShell; shortAppId: "omaglide-workspace-test" }
    Variants {
        model: ["Alpha", "Beta", "Gamma"]
        delegate: FloatingWindow {
            id: application
            required property string modelData
            title: "OmaGlide workspace fixture " + modelData
            implicitWidth: 640; implicitHeight: 480; visible: harness.armed
            color: modelData === "Alpha" ? "#274e67" : modelData === "Beta" ? "#684245" : "#496841"
            Text { anchors.centerIn: parent; text: application.modelData; color: "white"; font.pixelSize: 48 }
            Item { anchors.fill: parent; focus: true; Keys.onPressed: harness.appKeys++ }
        }
    }
    IpcHandler {
        target: "fixture"
        function status(): string {
            return JSON.stringify({ synthetic: true, appKeys: harness.appKeys, saved: harness.saved,
                entries: carousel.windows, pendingWorkspace: carousel.pendingWorkspace, pendingAddr: carousel.pendingAddr })
        }
        function done(): void { Qt.quit() }
    }
}
