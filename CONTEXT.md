# EdgeDeck

A touch dashboard for the CORSAIR Xeneon Edge used as a second display on a Mac: paged widgets for system stats, notifications, apps, media, clocks and AI agents.

## Language

### Screen

**Edge**:
The physical Xeneon Edge touchscreen that EdgeDeck draws on.
_Avoid_: Second screen, touchbar, panel

**Dashboard**:
Everything EdgeDeck shows on the Edge when no Takeover is active: the current Page plus the Page dots.
_Avoid_: Panel, deck, home screen

**Page dots**:
The row of dots showing how many Pages there are and which one is current. The only Page indicator; Pages have no visible names.
_Avoid_: Page tabs, tab strip, page bar

**Takeover**:
A state in which something other than the Dashboard fills the Edge, with a Rail beside it. There are exactly two kinds: Guest app and Edge player. At most one is active at a time; a new Takeover replaces the current one, which is Sent back.
_Avoid_: Docked mode, overlay

**Guest app**:
A Takeover in which a real app window has been brought onto the Edge.
_Avoid_: Docked app, docked window

**Edge player**:
A Takeover in which EdgeDeck itself plays a video taken from a browser tab.
_Avoid_: Watch on Edge window, PiP

**Rail**:
The strip of controls beside a Takeover (e.g. Activate, Send back, Play/Pause, Close).
_Avoid_: Dock rail, sidebar

**Bring to Edge**:
The act of turning an app window into a Guest app. Its reverse is **Send back**.
_Avoid_: Dock, dock on tap, move to Edge

**Dock**:
Only the macOS Dock (e.g. Dock badges shown on Running apps). Never EdgeDeck's own behaviour.

### Layout

**Page**:
A grid of Widgets, identified by its position among the Pages; the Dashboard shows one Page at a time and Swipes between them.
_Avoid_: Screen, tab, view

**Widget**:
One placed instance of a Widget kind on a Page, with its own Frame and settings. A Page can hold several Widgets of the same kind.
_Avoid_: Tile, card

**Widget kind**:
The type of a Widget (Clock, Weather, Calendar, Launcher, …). The Add Widget palette lists kinds.
_Avoid_: Widget type, widget (when meaning the kind)

**Frame**:
A Widget's position and size on its Page's grid, in whole cells.
_Avoid_: Slot, rect, bounds

**Editor**:
A full-screen Edit-mode screen for configuring one Widget (e.g. the City editor, the Launcher editor), opened by Tapping that Widget in Edit mode.
_Avoid_: Picker, settings sheet

**Widget palette**:
The Edit-mode list of Widget kinds to add to a Page.
_Avoid_: Add Widget menu, editor

**Edit mode**:
The Dashboard state in which Widgets and Pages are moved, resized, added, removed and configured. Configuration UI belongs here, not on Widgets in normal use.
_Avoid_: Layout mode, settings

### Input

**Tap**:
A brief touch, delivered as a click.
_Avoid_: Click, press

**Swipe**:
A quick horizontal or vertical finger movement; changes Page or scrolls a list.
_Avoid_: Scroll, flick, drag

**Long-press**:
A touch held in place, which opens extra choices (e.g. a Running app's menu).
_Avoid_: Right-click, press and hold, context click

**Hold-drag**:
A touch held, then moved; used to move and resize Widgets in Edit mode.
_Avoid_: Drag (alone), long-drag

### Apps

**Running app**:
An app that would appear in the macOS Dock.
_Avoid_: Process, open app

**Badge**:
The count a Running app shows on its macOS Dock icon, mirrored by EdgeDeck.
_Avoid_: Counter, unread count

**Activate**:
Bringing a Guest app's window forward to receive keyboard input. "Focus" is reserved for macOS Focus modes.
_Avoid_: Focus

### Launching

**Launcher**:
A Widget kind holding a list of Buttons.
_Avoid_: App grid, shortcut bar

**Button**:
A tappable entry in a Launcher with one Action, an icon, an optional colour and an optional title. A Button with no title shows only its icon.
_Avoid_: Shortcut, key, launcher item

**Action**:
Something EdgeDeck can do on the user's behalf (open an app or URL, run a shortcut or script, send keys, Bring to Edge). Buttons perform Actions, but so can notification taps and Running-app menus.
_Avoid_: Command, task

**Control**:
A predefined Button offered in the Launcher editor (volume, media keys, etc.). Only a template: adding one copies it into an ordinary Button with no link back, which can then be edited like any other. Not a separate concept from Button.
_Avoid_: Preset (as a user-facing term)

### Notifications

**Notification**:
EdgeDeck's mirror of one macOS notification, as listed by the Notifications Widget.
_Avoid_: Alert, banner (for the mirror)

**Toast**:
The brief pop-up on the Edge announcing a new Notification.
_Avoid_: Banner, popup

**Banner**:
Only Apple's original notification on the main screen, which EdgeDeck reads and presses.

### Media

**Media source**:
The app currently producing what Now Playing shows (a browser, Music, Spotify, …).
_Avoid_: Player, source app

**Now Playing**:
The Widget kind showing and controlling whatever any Media source is playing.
_Avoid_: Media widget

**Music**:
The Widget kind for browsing and playing the Music.app library. Separate from Now Playing on purpose.
_Avoid_: Library widget

### Places

**City**:
A named place with a time zone and coordinates. World Clock shows Cities and Weather forecasts a City.
_Avoid_: Zone, clock zone, location

**Local**:
A special City that always means wherever the Mac currently is (its current time zone). Any other City is fixed. A Weather Widget with no City chosen forecasts Local.
_Avoid_: Home, current city, my time zone

**World Clock**:
The only clock Widget kind: the current time in one or more Cities, including the local one.
_Avoid_: Clock (as a separate kind)

### AI agents

**Agent tool**:
A coding-agent program EdgeDeck watches, e.g. Claude Code or OpenCode.
_Avoid_: Agent, AI, provider

**Profile**:
One configuration of an Agent tool with its own state directory (Claude Code: `~/.claude`, `~/.claude-work`, …). OpenCode has exactly one implicit Profile.
_Avoid_: Account, config dir

**Session**:
One running conversation of an Agent tool within a Profile, which is either busy or idle. It exists only while its process is alive; there is no "ended" state.
_Avoid_: Agent, process, chat

**Connect**:
Installing EdgeDeck's bridge into one Profile so it reports events and rate limits. Its reverse is **Disconnect**.
_Avoid_: Setup, install, link

## Relationships

- The **Dashboard** has **Page dots** and one or more **Pages**; each **Page** has zero or more **Widgets**, each with exactly one **Widget kind** and one **Frame**.
- A **Takeover** replaces the **Dashboard** on the **Edge** and owns the **Rail**; it is either a **Guest app** or an **Edge player**.
- A **Launcher** has many **Buttons**; each **Button** has one **Action**.
- An **Agent tool** has one or more **Profiles**; a **Profile** has zero or more **Sessions**.
