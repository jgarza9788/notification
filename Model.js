// Pure helpers for the Notifications panel. Imported from Panel.qml as
// `import "Model.js" as Model`, and ES5-only so the same file runs under node.

var DAY_MS = 86400000

// Notification text is sender-chosen markup. Strip tags so nothing renders
// as rich text (an <img> would fetch a URL the sender picked).
function plain(text) {
  return String(text || "")
    .replace(/<img[^>]*>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"").replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim()
}

// Who sent it, for display: the app name, else the desktop id the icon came
// from, shortened to its last component ("com.mitchellh.ghostty" -> "ghostty").
function sender(entry) {
  if (!entry) return ""
  if (entry.app) return String(entry.app)
  var icon = String(entry.appIcon || "")
  if (icon === "" || icon.charAt(0) === "/" || icon.indexOf("://") >= 0) return ""
  var parts = icon.split(".")
  return parts[parts.length - 1]
}

// Case-insensitive substring match over sender, summary and body. Every
// whitespace-separated word must match somewhere.
function matches(entry, query) {
  var q = String(query || "").toLowerCase().trim()
  if (q === "") return true
  var hay = (sender(entry) + " " + String(entry.appIcon || "") + " " +
             plain(entry.summary) + " " + plain(entry.body)).toLowerCase()
  var words = q.split(/\s+/)
  for (var i = 0; i < words.length; i++)
    if (hay.indexOf(words[i]) < 0) return false
  return true
}

function filter(entries, query) {
  var out = []
  for (var i = 0; i < (entries || []).length; i++)
    if (matches(entries[i], query)) out.push(entries[i])
  return out
}

var WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var MONTHS = ["January", "February", "March", "April", "May", "June", "July",
              "August", "September", "October", "November", "December"]

// Section heading for a timestamp: Today, Yesterday, a weekday within the
// week, then "17 August" (plus the year when it isn't this year).
function dayOf(timestamp, now) {
  var n = new Date(now)
  var midnight = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime()
  var when = new Date(timestamp)
  if (timestamp >= midnight) return "Today"
  if (timestamp >= midnight - DAY_MS) return "Yesterday"
  if (timestamp >= midnight - 6 * DAY_MS) return WEEKDAYS[when.getDay()]
  var label = when.getDate() + " " + MONTHS[when.getMonth()]
  return when.getFullYear() === n.getFullYear() ? label : label + " " + when.getFullYear()
}

function pad2(n) { return n < 10 ? "0" + n : String(n) }

// "now", "4m", then the clock time (the day is in the section heading).
function relativeTime(timestamp, now) {
  var age = Math.max(0, now - timestamp)
  if (age < 60000) return "now"
  if (age < 3600000) return Math.floor(age / 60000) + "m"
  var d = new Date(timestamp)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function wrapIndex(index, count) {
  if (count <= 0) return -1
  return ((index % count) + count) % count
}

function clampIndex(index, count) {
  if (count <= 0) return -1
  return Math.max(0, Math.min(index, count - 1))
}

// An absolute path to an image file, nothing that could be read as an option
// or a URL scheme.
function isSafeImagePath(path) {
  var p = String(path || "")
  return /^\/[^\0\n]*\.(png|jpe?g|webp|gif|bmp|svg)$/i.test(p) && p.indexOf("/../") < 0
}

// The focus helper matches its argument as a regex against window classes,
// so only something shaped like a plain name is allowed through.
function isPlainAppName(name) {
  return /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/.test(String(name || ""))
}

// Window class to focus for an entry: the app name, else the desktop-id icon
// (which for most apps is their class, e.g. com.mitchellh.ghostty).
function focusTarget(entry) {
  if (!entry) return ""
  if (isPlainAppName(entry.app)) return String(entry.app)
  if (isPlainAppName(entry.appIcon)) return String(entry.appIcon)
  return ""
}

// Unread count: entries newer than lastSeen (newest first, so stop early).
function unreadCount(entries, lastSeen) {
  var n = 0
  for (var i = 0; i < (entries || []).length; i++) {
    if (Number(entries[i].timestamp) > lastSeen) n++
    else break
  }
  return n
}

if (typeof module !== "undefined") {
  module.exports = {
    plain: plain,
    sender: sender,
    matches: matches,
    filter: filter,
    dayOf: dayOf,
    relativeTime: relativeTime,
    wrapIndex: wrapIndex,
    clampIndex: clampIndex,
    isSafeImagePath: isSafeImagePath,
    isPlainAppName: isPlainAppName,
    focusTarget: focusTarget,
    unreadCount: unreadCount
  }
}
