import QtQuick
import qs.Commons
import qs.Ui

// A bordered header button that says which key does the same thing:
//   ┌──────────────────┐
//   │ 󰍉 Search   [ / ] │
//   └──────────────────┘
// `active` fills it with the accent tint (search open, DND on); `danger`
// paints it with the urgent colour (clear, once armed).
Rectangle {
  id: root

  property string iconText: ""
  property string text: ""
  property string keyHint: ""
  property string tooltipText: ""
  property bool active: false
  property bool danger: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property color tint: danger ? Color.urgent : (active ? Color.accent : foreground)
  readonly property bool hot: mouse.containsMouse && enabled

  implicitWidth: row.implicitWidth + Style.space(10) * 2
  implicitHeight: Math.max(row.implicitHeight, Style.space(14)) + Style.space(7) * 2
  radius: Style.space(7)
  color: danger ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.16)
       : active ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
       : hot ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)
       : "transparent"
  border.width: Math.max(1, Style.space(1))
  border.color: danger || active ? tint
              : Qt.rgba(foreground.r, foreground.g, foreground.b, hot ? 0.45 : 0.22)
  opacity: enabled ? 1 : 0.4

  Behavior on color { ColorAnimation { duration: 90 } }
  Behavior on border.color { ColorAnimation { duration: 90 } }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.iconText !== ""
      textFormat: Text.PlainText
      text: root.iconText
      color: root.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.text !== ""
      textFormat: Text.PlainText
      text: root.text
      color: root.danger || root.active ? root.tint : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: root.active || root.danger
    }

    // The key cap.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.keyHint !== ""
      width: Math.max(keyText.implicitWidth + Style.space(8), height)
      height: keyText.implicitHeight + Style.space(3)
      radius: Style.space(4)
      color: Qt.rgba(root.tint.r, root.tint.g, root.tint.b, 0.12)
      border.width: Math.max(1, Style.space(1))
      border.color: Qt.rgba(root.tint.r, root.tint.g, root.tint.b, 0.35)

      Text {
        id: keyText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.keyHint
        color: root.tint
        opacity: 0.9
        font.family: root.fontFamily
        font.pixelSize: Math.max(8, Style.font.caption - Style.space(1))
        font.bold: true
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (root.enabled) root.clicked()
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && mouse.containsMouse
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}
