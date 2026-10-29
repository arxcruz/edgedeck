import AppKit
import EdgeAgents

/// EdgeDeck's connection to Codex and Antigravity on this Mac: the logic is in `AgentConnection`.
enum AdditionalAgentConnection {
    typealias Kind = AgentKind

    private static let live = AgentConnection(
        home: FileManager.default.homeDirectoryForCurrentUser,
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeDeck/agents", isDirectory: true))

    static var root: URL { live.root }
    static var statuslineSnapshot: URL { live.statuslineSnapshot }
    static func events(_ kind: Kind) -> URL { live.events(kind) }
    static func installed(_ kind: Kind) -> Bool { live.installed(kind) }
    static func connected(_ kind: Kind) -> Bool { live.connected(kind) }
    static func connect(_ kind: Kind) throws -> String { try live.connect(kind) }
    static func disconnect(_ kind: Kind) throws -> String { try live.disconnect(kind) }
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
