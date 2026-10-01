import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// One notification in the side panel. `selected` is the keyboard cursor:
// accent border plus a stronger fill. Every Text is PlainText — notification
// text is sender-chosen and rich text would fetch remote <img> sources.
Item {
  id: root

  property string app: ""
  property string appIcon: ""
  property string summary: ""
  property string body: ""
  property string image: ""
  property string glyph: ""
  property double timestamp: 0
  property double now: 0
  property int urgency: 1
  property bool live: false
  property bool unread: false
  property bool selected: false
  property bool showBody: true

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal clicked()
  signal removeRequested()
  signal hoveredRow()

  readonly property string senderName: Model.sender({ app: app, appIcon: appIcon })
  readonly property string iconSource: image !== "" ? resolve(image) : resolve(appIcon)
  readonly property bool hasIcon: iconSource !== "" && icon.status !== Image.Error
  readonly property string cleanSummary: Model.plain(summary)
  readonly property string cleanBody: Model.plain(body)

  function resolve(value) {
    var v = String(value || "")
    if (v === "") return ""
    if (v.indexOf("file://") === 0 || v.indexOf("image://") === 0) return v
    if (v.charAt(0) === "/") return Util.fileUrl(v)
    return Quickshell.iconPath(v, true)
  }

  implicitHeight: card.implicitHeight

  Rectangle {
    id: card
    anchors.left: parent.left
    anchors.right: parent.right
    implicitHeight: Math.max(texts.implicitHeight, avatar.height) + Style.space(20)
    radius: Style.space(10)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                   root.selected ? 0.13 : (mouse.containsMouse ? 0.09 : 0.05))
    border.width: root.selected ? Math.max(1, Style.space(2)) : 0
    border.color: Color.accent

    Behavior on color { ColorAnimation { duration: 80 } }

    // Critical: a red bar down the leading edge.
    Rectangle {
      visible: root.urgency === 2
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(6)
      width: Style.space(3)
      radius: width / 2
      color: Color.urgent
    }

    // Unread dot.
    Rectangle {
      visible: root.unread && root.urgency !== 2
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(5)
      height: width
      radius: width / 2
      color: Color.accent
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onEntered: root.hoveredRow()
      onClicked: function(m) {
        if (m.button === Qt.RightButton) root.removeRequested()
        else root.clicked()
      }
    }

    Item {
      id: avatar
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.top: parent.top
      anchors.topMargin: Style.space(10)
      width: Style.space(30)
      height: width

      Rectangle {
        anchors.fill: parent
        radius: Style.space(8)
        visible: !root.hasIcon
        color: root.foreground
        opacity: 0.12
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: !root.hasIcon
        text: root.glyph !== "" ? root.glyph
            : (root.senderName === "" ? "?" : root.senderName.charAt(0).toUpperCase())
        font.family: root.fontFamily
        font.pixelSize: root.glyph !== "" ? Style.font.icon : Style.font.caption
        font.bold: root.glyph === ""
        color: root.foreground
        opacity: 0.75
      }

      Image {
        id: icon
        anchors.fill: parent
        visible: root.hasIcon
        source: root.iconSource
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
      }
    }

    Column {
      id: texts
      anchors.left: avatar.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.top: parent.top
      anchors.topMargin: Style.space(10)
      spacing: Style.space(1)

      Item {
        width: parent.width
        height: appLabel.implicitHeight

        Text {
          id: appLabel
          textFormat: Text.PlainText
          anchors.left: parent.left
          width: parent.width - whenLabel.implicitWidth - Style.space(12)
          text: root.senderName + (root.live ? "  • on screen" : "")
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.5
        }

        Text {
          id: whenLabel
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: Model.relativeTime(root.timestamp, root.now)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.45
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.cleanSummary !== ""
        text: root.cleanSummary
        elide: Text.ElideRight
        maximumLineCount: 1
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        color: root.foreground
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.showBody && root.cleanBody !== ""
        text: root.cleanBody
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.75
      }
    }
  }
}
