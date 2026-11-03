import QtQuick
import QtQuick.Effects

// Liquid glass, shared by every OmaGlide surface. A neutral smoke tint sits
// over the compositor's blur of the desktop (the overlay's layer rule blurs
// exactly the pixels this covers), with a soft top sheen and bright hairline
// edges. The tint is dark enough for white text over light windows; without
// compositor blur it gets denser so text stays legible.
Item {
    id: glass
    property real radius: 16
    // 0: barely-there chrome; 1: dense enough for paragraphs of text.
    property real density: 0.5
    property bool blurred: true
    // A soft drop shadow; off for glass laid inside another shadowed surface.
    property bool raised: true
    // Brighter glass, like a pressed or selected key.
    property bool highlighted: false
    readonly property real tint: blurred ? 0.18 + 0.30 * density : 0.62 + 0.28 * density

    // Created only when shown, keeping unraised glass to two rectangles.
    Loader {
        anchors.fill: parent
        active: glass.raised && glass.width > 0
        sourceComponent: RectangularShadow {
            radius: glass.radius; blur: 32; offset.y: 10
            color: Qt.rgba(0, 0, 0, 0.24)
        }
    }
    Rectangle {
        anchors.fill: parent
        radius: glass.radius
        color: Qt.rgba(0.07, 0.07, 0.09, glass.tint)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, glass.highlighted ? 0.48 : 0.24)
    }
    Rectangle {
        anchors { fill: parent; margins: 1 }
        radius: Math.max(0, glass.radius - 1)
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, glass.highlighted ? 0.30 : 0.14) }
            GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, glass.highlighted ? 0.12 : 0.03) }
            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, glass.highlighted ? 0.16 : 0.05) }
        }
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.07)
    }
}
