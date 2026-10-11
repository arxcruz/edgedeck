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
open build/EdgeDeck.app
```

On first launch macOS asks for **Accessibility** access (System Settings →
Privacy & Security → Accessibility → EdgeDeck). It's needed to read
Notification Center, move windows and send key presses.

The build is ad-hoc signed, so macOS treats every rebuild as a new app and you
have to re-enable Accessibility after rebuilding. To avoid that, sign with a
stable identity: `SIGN_IDENTITY="Your Cert Name" ./scripts/build.sh`.

The menu bar icon has Edit Layout, Open config.json, Reload, Send Back Guest App
and Quit.

## Pages & layout

The dashboard can have several pages. **Swipe left/right** anywhere on the Edge
to change page; dots at the bottom show which page you're on (hidden when
there's only one). Pages have no names. The menu bar macOS draws on the Edge is
always covered by a blank strip. Lists inside
widgets (notifications, launcher pages) use **vertical** swipes.

Swipes work both as mouse drags and as scroll gestures. Touch drivers such as
Edgetap, and trackpads, send a finger swipe as phased scroll events, which
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

In edit mode, tap **✎ Cities** on the widget to pick cities by touch: toggle **Local**, choose a region, page through
the cities (or jump with the A–Z index) and tap to add or remove. Selected
cities appear at the top, where ‹ moves one earlier and ✕ removes it. In
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

The location defaults to Local, the city of the Mac's current time zone. Set another per widget —
by name (looked up automatically) or by coordinates:

```json
{ "type": "weather", "location": { "name": "São Paulo" } }
{ "type": "weather", "location": { "name": "Home", "latitude": 52.52, "longitude": 13.40 } }
```

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
`.claude-personal` used via `CLAUDE_CONFIG_DIR` aliases) and recent **OpenCode**
sessions, each with its project, profile and state — Thinking, the tool it's
running (Bash, Edit…), **Needs you** (waiting for a permission; outlined in
orange), Compacting, Error or Idle — and for how long. Tap a row to bring its
terminal forward. On top: each Claude profile's **5-hour and weekly plan limits**,
and OpenCode's tokens/replies today. Everything is read from files on this Mac.

Out of the box you get busy/idle (Claude Code's own session files) and full
OpenCode state (its local database). For plan usage and tool-level detail, tap
**Connect** on the widget (or **✎ Connect** in edit mode) and **Connect** each
profile: EdgeDeck backs up its `settings.json`
(`settings.json.edgedeck-<time>.bak`), then adds hooks and wraps the statusline
through a small script (`~/Library/Application Support/EdgeDeck/bin/claude-bridge`)
that saves what Claude Code sends and runs your own statusline unchanged.
Running sessions pick up the hooks after a restart. **Disconnect** removes
exactly what was added and restores your statusline command. To list profiles
yourself: `"ai": { "claudeDirs": ["~/.claude-work"] }` in `config.json`
(`opencodeDatabase` overrides OpenCode's database path).

## Launcher buttons

In edit mode (**Edit**, bottom-left), tap **✎ Apps** on a launcher to edit it by touch
(an empty launcher also shows **+ Add apps** outside edit mode). The top row shows its buttons
in order (‹ › to move, ✕ to remove); below, every installed app (from the
Applications folders, plus Finder) — tap one to add or remove it. **Running**
narrows the list to open apps; page with ⌃⌄ / swipes or jump with the A–Z index.
**Controls** offers ready-made buttons (play/pause, previous/next, volume, mute,
brightness, screenshot, Spotlight, Mission Control, emoji, force quit, display
sleep, lock), and **Shortcuts** lists your Shortcuts.app shortcuts. Anything
else (custom key combos, URLs, scripts) is added in `config.json`:

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

`symbol` is any SF Symbol name; without it the app's icon is shown. `color` tints
the button. Buttons whose app isn't installed are dimmed and marked "Not installed".

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
`dockRailWidth`, `dockApp`, `zones`) are still read. Without a match EdgeDeck uses the
smallest secondary display, or shows a preview strip on the main display.

## Debugging

`EDGEDECK_SNAPSHOT=/tmp/edge.png build/EdgeDeck.app/Contents/MacOS/EdgeDeck`
writes a PNG of the dashboard every 3 seconds.

## License

MIT — see [LICENSE](LICENSE).
