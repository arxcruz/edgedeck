import Foundation

/// A command made of quoted words, as written into other tools' settings files.
public enum Shell {
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Splits a command made of `quote`d words (plus bare words) back into words.
    public static func words(_ command: String) -> [String] {
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

/// Installs, checks and removes EdgeDeck's hooks in Codex's and Antigravity's settings files. The two
/// folders are parameters so tests can work in a temporary one: `home` holds `.codex` and `.gemini`,
/// `root` is where the bridge scripts and the events they record live.
/// The two agents use different hook schemas, but both can report conversation metadata
/// without exposing prompts or transcript content to EdgeDeck.
public struct AgentConnection {
    public let home: URL
    public let root: URL

    public init(home: URL, root: URL) {
        self.home = home
        self.root = root
    }

    public typealias Kind = AgentKind

    public var bridge: URL { root.appendingPathComponent("event-bridge.py") }
    public var statuslineBridge: URL { root.appendingPathComponent("antigravity-statusline.py") }
    public var statuslineSnapshot: URL { root.appendingPathComponent("antigravity-statusline.json") }
    public var antigravitySettings: URL { home.appendingPathComponent(".gemini/antigravity-cli/settings.json") }
    public func events(_ kind: Kind) -> URL { root.appendingPathComponent("\(kind.rawValue).jsonl") }
    public func config(_ kind: Kind) -> URL {
        switch kind {
        case .codex: home.appendingPathComponent(".codex/hooks.json")
        case .antigravity: home.appendingPathComponent(".gemini/config/hooks.json")
        }
    }

    public static let script = #"""
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

    public static let statuslineScript = #"""
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

    public func installed(_ kind: Kind) -> Bool {
        return switch kind {
        case .codex: FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
        case .antigravity: FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli").path)
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity").path)
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-ide").path)
        }
    }

    public func connected(_ kind: Kind) -> Bool {
        guard let root = read(kind), let hooks = (kind == .codex ? root["hooks"] : root["edgedeck"]) as? [String: Any] else { return false }
        let hooksConnected = String(describing: hooks).contains(bridge.path)
        if kind == .codex { return hooksConnected }
        let settings = readAntigravitySettings() ?? [:]
        let command = (settings["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        return hooksConnected && command.contains(statuslineBridge.path)
    }

    public func connect(_ kind: Kind) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.script.write(to: bridge, atomically: true, encoding: .utf8)
        var data = try readStrict(kind)
        let command = "/usr/bin/python3 \(Shell.quote(bridge.path)) \(kind.rawValue)"
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

    public func disconnect(_ kind: Kind) throws -> String {
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

    /// Copies an existing file next to itself before it is rewritten. Two changes within a second get
    /// different names, so the second doesn't fail on the first's backup.
    private func backUp(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        var backup = url.appendingPathExtension("edgedeck-\(stamp).bak")
        var copy = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            copy += 1
            backup = url.appendingPathExtension("edgedeck-\(stamp)-\(copy).bak")
        }
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private func readAntigravitySettings() -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: antigravitySettings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    private func writeAntigravitySettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: antigravitySettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backUp(antigravitySettings)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: antigravitySettings, options: .atomic)
    }

    private func connectAntigravityStatusline() throws {
        try Self.statuslineScript.write(to: statuslineBridge, atomically: true, encoding: .utf8)
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
        status["command"] = "/usr/bin/python3 \(Shell.quote(statuslineBridge.path)) \(Shell.quote(current))"
        settings["statusLine"] = status
        try writeAntigravitySettings(settings)
    }

    private func disconnectAntigravityStatusline() throws {
        guard var settings = readAntigravitySettings(),
              var status = settings["statusLine"] as? [String: Any],
              let command = status["command"] as? String,
              command.contains(statuslineBridge.path) else { return }
        let words = Shell.words(command)
        let previous = words.count > 2 ? words[2] : ""
        if previous.isEmpty { settings.removeValue(forKey: "statusLine") }
        else {
            status["command"] = previous
            settings["statusLine"] = status
        }
        try writeAntigravitySettings(settings)
    }

    private func read(_ kind: Kind) -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: config(kind)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    private func readStrict(_ kind: Kind) throws -> [String: Any] {
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

    private func write(_ object: [String: Any], _ kind: Kind) throws {
        let url = config(kind)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backUp(url)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: url, options: .atomic)
    }
}
