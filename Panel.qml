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
//   C C       clear all        x / del     remove the selected one
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
  // Bell size on the bar, as a percentage of the bar's standard icon size.
  readonly property int iconScale: Math.max(50, Math.min(250, Number(setting("iconScale", 140)) || 140))

  // ----------------------------------------------------------------- service

  // Third-party plugins can't reach the notification service object (the
  // plugin shell API only hands out a plugin's own service), so everything
  // goes through its IPC target: `omarchy-shell notifications ...`.

  property bool dnd: false
  property int dndEpoch: 0     // bumped by every local toggle
  property int dndQueued: 0    // toggles pressed while a call was in flight

  // Reads come back as "on"/"off"; so does toggleDnd, so one parser serves both.
  // A reply to a call made before the latest toggle is stale: applying it
  // would flip the bell back until the toggle's own reply arrived.
  Process {
    id: dndProc
    property int epoch: 0
    stdout: StdioCollector {
      onStreamFinished: {
        var v = text.trim()
        if (dndProc.epoch !== root.dndEpoch) return
        if (v === "on" || v === "off") root.dnd = v === "on"
      }
    }
    onExited: if (root.dndQueued > 0) Qt.callLater(function() {
      root.dndQueued--
      root.dndCall("toggleDnd")
    })
  }

  function dndCall(method) {
    if (dndProc.running) {
      if (method === "toggleDnd") dndQueued++
      return
    }
    dndProc.epoch = dndEpoch
    dndProc.command = ["omarchy-shell", "notifications", method]
    dndProc.running = true
  }

  function toggleDnd() {
    dnd = !dnd   // answer the key press now; the IPC reply confirms it
    dndEpoch++
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

  // Callbacks wait for a fresh answer: one asked for mid-run waits for the
  // next run, since the toast may have expired since this one started.
  Process {
    id: liveProc
    property var then: []      // callbacks for this run
    property var waiting: []   // callbacks for the next run
    property bool again: false
    stdout: StdioCollector {
      onStreamFinished: {
        var keys = []
        try { keys = JSON.parse(text) } catch (e) {}
        root.live = Array.isArray(keys) ? keys : []
        var cbs = liveProc.then
        liveProc.then = []
        for (var i = 0; i < cbs.length; i++) cbs[i]()
      }
    }
    onExited: if (again) {
      again = false
      var cbs = waiting
      waiting = []
      Qt.callLater(function() { root.runLive(cbs) })
    }
  }

  function runLive(cbs) {
    liveProc.then = cbs
    liveProc.command = store(["live"])
    liveProc.running = true
  }

  function refreshLive(then) {
    var cbs = then ? [then] : []
    if (liveProc.running) {
      liveProc.again = true
      liveProc.waiting = liveProc.waiting.concat(cbs)
      return
    }
    runLive(cbs)
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
    property bool restartNow: false
    command: root.store(["watch"])
    environment: root.storeEnv
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.absorb(line) }
    }
    // Restart a watcher that died, slowly, so a broken one can't spin.
    onExited: {
      if (restartNow) {
        restartNow = false
        Qt.callLater(function() { watchProc.running = true })
      } else {
        restartWatch.restart()
      }
    }
  }

  // The watcher reads the retention limits from its environment once, at
  // start, so restart it when they change (after a slider settles).
  onStoreEnvChanged: envSettle.restart()

  Timer {
    id: envSettle
    interval: 1000
    onTriggered: {
      if (watchProc.running) {
        watchProc.restartNow = true
        watchProc.running = false
      } else {
        watchProc.running = true
      }
    }
  }

  // The archive or seen mark changed, maybe from the bar on another monitor.
  Timer {
    id: syncSoon
    interval: 250
    onTriggered: { root.load(); root.readSeen() }
  }

  Timer {
    id: restartWatch
    interval: 30000
    onTriggered: if (!watchProc.running) watchProc.running = true
  }

  function keysOf(list) {
    return list.map(function(e) { return e.key }).join(",")
  }

  Process {
    id: listProc
    property bool again: false
    environment: root.storeEnv
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try { data = JSON.parse(text) } catch (e) { return }
        if (!Array.isArray(data)) return
        root.loaded = true
        var same = root.keysOf(data) === root.keysOf(root.entries)
        root.entries = data
        if (!same) root.rebuild()
      }
    }
    // A change that landed mid-read gets a read of its own.
    onExited: if (again) { again = false; Qt.callLater(root.load) }
  }

  function load() {
    if (listProc.running) { listProc.again = true; return }
    listProc.command = store(["list", String(maxItems)])
    listProc.running = true
  }

  Process {
    id: seenProc
    property bool again: false
    environment: root.storeEnv
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d.ok) root.lastSeen = Math.max(root.lastSeen, Number(d.seen) || 0)
        } catch (e) {}
      }
    }
    onExited: if (again) { again = false; Qt.callLater(root.readSeen) }
  }

  function readSeen() {
    if (seenProc.running) { seenProc.again = true; return }
    seenProc.command = store(["seen"])
    seenProc.running = true
  }

  function markSeen() {
    lastSeen = Date.now()
    Quickshell.execDetached(store(["seen", String(Math.round(lastSeen))]))
  }

  // A newly archived notification from the watcher.
  function absorb(line) {
    var entry
    try { entry = JSON.parse(line) } catch (e) { return }
    if (entry && entry.changed) { syncSoon.restart(); return }
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
    if (name !== "clear") { clearArmed = false; disarm.stop() }
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
    case "clear": pressClear(); return true
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
    // Capital C only, twice: destructive, so it must not fire from ordinary
    // typing that lands here while the panel holds the keyboard.
    if (t === "C") return "clear"
    return ""
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: {
    readSeen()
    load()
    refreshLive()
  }

  // ---------------------------------------------------------------- slide-in
  //
  // KeyboardPanel fades its card in; the contents slide in from the right
  // inside it. Only this plugin's own items move: the card belongs to the
  // shell and is left alone.
  readonly property int slideMs: Math.max(0, Number(setting("animationMs", 240)) || 0)
  readonly property real slideDistance: popup.contentWidth

  Translate { id: slide; x: 0 }

  NumberAnimation {
    id: slideAnim
    target: slide
    property: "x"
  }

  function slideTo(x, easing, ms) {
    slideAnim.stop()
    if (slideMs <= 0) { slide.x = 0; return }
    slideAnim.from = slide.x
    slideAnim.to = x
    slideAnim.duration = ms
    slideAnim.easing.type = easing
    slideAnim.start()
  }

  function slideIn() {
    slideAnim.stop()
    slide.x = slideMs > 0 ? slideDistance : 0
    slideTo(0, Easing.OutCubic, slideMs)
  }

  onOpenedChanged: {
    if (!opened) {
      slideTo(slideDistance, Easing.InCubic, Math.round(slideMs * 0.6))
      searching = false
      search.text = ""
      filter = ""
      clearArmed = false
      return
    }
    slideIn()
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
    fontSize: Math.round(Style.bar.iconFont * root.iconScale / 100)
    opticalSize: Math.round(Style.bar.iconCanvas * root.iconScale / 100)
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

  // KeyboardPanel centres the card under its anchor, so the anchor goes where
  // that centre puts the card flush against the right edge: margin in from the
  // screen edge, half a card further left. Coordinates are the bar window's,
  // as KeyboardPanel uses. Until the window is known, a point far past the edge
  // gets the same result from KeyboardPanel keeping the card on screen.
  TransformWatcher {
    id: barWatcher
    a: root.QsWindow.window ? root.QsWindow.window.contentItem : null
    b: root
  }

  Item {
    id: rightAnchor
    anchors.top: button.top
    anchors.bottom: button.bottom
    width: 1
    visible: false
    x: {
      barWatcher.transform  // reactive dependency: the widget moving on the bar
      var win = root.QsWindow.window
      if (!win || popup.screenW <= 0) return 1000000
      var centre = popup.screenW - popup.margin - popup.contentWidth / 2
      return root.mapFromItem(win.contentItem, centre, 0).x - width / 2
    }
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
      clip: true   // the sliding contents stay inside the card
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
        transform: slide

        // ------------------------------------------------------- header

        Column {
          id: header
          width: parent.width
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              id: titleIcon
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.dnd ? root.iconDnd : root.iconOn
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Math.round(Style.font.iconLarge * 1.6)
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - titleIcon.width - closeBtn.width - parent.spacing * 2
              spacing: 2

              Text {
                textFormat: Text.PlainText
                text: "NOTIFICATIONS"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.6
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: {
                  var n = root.entries.length
                  var parts = [n + (n === 1 ? " notification" : " notifications")]
                  var fresh = Model.unreadCount(root.entries, root.readMark)
                  if (fresh > 0) parts.push(fresh + " new")
                  if (root.filter !== "") parts.push(root.shown.length + " shown")
                  parts.push(root.dnd ? "DND on" : "DND off")
                  return parts.join(" \u00b7 ")
                }
                color: Util.alpha(root.foreground, 0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            KeyButton {
              id: closeBtn
              anchors.verticalCenter: parent.verticalCenter
              keyHint: "esc"
              tooltipText: "Close"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.close()
            }
          }

          PanelSeparator { width: parent.width }

          Row {
            id: actions
            width: parent.width
            spacing: Style.space(6)

            KeyButton {
              iconText: "\u{f0349}"  // md-magnify
              text: "Search"
              keyHint: "/"
              active: root.searching || root.filter !== ""
              tooltipText: root.searching ? "Stop searching" : "Search notifications"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.searching ? root.endSearch(false) : root.startSearch()
            }

            KeyButton {
              iconText: root.dnd ? root.iconDnd : root.iconOn
              text: root.dnd ? "DND on" : "DND"
              keyHint: "d"
              active: root.dnd
              tooltipText: root.dnd ? "Allow notifications" : "Do Not Disturb"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleDnd()
            }

            KeyButton {
              iconText: "\u{f05e9}"  // md-delete_sweep
              text: root.clearArmed ? "Sure?" : "Clear"
              keyHint: root.clearArmed ? "\u21e7C" : "\u21e7C \u21e7C"
              danger: root.clearArmed
              enabled: root.entries.length > 0
              tooltipText: root.clearArmed ? "Again to clear everything" : "Clear all notifications"
              foreground: root.foreground
              fontFamily: root.fontFamily
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
              ? "Press Shift+C again to clear " + root.entries.length + " notification" + (root.entries.length === 1 ? "" : "s")
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
            : "↑↓ select · ⏎ open · x remove · tab next panel"
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
  // Off unless the flag file exists when the shell starts (it can seed fake
  // entries and press keys):
  //   touch ~/.local/state/jgarza-notification/test-ipc && omarchy-restart-shell
  //   omarchy-shell jgarza.notification.test state
  //   omarchy-shell jgarza.notification.test seed 20
  //   omarchy-shell jgarza.notification.test key down|up|enter|search|dnd|clear|remove|escape
  FileView {
    id: testFlag
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
          + "/jgarza-notification/test-ipc"
    printErrors: false
  }

  IpcHandler {
    target: "jgarza.notification.test"
    enabled: testFlag.loaded

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
        watching: watchProc.running,
        slideX: slide.x
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
