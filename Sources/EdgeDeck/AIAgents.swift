import AppKit
import SQLite3

// Live state of local AI coding agents — Claude Code (every profile / CLAUDE_CONFIG_DIR)
// and OpenCode — read from files they keep on disk, plus what EdgeDeck's own bridges
// (Connect) write there. Nothing leaves the Mac.

enum AgentState: Equatable {
    case idle
    case thinking
    case running(String)
    case needsYou(String?)
    case compacting
    case error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .running(let tool): tool.isEmpty ? "Working" : tool
        case .needsYou: "Needs you"
        case .compacting: "Compacting"
        case .error: "Error"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "moon.zzz.fill"
        case .thinking: "brain.head.profile"
        case .running: "hammer.fill"
        case .needsYou: "hand.raised.fill"
        case .compacting: "arrow.down.right.and.arrow.up.left"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var color: String {
        switch self {
        case .idle: "#8E8E93"
        case .thinking: "#BF5AF2"
        case .running: "#5E9EFF"
        case .needsYou: "#FF9F0A"
        case .compacting: "#64D2FF"
        case .error: "#FF453A"
        }
    }

    var isActive: Bool { self != .idle }
    var needsYou: Bool { if case .needsYou = self { true } else { false } }
}

struct AgentSession: Identifiable, Equatable {
    enum Tool: String { case claude, opencode, codex, antigravity }

    let id: String
    let tool: Tool
    /// Claude profile ("work", "personal"); OpenCode has just the one, so nil.
    let profile: String?
    let project: String
    let title: String?
    let state: AgentState
    let since: Date
    /// Process to bring forward (its terminal) when tapped.
    let pid: pid_t?
    /// Context window use, 0…100, when known.
    let contextPercent: Double?
    /// OpenCode agent the Session is using (build, plan, …); can change mid-Session.
    var agent: String? = nil
    /// Cost so far in USD, when known. Claude's is an API-price estimate (Connected Profiles only).
    var cost: Double? = nil
}

struct ClaudeUsage: Equatable {
    let profile: String
    let fiveHour: Double?
    let fiveHourResets: Date?
    let sevenDay: Double?
    let sevenDayResets: Date?
    let updated: Date
}

struct OpenCodeUsage: Equatable {
    let tokens: Int
    let cost: Double
    let messages: Int
}

// MARK: Claude profiles and Connect

struct ClaudeProfile: Identifiable, Hashable {
    let directory: URL
    /// "default", "work", "acme"… Unique among the Profiles shown (see `discover`).
    var name: String

    init(directory: URL, name: String? = nil) {
        self.directory = directory.standardizedFileURL
        self.name = name ?? Self.baseName(self.directory)
    }

    var id: String { directory.path }
    /// Names EdgeDeck's own files for this Profile: the path from the home folder, e.g.
    /// "claude", "claude-work", "dev-acme-claude". The bridge in settings.json carries it.
    var key: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        var parts = directory.pathComponents
        if parts.starts(with: home) { parts.removeFirst(home.count) } else { parts.removeFirst() }
        return parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .replacingOccurrences(of: " ", with: "_")
    }
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    var sessionsDirectory: URL { directory.appendingPathComponent("sessions") }
    /// Where the bridge writes for this profile.
    var dataDirectory: URL { ClaudeConnection.dataRoot.appendingPathComponent(key, isDirectory: true) }
    /// The folder as config.json stores it, e.g. "~/.claude-work".
    var configPath: String { Self.configPath(directory) }

    /// "~/.claude" is "default", "~/.claude-work" is "work"; a folder called just "claude"
    /// elsewhere takes its parent's name ("~/dev/acme/claude" is "acme").
    private static func baseName(_ directory: URL) -> String {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let last = trimmed(directory.lastPathComponent)
        for prefix in ["claude-", "claude_", "claude."] where last.hasPrefix(prefix) && last.count > prefix.count {
            return String(last.dropFirst(prefix.count))
        }
        guard last == "claude" else { return last }
        if directory == home.appendingPathComponent(".claude").standardizedFileURL { return "default" }
        let parent = trimmed(directory.deletingLastPathComponent().lastPathComponent)
        return parent.isEmpty ? last : parent
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func configPath(_ directory: URL) -> String {
        (directory.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    static func url(fromConfig path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// Every Profile: ~/.claude, ~/.claude-* and ~/.claude_* that Claude Code has actually run
    /// in (a copied settings.json alone doesn't count), plus `extra` folders that exist (added
    /// by hand or learned from running Sessions). Returns the shown and the hidden ones.
    static func discover(extra: [String], hidden: [String]) -> (shown: [ClaudeProfile], hidden: [ClaudeProfile]) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        let found = names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") || $0.hasPrefix(".claude_") }
            .map { home.appendingPathComponent($0, isDirectory: true).standardizedFileURL }
            .filter { dir in ["projects", "sessions", ".claude.json"].contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) } }
            .sorted { ($0.lastPathComponent == ".claude" ? 0 : 1, $0.path) < ($1.lastPathComponent == ".claude" ? 0 : 1, $1.path) }
        var dirs: [URL] = []
        for dir in found + extra.map(url(fromConfig:)) where !dirs.contains(dir) {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue { dirs.append(dir) }
        }
        let hiddenDirs = Set(hidden.map(url(fromConfig:)))
        var profiles = dirs.map { ClaudeProfile(directory: $0) }
        // Two "work"s: tell them apart by their parent folders.
        let clashing = Set(Dictionary(grouping: profiles, by: \.name).filter { $0.value.count > 1 }.keys)
        for index in profiles.indices where clashing.contains(profiles[index].name) {
            let parent = profiles[index].directory.deletingLastPathComponent().lastPathComponent
            profiles[index].name = "\(parent.trimmingCharacters(in: CharacterSet(charactersIn: ".")))/\(profiles[index].name)"
        }
        return (profiles.filter { !hiddenDirs.contains($0.directory) }, profiles.filter { hiddenDirs.contains($0.directory) })
    }
}

