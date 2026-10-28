import Foundation

/// What Codex's rollout file says about one conversation. Only metadata and event kinds are read.
public struct CodexRollout: Equatable, Sendable {
    public enum State: Equatable, Sendable { case thinking, idle }

    public let id: String
    public let cwd: String
    public let updated: Date
    public let state: State
    public let quota: AgentQuotaUsage?

    /// `head` holds the file's first line (the session metadata); `tail` its last part, which may start
    /// mid-line. Nil when the first line has no id and cwd.
    public static func parse(head: Data, tail: Data, modified: Date, now: Date) -> CodexRollout? {
        guard let first = head.split(separator: 0x0A).first,
              let metadata = (try? JSONSerialization.jsonObject(with: Data(first))) as? [String: Any],
              let payload = metadata["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String else { return nil }
        var state = State.thinking
        var foundState = false
        var quota: AgentQuotaUsage?
        for line in String(decoding: tail, as: UTF8.self).split(separator: "\n").reversed() {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  row["type"] as? String == "event_msg",
                  let event = row["payload"] as? [String: Any],
                  let type = event["type"] as? String else { continue }
            if !foundState && type == "task_complete" { state = .idle; foundState = true }
            if !foundState && type == "task_started" { state = .thinking; foundState = true }
            if quota == nil && type == "token_count", let limits = event["rate_limits"] as? [String: Any] {
                var windows: [AgentQuotaWindow] = []
                for (key, label, minutes) in [("primary", "5h", 300), ("secondary", "Week", 10_080)] {
                    guard let bucket = limits[key] as? [String: Any],
                          let duration = bucket["window_minutes"] as? Int, duration == minutes,
                          let percent = (bucket["used_percent"] as? NSNumber)?.doubleValue,
                          (0...100).contains(percent) else { continue }
                    let reset = (bucket["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    if let reset, reset <= now { continue }
                    windows.append(AgentQuotaWindow(label: label, used: percent, resets: reset))
                }
                if !windows.isEmpty { quota = AgentQuotaUsage(name: "Codex", windows: windows) }
            }
            if foundState && quota != nil { break }
        }
        return CodexRollout(id: id, cwd: cwd, updated: modified, state: state, quota: quota)
    }
}

/// One line the hook bridge appended to codex.jsonl or antigravity.jsonl.
public struct AgentEvent: Equatable, Sendable {
    public let id: String
    public let event: String
    public let date: Date
    public let cwd: String
    public let tool: String?
    public let transcript: String
    public let pid: Int32?

    public init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, let event = row["event"] as? String,
              let timestamp = row["ts"] as? Double else { return nil }
        self.id = id
        self.event = event
        date = Date(timeIntervalSince1970: timestamp)
        cwd = row["cwd"] as? String ?? ""
        tool = row["tool"] as? String
        transcript = row["transcript"] as? String ?? ""
        pid = (row["pid"] as? NSNumber)?.int32Value
    }

    /// The newest event of each conversation. Lines that aren't events are skipped.
    public static func latest(in content: String) -> [AgentEvent] {
        var latest: [String: AgentEvent] = [:]
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let event = AgentEvent(row) else { continue }
            if latest[event.id].map({ $0.date < event.date }) ?? true { latest[event.id] = event }
        }
        return Array(latest.values)
    }
}
