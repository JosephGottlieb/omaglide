import QtQuick
import Quickshell.Wayland
import qs.Commons

// A workspace is composed from native window buffers, not a screenshot of the
// active desktop. The caller mounts only carousel slots near the viewport.
Item {
    id: root

    property var entry: null
    property var handles: ({})
    property bool selected: false
    property bool opened: false
    property bool retainFrames: false
    property real dpr: 1
    property int refreshInterval: 450

    readonly property var windows: root.entry && Array.isArray(root.entry.windows) ? root.entry.windows : []
    readonly property var viewport: root.validRect(root.entry ? root.entry.viewport : null)
    readonly property var monitorViewport: root.validRect(root.entry ? root.entry.monitorViewport : null)
    readonly property real fitScale: Math.max(0, Math.min(root.width / root.viewport.width, root.height / root.viewport.height))
    readonly property real pixelRatio: root.numberOr(root.dpr, 1) > 0 ? root.numberOr(root.dpr, 1) : 1
    clip: true

    function numberOr(value, fallback) {
        if (value === undefined || value === null) return fallback
        const result = Number(value)
        return isFinite(result) ? result : fallback
    }

    function validRect(value) {
        const rect = value || {}
        return {
            x: root.numberOr(rect.x, 0),
            y: root.numberOr(rect.y, 0),
            width: Math.max(1, root.numberOr(rect.width, 1)),
            height: Math.max(1, root.numberOr(rect.height, 1))
        }
    }

    function metrics() {
        const records = []
        let loaded = 0
        for (let i = 0; i < tiles.count; i++) {
            const tile = tiles.itemAt(i)
            if (!tile) continue
            const capture = tile.captureItem
            if (capture) loaded++
            records.push({
                address: String(tile.win.address || ""),
                hasContent: capture ? capture.hasContent : false,
                nativeWidth: capture && capture.hasContent ? capture.sourceSize.width : 0,
                nativeHeight: capture && capture.hasContent ? capture.sourceSize.height : 0,
                renderedWidth: capture ? capture.renderedWidth * root.pixelRatio : 0,
                renderedHeight: capture ? capture.renderedHeight * root.pixelRatio : 0
            })
        }
        return {
            workspaceId: root.entry ? root.entry.workspaceId : null,
            count: root.windows.length,
            windows: records,
            loadedPreviews: loaded
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(Color.foreground, 0.025)
    }

    // Translate the entire union into the available tile using one uniform
    // scale. Offscreen scrolling windows retain their actual relative position.
    Item {
        id: scene
        width: root.viewport.width * root.fitScale
        height: root.viewport.height * root.fitScale
        anchors.centerIn: parent

        Rectangle {
            x: (root.monitorViewport.x - root.viewport.x) * root.fitScale
            y: (root.monitorViewport.y - root.viewport.y) * root.fitScale
            width: root.monitorViewport.width * root.fitScale
            height: root.monitorViewport.height * root.fitScale
            z: -1000000000
            color: Color.popups.background
            border.width: 1
            border.color: root.selected ? Color.menu.selectedBorder : Color.popups.border
        }

        Repeater {
            id: tiles
            // Geometry refreshes replace the records array. An integer model
            // keeps native captures mounted while the window count is stable.
            model: root.windows.length

            delegate: Item {
                id: tile
                required property int index
                readonly property var win: root.windows[tile.index] || {}
                readonly property var bounds: root.validRect(tile.win)
                readonly property var handle: root.handles && tile.win.address ? root.handles[tile.win.address] || null : null
                readonly property var captureItem: captureLoader.item
                x: (tile.bounds.x - root.viewport.x) * root.fitScale
                y: (tile.bounds.y - root.viewport.y) * root.fitScale
                width: tile.bounds.width * root.fitScale
                height: tile.bounds.height * root.fitScale
                z: root.numberOr(tile.win.z, tile.index)
                clip: true

                Rectangle {
                    anchors.fill: parent
                    color: Qt.tint(Color.popups.background, Qt.alpha(Color.foreground, 0.075))
                    border.width: 1
                    border.color: Color.popups.border
                }

                Text {
                    anchors.centerIn: parent
                    text: String(tile.win.cls || tile.win.title || "?").charAt(0).toUpperCase()
                    color: Color.popups.text
                    opacity: 0.5
                    font.family: Style.font.family
                    font.pixelSize: Math.max(1, Math.min(42, tile.width * 0.35, tile.height * 0.5))
                    visible: !captureLoader.item || !captureLoader.item.hasContent
                }

                Loader {
                    id: captureLoader
                    anchors.fill: parent
                    property var requestedHandle: tile.handle
                    property var mountedHandle: null
                    onRequestedHandleChanged: {
                        mountedHandle = null
                        Qt.callLater(() => { mountedHandle = requestedHandle })
                    }
                    active: (root.opened || root.retainFrames) && !!requestedHandle && mountedHandle === requestedHandle
                        && tile.width > 0 && tile.height > 0
                    sourceComponent: Component {
                        Item {
                            readonly property size sourceSize: preview.sourceSize
                            readonly property bool hasContent: preview.hasContent
                            readonly property real renderedWidth: preview.width
                            readonly property real renderedHeight: preview.height

                            ScreencopyView {
                                id: preview
                                captureSource: captureLoader.mountedHandle
                                live: root.opened && root.selected
                                paintCursor: false
                                visible: hasContent
                                // Render the native buffer directly at its final geometry;
                                // do not downsample into a thumbnail or scale a raster layer.
                                readonly property real sourceRatio: hasContent && sourceSize.width > 0 && sourceSize.height > 0
                                    ? sourceSize.width / sourceSize.height : tile.bounds.width / tile.bounds.height
                                width: Math.min(parent.width, parent.height * sourceRatio)
                                height: width / sourceRatio
                                anchors.centerIn: parent

                                Connections {
                                    target: root
                                    function onOpenedChanged() {
                                        if (root.opened && !root.selected && preview.hasContent)
                                            preview.captureFrame()
                                    }
                                }
                                Timer {
                                    interval: Math.max(1, root.refreshInterval)
                                    repeat: true
                                    running: root.opened && !root.selected && preview.hasContent && root.refreshInterval > 0
                                    onTriggered: preview.captureFrame()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Text {
        anchors.centerIn: parent
        text: "Empty workspace"
        color: Color.popups.text
        opacity: 0.55
        font.family: Style.font.family
        font.pixelSize: Math.min(16, Math.max(1, root.width / 12))
        visible: root.windows.length === 0
    }
}
