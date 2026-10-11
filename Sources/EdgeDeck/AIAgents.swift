import AppKit
import SQLite3

// Live state of local AI coding agents — Claude Code (every profile / CLAUDE_CONFIG_DIR)
// and OpenCode — read from files they keep on disk. Nothing leaves the Mac.

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
    enum Tool: String { case claude, opencode }

    let id: String
    let tool: Tool
    /// Claude profile ("work", "personal") or OpenCode agent/model.
    let profile: String?
    let project: String
    let title: String?
    let state: AgentState
    let since: Date
    /// Process to bring forward (its terminal) when tapped.
    let pid: pid_t?
    /// Context window use, 0…100, when known.
    let contextPercent: Double?
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

// MARK: Model

final class AIModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var claudeUsage: [ClaudeUsage] = []
    @Published private(set) var openCodeUsage: OpenCodeUsage?
    @Published private(set) var profiles: [ClaudeProfile] = []
    /// Profiles the user hid; listed in the Editor so they can be shown again.
    @Published private(set) var hiddenProfiles: [ClaudeProfile] = []
    @Published private(set) var connectionStatus: [String: ClaudeConnection.Status] = [:]
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
    private let queue = DispatchQueue(label: "edgedeck.ai")
    /// Per profile key: last hook event per Claude session id.
    private var hookEvents: [String: [String: HookEvent]] = [:]
    private var eventOffsets: [String: UInt64] = [:]
    /// When each session entered its current state (for "for 3 min").
    private var stateSince: [String: (AgentState, Date)] = [:]
    private var contextBySession: [String: Double] = [:]

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
        try? FileManager.default.createDirectory(at: ClaudeConnection.dataRoot, withIntermediateDirectories: true)
        let opencode = (settings.opencodeDatabase.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path) as NSString
        let paths = ([ClaudeConnection.dataRoot.path, opencode.deletingLastPathComponent] + profiles.map(\.sessionsDirectory.path))
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

    /// Brings the terminal running a session forward.
    func focus(_ session: AgentSession) {
        terminal(of: session)?.activate()
    }

    /// The app (usually a terminal) a Session's process runs under.
    func terminal(of session: AgentSession) -> NSRunningApplication? {
        guard var pid = session.pid else { return nil }
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            let parent = Self.parentPID(pid)
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
        let opencodePath = settings.opencodeDatabase.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        queue.async { [weak self] in
            guard let self else { return }
            var sessions: [AgentSession] = []
            var usage: [ClaudeUsage] = []
            for profile in profiles {
                readHookEvents(profile)
                if let u = readStatusline(profile) { usage.append(u) }
                sessions += readClaudeSessions(profile, label: profiles.count > 1 ? profile.name : nil)
            }
            let openCode = OpenCodeReader(path: opencodePath)
            let ocSessions = openCode?.activeSessions() ?? []
            let ocUsage = openCode?.todayUsage()
            sessions += ocSessions.map { s in
                AgentSession(id: "oc:" + s.id, tool: .opencode, profile: s.agent, project: s.project, title: s.title,
                             state: s.state, since: self.since("oc:" + s.id, s.state, fallback: s.updated), pid: s.pid, contextPercent: nil)
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
                } else if let fromHook {
                    state = fromHook
                }
            }
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let id = "cc:\(profile.key):\(sessionID)"
            return AgentSession(id: id, tool: .claude, profile: label, project: (cwd as NSString).lastPathComponent,
                                title: name, state: state, since: since(id, state, fallback: statusAt), pid: pid,
                                contextPercent: contextBySession[sessionID])
        }
    }

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

    private func readStatusline(_ profile: ClaudeProfile) -> ClaudeUsage? {
        let url = profile.dataDirectory.appendingPathComponent("statusline.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let session = json["session_id"] as? String,
           let used = ((json["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
            contextBySession[session] = used
        }
        let limits = json["rate_limits"] as? [String: Any] ?? [:]
        func window(_ key: String) -> (Double?, Date?) {
            let w = limits[key] as? [String: Any] ?? [:]
            return ((w["used_percentage"] as? NSNumber)?.doubleValue, Self.date(w["resets_at"] ?? w["reset_at"] ?? w["resets"]))
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five.0 != nil || seven.0 != nil else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
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
        return pids.prefix(Int(n)).filter { $0 > 0 && processName($0).lowercased().contains(name) }
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

    /// Top-level sessions touched in the last 12 h, while OpenCode is running.
    func activeSessions() -> [Session] {
        let running = AIModel.pids(named: "opencode")
        guard !running.isEmpty else { return [] }
        let cutoff = Int64((Date().timeIntervalSince1970 - 12 * 3600) * 1000)
        let rows = query("""
            select id, title, directory, agent, time_updated from session_v2
            where parent_id is null and time_archived is null and time_updated > \(cutoff)
            order by time_updated desc limit 8
            """)
        return rows.map { row in
            let id = row[0] ?? ""
            return Session(id: id, title: row[1], project: ((row[2] ?? "") as NSString).lastPathComponent, agent: row[3],
                           state: state(of: id), updated: Date(timeIntervalSince1970: (Double(row[4] ?? "0") ?? 0) / 1000),
                           pid: running.first)
        }
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
