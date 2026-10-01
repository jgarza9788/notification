#!/usr/bin/env bash
# Run: bash tests/store.test.sh
# Drives bin/notification-store against scratch directories.
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
store_bin=$here/bin/notification-store
tmp=$(mktemp -d)
trap 'kill "${watch_pid:-}" 2>/dev/null; rm -rf "$tmp"' EXIT

export NS_SRC_DIR=$tmp/src NS_STORE=$tmp/store
mkdir -p "$NS_SRC_DIR/history"

failed=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failed=$((failed + 1)); fi; }

now=$(($(date +%s%N) / 1000000))
old=$((now - 40 * 86400000))
printf '{"id":1,"originalId":1,"app":"Slack","appIcon":"","summary":"one","body":"b1","image":"","glyph":"","execArgv":"","urgency":1,"timestamp":%s}\n' "$((now - 2000))" > "$NS_SRC_DIR/history/$((now - 2000))-1.json"
printf '{"id":2,"originalId":2,"app":"","appIcon":"com.mitchellh.ghostty","summary":"two","body":"b2","image":"","glyph":"","execArgv":"[\\"omarchy-cmd-screenshot-edit\\",\\"/home/u/Pictures/shot one.png\\"]","urgency":2,"timestamp":%s}\n' "$((now - 1000))" > "$NS_SRC_DIR/$((now - 1000))-2.json"
printf '{"id":3,"originalId":3,"app":"Old","summary":"old","timestamp":%s}\n' "$old" > "$NS_SRC_DIR/history/$old-3.json"
echo 'not json' > "$NS_SRC_DIR/history/123-9.json"

out=$("$store_bin" sync)
ok "sync ok" '[[ $(jq -r .ok <<< "$out") == true ]]'
list=$("$store_bin" list)
ok "old entry pruned, junk skipped" '[[ $(jq length <<< "$list") == 2 ]]'
ok "newest first" '[[ $(jq -r ".[0].summary" <<< "$list") == two ]]'
ok "picture path kept from execArgv" '[[ $(jq -r ".[0].file" <<< "$list") == "/home/u/Pictures/shot one.png" ]]'
ok "command itself not kept" '[[ $(jq -r ".[0] | has(\"execArgv\")" <<< "$list") == false ]]'
ok "originalId kept" '[[ $(jq -r ".[0].originalId" <<< "$list") == 2 ]]'

# Moving a toast into history must not archive it twice.
mv "$NS_SRC_DIR/$((now - 1000))-2.json" "$NS_SRC_DIR/history/"
"$store_bin" sync >/dev/null
ok "no duplicate after move to history" '[[ $("$store_bin" list | jq length) == 2 ]]'

# Watch picks up new files.
"$store_bin" watch > "$tmp/watch.out" &
watch_pid=$!
sleep 1
printf '{"id":4,"originalId":4,"app":"Signal","summary":"four","timestamp":%s}\n' "$now" > "$NS_SRC_DIR/$now-4.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q '"four"' "$tmp/watch.out" && break; sleep 0.3; done
ok "watch emits new entry" 'grep -q "\"summary\":\"four\"" "$tmp/watch.out"'
kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
ok "watch archived it" '[[ $("$store_bin" list | jq length) == 3 ]]'

key=$("$store_bin" list | jq -r '.[0].key')
"$store_bin" remove "$key" >/dev/null
ok "remove" '[[ $("$store_bin" list | jq length) == 2 ]]'
"$store_bin" sync >/dev/null
ok "removed entry stays removed after sync" '[[ $("$store_bin" list | jq length) == 2 ]]'
ok "remove rejects junk key" '! "$store_bin" remove "../x" >/dev/null'

NS_MAX_ITEMS=1 "$store_bin" prune >/dev/null
ok "maxItems keeps newest" '[[ $("$store_bin" list | jq -r ".[0].summary") == two && $("$store_bin" list | jq length) == 1 ]]'

"$store_bin" seen 12345 >/dev/null
ok "seen round-trips" '[[ $("$store_bin" seen | jq .seen) == 12345 ]]'

"$store_bin" clear >/dev/null
ok "clear" '[[ $("$store_bin" list | jq length) == 0 ]]'
"$store_bin" sync >/dev/null
ok "clear survives sync" '[[ $("$store_bin" list | jq length) == 0 ]]'
rm -f "$NS_SRC_DIR"/history/*.json "$NS_SRC_DIR"/*.json
"$store_bin" prune >/dev/null
ok "tombstones dropped once source is gone" '[[ ! -s "$NS_STORE/removed" ]]'

"$store_bin" seed 5 >/dev/null
ok "seed" '[[ $("$store_bin" list | jq length) == 5 ]]'

ok "archive is private" '[[ $(stat -c %a "$NS_STORE") == 700 ]]'

echo
(( failed == 0 )) && echo "all passed" || echo "$failed failed"
exit $(( failed > 0 ))
