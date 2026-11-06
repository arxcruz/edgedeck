# Edge off disables the display instead of covering it

To turn the Edge off, EdgeDeck disables it as a display with the private CoreGraphics call `CGSConfigureDisplayEnabled`, confined to `PrivateDisplayModes.swift` beside the mode calls of ADR 0002. macOS then treats the Edge as unplugged, the monitor sees no signal and puts its backlight out. Turning it on enables the display again, and Native mode puts it back in 2560×720.

We chose this over a full-screen black window (no private API, but an LCD that is only showing black still glows in a dark room, which is the thing to avoid) and over `pmset displaysleepnow` (sleeps every display, and any touch or key wakes it). The cost is the same as ADR 0002: a future macOS may change or remove the call. If it goes missing, the menu says "Couldn't turn the Edge off" and the Edge stays on; nothing else breaks. A disabled display also leaves macOS's screen list, so EdgeDeck must remember that the Edge is off, or it would take it for unplugged.
