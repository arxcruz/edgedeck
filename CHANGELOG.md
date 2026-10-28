# Changelog

What changed in each EdgeDeck release. Downloads are on the
[Releases](https://github.com/arxcruz/edgedeck/releases) page.

## Unreleased

- **Codex** and **Antigravity** in the **AI Agents** widget: connect them from the Connect view and
  their sessions show beside Claude and OpenCode, with their 5-hour and weekly quotas. Choose how
  quotas show under **Quota layout** in the widget's Editor: together with the sessions, on
  separate **Sessions** / **Quotas** buttons, or **Tap to flip** the whole widget. Claude's plan
  usage now disappears when the saved reading is over an hour old, instead of showing a wrong one.

- **CPU** widget: tap it to flip to the five processes using the most CPU, with their CPU and RAM
  use. It measures every two seconds only while that side is showing on the current page.

- **Stocks** and **Currency** widgets: a Watchlist of Symbols with price and change on the day, and
  the rate of one currency pair (Tap to flip BRL → EUR). Search and add Symbols in the widget's Editor.
  Prices come from Yahoo Finance, every 5 minutes by default (**Settings → Markets**); tap a widget's
  header to update it now. **Alerts**: a price level that makes the widget pulse and raises a Toast
  once the price reaches it.

- **Temperature** and **Fans** widgets: CPU and GPU temperature with a graph, and the speed of each
  fan. Tap Temperature to turn it over between °C and °F; each widget remembers its own side.
  They read the sensors only while one is on the current page.

## 0.2.0 — 2026-10-16

- **Fix:** the **App Windows** and **Mission Control** Controls, and any Button that sends an arrow
  key with a modifier, now work the way the real keys do.
- **Settings window:** Touch, Keyboard, Open at Login, Keep Edge at 2560×720 and config.json
  moved out of the menu bar's submenus into one window on your main screen (**Settings…**, ⌘,),
  with no menus to navigate and every change applied at once. It also covers settings that used
  to need editing config.json: the Edge's display name, the Rail width and the Notifications options.
- **Edge goes back to 2560×720 by itself:** when macOS drops the Edge to 1080p (after a replug,
  wake or KVM switch), EdgeDeck puts it back in its Native mode, with no trip to System Settings.
  Untick **Keep Edge at 2560×720** in **Settings → Display** to leave the resolution alone; if the
  switch fails, Settings says so and offers **Try Again**.
- **Timer** and **Pomodoro** widgets: start a countdown with one tap on a chip, pause and resume
  by tapping the time, and take Rounds of Work and Break. When one runs out it rings: the
  widget pulses, a sound plays and a Toast says which (a button on the Rail during a
  Takeover). Countdowns keep going across restarts and sleep.
- **Lower idle CPU:** the AI agents, Notifications, system stats and Dock badges are looked at
  less often, and only while a widget that needs them is on the Page.

## 0.1.3 — 2026-10-12

- **Grab the keyboard:** with two Macs, type into the app on the Edge using the other Mac's
  keyboard (**Grab keyboard** beside the app; ⌃⌥⌘K on the other Mac takes it back).
- **Bring to Edge works with tmux:** Claude Code running inside tmux in iTerm2 now finds its
  terminal. When something can't be done, the Edge says why instead of nothing happening.
- **Clearer two-Mac setup:** EdgeDeck explains macOS's password prompt before it appears and
  offers to Pair again instead, shows "Waiting for you on …" while the other Mac asks for its
  password, and says when a Mac needs Screen & System Audio Recording.
- **Fix:** touch on the Edge no longer stops while EdgeDeck waits for an answer on the Mac
  (the Pairing code or the password explanation).

## 0.1.2 — 2026-10-11

- **Fix:** tapping into a text field in an Editor could freeze all touch on the Edge.
- Touch checks the Input Monitoring permission up front on macOS versions that need it.

## 0.1.1 — 2026-10-11

- Faster menu bar menu.
- Uses macOS 27's name for the Accessibility permission (Device Control and Data Access).
- First-launch and permission help in the README.

## 0.1.0 — 2026-10-11

- First release: Pages of Widgets for system stats, Notifications, Launcher Buttons, Now
  Playing, Music, World Clock, Weather, Calendar and AI Agents (Claude Code and OpenCode);
  Guest apps and the Edge player; Remote view between your Macs.
