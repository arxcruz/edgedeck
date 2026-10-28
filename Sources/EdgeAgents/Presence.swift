import Foundation

/// What EdgeDeck asks the system about processes. The app passes the real lookups; tests pass fakes.
public struct ProcessProbe {
    public var isAlive: (Int32) -> Bool
    public var name: (Int32) -> String
    public var hasTerminal: (Int32) -> Bool
    public var workingDirectory: (Int32) -> String?
    public var pids: (String) -> [Int32]

    public init(isAlive: @escaping (Int32) -> Bool, name: @escaping (Int32) -> String, hasTerminal: @escaping (Int32) -> Bool,
                workingDirectory: @escaping (Int32) -> String?, pids: @escaping (String) -> [Int32]) {
        self.isAlive = isAlive
        self.name = name
        self.hasTerminal = hasTerminal
        self.workingDirectory = workingDirectory
        self.pids = pids
    }
}

public enum AgentKind: String, CaseIterable, Sendable {
    case codex, antigravity

    /// Parts of the process name the agent's command line runs under.
    public var processNames: [String] {
        switch self {
        case .codex: ["codex"]
        case .antigravity: ["agy", "antigravity", "antigravity-cli"]
        }
    }
}

public enum HookState: Equatable, Sendable {
    case idle, thinking
    case running(String)
    case needsYou(String?)
}

extension AgentEvent {
    public var state: HookState {
        switch event {
        case "Stop", "Interrupt": .idle
        case "PermissionRequest": .needsYou(tool)
        case "PreToolUse": .running(tool ?? "")
        default: .thinking
        }
    }
}

/// Decides whether a conversation seen in the agent's files is still a live session.
public enum AgentPresence {
    /// A conversation with no sign of life for this long is not shown, when only the desktop app could own it.
    public static let desktopGrace: TimeInterval = 300

    /// The terminal process running the conversation, when there is one.
    public struct Found: Equatable, Sendable {
        public let pid: Int32?
    }

    /// Nil when the conversation is over. A hook event is alive when the process that sent it still runs the
    /// agent in a terminal, when a terminal process of the agent is in the event's folder, or, for the
    /// desktop app, when the app runs and the event is recent. A sender with no terminal doesn't count by
    /// itself: Codex's background server outlives the app and would keep every conversation alive.
    public static func resolve(_ event: AgentEvent, kind: AgentKind, desktopAppRunning: Bool,
                               probe: ProcessProbe, now: Date) -> Found? {
        let owner = event.pid.flatMap { candidate -> Int32? in
            guard probe.isAlive(candidate) else { return nil }
            let name = probe.name(candidate).lowercased()
            return kind.processNames.contains(where: name.contains) ? candidate : nil
        }
        // Without the sender's pid, look for the agent in a terminal started in the event's folder.
        let pid = owner.flatMap { probe.hasTerminal($0) ? $0 : nil } ??
            (event.pid == nil ? kind.processNames.flatMap(probe.pids).first {
                probe.hasTerminal($0) && probe.workingDirectory($0) == event.cwd
            } : nil)
        let desktopAlive = kind == .codex ? desktopAppRunning
            : (!event.transcript.contains("/antigravity-cli/") && desktopAppRunning)
        guard pid != nil || (desktopAlive && now.timeIntervalSince(event.date) < desktopGrace) else { return nil }
        return Found(pid: pid)
    }

    /// The same for a Codex rollout file with no hook event: alive when the desktop app runs or a Codex
    /// terminal process is in its folder, and the rollout changed recently.
    public static func resolve(_ rollout: CodexRollout, desktopAppRunning: Bool, probe: ProcessProbe, now: Date) -> Found? {
        guard now.timeIntervalSince(rollout.updated) < desktopGrace else { return nil }
        let cliPID = probe.pids("codex").first { probe.hasTerminal($0) && probe.workingDirectory($0) == rollout.cwd }
        guard desktopAppRunning || cliPID != nil else { return nil }
        return Found(pid: cliPID)
    }
}