/// Installs / checks / removes EdgeDeck's statusline and hook entries in a profile's
/// settings.json. Every hook and the statusline go through one small shell script that
/// saves what Claude Code sends, then (for the statusline) runs the user's own command,
/// so their statusline keeps working unchanged.
enum ClaudeConnection {
    static let dataRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EdgeDeck/claude", isDirectory: true)
    static let bridgeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EdgeDeck/bin/claude-bridge")
    static let marker = "EdgeDeck/bin/claude-bridge"

    static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                             "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
                             "PreCompact", "SessionEnd"]
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

    static let bridgeScript = #"""
    #!/bin/sh
    # EdgeDeck bridge for Claude Code — installed by EdgeDeck (AI Agents widget).
    # Saves what Claude Code sends to hooks / the statusline into
    # ~/Library/Application Support/EdgeDeck/claude/<profile>/ for the widget, then
    # runs your original statusline command (if any) so its output is unchanged.
    # Never prints anything for hooks and always exits 0, so it can't affect Claude.
    mode="$1"; key="$2"
    out="$HOME/Library/Application Support/EdgeDeck/claude/$key"
    mkdir -p "$out" 2>/dev/null
    case "$mode" in
    hook)
        line=$(tr -d '\n')
        printf '{"ts":%s,"event":%s}\n' "$(date +%s)" "${line:-null}" >> "$out/events.jsonl" 2>/dev/null
        ;;
    statusline)
        input=$(cat)
        printf '%s' "$input" > "$out/statusline.tmp.$$" 2>/dev/null && mv -f "$out/statusline.tmp.$$" "$out/statusline.json" 2>/dev/null
        if [ -n "$3" ]; then printf '%s' "$input" | sh -c "$3"; fi
        ;;
    esac
    exit 0
    """#

    struct Status: Equatable {
        var statusline: Bool
        var hooks: Bool
        var settingsExists: Bool
        var connected: Bool { statusline && hooks }
    }

    static func status(_ profile: ClaudeProfile) -> Status {
        guard let settings = readSettings(profile) else { return Status(statusline: false, hooks: false, settingsExists: false) }
        let statusline = ((settings["statusLine"] as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
        let hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        let allHooks = hookEvents.allSatisfy { event in hasOurHook(hooks[event]) }
        return Status(statusline: statusline, hooks: allHooks, settingsExists: true)
    }

    /// Adds whatever is missing. Backs settings.json up first; returns a message for the UI.
    @discardableResult
    static func connect(_ profile: ClaudeProfile) throws -> String {
        try installBridge()
        var settings = readSettings(profile) ?? [:]
        let original = settings
        let q = shellQuote(bridgeURL.path)

        // Statusline: wrap the existing command, if any.
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        let current = statusLine["command"] as? String ?? ""
        if !current.contains(marker) {
            var command = "\(q) statusline \(shellQuote(profile.key))"
            if !current.isEmpty { command += " \(shellQuote(current))" }
            statusLine["type"] = "command"
            statusLine["command"] = command
            settings["statusLine"] = statusLine
        }

        // Hooks: one extra entry per event, next to whatever is already there.
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in hookEvents where !hasOurHook(hooks[event]) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var group: [String: Any] = ["hooks": [["type": "command", "command": "\(q) hook \(shellQuote(profile.key))", "timeout": 5]]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        guard !NSDictionary(dictionary: settings).isEqual(to: original) else { return "Already connected" }
        try backup(profile)
        try writeSettings(settings, profile)
        return "Connected — restart running \(profile.name) sessions to pick up the hooks"
    }

    /// Removes EdgeDeck's entries and restores the original statusline command.
    @discardableResult
    static func disconnect(_ profile: ClaudeProfile) throws -> String {
        guard var settings = readSettings(profile) else { return "Nothing to remove" }
        let original = settings
        if var statusLine = settings["statusLine"] as? [String: Any], let command = statusLine["command"] as? String, command.contains(marker) {
            // The original command is the wrapper's 4th shell word: '<bridge>' statusline '<key>' '<original>'.
            let words = shellWords(command)
            let saved = words.count >= 4 ? words[3] : ""
            if saved.isEmpty {
                settings.removeValue(forKey: "statusLine")
            } else {
                statusLine["command"] = saved
                settings["statusLine"] = statusLine
            }
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var groups = value as? [[String: Any]] else { continue }
                groups = groups.compactMap { group in
                    var group = group
                    let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                    if kept.isEmpty { return nil }
                    group["hooks"] = kept
                    return group
                }
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        guard !NSDictionary(dictionary: settings).isEqual(to: original) else { return "Nothing to remove" }
        try backup(profile)
        try writeSettings(settings, profile)
        return "Disconnected \(profile.name)"
    }

    // MARK: Helpers

    private static func hasOurHook(_ value: Any?) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) ?? false }
        }
    }

    private static func installBridge() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bridgeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? String(contentsOf: bridgeURL, encoding: .utf8)) != bridgeScript {
            try bridgeScript.write(to: bridgeURL, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeURL.path)
    }

    private static func readSettings(_ profile: ClaudeProfile) -> [String: Any]? {
        guard let data = try? Data(contentsOf: profile.settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any], _ profile: ClaudeProfile) throws {
        try FileManager.default.createDirectory(at: profile.dataDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: profile.settingsURL, options: .atomic)
    }

    private static func backup(_ profile: ClaudeProfile) throws {
        try FileManager.default.createDirectory(at: profile.dataDirectory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: profile.settingsURL.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let target = profile.directory.appendingPathComponent("settings.json.edgedeck-\(stamp).bak")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: profile.settingsURL, to: target)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Splits a command made of `shellQuote`d words (plus bare words) back into words.
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = [], current = "", inQuote = false, hasWord = false
        var chars = command.makeIterator()
        while let c = chars.next() {
            if inQuote {
                if c == "'" { inQuote = false } else { current.append(c) }
            } else if c == "'" {
                inQuote = true
                hasWord = true
            } else if c == "\\", let next = chars.next() {
                current.append(next)
                hasWord = true
            } else if c == " " {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(c)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }
}

/// Installs / checks / removes EdgeDeck's plugin in OpenCode's global plugins folder. The plugin
/// appends the events that say a Session needs you (a permission ask or a question) to a file
/// the widget watches. OpenCode has one implicit Profile, so there's one plugin.
enum OpenCodeConnection {
    static let pluginURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/plugins/edgedeck.ts")
    static let eventsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EdgeDeck/opencode/events.jsonl")

    /// OpenCode 2.x plugin: a default export with an id and a setup function.
    static let plugin = #"""
    // EdgeDeck bridge for OpenCode — installed by EdgeDeck (AI Agents widget); Disconnect removes it.
    // Appends the events that tell a Session needs you (a permission ask or a question) to
    // ~/Library/Application Support/EdgeDeck/opencode/events.jsonl. Nothing leaves this Mac.
    import { appendFileSync, mkdirSync } from "node:fs";
    import { homedir } from "node:os";
    import { join } from "node:path";

    const dir = join(homedir(), "Library/Application Support/EdgeDeck/opencode");
    const file = join(dir, "events.jsonl");
    const wanted = new Set([
      "permission.asked", "permission.replied", "form.created", "form.replied", "form.cancelled",
      "session.execution.started", "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted",
    ]);

    export default {
      id: "edgedeck",
      setup: async (api: any) => {
        (async () => {
          try {
            mkdirSync(dir, { recursive: true });
            for await (const event of api.event.subscribe()) {
              if (!wanted.has(event?.type)) continue;
              const data = event.data ?? {};
              const form = data.form ?? {};
              const line = {
                ts: Date.now() / 1000, pid: process.pid, type: event.type,
                session: data.sessionID ?? form.sessionID, id: data.id ?? data.requestID ?? form.id, action: data.action,
              };
              try { appendFileSync(file, JSON.stringify(line) + "\n"); } catch {}
            }
          } catch {}
        })();
      },
    };

    """#

    enum Status: Equatable {
        case notInstalled
        /// Ours, but from an older EdgeDeck.
        case outdated
        case connected
    }

    /// OpenCode has been used on this Mac (its config folder or database exists).
    static func isInstalled(database: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: database) || fm.fileExists(atPath: pluginURL.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    static func status() -> Status {
        guard let current = try? String(contentsOf: pluginURL, encoding: .utf8) else { return .notInstalled }
        return current == plugin ? .connected : .outdated
    }

    @discardableResult
    static func connect() throws -> String {
        guard status() != .connected else { return "Already connected" }
        try FileManager.default.createDirectory(at: pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plugin.write(to: pluginURL, atomically: true, encoding: .utf8)
        return "Connected — restart OpenCode to load the plugin"
    }

    @discardableResult
    static func disconnect() throws -> String {
        guard status() != .notInstalled else { return "Nothing to remove" }
        try FileManager.default.removeItem(at: pluginURL)
        return "Disconnected OpenCode"
    }
}

// MARK: Model

final class AIModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var claudeUsage: [ClaudeUsage] = []
    @Published private(set) var openCodeUsage: OpenCodeUsage?
    @Published private(set) var codexQuota: AgentQuotaUsage?
    @Published private(set) var antigravityQuotas: [AgentQuotaUsage] = []
    @Published private(set) var profiles: [ClaudeProfile] = []
    /// Profiles the user hid; listed in the Editor so they can be shown again.
    @Published private(set) var hiddenProfiles: [ClaudeProfile] = []
    @Published private(set) var connectionStatus: [String: ClaudeConnection.Status] = [:]
    /// Nil while OpenCode isn't installed.
    @Published private(set) var openCodeStatus: OpenCodeConnection.Status?
    @Published private(set) var additionalStatus: [AdditionalAgentConnection.Kind: Bool] = [:]
    @Published var connectionMessage: String?
    /// The full-screen Connect Claude Code view is showing.
    @Published var connectEditorOpen = false

    var settings = AISettings() {
        didSet { if settings != oldValue { refreshProfiles() } }
    }

    /// Needs-you occurrences closed with ✕ (see `toastKey`).
    @Published private var dismissedToasts = Set<String>()

    private var visibleWidgets = Set<UUID>()
    private var timer: Timer?
    private var fileWatch: FSEventStreamRef?
    /// Called with a Claude config folder a running Session uses that isn't a Profile yet;
    /// the app remembers it in config.json (`ai.claudeDirs`).
    var learnedProfile: (String) -> Void = { _ in }
    private var lastLearn = Date.distantPast
    private var polling = false
    private var usageRead = Date.distantPast
    private var cachedOpenCodeUsage: OpenCodeUsage?
    private let queue = DispatchQueue(label: "edgedeck.ai")
    /// Per profile key: last hook event per Claude session id.
    private var hookEvents: [String: [String: HookEvent]] = [:]
    private var eventOffsets: [String: UInt64] = [:]
    /// When each session entered its current state (for "for 3 min").
    private var stateSince: [String: (AgentState, Date)] = [:]
    private var contextBySession: [String: Double] = [:]
    private var costBySession: [String: Double] = [:]
    /// From the OpenCode plugin: open permission asks and questions per OpenCode session id.
    private var openCodeAsks: [String: [String: OpenCodeAsk]] = [:]
    /// From the OpenCode plugin: the server process each OpenCode session last ran in.
    private var openCodeServers: [String: pid_t] = [:]
    private var openCodeOffset: UInt64?

    struct OpenCodeAsk {
        /// The permission's action ("shell", "edit"…); nil for a question.
        let action: String?
        let time: Date
        let pid: pid_t
    }

    struct HookEvent {
        let name: String
        let tool: String?
        let message: String?
        let time: Date
    }

    func start() {
        refreshProfiles()
        schedule()
        watchFiles()
    }

    // MARK: Needs you

    /// Sessions that Need you, newest first (the Rail shows these during a Takeover).
    var needingYou: [AgentSession] {
        guard settings.toastOnNeedsYou else { return [] }
        return sessions.filter(\.state.needsYou).sorted { $0.since > $1.since }
    }

    /// What the Toast announces: Sessions that Need you, minus the ones dismissed.
    var toastSessions: [AgentSession] {
        needingYou.filter { !dismissedToasts.contains(Self.toastKey($0)) }
    }

    /// ✕ closes these occurrences only; the same Session needing you again is a new Toast.
    func dismissToast() {
        dismissedToasts.formUnion(toastSessions.map(Self.toastKey))
    }

    /// Names of the terminal apps running Sessions that Need you, e.g. "iTerm2".
    var needingYouTerminals: Set<String> {
        Set(needingYou.compactMap { terminal(of: $0)?.localizedName?.lowercased() })
    }

    /// One Needs-you occurrence: the Session plus when it started needing you.
    private static func toastKey(_ session: AgentSession) -> String {
        "\(session.id)@\(session.since.timeIntervalSince1970)"
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        let before = visibleWidgets.isEmpty
        if visible { visibleWidgets.insert(id) } else { visibleWidgets.remove(id) }
        if before != visibleWidgets.isEmpty { schedule() }
    }

    /// Polls quickly while a widget is on screen, slowly otherwise. Changes on disk
    /// trigger a poll straight away (see `watchFiles`), so Toasts don't wait for this.
    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = visibleWidgets.isEmpty ? 10 : 1.5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func refreshProfiles() {
        (profiles, hiddenProfiles) = ClaudeProfile.discover(extra: settings.claudeDirs ?? [], hidden: settings.hiddenClaudeDirs)
        connectionStatus = Dictionary(uniqueKeysWithValues: (profiles + hiddenProfiles).map { ($0.key, ClaudeConnection.status($0)) })
        openCodeStatus = OpenCodeConnection.isInstalled(database: openCodeDatabase) ? OpenCodeConnection.status() : nil
        additionalStatus = Dictionary(uniqueKeysWithValues: AdditionalAgentConnection.Kind.allCases
            .filter(AdditionalAgentConnection.installed).map { ($0, AdditionalAgentConnection.connected($0)) })
        if fileWatch != nil { watchFiles() }
    }

    /// Polls whenever the bridge's events or a profile's session files change, so a Session
    /// that Needs you shows within a fraction of a second. OpenCode's database folder too.
    private func watchFiles() {
        if let stream = fileWatch {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        let openCodeEvents = OpenCodeConnection.eventsURL.deletingLastPathComponent()
        for dir in [ClaudeConnection.dataRoot, openCodeEvents, AdditionalAgentConnection.root] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let paths = ([ClaudeConnection.dataRoot.path, openCodeEvents.path, AdditionalAgentConnection.root.path,
                      (openCodeDatabase as NSString).deletingLastPathComponent]
                     + profiles.map(\.sessionsDirectory.path))
            .filter { FileManager.default.fileExists(atPath: $0) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AIModel>.fromOpaque(info).takeUnretainedValue().poll()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { fileWatch = nil; return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        fileWatch = stream
    }

    func connect(_ profile: ClaudeProfile) {
        do { connectionMessage = try ClaudeConnection.connect(profile) } catch { connectionMessage = "Couldn't connect \(profile.name): \(error.localizedDescription)" }
        refreshProfiles()
    }

    func disconnect(_ profile: ClaudeProfile) {
        do { connectionMessage = try ClaudeConnection.disconnect(profile) } catch { connectionMessage = "Couldn't remove \(profile.name): \(error.localizedDescription)" }
        refreshProfiles()
    }

    func connectOpenCode() {
        do { connectionMessage = try OpenCodeConnection.connect() } catch { connectionMessage = "Couldn't connect OpenCode: \(error.localizedDescription)" }
        refreshProfiles()
    }

    func disconnectOpenCode() {
        do { connectionMessage = try OpenCodeConnection.disconnect() } catch { connectionMessage = "Couldn't remove OpenCode's plugin: \(error.localizedDescription)" }
        refreshProfiles()
    }

    func connectAdditional(_ kind: AdditionalAgentConnection.Kind) {
        do { connectionMessage = try AdditionalAgentConnection.connect(kind) }
        catch { connectionMessage = "Couldn't connect \(kind.rawValue): \(error.localizedDescription)" }
        refreshProfiles()
    }

    func disconnectAdditional(_ kind: AdditionalAgentConnection.Kind) {
        do { connectionMessage = try AdditionalAgentConnection.disconnect(kind) }
        catch { connectionMessage = "Couldn't disconnect \(kind.rawValue): \(error.localizedDescription)" }
        refreshProfiles()
    }

    private var openCodeDatabase: String {
        settings.opencodeDatabase.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    var needsConnect: Bool { profiles.contains { !(connectionStatus[$0.key]?.connected ?? false) } }

    /// Running Claude Code processes started with CLAUDE_CONFIG_DIR reveal Profiles kept
    /// anywhere, e.g. ~/dev/acme/claude. Hidden ones stay hidden.
    private func learnProfiles() {
        let known = Set((profiles + hiddenProfiles).map(\.directory))
        queue.async { [weak self] in
            var found: [URL] = []
            for pid in Self.pids(named: "claude") + Self.pids(named: "node") {
                guard let dir = Self.environment(pid)["CLAUDE_CONFIG_DIR"], !dir.isEmpty else { continue }
                let url = ClaudeProfile.url(fromConfig: dir)
                if !known.contains(url), !found.contains(url) { found.append(url) }
            }
            guard !found.isEmpty else { return }
            DispatchQueue.main.async {
                for url in found { self?.learnedProfile(ClaudeProfile.configPath(url)) }
            }
        }
    }

    /// Shows a short message on the Edge (the app wires it to the Dashboard's message line).
    var showMessage: (String) -> Void = { _ in }

    /// Brings the terminal running a session forward.
    func focus(_ session: AgentSession) {
        let app: NSRunningApplication?
        if session.pid != nil, let terminal = terminal(of: session) {
            terminal.activate()
            selectTerminalTab(of: session)
            return
        }
        switch session.tool {
        case .codex:
            app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        case .antigravity:
            app = NSWorkspace.shared.runningApplications.first { $0.localizedName?.lowercased().contains("antigravity") == true }
        default:
            app = terminal(of: session)
        }
        guard let app else { return showMessage("Couldn't find the app running this session") }
        app.activate()
    }

    /// Selects the terminal tab a Session runs in (iTerm2 and Terminal know each tab's tty), so
    /// its window is the terminal's front one. Other terminals keep whatever window is in front.
    func selectTerminalTab(of session: AgentSession) {
        guard let pid = session.pid, let tty = Self.tty(of: pid), let app = terminal(of: session) else { return }
        let script: String
        switch app.bundleIdentifier {
        case "com.googlecode.iterm2":
            script = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case "com.apple.Terminal":
            script = """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            return
        }
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { NSLog("EdgeDeck: couldn't select the session's tab: \(error)") }
    }

    /// "/dev/ttys003" for a process attached to a terminal.
    static func tty(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              info.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// A process's current folder (same user only).
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// The app (usually a terminal) a Session's process runs under.
    func terminal(of session: AgentSession) -> NSRunningApplication? {
        guard let pid = session.pid else { return nil }
        return Self.app(above: pid)
    }

    /// The first ordinary app among a process and its parents.
    private static func app(above start: pid_t) -> NSRunningApplication? {
        var pid = start
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            // iTerm2 runs sessions under an iTermServer process that outlives iTerm2 itself: after
            // iTerm2 restarts (an update, session restore), its parent is launchd, not iTerm2.
            if processName(pid).hasPrefix("iTermServer") {
                return NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first
            }
            let parent = Self.parentPID(pid)
            // A tmux server detaches from its terminal; the terminal is the attached client's.
            if parent <= 1, Self.processName(pid) == "tmux" {
                for client in Self.pids(named: "tmux") where client != pid && Self.tty(of: client) != nil {
                    if let app = app(above: client) { return app }
                }
                return nil
            }
            guard parent > 1 else { return nil }
            pid = parent
        }
        return nil
    }

    // MARK: Polling

    private func poll() {
        // File changes can arrive in bursts; one poll in flight is enough.
        guard !polling else { return }
        polling = true
        if Date().timeIntervalSince(lastLearn) > 10 {
            lastLearn = Date()
            learnProfiles()
        }
        let profiles = profiles
        let opencodePath = openCodeDatabase
        queue.async { [weak self] in
            guard let self else { return }
            var sessions: [AgentSession] = []
            var usage: [ClaudeUsage] = []
            for profile in profiles {
                readHookEvents(profile)
                if let u = readStatusline(profile) { usage.append(u) }
                sessions += readClaudeSessions(profile, label: profiles.count > 1 ? profile.name : nil)
            }
            readOpenCodeEvents()
            let openCode = OpenCodeReader(path: opencodePath)
            let asks = openCodeAsks.compactMapValues { $0.values.max { $0.time < $1.time } }
            let ocSessions = openCode?.activeSessions(servers: openCodeServers, asks: asks.mapValues(\.action)) ?? []
            // Today's totals change on a message, not a poll; summing the day's rows each time is wasteful.
            if Date().timeIntervalSince(self.usageRead) > 30 {
                self.usageRead = Date()
                self.cachedOpenCodeUsage = openCode?.todayUsage()
            }
            let ocUsage = self.cachedOpenCodeUsage
            sessions += ocSessions.map { s in
                AgentSession(id: "oc:" + s.id, tool: .opencode, profile: nil, project: s.project, title: s.title,
                             state: s.state, since: self.since("oc:" + s.id, s.state, fallback: s.updated), pid: s.pid,
                             contextPercent: nil, agent: s.agent, cost: s.cost)
            }
            let now = Date()
            let codexAppRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
            let antigravityAppRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity").isEmpty
            for kind in AdditionalAgentConnection.Kind.allCases {
                for event in AdditionalAgentReader.events(kind) where event.event != "SessionEnd" {
                    let tool: AgentSession.Tool = kind == .codex ? .codex : .antigravity
                    let state: AgentState = switch event.event {
                    case "Stop", "Interrupt": .idle
                    case "PermissionRequest": .needsYou(event.tool)
                    case "PreToolUse": .running(event.tool ?? "")
                    default: .thinking
                    }
                    let id = "\(kind.rawValue):\(event.id)"
                    let candidates = kind == .codex ? ["codex"] : ["agy", "antigravity", "antigravity-cli"]
                    let ownerPID = event.pid.flatMap { candidate -> pid_t? in
                        guard kill(candidate, 0) == 0 || errno == EPERM else { return nil }
                        let name = Self.processName(candidate).lowercased()
                        return candidates.contains(where: name.contains) ? candidate : nil
                    }
                    let pid = ownerPID.flatMap { Self.tty(of: $0) != nil ? $0 : nil } ??
                        (event.pid == nil ? candidates.flatMap(Self.pids(named:)).first {
                            Self.tty(of: $0) != nil && Self.workingDirectory(of: $0) == event.cwd
                        } : nil)
                    let ownerAlive = ownerPID != nil
                    let desktopAlive = kind == .codex ? codexAppRunning :
                        (!event.transcript.contains("/antigravity-cli/") && antigravityAppRunning)
                    guard ownerAlive || pid != nil || (desktopAlive && now.timeIntervalSince(event.date) < 300) else { continue }
                    sessions.append(AgentSession(id: id, tool: tool, profile: nil,
                                                 project: (event.cwd as NSString).lastPathComponent,
                                                 title: nil, state: state,
                                                 since: self.since(id, state, fallback: event.date),
                                                 pid: pid, contextPercent: nil))
                }
            }
            let codexIDs = Set(sessions.filter { $0.tool == .codex }.map(\.id))
            let rollouts = AdditionalAgentReader.codexRollouts(now: now)
            let codexQuota = rollouts.sorted { $0.updated > $1.updated }.compactMap(\.quota).first
            let antigravityQuotas = AdditionalAgentReader.antigravityQuota(now: now)
            for rollout in rollouts where now.timeIntervalSince(rollout.updated) < 300 {
                let id = "codex:\(rollout.id)"
                guard !codexIDs.contains(id) else { continue }
                let cliPID = Self.pids(named: "codex").first {
                    Self.tty(of: $0) != nil && Self.workingDirectory(of: $0) == rollout.cwd
                }
                guard codexAppRunning || cliPID != nil else { continue }
                sessions.append(AgentSession(id: id, tool: .codex, profile: nil,
                                             project: (rollout.cwd as NSString).lastPathComponent,
                                             title: nil, state: rollout.state,
                                             since: self.since(id, rollout.state, fallback: rollout.updated),
                                             pid: cliPID, contextPercent: nil))
            }
            // Busy sessions first, then the most recently changed.
            sessions.sort { ($0.state.isActive ? 0 : 1, -$0.since.timeIntervalSince1970) < ($1.state.isActive ? 0 : 1, -$1.since.timeIntervalSince1970) }
            DispatchQueue.main.async {
                self.polling = false
                if sessions != self.sessions { self.sessions = sessions }
                let current = Set(sessions.filter(\.state.needsYou).map(Self.toastKey))
                if !self.dismissedToasts.isSubset(of: current) { self.dismissedToasts.formIntersection(current) }
                if usage != self.claudeUsage { self.claudeUsage = usage }
                if ocUsage != self.openCodeUsage { self.openCodeUsage = ocUsage }
                if codexQuota != self.codexQuota { self.codexQuota = codexQuota }
                if antigravityQuotas != self.antigravityQuotas { self.antigravityQuotas = antigravityQuotas }
            }
        }
    }

    private func since(_ id: String, _ state: AgentState, fallback: Date) -> Date {
        // A permission request followed by its Notification is one Needs you, not two.
        if let (previous, date) = stateSince[id], previous == state || (previous.needsYou && state.needsYou) { return date }
        let date = stateSince[id] == nil ? fallback : Date()
        stateSince[id] = (state, date)
        return date
    }

    /// Claude Code's own per-process status files: <profile>/sessions/<pid>.json.
    private func readClaudeSessions(_ profile: ClaudeProfile, label: String?) -> [AgentSession] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: profile.sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 || errno == EPERM,
                  Self.processName(pid).lowercased().contains("claude") || Self.processName(pid).lowercased().contains("node")
            else { return nil }
            let sessionID = json["sessionId"] as? String ?? url.lastPathComponent
            let cwd = json["cwd"] as? String ?? ""
            let statusText = (json["status"] as? String ?? "").lowercased()
            let statusAt = Date(timeIntervalSince1970: ((json["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            let base: AgentState = switch statusText {
            case "busy", "working", "running": .thinking
            case let s where s.contains("wait") || s.contains("permission") || s.contains("input"): .needsYou(nil)
            default: .idle
            }
            var state = base
            if let event = hookEvents[profile.key]?[sessionID] {
                let fromHook = Self.state(for: event)
                // Claude's own "idle" written after our last event wins (e.g. Esc pressed).
                if base == .idle, statusAt.timeIntervalSince(event.time) > 2 {
                    state = .idle
                } else if base == .idle, Self.midTurnEvents.contains(event.name) {
                    // The bridge stamps events when it runs, and hooks run in parallel, so a
                    // PostToolUse can land after the turn's Stop. Claude says idle: it's stale.
                    state = .idle
                } else if let fromHook {
                    state = fromHook
                }
            }
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let id = "cc:\(profile.key):\(sessionID)"
            return AgentSession(id: id, tool: .claude, profile: label, project: (cwd as NSString).lastPathComponent,
                                title: name, state: state, since: since(id, state, fallback: statusAt), pid: pid,
                                contextPercent: contextBySession[sessionID], cost: costBySession[sessionID])
        }
    }

    /// Hook events that only happen while Claude is busy; once Claude reports idle they can't be current.
    private static let midTurnEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure",
                                                     "SubagentStart", "SubagentStop", "PreCompact"]

    private static func state(for event: HookEvent) -> AgentState? {
        switch event.name {
        case "PermissionRequest": return .needsYou(event.tool)
        case "Notification":
            let m = (event.message ?? "").lowercased()
            return m.contains("permission") || m.contains("approve") ? .needsYou(nil) : nil
        case "PreToolUse": return .running(event.tool ?? "")
        case "SubagentStart": return .running("Agent")
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "SubagentStop": return .thinking
        case "PreCompact": return .compacting
        case "StopFailure": return .error
        case "Stop", "SessionStart", "SessionEnd": return .idle
        default: return nil
        }
    }

    /// Reads new lines appended by the bridge since the last poll; rotates the file when big.
    private func readHookEvents(_ profile: ClaudeProfile) {
        let url = profile.dataDirectory.appendingPathComponent("events.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var offset = eventOffsets[profile.key] ?? 0
        if offset > size { offset = 0 }
        if eventOffsets[profile.key] == nil, size > 256_000 { offset = size - 256_000 }  // first read: recent tail only
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        eventOffsets[profile.key] = offset + UInt64(lastNewline + 1)
        var events = hookEvents[profile.key] ?? [:]
        for line in data[..<lastNewline].split(separator: 0x0A) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let event = json["event"] as? [String: Any],
                  let session = event["session_id"] as? String,
                  let name = event["hook_event_name"] as? String else { continue }
            let time = Date(timeIntervalSince1970: (json["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
            if name == "SessionEnd" { events.removeValue(forKey: session); continue }
            // Keep the PermissionRequest (it names the tool) over the Notification that follows it.
            if name == "Notification", events[session]?.name == "PermissionRequest" { continue }
            // Claude Code finishes a background subagent just after the turn's Stop; that
            // SubagentStop would otherwise read as Busy and leave the Session stuck there.
            if name == "SubagentStop", ["Stop", "StopFailure"].contains(events[session]?.name) { continue }
            events[session] = HookEvent(name: name, tool: event["tool_name"] as? String, message: event["message"] as? String, time: time)
        }
        hookEvents[profile.key] = events
        // Keep the file small: start over once it's past 2 MB (everything in it has been read).
        if size > 2_000_000, eventOffsets[profile.key] == size {
            try? FileManager.default.removeItem(at: url)
            eventOffsets[profile.key] = 0
        }
    }

    /// Reads new lines the OpenCode plugin appended since the last poll; rotates the file when big.
    private func readOpenCodeEvents() {
        let url = OpenCodeConnection.eventsURL
        guard let handle = try? FileHandle(forReadingFrom: url) else { openCodeAsks = [:]; return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var offset = openCodeOffset ?? (size > 256_000 ? size - 256_000 : 0)  // first read: recent tail only
        if offset > size { offset = 0 }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        if let lastNewline = data.lastIndex(of: 0x0A) {
            openCodeOffset = offset + UInt64(lastNewline + 1)
            for line in data[..<lastNewline].split(separator: 0x0A) {
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let type = json["type"] as? String, let session = json["session"] as? String,
                      let pid = (json["pid"] as? NSNumber)?.int32Value else { continue }
                let time = Date(timeIntervalSince1970: (json["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
                let id = json["id"] as? String ?? ""
                openCodeServers[session] = pid
                switch type {
                case "permission.asked": openCodeAsks[session, default: [:]][id] = OpenCodeAsk(action: json["action"] as? String ?? "", time: time, pid: pid)
                case "form.created": openCodeAsks[session, default: [:]][id] = OpenCodeAsk(action: nil, time: time, pid: pid)
                case "permission.replied", "form.replied", "form.cancelled": openCodeAsks[session]?.removeValue(forKey: id)
                // A finished run can't still be waiting on the user, whatever we missed.
                case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted": openCodeAsks[session] = nil
                default: break
                }
            }
        } else {
            openCodeOffset = offset
        }
        // Asks die with their OpenCode process.
        openCodeAsks = openCodeAsks.mapValues { $0.filter { kill($0.value.pid, 0) == 0 || errno == EPERM } }.filter { !$0.value.isEmpty }
        openCodeServers = openCodeServers.filter { kill($0.value, 0) == 0 || errno == EPERM }
        // Keep the file small: start over once it's past 2 MB (everything in it has been read).
        if size > 2_000_000, openCodeOffset == size {
            try? FileManager.default.removeItem(at: url)
            openCodeOffset = 0
        }
    }

    private func readStatusline(_ profile: ClaudeProfile) -> ClaudeUsage? {
        let url = profile.dataDirectory.appendingPathComponent("statusline.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let session = json["session_id"] as? String,
           let used = ((json["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
            contextBySession[session] = used
        }
        if let session = json["session_id"] as? String,
           let cost = ((json["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue {
            costBySession[session] = cost
        }
        let limits = json["rate_limits"] as? [String: Any] ?? [:]
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let now = Date()
        // The bridge only receives a new usage snapshot while Claude is active. A saved
        // percentage can be wrong after a reset or usage in another Claude session/device.
        let recent = now.timeIntervalSince(modified) < 3600
        func window(_ key: String) -> (Double?, Date?) {
            let w = limits[key] as? [String: Any] ?? [:]
            let reset = Self.date(w["resets_at"] ?? w["reset_at"] ?? w["resets"])
            guard let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  (0...100).contains(used),
                  recent, (reset.map { $0 > now } ?? true) else { return (nil, nil) }
            return (used, reset)
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five.0 != nil || seven.0 != nil else { return nil }
        return ClaudeUsage(profile: profile.name, fiveHour: five.0, fiveHourResets: five.1, sevenDay: seven.0, sevenDayResets: seven.1, updated: modified)
    }

    /// Epoch seconds / milliseconds or an ISO-8601 string.
    private static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v)
        }
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }

    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    static func parentPID(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    /// A process's environment (same user only), read the way `ps -E` does.
    static func environment(_ pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [:] }
        // argc, the executable path, argv, then the environment, all NUL-separated.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let strings = buffer[4..<size].split(separator: 0, omittingEmptySubsequences: true)
        var env: [String: String] = [:]
        for raw in strings.dropFirst(1 + Int(argc)) {
            let entry = String(decoding: raw, as: UTF8.self)
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }

    /// PIDs of processes whose executable name contains `name`.
    static func pids(named name: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        // One reused C buffer and strcasestr: a String per process, every poll, was the AI widget's main cost.
        var buffer = [CChar](repeating: 0, count: 256)
        return pids.prefix(Int(n)).filter { pid in
            pid > 0 && proc_name(pid, &buffer, UInt32(buffer.count)) > 0 && strcasestr(buffer, name) != nil
        }
    }
}

// MARK: OpenCode

/// Reads OpenCode's SQLite database (read-only). Opened per poll, closed on release.
final class OpenCodeReader {
    struct Session {
        let id: String
        let title: String?
        let project: String
        let agent: String?
        let cost: Double
        let state: AgentState
        let updated: Date
        let pid: pid_t?
    }

    private let db: OpaquePointer

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 200)
        db = handle
    }

    deinit { sqlite3_close(db) }

    /// Sessions open in an `opencode` terminal client right now, plus any that Need you.
    /// In OpenCode's service mode every Session runs in one shared background server, so a
    /// Session is matched to the client running in its folder: the most recently used Sessions
    /// there, one per client. A standalone client is its server's parent, which pins it exactly.
    /// `servers`: OpenCode session id → server pid; `asks`: session id → what it's asking
    /// (a permission's action, or nil for a question), both from the plugin.
    func activeSessions(servers: [String: pid_t], asks: [String: String?]) -> [Session] {
        let clients = Self.clients()
        // A subagent's ask blocks its top-level Session.
        var asking: [String: String?] = [:]
        for (session, action) in asks { asking[root(of: session)] = action }
        guard !clients.isEmpty || !asking.isEmpty else { return [] }

        let cutoff = Int64((Date().timeIntervalSince1970 - 12 * 3600) * 1000)
        let rows = query("""
            select id, title, directory, agent, time_updated,
                   cost + (select coalesce(sum(c.cost), 0) from session_v2 c where c.parent_id = s.id)
            from session_v2 s
            where parent_id is null and time_archived is null and time_updated > \(cutoff)
            order by time_updated desc limit 40
            """)
        var pidOf: [String: pid_t] = [:]
        var free = clients
        for row in rows {
            guard let id = row[0], let server = servers[id] else { continue }
            let client = AIModel.parentPID(server)
            if free[client] != nil { pidOf[id] = client; free[client] = nil }
        }
        for row in rows {
            guard let id = row[0], pidOf[id] == nil, let directory = row[2] else { continue }
            let folder = Self.canonical(directory)
            if let client = free.first(where: { $0.value == folder })?.key { pidOf[id] = client; free[client] = nil }
        }
        return rows.compactMap { row in
            guard let id = row[0], pidOf[id] != nil || asking[id] != nil else { return nil }
            let state: AgentState = if let action = asking[id] { .needsYou(action.flatMap { $0.isEmpty ? nil : $0 }) } else { state(of: id) }
            return Session(id: id, title: row[1], project: ((row[2] ?? "") as NSString).lastPathComponent, agent: row[3],
                           cost: Double(row[5] ?? "0") ?? 0, state: state, updated: Date(timeIntervalSince1970: (Double(row[4] ?? "0") ?? 0) / 1000),
                           pid: pidOf[id])
        }
    }

    /// Running `opencode` terminal clients and the folder each runs in. Not the servers: the
    /// shared one has no terminal, and a standalone client's own server is its child.
    private static func clients() -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for pid in AIModel.pids(named: "opencode") where AIModel.tty(of: pid) != nil {
            guard !AIModel.processName(AIModel.parentPID(pid)).lowercased().contains("opencode"),
                  let cwd = AIModel.workingDirectory(of: pid) else { continue }
            result[pid] = canonical(cwd)
        }
        return result
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func root(of session: String) -> String {
        var id = session
        for _ in 0..<8 {
            guard let parent = query("select parent_id from session_v2 where id = ?", [id]).first?.first ?? nil else { break }
            id = parent
        }
        return id
    }

    /// Tokens and cost of assistant messages since midnight.
    func todayUsage() -> OpenCodeUsage? {
        let midnight = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let rows = query("select data from session_message where type = 'assistant' and time_created >= \(midnight)")
        var tokens = 0, cost = 0.0
        for row in rows {
            guard let text = row[0], let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
            let t = json["tokens"] as? [String: Any] ?? [:]
            tokens += (t["input"] as? Int ?? 0) + (t["output"] as? Int ?? 0) + (t["reasoning"] as? Int ?? 0)
            cost += (json["cost"] as? NSNumber)?.doubleValue ?? 0
        }
        return OpenCodeUsage(tokens: tokens, cost: cost, messages: rows.count)
    }

    /// From the session's latest message: idle, waiting on the model, or running a tool.
    private func state(of session: String) -> AgentState {
        guard let row = query("select type, data from session_message where session_id = ? order by seq desc limit 1", [session]).first,
              let type = row[0] else { return .idle }
        let json = row[1].flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
        switch type {
        case "idle":
            return (json["outcome"] as? String).map { $0 == "failed" || $0 == "error" } == true ? .error : .idle
        case "user", "model-switched": return .thinking
        case "assistant":
            if (json["time"] as? [String: Any])?["completed"] != nil { return .thinking }
            let parts = json["content"] as? [[String: Any]] ?? []
            if let tool = parts.last(where: { ($0["type"] as? String) == "tool" }),
               let status = (tool["state"] as? [String: Any])?["status"] as? String, status == "running" || status == "pending" {
                return .running(tool["name"] as? String ?? "")
            }
            return .thinking
        default: return .idle
        }
    }

    private func query(_ sql: String, _ args: [String] = []) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), arg, -1, transient) }
        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            rows.append((0..<count).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } })
        }
        return rows
    }
}
