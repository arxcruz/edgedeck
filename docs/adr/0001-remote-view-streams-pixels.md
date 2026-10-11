# Remote view streams pixels, not Widget data

To show another Mac's Dashboard on the Edge, the Source draws its own Dashboard in a hidden 2560×720 window and streams it as video to the Host, which sends touches back. We chose this over sending Widget data and drawing it on the Host, because every Widget kind and every Editor then works remotely for free, with no per-kind protocol and no need to keep the two Macs' Widget code in sync beyond a version check. The cost is bandwidth, a little latency, and that the Host can't restyle or mix the Source's content.

## Consequences

- Only the Dashboard is streamed: no Takeovers start from a Remote view, so no real app windows from the Source reach the Host (and no private virtual-display API is needed, as long as a hidden window can be captured with its Core Animation content live).
- Mixing Widgets from both Macs on one Dashboard, or showing the other Mac's Toasts, would need a separate data channel; that was deliberately left for later.
- Capture stops while the Source's display sleeps, so a Source keeps its display awake while a Host is watching (and only then).
