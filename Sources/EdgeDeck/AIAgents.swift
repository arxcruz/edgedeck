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

    var id: String { directory.path }
    /// "claude", "claude-work"… — names EdgeDeck's own files for this profile.
    var key: String { directory.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    /// "default", "work", "personal".
    var name: String {
        let k = key
        if k == "claude" { return "default" }
        for prefix in ["claude-", "claude_", "claude."] where k.hasPrefix(prefix) { return String(k.dropFirst(prefix.count)) }
        return k
    }
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    var sessionsDirectory: URL { directory.appendingPathComponent("sessions") }
    /// Where the bridge writes for this profile.
    var dataDirectory: URL { ClaudeConnection.dataRoot.appendingPathComponent(key, isDirectory: true) }

    /// ~/.claude plus any ~/.claude-* / ~/.claude_* that looks like a Claude Code config dir.
    static func discover(_ configured: [String]?) -> [ClaudeProfile] {
        let fm = FileManager.default
        if let configured {
            return configured.map { ClaudeProfile(directory: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)) }
                .filter { fm.fileExists(atPath: $0.directory.path) }
        }
        let home = fm.homeDirectoryForCurrentUser
        let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") || $0.hasPrefix(".claude_") }
            .map { ClaudeProfile(directory: home.appendingPathComponent($0, isDirectory: true)) }
            .filter { profile in
                ["settings.json", "projects", "sessions", ".claude.json"].contains { fm.fileExists(atPath: profile.directory.appendingPathComponent($0).path) }
            }
            .sorted { ($0.key == "claude" ? 0 : 1, $0.key) < ($1.key == "claude" ? 0 : 1, $1.key) }
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
    @Published private(set) var connectionStatus: [String: ClaudeConnection.Status] = [:]
    @Published var connectionMessage: String?
    /// The full-screen Connect Claude Code view is showing.
    @Published var connectEditorOpen = false

    var settings = AISettings() {
        didSet { if settings != oldValue { refreshProfiles() } }
    }

    private var visibleWidgets = Set<UUID>()
    private var timer: Timer?
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
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        let before = visibleWidgets.isEmpty
        if visible { visibleWidgets.insert(id) } else { visibleWidgets.remove(id) }
        if before != visibleWidgets.isEmpty { schedule() }
    }

    /// Polls quickly while a widget is on screen, slowly otherwise (state for toasts later).
    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = visibleWidgets.isEmpty ? 10 : 1.5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func refreshProfiles() {
        profiles = ClaudeProfile.discover(settings.claudeDirs)
        connectionStatus = Dictionary(uniqueKeysWithValues: profiles.map { ($0.key, ClaudeConnection.status($0)) })
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

    /// Brings the terminal running a session forward.
    func focus(_ session: AgentSession) {
        guard var pid = session.pid else { return }
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                app.activate()
                return
            }
            let parent = Self.parentPID(pid)
            guard parent > 1 else { return }
            pid = parent
        }
    }

    // MARK: Polling

    private func poll() {
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
                if sessions != self.sessions { self.sessions = sessions }
                if usage != self.claudeUsage { self.claudeUsage = usage }
                if ocUsage != self.openCodeUsage { self.openCodeUsage = ocUsage }
            }
        }
    }

    private func since(_ id: String, _ state: AgentState, fallback: Date) -> Date {
        if let (previous, date) = stateSince[id], previous == state { return date }
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
