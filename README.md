# EdgeDeck

A touch dashboard for the CORSAIR Xeneon Edge on macOS: live system stats, a
mirror of your macOS notifications, and Stream Deck–style launcher buttons.

Tapping a notification clicks the real macOS banner (so Slack opens the right
conversation) and, for apps listed in `bringToEdgeOnTap`, brings that app's window to
the Edge as the Guest app. A strip on the right keeps **Activate** / **Send back** and your newest
notifications reachable while it's there.

## Build & run

```sh
./scripts/build.sh
open /Applications/EdgeDeck.app
```

The build script installs the app to `/Applications` (`NO_INSTALL=1` skips that and
leaves only `build/EdgeDeck.app`).

On first launch macOS asks for **Accessibility** access (System Settings →
Privacy & Security → Accessibility → EdgeDeck). It's needed to read
Notification Center, move windows and send key presses.

The build is ad-hoc signed, so macOS treats every rebuild as a new app and you
have to re-enable Accessibility after rebuilding. To avoid that, sign with a
stable identity: `SIGN_IDENTITY="Your Cert Name" ./scripts/build.sh`.

The menu bar icon has Edit Layout, **Use as Plain Display**, Open config.json, Reload,
Send Back Guest App, **Touch** settings, **Open at Login** and Quit. Open at Login works for the copy in `/Applications`.

## Touch

Out of the box macOS treats the Edge's touchscreen as an absolute mouse: every touch
drags the cursor onto the Edge. EdgeDeck takes over the touchscreen instead (this used
to be the separate Edgetap app) and decides at touch-down where each touch goes:

- **On EdgeDeck itself** (the dashboard, the strip on the right, editors) touches go
  straight to it, without moving the cursor: buttons react the moment you touch them,
  a held finger shows as pressed and opens menus while it's still down, and in edit
  mode a drag moves a widget at once.
- **On any other window on the Edge** (a Guest app) touches become clicks, scrolls
  and drags:

| Touch | Result |
| --- | --- |
| Tap / double-tap | Click / double-click |
| Drag a finger | Scroll (content follows the finger); a flick keeps coasting, touch to stop |
| Rest ~0.5 s, then drag | Click-and-drag (move windows, select text) |
| Rest ~0.5 s, then lift | Right-click |

Touch needs **Input Monitoring** (System Settings → Privacy & Security → Input
Monitoring → EdgeDeck) on top of Accessibility; a banner on the Edge says so until
it's granted. The menu bar's **Touch** submenu turns it on or off (off hands the
touchscreen back to macOS) and has scroll speed, reverse direction, momentum, flick
acceleration, the hold time and hiding the cursor. If the old Edgetap app is
running, EdgeDeck offers to quit it, since only one app can hold the touchscreen.

### Plain display

