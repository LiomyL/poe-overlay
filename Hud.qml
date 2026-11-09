import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland

PanelWindow {
    property int screenLeft: 20
    property int screenTop: 95
    property string zone: ""
    property bool routePausedForDetour: false
    property var routeItems: []

    visible: true

    anchors {
        top: true
        left: true
    }
    margins {
        top: screenTop
        left: screenLeft
    }

    implicitWidth: Math.max(headerRow.implicitWidth + 20, routeList.implicitWidth + 20)
    implicitHeight: hudContent.implicitHeight + 18

    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}

    Rectangle {
        anchors.fill: parent
        radius: 7
        color: "#99101010"
        border.color: "#4d4030"
        border.width: 1

        Column {
            id: hudContent
            x: 10
            y: 10
            width: childrenRect.width
            spacing: 8

            Row {
                id: headerRow
                width: Math.min(zoneText.implicitWidth + 12, Math.max(80, Screen.width * 0.4))
                spacing: 8

                Rectangle {
                    width: 3
                    height: 20
                    color: "#d9a763"
                    radius: 2
                }

                Text {
                    id: zoneText
                    text: routePausedForDetour ? `${zone} · route paused` : zone
                    color: "#f1eee8"
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    width: parent.width - 12
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: "#413a33"
            }

            Column {
                id: routeList
                width: childrenRect.width
                spacing: 5

                Repeater {
                    model: routeItems

                    delegate: Row {
                        required property var modelData
                        width: routeText.width + 14
                        spacing: 6

                        Rectangle {
                            width: 4
                            height: 4
                            radius: 2
                            color: modelData.gem ? modelData.gemColor : modelData.hint ? "#80c7d4" : modelData.optional ? "#8e887c" : "#e4ad55"
                            anchors.top: parent.top
                            anchors.topMargin: 6
                        }

                        Text {
                            id: routeText
                            text: modelData.html
                            textFormat: Text.RichText
                            color: modelData.optional ? "#b3ada2" : "#eee9df"
                            font.pixelSize: 13
                            wrapMode: Text.Wrap
                            width: Math.min(implicitWidth, Math.max(80, Screen.width * 0.4 - 34))
                        }
                    }
                }
            }
        }
    }
}
