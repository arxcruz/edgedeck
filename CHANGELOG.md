# Changelog

What changed in each EdgeDeck release. Downloads are on the
[Releases](https://github.com/arxcruz/edgedeck/releases) page.

## Unreleased

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
