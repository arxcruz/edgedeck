# EdgeDeck

A touch dashboard for the CORSAIR Xeneon Edge used as a second display on a Mac: paged widgets for system stats, notifications, apps, media, clocks and AI agents.

## Language

### Screen

**Edge**:
The physical Xeneon Edge touchscreen that EdgeDeck draws on.
_Avoid_: Second screen, touchbar, panel

**Touch support**:
EdgeDeck holding the Edge's touchscreen and turning touches into input. It comes back by itself whenever the Edge is replugged; the user never has to restart it.
_Avoid_: Touch enabled, touch active

**Dashboard**:
Everything EdgeDeck shows on the Edge when no Takeover is active: the current Page plus the Page dots.
_Avoid_: Panel, deck, home screen

**Plain display**:
The state in which the Dashboard is off and the Edge is used as a normal monitor; touch still works on whatever window is there, and a swipe in from the right edge brings the Dashboard back. Bringing something to the Edge ends it.
_Avoid_: Hidden mode, monitor mode, dashboard off

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
A touch held in place, which opens extra choices (e.g. a Running app's menu) as soon as the hold is long enough, while the finger is still down.
_Avoid_: Right-click, press and hold, context click

**Drag**:
A touch moved while held down on something that moves with it; in Edit mode it moves and resizes Widgets straight away. In other apps' windows on the Edge the finger must rest first (about half a second), or the movement is a Swipe.
_Avoid_: Hold-drag, long-drag

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
The brief pop-up on the Edge announcing something that wants the user: a new Notification, a Session that Needs you, or a Timer or Pomodoro that is Ringing.
_Avoid_: Banner, popup, agent alert

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

### Timing

**Timer**:
A Widget kind running one countdown. Several Timers means several Widgets. It counts down only; it has no stopwatch.
_Avoid_: Countdown widget, alarm, stopwatch

**Ringing**:
The state of a Timer or Pomodoro whose countdown has run out: it pulses, plays its sound and raises a Toast (or a Rail button during a Takeover) until the user Taps it. Tapping a Ringing Pomodoro starts its next phase.
_Avoid_: Done, finished, expired, alarm

**Pomodoro**:
A Widget kind that takes the user through Rounds of Work and Break, counting each phase down like a Timer.
_Avoid_: Focus timer, Pomodoro timer (as a kind name)

**Work**:
The Pomodoro phase for concentrating. "Focus" is reserved for macOS Focus modes.
_Avoid_: Focus, focus session, pomodoro session

**Break**:
The Pomodoro phase for resting after Work. The Break after a Cycle's last Work is the long one; there is no separate "long break" concept.
_Avoid_: Rest, pause

**Round**:
One Work followed by its Break.
_Avoid_: Pomodoro (for one unit), session, interval

**Cycle**:
The set of Rounds that ends with the long Break, after which the Pomodoro starts again at its first Round.
_Avoid_: Set, session

### AI agents

**Agent tool**:
A coding-agent program EdgeDeck watches, e.g. Claude Code or OpenCode.
_Avoid_: Agent, AI, provider

**Profile**:
One configuration of an Agent tool with its own state directory (Claude Code: `~/.claude`, `~/.claude-work`, or any folder named by `CLAUDE_CONFIG_DIR`). A folder only counts once the Agent tool has run there; Profiles are found on their own (home folder, running Sessions) or added by the user, and can be hidden. OpenCode has exactly one implicit Profile.
_Avoid_: Account, config dir

**Session**:
One running conversation of an Agent tool within a Profile, which is always Busy, Idle or Needs you. It exists only while its process is alive; there is no "ended" state.
_Avoid_: Agent, process, chat

**OpenCode agent**:
The OpenCode agent a Session is currently using (e.g. build, plan, or a custom one). A detail of the Session that can change mid-Session; never a Profile.
_Avoid_: Profile, mode

**Busy**:
A Session working on its own (thinking, running a tool, compacting).
_Avoid_: Working, running (as the state name)

**Idle**:
A Session waiting for a new prompt, including one that stopped on an error.
_Avoid_: Done, finished, stopped

**Needs you**:
A Session blocked until the user answers it (e.g. approves a tool). The only Session state that raises a Toast.
_Avoid_: Waiting, blocked, pending permission

**Connect**:
Installing EdgeDeck's bridge into one Profile so it reports events (and, for Claude Code, rate limits). Without it EdgeDeck still sees Sessions, but cannot tell when one Needs you. Its reverse is **Disconnect**.
_Avoid_: Setup, install, link

### Two Macs

**Host**:
The Mac the Edge is physically plugged into. It receives touch and draws whatever is on the Edge.
_Avoid_: Server, client, local Mac, Edge Mac

**Source**:
The Mac whose Dashboard is on the Edge. Normally the Host itself; after switching, the other Mac. Either Mac can be Host or Source.
_Avoid_: Remote, server, sender

**Remote view**:
The state in which the Edge shows another Mac's Dashboard (the Source is not the Host). Only the Dashboard comes across: no Takeovers start from a Remote view, and Actions happen on the Source. A Takeover on the Host, or Plain display, ends it.
_Avoid_: AirPlay, mirroring, streaming mode, remote mode

**Pair**:
Introducing two Macs to each other once, with a code shown on the Edge, so they can later switch Sources securely.
_Avoid_: Link, trust, connect (Connect is for Profiles)

**Grab the keyboard**:
The Host, at the user's request from the Rail, makes a Paired Mac's keyboard type only on the Host, so a Guest app on the Edge can be typed into while the user sits at the other Mac. Its reverse is **Release**, which also happens on its own when the Guest app goes, when the link between the Macs goes quiet, or with the other Mac's **Take Back Keyboard** shortcut.
_Avoid_: Lend, capture, share the keyboard, keyboard forwarding

## Relationships

- The **Dashboard** has **Page dots** and one or more **Pages**; each **Page** has zero or more **Widgets**, each with exactly one **Widget kind** and one **Frame**.
- A **Takeover** replaces the **Dashboard** on the **Edge** and owns the **Rail**; it is either a **Guest app** or an **Edge player**.
- A **Launcher** has many **Buttons**; each **Button** has one **Action**.
- A **Timer** or **Pomodoro** runs one countdown at a time and can have a title; a **Toast** lists every Widget that is **Ringing**.
- A **Pomodoro** goes through **Cycles**; a **Cycle** has one or more **Rounds**; a **Round** is one **Work** then one **Break**. Neither phase starts until the user Taps.
- An **Agent tool** has one or more **Profiles**; a **Profile** has zero or more **Sessions**.
- The **Edge** has one **Host** and shows one **Source** at a time; when they differ, it is a **Remote view**. Only **Paired** Macs can be a **Source** for each other.
- The **Host** can **Grab the keyboard** of one **Paired** Mac at a time, only while a **Guest app** is on the Edge.
