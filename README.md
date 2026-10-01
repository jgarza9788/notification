# Notifications

A bell on the Omarchy bar that opens a full-height side panel of your
notifications, against the right edge of the screen. You can do everything in
the panel from the keyboard.

## Keys

| Key | |
|---|---|
| `↑` `↓` / `k` `j` | select (wraps around) |
| `PgUp` `PgDn`, `Home`/`g`, `End`/`G` | jump |
| `Enter` / `Space` | open the selected notification ("click" it) |
| `/` | search; type to filter, `Enter` keeps the filter, `Esc` clears it |
| `d` | toggle Do Not Disturb |
| `c` `c` | clear everything (the first `c` asks, the second clears) |
| `x` / `Delete` | remove the selected notification |
| `Esc` | clear the search, or close the panel |
| `Tab` | next bar panel |

On the bar, left-click opens the panel and right-click toggles Do Not Disturb.
The bell changes to a crossed-out bell while DND is on, and a badge counts
what's new since you last opened the panel.

### What "open" does

1. **Still on screen as a toast**: runs the toast's own action, the same as
   clicking the toast.
2. **Pointed at a picture** (screenshots, camera): opens the picture.
3. **Otherwise**: focuses the app that sent it.

The panel never re-runs a command stored with an old notification, because
any program can send one.

## Open it from a key

```bash
omarchy-shell jgarza.notification toggle
```

For example, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + N", "Notifications", "omarchy-shell jgarza.notification toggle")
```

## History

Omarchy's notification service keeps only the last 10 notifications.
`bin/notification-store` copies each one as it arrives into
`~/.local/state/jgarza-notification/` (mode `0700`), icons included. It keeps
them for `keepDays` days, up to a limit of `maxItems`. Clearing the panel also
clears Omarchy's own history.

```
bin/notification-store list 50 | jq -r '.[] | "\(.app): \(.summary)"'
```

## Settings

| Setting | Default | |
|---|---|---|
| `panelWidth` | 420 | panel width |
| `keepDays` | 30 | days to keep |
| `maxItems` | 500 | most to keep |
| `badge` | Count | `Count`, `Dot` or `None` |
| `showBody` | true | show message text |
| `icon` / `iconDnd` | bell / bell-off | bar glyphs |

## Tests

```bash
node tests/model.test.js
bash tests/store.test.sh
```

The running panel can be driven over IPC, since synthetic key presses don't
reach the shell:

```bash
omarchy-shell jgarza.notification.test seed 20
omarchy-shell jgarza.notification.test key down      # up enter search dnd c remove escape
omarchy-shell jgarza.notification.test state
```
