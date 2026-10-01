import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "components"

// Notifications: a bell on the bar and a full-height side panel on the right
// edge of the screen, driven from the keyboard.
//
//   ↑/↓ j/k   select           ⏎ / space   open (click) the selected one
//   /         search           d           toggle Do Not Disturb
//   c c       clear all        x / del     remove the selected one
//   esc       leave search / close         tab   next bar panel
//
// History comes from bin/notification-store, which archives every file the
// Omarchy notification service writes (the service itself keeps only 10).
// DND and "is this toast still on screen" go through the service's IPC.
Panel {
  id: root

  moduleName: "jgarza.notification"
  ipcTarget: "jgarza.notification"

  readonly property string script:
    Qt.resolvedUrl("bin/notification-store").toString().replace(/^file:\/\//, "")
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- settings

  readonly property int panelWidth: setting("panelWidth", 420)
  readonly property int keepDays: setting("keepDays", 30)
  readonly property int maxItems: setting("maxItems", 500)
  readonly property string badge: setting("badge", "Count")
  readonly property bool showBody: setting("showBody", true) !== false
  readonly property string iconOn: setting("icon", "") || "\u{f009a}"       // md-bell
  readonly property string iconDnd: setting("iconDnd", "") || "\u{f009b}"   // md-bell_off

  // ----------------------------------------------------------------- service

  // Third-party plugins can't reach the notification service object (the
  // plugin shell API only hands out a plugin's own service), so everything
  // goes through its IPC target: `omarchy-shell notifications ...`.

  property bool dnd: false

  // Reads come back as "on"/"off"; so does toggleDnd, so one parser serves both.
  Process {
    id: dndProc
    stdout: StdioCollector {
      onStreamFinished: {
        var v = text.trim()
        if (v === "on" || v === "off") root.dnd = v === "on"
      }
    }
  }

  function dndCall(method) {
    if (dndProc.running) {
      if (method === "toggleDnd") Qt.callLater(function() { root.dndCall(method) })
      return
    }
    dndProc.command = ["omarchy-shell", "notifications", method]
    dndProc.running = true
  }

  function toggleDnd() {
    dnd = !dnd   // answer the key press now; the IPC reply confirms it
    dndCall("toggleDnd")
    // The bar's own DND indicator only re-reads on refresh.
    Quickshell.execDetached(["omarchy-shell", "-q", "omarchy.indicators", "refresh"])
  }

  // DND can change elsewhere (bar indicator, the toggle command). Poll it:
  // quickly while the panel is open, lazily for the bar icon otherwise.
  Timer {
    interval: root.opened ? 2000 : 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.dndCall("dndState")
  }

  // Keys of toasts still on screen, newest first (from `notification-store live`).
  property var live: []

  Process {
    id: liveProc
    property var then: null
    stdout: StdioCollector {
      onStreamFinished: {
        var keys = []
        try { keys = JSON.parse(text) } catch (e) {}
        root.live = Array.isArray(keys) ? keys : []
        var cb = liveProc.then
        liveProc.then = null
        if (cb) cb()
      }
    }
  }

  function refreshLive(then) {
    if (liveProc.running) {
      if (then) Qt.callLater(function() { root.refreshLive(then) })
      return
    }
    liveProc.then = then || null
    liveProc.command = store(["live"])
    liveProc.running = true
  }

  // ------------------------------------------------------------------- state

  property var entries: []          // newest first, everything loaded
  property var shown: []            // entries after the search filter, same order as `rows`
  property string filter: ""
  property bool searching: false
  property bool loaded: false
  property double lastSeen: 0
  property double readMark: 0       // lastSeen as it was when the panel opened
  property double now: Date.now()
  property bool clearArmed: false

  readonly property int unread: Model.unreadCount(entries, lastSeen)
  readonly property int selected: list.currentIndex

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  // Catch anything a dead watcher or a shell restart missed.
  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: { root.load(); root.refreshLive() }
  }

  Timer {
    id: disarm
    interval: 2500
    onTriggered: root.clearArmed = false
  }

  // ------------------------------------------------------------------- store

  readonly property var storeEnv: ({
    "NS_KEEP_DAYS": String(root.keepDays),
    "NS_MAX_ITEMS": String(root.maxItems)
  })

  function store(args) { return [root.script].concat(args) }

  Process {
    id: watchProc
    command: root.store(["watch"])
    environment: root.storeEnv
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.absorb(line) }
    }
    // Restart a watcher that died, slowly, so a broken one can't spin.
    onExited: restartWatch.restart()
  }

  Timer {
    id: restartWatch
    interval: 30000
    onTriggered: if (!watchProc.running) watchProc.running = true
  }

  Process {
    id: listProc
    environment: root.storeEnv
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try { data = JSON.parse(text) } catch (e) { return }
        if (!Array.isArray(data)) return
        root.loaded = true
        var same = data.length === root.entries.length &&
                   (data.length === 0 || data[0].key === root.entries[0].key)
        root.entries = data
        if (!same) root.rebuild()
      }
    }
  }

  function load() {
    if (listProc.running) return
    listProc.command = store(["list", String(maxItems)])
    listProc.running = true
  }

  Process {
    id: seenProc
    environment: root.storeEnv
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d.ok) root.lastSeen = Math.max(root.lastSeen, Number(d.seen) || 0)
        } catch (e) {}
      }
    }
  }

  function markSeen() {
    lastSeen = Date.now()
    Quickshell.execDetached(store(["seen", String(Math.round(lastSeen))]))
  }

  // A newly archived notification from the watcher.
  function absorb(line) {
    var entry
    try { entry = JSON.parse(line) } catch (e) { return }
    if (!entry || !entry.key) return
    for (var i = 0; i < entries.length; i++)
      if (entries[i].key === entry.key) return
    var next = [entry].concat(entries)
    if (next.length > maxItems) next = next.slice(0, maxItems)
    entries = next
    refreshLive()
    if (opened) markSeen()
    if (!Model.matches(entry, filter)) return
    // Keep the cursor on the same notification when one lands above it.
    var keep = list.currentIndex
    shown = [entry].concat(shown)
    rows.insert(0, rowFor(entry))
    list.currentIndex = keep <= 0 ? 0 : keep + 1
  }

  function remove(index) {
    var entry = shown[index]
    if (!entry) return
    entries = entries.filter(function(e) { return e.key !== entry.key })
    var nextShown = shown.slice()
    nextShown.splice(index, 1)
    shown = nextShown
    rows.remove(index)
    list.currentIndex = Model.clampIndex(index, rows.count)
    Quickshell.execDetached(store(["remove", String(entry.key)]))
  }

  function clearAll() {
    clearArmed = false
    disarm.stop()
    entries = []
    rebuild()
    Quickshell.execDetached(store(["clear"]))
  }

  function pressClear() {
    if (entries.length === 0) return
    if (clearArmed) { clearAll(); return }
    clearArmed = true
    disarm.restart()
  }

  // -------------------------------------------------------------------- list

  ListModel { id: rows }

  function rowFor(e) {
    var ts = Number(e.timestamp || 0)
    return {
      key: String(e.key || ""),
      app: String(e.app || ""),
      appIcon: String(e.appIcon || ""),
      summary: String(e.summary || ""),
      body: String(e.body || ""),
      image: String(e.image || ""),
      glyph: String(e.glyph || ""),
      urgency: Number(e.urgency || 1),
      originalId: Number(e.originalId || 0),
      timestamp: ts,
      day: Model.dayOf(ts, Date.now())
    }
  }

  function rebuild() {
    var keepKey = list.currentIndex >= 0 && shown[list.currentIndex] ? shown[list.currentIndex].key : ""
    shown = Model.filter(entries, filter)
    rows.clear()
    var at = 0
    for (var i = 0; i < shown.length; i++) {
      rows.append(rowFor(shown[i]))
      if (shown[i].key === keepKey) at = i
    }
    list.currentIndex = rows.count > 0 ? at : -1
    if (rows.count > 0) list.positionViewAtIndex(at, ListView.Contain)
  }

  onFilterChanged: rebuild()

  function move(delta) {
    if (rows.count === 0) return
    var i = list.currentIndex < 0 ? 0 : list.currentIndex + delta
    list.currentIndex = Math.abs(delta) === 1 ? Model.wrapIndex(i, rows.count)
                                              : Model.clampIndex(i, rows.count)
  }

  // ---------------------------------------------------------------- activate

  // What Enter (or a click) does:
  //  1. it is the newest toast still on screen -> the service runs that
  //     toast's own default action, exactly as clicking it would (the IPC
  //     can only reach the most recent popup);
  //  2. it pointed at a picture (screenshot, camera) -> open the picture;
  //  3. otherwise focus the app that sent it.
  // A stored command is never re-run: anything can send a notification.
  Process { id: focusProc }

  function activate(index) {
    var entry = shown[index]
    if (!entry) return
    // Check liveness fresh: the toast may have expired since the panel opened.
    refreshLive(function() { root.activateEntry(entry) })
  }

  function activateEntry(entry) {
    if (live.length > 0 && live[0] === entry.key) {
      Quickshell.execDetached(["omarchy-shell", "notifications", "invokeLast"])
      close()
      return
    }
    if (Model.isSafeImagePath(entry.file)) {
      Quickshell.execDetached(["xdg-open", String(entry.file)])
      close()
      return
    }
    var target = Model.focusTarget(entry)
    if (target !== "") {
      focusProc.command = [omarchyPath + "/bin/omarchy-hyprland-focus-app", target]
      focusProc.running = true
    }
    close()
  }

  // ------------------------------------------------------------------ search

  function startSearch() {
    searching = true
    Qt.callLater(function() { if (root.searching) search.forceActiveFocus() })
  }

  // keep=true: back to the list with the filter still applied.
  function endSearch(keep) {
    searching = false
    if (!keep) { search.text = ""; filter = "" }
    Qt.callLater(function() { if (root.opened) keys.forceActiveFocus() })
  }

  // ------------------------------------------------------------------- keys

  // Named so the test IPC can drive it: synthetic input doesn't reach the shell.
  function handleKey(name) {
    if (name !== "c") { clearArmed = false; disarm.stop() }
    switch (name) {
    case "down": move(1); return true
    case "up": move(-1); return true
    case "pagedown": move(5); return true
    case "pageup": move(-5); return true
    case "home": list.currentIndex = rows.count > 0 ? 0 : -1; return true
    case "end": list.currentIndex = rows.count - 1; return true
    case "enter": activate(list.currentIndex); return true
    case "search": startSearch(); return true
    case "dnd": toggleDnd(); return true
    case "c": pressClear(); return true
    case "remove": remove(list.currentIndex); return true
    case "escape":
      if (filter !== "") endSearch(false)
      else close()
      return true
    }
    return false
  }

  function keyName(event) {
    var k = event.key, t = event.text
    if (k === Qt.Key_Down || t === "j") return "down"
    if (k === Qt.Key_Up || t === "k") return "up"
    if (k === Qt.Key_PageDown) return "pagedown"
    if (k === Qt.Key_PageUp) return "pageup"
    if (k === Qt.Key_Home || t === "g") return "home"
    if (k === Qt.Key_End || t === "G") return "end"
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) return "enter"
    if (k === Qt.Key_Escape) return "escape"
    if (k === Qt.Key_Delete || t === "x" || t === "X") return "remove"
    if (t === "/") return "search"
    if (t === "d" || t === "D") return "dnd"
    if (t === "c" || t === "C") return "c"
    return ""
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: {
    seenProc.command = store(["seen"])
    seenProc.running = true
    load()
    refreshLive()
  }

  onOpenedChanged: {
    if (!opened) {
      searching = false
      search.text = ""
      filter = ""
      clearArmed = false
      return
    }
    now = Date.now()
    readMark = lastSeen
    markSeen()
    refreshLive()
    load()
    rebuild()
    list.currentIndex = rows.count > 0 ? 0 : -1
    list.positionViewAtBeginning()
  }

  // --------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    text: root.dnd ? root.iconDnd : root.iconOn
    dimmed: root.dnd
    tooltipText: {
      if (root.dnd) return "Do Not Disturb" + (root.unread > 0 ? " · " + root.unread + " new" : "")
      if (root.unread === 1) return "1 new notification"
      if (root.unread > 1) return root.unread + " new notifications"
      return "Notifications"
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleDnd()
      else root.toggle()
    }
  }

  // The panel hangs from a point far past the right edge; KeyboardPanel clamps
  // the card inside the screen, so it always sits against the right edge.
  Item {
    id: rightAnchor
    anchors.top: button.top
    anchors.bottom: button.bottom
    x: 1000000
    width: 1
    visible: false
  }

  Rectangle {
    visible: root.badge === "Dot" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(3)
    anchors.top: button.top
    anchors.topMargin: Style.space(5)
    width: Style.space(6)
    height: width
    radius: width / 2
    color: Color.accent
  }

  Rectangle {
    visible: root.badge === "Count" && root.unread > 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(1)
    anchors.top: button.top
    anchors.topMargin: Style.space(3)
    width: Math.max(countText.implicitWidth + Style.space(6), Style.space(12))
    height: Style.space(12)
    radius: height / 2
    color: Color.accent

    Text {
      id: countText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: root.unread > 99 ? "99+" : String(root.unread)
      font.family: root.fontFamily
      font.pixelSize: Math.max(8, Style.font.caption - Style.space(3))
      font.bold: true
      color: Color.background
    }
  }

  // ------------------------------------------------------------------- panel

  KeyboardPanel {
    id: popup
    anchorItem: rightAnchor
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keys
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    // Full height: the side panel runs from the top of the screen to the bar.
    contentHeight: Math.round(popup.availableCardHeight)

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var name = root.keyName(event)
        if (root.searching) {
          // The search field owns typing; only these get through.
          if (name === "up" && event.key === Qt.Key_Up) { root.move(-1); event.accepted = true }
          else if (name === "down" && event.key === Qt.Key_Down) { root.move(1); event.accepted = true }
          else if (event.key === Qt.Key_Escape) { root.endSearch(false); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.endSearch(true); event.accepted = true }
          return
        }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.switchPanel(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
          event.accepted = true
          return
        }
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        if (name !== "" && root.handleKey(name)) event.accepted = true
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // ------------------------------------------------------- header

        Item {
          id: header
          width: parent.width
          height: Math.max(title.implicitHeight, chips.height)

          PanelSectionHeader {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.entries.length > 0 ? "NOTIFICATIONS  " + root.entries.length : "NOTIFICATIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            id: chips
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f0349}"  // md-magnify
              tooltipText: "Search  ( / )"
              foreground: root.searching || root.filter !== "" ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.searching ? root.endSearch(false) : root.startSearch()
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.dnd ? root.iconDnd : root.iconOn
              tooltipText: (root.dnd ? "Allow notifications" : "Do Not Disturb") + "  ( d )"
              foreground: root.dnd ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleDnd()
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f045a}"  // md-notification_clear_all
              tooltipText: root.clearArmed ? "Click again to clear everything" : "Clear all  ( c c )"
              foreground: root.clearArmed ? Color.urgent : root.foreground
              fontFamily: root.fontFamily
              enabled: root.entries.length > 0
              onClicked: root.pressClear()
            }
          }
        }

        // Status strip: DND on, or clear armed.
        Rectangle {
          id: status
          width: parent.width
          visible: root.dnd || root.clearArmed
          height: visible ? statusText.implicitHeight + Style.space(10) : 0
          radius: Style.space(8)
          color: Qt.rgba(statusColor.r, statusColor.g, statusColor.b, 0.15)
          readonly property color statusColor: root.clearArmed ? Color.urgent : Color.accent

          Text {
            id: statusText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: root.clearArmed
              ? "Press c again to clear " + root.entries.length + " notification" + (root.entries.length === 1 ? "" : "s")
              : root.iconDnd + "  Do Not Disturb is on  ·  d to turn off"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            color: status.statusColor
          }
        }

        // ------------------------------------------------------- search

        TextField {
          id: search
          width: parent.width
          visible: root.searching || root.filter !== ""
          placeholderText: "Search notifications"
          foreground: root.foreground
          onTextChanged: root.filter = text
        }

        // --------------------------------------------------------- list

        ListView {
          id: list
          width: parent.width
          height: Math.max(0, content.height - header.height - status.height
                           - (search.visible ? search.height : 0) - foot.height
                           - content.spacing * (search.visible ? 4 : 3))
          visible: rows.count > 0
          clip: true
          model: rows
          spacing: Style.space(6)
          currentIndex: -1
          keyNavigationEnabled: false
          highlightFollowsCurrentItem: false
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          readonly property real lane: Style.space(10)

          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          section.property: "day"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            id: daySection
            required property string section
            width: list.width - list.lane
            height: dayLabel.implicitHeight + Style.space(12)

            PanelSectionHeader {
              id: dayLabel
              anchors.left: parent.left
              anchors.leftMargin: Style.space(2)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(4)
              text: daySection.section.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          delegate: NotificationRow {
            id: row
            required property var model
            required property int index

            width: list.width - list.lane
            app: model.app
            appIcon: model.appIcon
            summary: model.summary
            body: model.body
            image: model.image
            glyph: model.glyph
            urgency: model.urgency
            timestamp: model.timestamp
            now: root.now
            live: root.live.indexOf(model.key) >= 0
            unread: model.timestamp > root.readMark
            selected: row.index === list.currentIndex
            showBody: root.showBody
            foreground: root.foreground
            fontFamily: root.fontFamily

            onClicked: { list.currentIndex = row.index; root.activate(row.index) }
            onRemoveRequested: root.remove(row.index)
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: rows.count === 0
          height: visible ? list.height : 0
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: !root.loaded ? "Loading…"
              : root.filter !== "" ? "Nothing matches “" + root.filter + "”"
              : "No notifications"
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.foreground
          opacity: 0.5
        }

        // ---------------------------------------------------------- foot

        Text {
          id: foot
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: root.searching
            ? "type to filter · ↑↓ select · ⏎ done · esc clear"
            : "↑↓ select · ⏎ open · / search · d dnd · c clear · x remove · esc close"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.45
        }
      }
    }
  }

  // ---------------------------------------------------------------- testing
  //
  //   omarchy-shell jgarza.notification.test state
  //   omarchy-shell jgarza.notification.test seed 20
  //   omarchy-shell jgarza.notification.test key down|up|enter|search|dnd|c|remove|escape
  IpcHandler {
    target: "jgarza.notification.test"

    function state(): string {
      return JSON.stringify({
        opened: root.opened,
        entries: root.entries.length,
        rows: rows.count,
        selected: list.currentIndex,
        selectedSummary: root.shown[list.currentIndex] ? root.shown[list.currentIndex].summary : "",
        filter: root.filter,
        searching: root.searching,
        dnd: root.dnd,
        clearArmed: root.clearArmed,
        unread: root.unread,
        live: root.live,
        watching: watchProc.running
      })
    }

    function seed(count: int): string {
      Quickshell.execDetached(root.store(["seed", String(count > 0 ? count : 20)]))
      reloadSoon.restart()
      return "seeding"
    }

    function key(name: string): string {
      return root.handleKey(String(name)) ? "ok" : "unknown key"
    }

    function find(text: string): string {
      root.startSearch()
      search.text = String(text)
      return String(root.shown.length)
    }

    function reload(): string { root.load(); return "ok" }
  }

  Timer {
    id: reloadSoon
    interval: 600
    onTriggered: root.load()
  }
}