To use the Edge as a normal monitor, turn the dashboard off: **Use as Plain Display**
in the menu bar (⌘D while the menu is open), or a launcher button with the **Plain
Display** action (it's in the editor's Controls). Touch keeps working on whatever
windows you put there. **Swipe in from the Edge's right edge** to bring the dashboard
back (a small tab at that edge reminds you for a few seconds), or use the menu again.
EdgeDeck remembers it across restarts. While the Edge is a plain display, a session
that **Needs you** still pops its toast over your windows (notification toasts
don't), and bringing an app or video to the Edge turns the dashboard back on so the
strip with **Send back** is there.

The touchscreen reports a single finger, so there are no two-finger gestures. The
hardware notes and `touch-probe` (`swift run touch-probe [--seize]`, dumps the
controller's HID reports) came from Edgetap. `scripts/test.sh` runs the gesture
tests.

EdgeDeck only uses the Xeneon Edge. While it isn't connected, the menu bar icon
turns into a dashed rectangle, the menu says "Waiting for the Xeneon Edge…", and
**Show Preview** opens the dashboard in a window on the main display, at the Edge's
layout scaled to fit. Use it with the mouse to look around and edit. It closes when
the Edge is plugged in. Bringing an app to the Edge needs the real Edge.

## Another Mac's Dashboard (Remote view)

With EdgeDeck on a second Mac on the same network, the Edge can show **that Mac's
Dashboard** instead of this one's, and switch back, without moving any cables. The
Mac the Edge is plugged into is the **Host**; the Mac whose Dashboard is showing is the
**Source**. Either Mac can be either.

- Once another Mac is found, a pill at the Edge's bottom right names the Mac on show
  (**This Mac** at first). Tap it to choose another; the menu bar's **Show on Edge**
  does the same.
- The first time, the two Macs **Pair**: the Edge shows a 6-digit code and the Source
  asks for it. After that they remember each other (in each Mac's Keychain). Everything
  between them is encrypted.
- The Source needs the **Screen Recording** permission (it streams its own Dashboard,
  which it draws out of sight under the wallpaper) and both need **Local Network**.
  While it's being watched, the Source keeps its display awake.
- Touches act on the Source: Buttons, Now Playing and Notifications act on that Mac,
  and Edit mode edits its Dashboard. Only the Dashboard comes across: nothing can be
  brought to the Edge from a Remote view.
- Text fields in its Editors take either Mac's keyboard: this Mac's is forwarded while a
  field is in use (and handed back to your app afterwards), and the Source's own works
  too. Pasting uses the Source's clipboard.
- This Mac's Toasts still pop up over a Remote view. Bringing an app or video to the
  Edge, opening a Notification, or turning on Plain display goes back to this Mac's
  Dashboard, as does the Source going away (a message says so). EdgeDeck always
  starts on this Mac's Dashboard.

`EDGEDECK_REMOTE_STATS=1` on the Source logs frames per second, encoding time and bit
rate. `EDGEDECK_REMOTE_NAME=<name>` renames a Mac on the network (for running a second
copy as a test Source on one Mac, with `EDGEDECK_NO_EDGE=1`), and
`EDGEDECK_REMOTE_SHOW=<name>` switches the Edge to that Source as soon as it's found.

## Pages & layout

The dashboard can have several pages. **Swipe left/right** anywhere on the Edge
to change page; dots at the bottom show which page you're on (hidden when
there's only one). Pages have no names. The menu bar macOS draws on the Edge is
always covered by a blank strip. Lists inside
widgets (notifications, launcher pages) use **vertical** swipes.

Swipes work both as drags (touch, mouse) and as scroll gestures (trackpads), which
EdgeDeck turns into page changes (the page follows the finger; momentum after
lifting is ignored, so one flick moves one page).

Each page is a grid (30 columns × 4 rows by default) and every widget has its
own position and size on it. Tap the slider icon (bottom-left of the Edge) to
edit:

- **Drag a widget** to move it, **drag its corner handle** to resize. The target
  cell turns green, or red if it would overlap another widget.
- **✕** removes a widget; **Add Widget** puts a new one in the first free spot.
- **Add Page**, **Move Left/Right** and **Delete Page** (tap twice to confirm)
  manage pages; ‹ › switch pages while editing.

Everything is saved to `~/Library/Application Support/EdgeDeck/config.json`,
which is also live-reloaded when you edit it by hand:

```json
"pages": [
  {
    "columns": 30,
    "rows": 4,
    "widgets": [
      { "type": "worldClock", "frame": { "x": 0, "y": 0, "w": 3, "h": 4 }, "cities": [{ "timeZone": "local" }] },
      { "type": "cpu",   "frame": { "x": 3, "y": 0, "w": 3, "h": 2 } },
      { "type": "gpu",   "frame": { "x": 3, "y": 2, "w": 3, "h": 2 } }
    ]
  }
]
```

Widget types: `cpu`, `gpu`, `memory`, `disk`, `network`,
`notifications`, `launcher`, `runningApps`, `nowPlaying`, `worldClock`, `weather`,
`calendar`, `music`, `ai`. Older `clock` widgets become a World Clock showing
the Local city, which looks the same. Older single-row configs are converted automatically (the original is kept
as `config.v1-backup.json`).

## Running apps

`runningApps` shows the apps currently open, with their Dock badges (unread
counts). Tap an app to bring it forward (it reopens a window if it has none);
long-press for **Bring to Edge**, **Hide** and **Quit**. The frontmost app is outlined
in white, the Guest app (on the Edge) in purple, and hidden apps are dimmed.

## Now Playing

`nowPlaying` shows whatever macOS lists as Now Playing (Music, Spotify, YouTube
in a browser, podcasts…): artwork, title, artist, source app and position, with
previous / play-pause / next. Tap the progress bar to seek, and the artwork or
app name to bring the source app forward. The layout adapts to the widget's
shape and size.

Below the controls, **Open in <app>** brings the source app forward and, for
browser media, **Watch on Edge** moves the video onto the Edge: EdgeDeck reads
the tab's URL (via Accessibility), pauses it in the browser and plays it
full-size on the Edge from the same second (YouTube through its official
embedded player, other sites by stretching the page's video). The strip on the
right then offers Play/Pause, **Back to <browser>** — which resumes the browser
at the point you reached — and Close. The video needs to be the active tab in
its browser window. The Edge player has its own web session, so you're not
signed in to YouTube there unless you sign in once inside it.

MediaRemote, the framework behind this, only answers Apple-signed processes on
recent macOS, so EdgeDeck runs a small helper (`Helpers/EdgeDeckMedia.m`,
bundled as `EdgeDeckMedia.dylib`) inside `/usr/bin/perl` and talks to it over a
pipe. If a future macOS closes that route, the widget says so instead of
showing stale data.

## World Clock

`worldClock` shows any number of cities as cards: local time (12/24-hour per
your macOS setting), a sun or moon for day/night, and how they relate to you
("Tomorrow · +7h"). The **Local** city always follows the Mac's current time
zone (marked **HERE**); every other city is fixed. With a single city the widget
is a desk clock: the time large with the full date. Cards re-flow to fill
the widget; when there are too many to stay readable they page (swipe up/down).
Add as many World Clock widgets as you like, on any page.

In edit mode, tap the widget to pick cities by touch: toggle **Local**, choose a region, page through
the cities (or jump with the A–Z index) and tap to add or remove. Selected
cities appear at the top, where you drag to reorder and ✕ removes one. In
`config.json` each city is `{ "timeZone": "America/Sao_Paulo", "label": "Office" }`,
where `label` is an optional custom name; `"timeZone": "local"` is the Local city.

## Weather

`weather` shows current conditions (temperature, condition, today's high/low,
feels-like), an hourly strip when the widget is wide enough, and a 7-day list
when it's 4 rows tall. Data comes from [Open-Meteo](https://open-meteo.com) (no
account or API key) and refreshes every 15 minutes and after the Mac wakes.
Behind it, an animated sky matches the current weather, iOS-style: sun glow
and rays or twinkling stars, drifting clouds, rain, snow, fog or lightning,
different by day and night. It only animates while its page is on screen (and
stays still with System Settings › Accessibility › Reduce motion).
Units follow your macOS region (°C/km/h, or °F/mph for US). Tap the current
conditions to open Apple Weather.

Each Weather widget forecasts one city, Local (the Mac's current time zone) by
default. In edit mode tap the widget to pick Local or any city by touch, the same
picker World Clock uses. A city is the same thing in both widgets: a time zone,
an optional label, and optional coordinates (otherwise looked up by name). For a
place that isn't in the time-zone list, set it in `config.json`:

```json
{ "type": "weather", "city": { "timeZone": "America/Sao_Paulo" } }
{ "type": "weather", "city": { "timeZone": "Europe/Berlin", "label": "Home", "latitude": 52.52, "longitude": 13.40 } }
```

The older `"location": { "name": … }` form still works: a name matching a
time-zone city becomes that city, any other place is looked up and gets its
time zone and coordinates from its first forecast.

## Calendar

`calendar` lists today's and upcoming events from every calendar set up in
macOS Calendar (iCloud, Google, Exchange…), coloured by calendar. The next or
current meeting is outlined and shows "In 12 min" / "Now · 20 min left".
Events with a Zoom, Google Meet, Teams or Webex link get a **Join** button;
tap an event to open it in Calendar. Cancelled and declined events are hidden.

The first time, tap **Allow Calendar Access** on the widget. Optional settings:

```json
{ "type": "calendar", "days": 2, "calendars": ["Work", "Family"] }
```

`days` is how many days to show starting today (1–7, default 2); `calendars`
limits it to those calendar names (all by default).

## Music

`music` is a touch remote for Apple Music (Music.app), made to sit next to Now
Playing. **Playlists** shows your playlists (with artwork, or a mosaic of their
first albums) plus **Shuffle All**; **Albums** shows every album in your library
with its cover. Tap a tile to play it; the playing playlist is outlined. The top
bar has ♥ (favourite the current song), shuffle, repeat (off → all → one) and the
output button, which opens **Play on**: tap a device (Mac, Apple TV, HomePod,
AirPods, TV…) to play only there, or ＋/− to add or drop speakers. The bottom
slider is Music's own volume.

Albums are played through a helper playlist named **EdgeDeck** (Music can't be
told to play an album directly), so it appears in Music's sidebar. The first
time, macOS asks to let EdgeDeck control Music; if you said no, the widget links
to System Settings › Privacy & Security › Automation. Music is never opened by
the widget unless you tap **Open Music**.

## AI Agents

`ai` shows your local AI coding agents live: every running **Claude Code** session
(in all profiles — `~/.claude` and any `~/.claude-*`, e.g. `.claude-work` /
`.claude-personal` used via `CLAUDE_CONFIG_DIR` aliases) and every **OpenCode**
session open in a terminal, each with its project, Claude profile or OpenCode
agent (build, plan…) and state — Thinking, the tool it's running (Bash, Edit…),
**Needs you** (waiting for a permission or an answer; outlined in orange),
Compacting, Error or Idle — and for how long. Tap a row to bring its
terminal forward. On top: each Claude profile's **5-hour and weekly plan limits**,
and OpenCode's tokens/replies today. **Show cost** (in the widget's editor, off by
default) adds each session's cost so far to its row — for Claude Code an estimate at
API prices (≈, connected profiles only), for OpenCode what it records — and today's
cost to OpenCode's row. Everything is read from files on this Mac.

Out of the box you get busy/idle (Claude Code's own session files) and OpenCode's
state from its local database. For plan usage and tool-level detail, tap
**Connect** on the widget (or tap the widget in edit mode) and **Connect** each
profile: EdgeDeck backs up its `settings.json`
(`settings.json.edgedeck-<time>.bak`), then adds hooks and wraps the statusline
through a small script (`~/Library/Application Support/EdgeDeck/bin/claude-bridge`)
that saves what Claude Code sends and runs your own statusline unchanged.
Running sessions pick up the hooks after a restart. **Disconnect** removes
exactly what was added and restores your statusline command.
**Connect** on the OpenCode card (OpenCode 2.x) adds one plugin,
`~/.config/opencode/plugins/edgedeck.ts`, which tells EdgeDeck when a session asks
for a permission or asks you a question; restart OpenCode to load it.
**Disconnect** deletes the file. OpenCode sessions are matched to the `opencode`
running in their folder, so with several open in one folder, **Go to session** may
pick the wrong tab unless they run `--standalone` with the plugin installed.
(`"ai": { "opencodeDatabase": "…" }` overrides OpenCode's database path.)

When a session **Needs you**, a Toast drops in on the Edge (whatever Page you're
on) with **Go to session**; it stays until the session moves on or you tap ✕.
**Bring to Edge** on the Toast moves that session's terminal tab (iTerm2 and Terminal;
other terminals: their front window) onto the Edge, and the strip on the right offers
**Yes / Always / No** — Claude Code's `1` / `2` / Esc, sent to that terminal only — so you
can answer without the Mac's keyboard or screen (handy when a KVM has them on another
Mac). Once it no longer needs you, the terminal goes back and the Edge returns to how it
was. While
a Guest app or the Edge player covers the Dashboard, an orange **Needs you** button
on the Rail stands in for it. Your terminal's own "needs your permission"
notification gets no second Toast. Turn it off in the widget's Connect view
(`"ai": { "toastOnNeedsYou": false }`). Claude Code profiles must be Connected.

### Several Claude Code profiles

Claude Code keeps everything (login, settings, history) in one config folder,
`~/.claude` by default. Setting `CLAUDE_CONFIG_DIR` points it at another one, so
you can keep separate profiles — e.g. work and personal accounts on one Mac:

```sh
# zsh / bash (~/.zshrc, ~/.bashrc)
alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias claude-personal='CLAUDE_CONFIG_DIR=~/.claude-personal claude'
```

```fish
# fish (~/.config/fish/config.fish)
alias claude-work 'CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias claude-personal 'CLAUDE_CONFIG_DIR=~/.claude-personal claude'
```

EdgeDeck finds profiles on its own:

- `~/.claude`, `~/.claude-*` and `~/.claude_*`, once Claude Code has run there
  (a folder with only a copied `settings.json` doesn't count);
- any other folder, the first time a session runs with `CLAUDE_CONFIG_DIR`
  pointing at it (it's remembered in `config.json`);
- **Add folder…** in the widget's Connect view (opens the folder picker on the
  Mac's own screen).

Profiles are named after their folder: `~/.claude` is *default*, `~/.claude-work`
is *work*, `~/dev/acme/claude` is *acme*. Each one is Connected on its own. **Hide**
takes one off the list (Disconnecting it first); hidden ones can be shown again
from the same view. In `config.json`:

```json
"ai": {
  "claudeDirs": ["~/dev/acme/claude"],
  "hiddenClaudeDirs": ["~/.claude-old"]
}
```

`claudeDirs` adds folders to the ones found automatically; `hiddenClaudeDirs`
hides profiles.

## Launcher buttons

In edit mode (**Edit**, bottom-left), tap a launcher to edit it by touch
(an empty launcher also shows **+ Add apps** outside edit mode). Tap the title at the top
to rename the launcher (**Save** / **Cancel**; empty shows "Launcher"). The top row shows its buttons
in order (drag to reorder, ✕ to remove, tap one to edit it, **+ New Button** for a blank one); below, every installed app (from the
Applications folders, plus Finder) — tap one to add or remove it. **Running**
narrows the list to open apps; page with ⌃⌄ / swipes or jump with the A–Z index.
**Controls** offers ready-made buttons (play/pause, previous/next, volume, mute,
brightness, screenshot, Spotlight, Mission Control, emoji, force quit, display
sleep, lock), and **Shortcuts** lists your Shortcuts.app shortcuts. A Control is
only a template: once added it's an ordinary button you can change.

Editing a button sets its **Action** (an app to Open or Bring to Edge, a URL, a
shortcut, keys, a shell command or AppleScript), title, colour and icon. **Save**
keeps the changes (**Add to Launcher** for a new button), **Cancel** drops them. The title and
icon follow the Action until you choose your own; **Icon only** clears the title.
**Record** captures a key combo from the Mac's keyboard (type combos macOS keeps for
itself, like `cmd+space`, in the field instead). Text is typed on the Mac's keyboard:
tapping a field lets the Edge take keystrokes until you leave the button (or tap
**Stop**). **Try** runs the Action and shows a script's exit status and output. On the
dashboard, a button whose Action fails flashes red. Everything can also be set in
`config.json`:

```json
{
  "type": "launcher",
  "title": "Apps",
  "frame": { "x": 21, "y": 0, "w": 9, "h": 2 },
  "buttons": [
    { "title": "Slack", "action": { "type": "openApp", "value": "com.tinyspeck.slackmacgap" } },
    { "title": "Bring Slack", "symbol": "rectangle.portrait.and.arrow.right", "color": "#BF5AF2",
      "action": { "type": "bringToEdge", "value": "Slack" } },
    { "title": "Mute", "symbol": "speaker.slash.fill", "action": { "type": "keys", "value": "mute" } }
  ]
}
```

| `action.type` | `value` |
| --- | --- |
| `openApp` | bundle id, app name or path |
| `bringToEdge` | same as `openApp`; opens the app and brings its window to the Edge as the Guest app |
| `openURL` | any URL, including app schemes (`slack://`, `raycast://`, …) |
| `shell` | command, run with `zsh -lc` |
| `shortcut` | name of a Shortcuts.app shortcut |
| `appleScript` | AppleScript source |
| `keys` | shortcut like `cmd+shift+4`, or a media key: `playpause`, `next`, `previous`, `volumeup`, `volumedown`, `mute`, `brightnessup`, `brightnessdown` |

`symbol` is any SF Symbol name; without it the app's icon (or one matching the
Action) is shown. `color` tints the button (any hex in `config.json`; the editor
offers ten swatches). An empty `title` shows only the icon. Buttons whose app isn't installed are dimmed and marked "Not installed".

## Notifications

```json
"notifications": {
  "bringToEdgeOnTap": ["Slack"],
  "ignoreApps": [],
  "maxItems": 30,
  "toastSeconds": 8
}
```

Names are the app names shown on macOS banners. Notifications are read from the
banners macOS displays, so apps silenced by Focus/Do Not Disturb, or set to
"None" in System Settings → Notifications, won't appear. If a banner has already
disappeared when you tap it, EdgeDeck activates the app instead; setting Slack's
alert style to **Persistent** keeps banners around so taps always open the
exact conversation.

## Display

```json
"display": { "match": "XENEON", "railWidth": 150 }
```

`match` is a substring of the display name; `railWidth` is the width of the
Rail beside a Guest app or the Edge player. Older names (`dockOnTap`,
`dockRailWidth`, `dockApp`, `zones`, `location`) are still read. Without a match EdgeDeck waits for
the Edge (see Show Preview above) rather than taking over another display.

## Debugging

`EDGEDECK_SNAPSHOT=/tmp/edge.png build/EdgeDeck.app/Contents/MacOS/EdgeDeck`
writes a PNG of the dashboard every 3 seconds.
`EDGEDECK_NO_EDGE=1` behaves as if the Edge were unplugged; add
`EDGEDECK_SNAPSHOT_PREVIEW=1` to open the preview and save it as `<path>-preview.png`.

## License

MIT — see [LICENSE](LICENSE).
