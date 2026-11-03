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
    property bool recolored: false
    property var entranceSamples: []
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
    Switcher.Carousel { id: carousel; shell: memoryShell; shortAppId: "omaglide-workspace-test"; groupApps: false }
    Connections {
        target: carousel
        function onOpenChanged() {
            if (carousel.open) harness.entranceSamples = []
        }
        function onEntranceProgressChanged() {
            // Observe after bindings update, rather than pairing new progress
            // with the previous frame's dependent viewport offset.
            Qt.callLater(() => {
                if (carousel.open && harness.entranceSamples.length < 32) {
                    const metrics = carousel.previewMetrics()
                    harness.entranceSamples = harness.entranceSamples.concat([{
                        progress: carousel.entranceProgress, offset: metrics ? metrics.entranceOffset : null,
                        opacity: metrics ? metrics.entranceOpacity : null
                    }])
                }
            })
        }
    }
    Variants {
        model: ["Alpha", "Beta", "Gamma"]
        delegate: FloatingWindow {
            id: application
            required property string modelData
            title: "OmaGlide workspace fixture " + modelData
            implicitWidth: 640; implicitHeight: 480; visible: harness.armed
            color: harness.recolored ? "#e02b91"
                : modelData === "Alpha" ? "#274e67" : modelData === "Beta" ? "#684245" : "#496841"
            Text { anchors.centerIn: parent; text: application.modelData; color: "white"; font.pixelSize: 48 }
            Item { anchors.fill: parent; focus: true; Keys.onPressed: harness.appKeys++ }
        }
    }
    IpcHandler {
        target: "fixture"
        function status(): string {
            return JSON.stringify({ synthetic: true, appKeys: harness.appKeys, saved: harness.saved,
                entranceSamples: harness.entranceSamples,
                entries: carousel.windows, pendingWorkspace: carousel.pendingWorkspace, pendingAddr: carousel.pendingAddr })
        }
        function done(): void { Qt.quit() }
        function recolor(): void { if (harness.armed) harness.recolored = true }
        function numberedWorkspaceWhileOpening(number: int): bool {
            if (!harness.armed || carousel.mode !== "windows") throw new Error("Fixture state is not armed")
            carousel.showWorkspaces()
            const wasOpening = carousel.opening
            carousel.selectWorkspace(number)
            return wasOpening
        }
    }
}
