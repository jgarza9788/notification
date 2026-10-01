// Run: node tests/model.test.js
const M = require("../Model.js");

let failed = 0;
function ok(name, cond) {
  console.log((cond ? "PASS " : "FAIL ") + name);
  if (!cond) failed++;
}

// plain
ok("plain strips tags", M.plain("<b>Hi</b> <img src='http://x'/>there") === "Hi there");
ok("plain decodes entities", M.plain("a &amp; b &lt;c&gt;") === "a & b <c>");
ok("plain collapses whitespace", M.plain("  a \n\n b ") === "a b");

// sender
ok("sender prefers app", M.sender({ app: "Slack", appIcon: "slack" }) === "Slack");
ok("sender shortens desktop id", M.sender({ app: "", appIcon: "com.mitchellh.ghostty" }) === "ghostty");
ok("sender ignores icon paths", M.sender({ app: "", appIcon: "/tmp/x.png" }) === "");

// matches / filter
const entries = [
  { key: "1", app: "Slack", summary: "Deploy done", body: "4f21c9 is <b>live</b>", timestamp: 3 },
  { key: "2", app: "", appIcon: "com.mitchellh.ghostty", summary: "Claude Code", body: "waiting for input", timestamp: 2 },
  { key: "3", app: "Signal", summary: "Jules", body: "Thursday?", timestamp: 1 },
];
ok("empty query matches all", M.filter(entries, "").length === 3);
ok("case-insensitive", M.filter(entries, "SLACK").length === 1);
ok("matches body text without markup", M.filter(entries, "is live").length === 1);
ok("matches desktop id sender", M.filter(entries, "ghostty").length === 1);
ok("all words must match", M.filter(entries, "claude input").length === 1);
ok("words across fields", M.filter(entries, "signal thursday").length === 1);
ok("no match", M.filter(entries, "zzz").length === 0);

// dayOf
const now = new Date(2026, 8, 30, 15, 0).getTime(); // Wed 30 Sep 2026
ok("today", M.dayOf(new Date(2026, 8, 30, 0, 5).getTime(), now) === "Today");
ok("yesterday", M.dayOf(new Date(2026, 8, 29, 23, 0).getTime(), now) === "Yesterday");
ok("weekday", M.dayOf(new Date(2026, 8, 26, 12, 0).getTime(), now) === "Saturday");
ok("date this year", M.dayOf(new Date(2026, 7, 17, 12, 0).getTime(), now) === "17 August");
ok("date other year", M.dayOf(new Date(2025, 11, 1, 12, 0).getTime(), now) === "1 December 2025");

// relativeTime
ok("now", M.relativeTime(now - 5000, now) === "now");
ok("minutes", M.relativeTime(now - 4 * 60000, now) === "4m");
ok("clock", M.relativeTime(new Date(2026, 8, 30, 9, 7).getTime(), now) === "09:07");
ok("future clamps to now", M.relativeTime(now + 9999, now) === "now");

// indices
ok("wrap down past end", M.wrapIndex(3, 3) === 0);
ok("wrap up past start", M.wrapIndex(-1, 3) === 2);
ok("wrap empty", M.wrapIndex(0, 0) === -1);
ok("clamp high", M.clampIndex(9, 3) === 2);
ok("clamp low", M.clampIndex(-4, 3) === 0);
ok("clamp empty", M.clampIndex(0, 0) === -1);

// safety
ok("image path ok", M.isSafeImagePath("/home/u/Pictures/shot.png"));
ok("image path rejects relative", !M.isSafeImagePath("shot.png"));
ok("image path rejects option", !M.isSafeImagePath("--help.png"));
ok("image path rejects non-image", !M.isSafeImagePath("/bin/sh"));
ok("image path rejects traversal", !M.isSafeImagePath("/a/../etc/x.png"));
ok("plain app name", M.isPlainAppName("Slack"));
ok("app name rejects regex", !M.isPlainAppName(".*"));
ok("app name rejects empty", !M.isPlainAppName(""));
ok("focusTarget app", M.focusTarget({ app: "Slack", appIcon: "slack" }) === "Slack");
ok("focusTarget falls back to icon id", M.focusTarget({ app: "", appIcon: "com.mitchellh.ghostty" }) === "com.mitchellh.ghostty");
ok("focusTarget nothing usable", M.focusTarget({ app: "", appIcon: "/x/y.png" }) === "");

// unread
ok("unreadCount", M.unreadCount(entries, 1) === 2);
ok("unreadCount none", M.unreadCount(entries, 5) === 0);

console.log(failed ? failed + " failed" : "all passed");
process.exit(failed ? 1 : 0);
