# Codex and Antigravity in AI Agents

## Scope

The AI Agents widget covers Codex CLI, Codex desktop, and Google Antigravity App, IDE, and CLI. Each active conversation is one Session, including when several conversations share one desktop process. Views of the same conversation are deduplicated only when their identities match confidently.

Each Session shows its project, state, elapsed time, and a tap target. Tapping opens the exact conversation when a supported target exists; otherwise it activates the owning app. A usage summary appears only when trustworthy local data is available.

## State and lifetime

Busy means the agent is working; Idle means it waits for a new prompt. Needs you requires a reliable pending user decision. Only Needs you raises a Toast. In particular, a pre-tool event alone is not a permission request.

A desktop Session appears once activity begins and remains visible until a reliable end event or app closure. If neither signal exists, five minutes without an agent event expires the Session. A CLI Session ends when its owning process ends. A conversation retained only as history is not a live Session.

## Connect

Connect installs EdgeDeck hooks only where needed for live state. It preserves other hooks and settings. Disconnect removes only EdgeDeck's additions. An incompatible existing configuration is reported rather than overwritten. Both actions must be reversible and profile aware where the tool supports multiple configurations.

## Implementation notes

Codex documents lifecycle and permission hooks, including `PermissionRequest`; its local rollout files provide conversation metadata. Antigravity documents `SessionStart`, `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, and `Stop`, with conversation IDs and workspace paths. It does not document a dedicated permission-request event, so the Antigravity adapter must not infer Needs you from a tool hook. Antigravity's App, IDE, and CLI have separate data directories. Hook adapters must store only the metadata needed for live Sessions and must not forward transcript content.

References: [Codex hooks](https://developers.openai.com/de-DE/docs/hooks), [Antigravity hooks](https://antigravity.google/docs/hooks).
