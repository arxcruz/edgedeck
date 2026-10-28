import AppKit
import EdgeAgents

/// The two agents use different hook schemas, but both can report conversation metadata
/// without exposing prompts or transcript content to EdgeDeck.
enum AdditionalAgentConnection {
    enum Kind: String, CaseIterable { case codex, antigravity }

    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EdgeDeck/agents", isDirectory: true)
    static let bridge = root.appendingPathComponent("event-bridge.py")
    static let statuslineBridge = root.appendingPathComponent("antigravity-statusline.py")
    static let statuslineSnapshot = root.appendingPathComponent("antigravity-statusline.json")
    static let antigravitySettings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli/settings.json")
    static func events(_ kind: Kind) -> URL { root.appendingPathComponent("\(kind.rawValue).jsonl") }
    static func config(_ kind: Kind) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch kind {
        case .codex: home.appendingPathComponent(".codex/hooks.json")
        case .antigravity: home.appendingPathComponent(".gemini/config/hooks.json")
        }
    }

    static let script = #"""
    #!/usr/bin/env python3
    # EdgeDeck AI Agents bridge. Records only event metadata; never prompt or tool input.
    import json, os, sys, time
    kind = sys.argv[1] if len(sys.argv) > 1 else ''
    if kind not in ('codex', 'antigravity'):
        sys.exit(0)
    name = sys.argv[2] if len(sys.argv) > 2 else ''
    try:
        payload = json.load(sys.stdin)
        name = payload.get('hook_event_name') or name
        ident = payload.get('session_id') or payload.get('conversationId')
        if not ident:
            sys.exit(0)
        paths = payload.get('workspacePaths') or []
        cwd = payload.get('cwd') or (paths[0] if paths else '')
        tool = payload.get('tool_name') or (payload.get('toolCall') or {}).get('name')
        path = payload.get('transcript_path') or payload.get('transcriptPath') or ''
        row = dict(ts=time.time(), event=name, id=ident, cwd=cwd, tool=tool,
                   transcript=path, pid=os.getppid())
        directory = os.path.expanduser('~/Library/Application Support/EdgeDeck/agents')
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, kind + '.jsonl'), 'a') as stream:
            stream.write(json.dumps(row, separators=(',', ':')) + '\n')
    except Exception:
        pass
    if kind == 'antigravity':
        print('{"decision":"allow"}' if name == 'PreToolUse' else '{}')
    """#

    static let statuslineScript = #"""
    #!/usr/bin/env python3
    # Preserve the existing statusline and save quota fields only.
    import json, os, subprocess, sys
    raw = sys.stdin.buffer.read()
    try:
        quota = json.loads(raw).get('quota')
        if isinstance(quota, dict):
            directory = os.path.expanduser('~/Library/Application Support/EdgeDeck/agents')
            os.makedirs(directory, exist_ok=True)
            target = os.path.join(directory, 'antigravity-statusline.json')
            temporary = target + '.tmp.' + str(os.getpid())
            with open(temporary, 'w') as stream:
                json.dump({'quota': quota}, stream)
            os.replace(temporary, target)
    except Exception:
        pass
    if len(sys.argv) > 1 and sys.argv[1]:
        result = subprocess.run(sys.argv[1], shell=True, input=raw, capture_output=True)
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
    """#

    static func installed(_ kind: Kind) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch kind {
        case .codex: FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
        case .antigravity: FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli").path)
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity").path)
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-ide").path)
        }
    }

    static func connected(_ kind: Kind) -> Bool {
        guard let root = read(kind), let hooks = (kind == .codex ? root["hooks"] : root["edgedeck"]) as? [String: Any] else { return false }
        let hooksConnected = String(describing: hooks).contains(bridge.path)
        if kind == .codex { return hooksConnected }
        let settings = readAntigravitySettings() ?? [:]
        let command = (settings["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        return hooksConnected && command.contains(statuslineBridge.path)
    }

    static func connect(_ kind: Kind) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: bridge, atomically: true, encoding: .utf8)
        var data = try readStrict(kind)
        let command = "/usr/bin/python3 \(ClaudeConnection.shellQuote(bridge.path)) \(kind.rawValue)"
        if kind == .codex {
            var hooks = data["hooks"] as? [String: Any] ?? [:]
            for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact", "Stop", "Interrupt", "SessionEnd"] {
                var groups = hooks[event] as? [[String: Any]] ?? []
                if !groups.contains(where: { group in (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command } }) {
                    groups.append(["hooks": [["type": "command", "command": command, "timeout": 3]]])
                }
                hooks[event] = groups
            }
            data["hooks"] = hooks
        } else {
            if data["edgedeck"] != nil && !String(describing: data["edgedeck"]!).contains(bridge.path) {
                throw NSError(domain: "EdgeDeck", code: 3, userInfo: [NSLocalizedDescriptionKey: "An Antigravity hook named edgedeck already exists"])
            }
            func handler(_ event: String) -> [String: Any] {
                ["type": "command", "command": command + " " + event, "timeout": 3]
            }
            data["edgedeck"] = [
                "SessionStart": [handler("SessionStart")], "PreInvocation": [handler("PreInvocation")],
                "PostInvocation": [handler("PostInvocation")], "Stop": [handler("Stop")],
                "PreToolUse": [["matcher": "*", "hooks": [handler("PreToolUse")]]],
                "PostToolUse": [["matcher": "*", "hooks": [handler("PostToolUse")]]]
            ]
        }
        try write(data, kind)
        if kind == .antigravity { try connectAntigravityStatusline() }
        return "Connected \(kind.rawValue.capitalized) — restart running sessions to load hooks"
    }

    static func disconnect(_ kind: Kind) throws -> String {
        var data = try readStrict(kind)
        if kind == .codex {
            if var hooks = data["hooks"] as? [String: Any] {
                for (event, value) in hooks {
                    guard let groups = value as? [[String: Any]] else { continue }
                    let kept = groups.compactMap { group -> [String: Any]? in
                        var group = group
                        guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                        let remaining = handlers.filter { !(($0["command"] as? String)?.contains(bridge.path) ?? false) }
                        if remaining.isEmpty { return nil }
                        group["hooks"] = remaining
                        return group
                    }
                    if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
                }
                if hooks.isEmpty { data.removeValue(forKey: "hooks") } else { data["hooks"] = hooks }
            }
        } else if let hook = data["edgedeck"], String(describing: hook).contains(bridge.path) {
            data.removeValue(forKey: "edgedeck")
        }
        try write(data, kind)
        if kind == .antigravity { try disconnectAntigravityStatusline() }
        return "Disconnected \(kind.rawValue.capitalized)"
    }

    private static func readAntigravitySettings() -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: antigravitySettings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    private static func writeAntigravitySettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: antigravitySettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: antigravitySettings.path) {
            let backup = antigravitySettings.appendingPathExtension("edgedeck-\(Int(Date().timeIntervalSince1970)).bak")
            try FileManager.default.copyItem(at: antigravitySettings, to: backup)
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: antigravitySettings, options: .atomic)
    }

    private static func connectAntigravityStatusline() throws {
        try statuslineScript.write(to: statuslineBridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statuslineBridge.path)
        guard var settings = readAntigravitySettings() ?? (FileManager.default.fileExists(atPath: antigravitySettings.path) ? nil : [:]) else {
            throw NSError(domain: "EdgeDeck", code: 4, userInfo: [NSLocalizedDescriptionKey: "Antigravity settings.json is not a JSON object"])
        }
        if let existing = settings["statusLine"], !(existing is [String: Any]) {
            throw NSError(domain: "EdgeDeck", code: 5, userInfo: [NSLocalizedDescriptionKey: "Incompatible Antigravity statusLine configuration"])
        }
        var status = settings["statusLine"] as? [String: Any] ?? [:]
        if let command = status["command"], !(command is String) {
            throw NSError(domain: "EdgeDeck", code: 5, userInfo: [NSLocalizedDescriptionKey: "Incompatible Antigravity statusLine command"])
        }
        let current = status["command"] as? String ?? ""
        if current.contains(statuslineBridge.path) { return }
        status["type"] = "command"
        status["command"] = "/usr/bin/python3 \(ClaudeConnection.shellQuote(statuslineBridge.path)) \(ClaudeConnection.shellQuote(current))"
        settings["statusLine"] = status
        try writeAntigravitySettings(settings)
    }

    private static func disconnectAntigravityStatusline() throws {
        guard var settings = readAntigravitySettings(),
              var status = settings["statusLine"] as? [String: Any],
              let command = status["command"] as? String,
              command.contains(statuslineBridge.path) else { return }
        let words = ClaudeConnection.shellWords(command)
        let previous = words.count > 2 ? words[2] : ""
        if previous.isEmpty { settings.removeValue(forKey: "statusLine") }
        else {
            status["command"] = previous
            settings["statusLine"] = status
        }
        try writeAntigravitySettings(settings)
    }

    private static func read(_ kind: Kind) -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: config(kind)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    private static func readStrict(_ kind: Kind) throws -> [String: Any] {
        let url = config(kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let bytes = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw NSError(domain: "EdgeDeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported hooks.json structure"])
        }
        if kind == .codex, let hooks = object["hooks"], !(hooks is [String: Any]) {
            throw NSError(domain: "EdgeDeck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Incompatible Codex hooks configuration"])
        }
        if kind == .codex, let hooks = object["hooks"] as? [String: Any] {
            for value in hooks.values where !(value is [[String: Any]]) {
                throw NSError(domain: "EdgeDeck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Incompatible Codex hook entries"])
            }
        }
        if kind == .antigravity, let existing = object["edgedeck"], !(existing is [String: Any]) {
            throw NSError(domain: "EdgeDeck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Conflicting Antigravity edgedeck hook"])
        }
        return object
    }

    private static func write(_ object: [String: Any], _ kind: Kind) throws {
        let url = config(kind)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("edgedeck-\(Int(Date().timeIntervalSince1970)).bak")
            try FileManager.default.copyItem(at: url, to: backup)
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: url, options: .atomic)
    }
}

enum AdditionalAgentReader {
    static func antigravityQuota(now: Date = Date()) -> [AgentQuotaUsage] {
        let url = AdditionalAgentConnection.statuslineSnapshot
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              now.timeIntervalSince(modified) < quotaSnapshotLifetime,
              let bytes = try? Data(contentsOf: url) else { return [] }
        return AntigravityQuota.parse(bytes, now: now)
    }

    /// Codex writes rollout files even for conversations that began before Connect.
    /// Read only metadata and event kinds; prompt and transcript bodies are ignored.
    static func codexRollouts(now: Date = Date()) -> [CodexRollout] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let fm = FileManager.default
        let days = [now, now.addingTimeInterval(-86_400)]
        let folders = days.map { date in
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return base.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        }
        var found: [String: CodexRollout] = [:]
        for folder in Set(folders) {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension == "jsonl" {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) < quotaSnapshotLifetime,
                      let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                var head = Data()
                while head.count < 1_048_576 && !head.contains(0x0A) {
                    let chunk = handle.readData(ofLength: 16_384)
                    if chunk.isEmpty { break }
                    head.append(chunk)
                }
                let size = handle.seekToEndOfFile()
                handle.seek(toFileOffset: size > 262_144 ? size - 262_144 : 0)
                let tail = handle.readDataToEndOfFile()
                guard let rollout = CodexRollout.parse(head: head, tail: tail, modified: modified, now: now) else { continue }
                if found[rollout.id].map({ $0.updated < modified }) ?? true { found[rollout.id] = rollout }
            }
        }
        return Array(found.values)
    }

    static func events(_ kind: AdditionalAgentConnection.Kind) -> [AgentEvent] {
        guard let bytes = try? Data(contentsOf: AdditionalAgentConnection.events(kind)),
              let content = String(data: bytes.suffix(2_000_000), encoding: .utf8) else { return [] }
        return AgentEvent.latest(in: content)
    }
}
