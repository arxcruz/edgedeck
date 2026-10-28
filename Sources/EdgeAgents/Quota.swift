import Foundation

public struct AgentQuotaWindow: Equatable, Sendable {
    public let label: String
    public let used: Double
    public let resets: Date?

    public init(label: String, used: Double, resets: Date?) {
        self.label = label
        self.used = used
        self.resets = resets
    }
}

public struct AgentQuotaUsage: Equatable, Sendable {
    public let name: String
    public let windows: [AgentQuotaWindow]

    public init(name: String, windows: [AgentQuotaWindow]) {
        self.name = name
        self.windows = windows
    }
}

/// A snapshot older than this no longer says how much of a quota is left.
public let quotaSnapshotLifetime: TimeInterval = 3600

/// Claude's statusline bridge only saves a reading while Claude is active, so a saved percentage can be
/// wrong after a reset or after use elsewhere. Returns the reading only while it can still be trusted.
public func trustedClaudeWindow(used: Double?, resets: Date?, modified: Date, now: Date) -> (used: Double, resets: Date?)? {
    guard let used, (0...100).contains(used),
          now.timeIntervalSince(modified) < quotaSnapshotLifetime,
          resets.map({ $0 > now }) ?? true else { return nil }
    return (used, resets)
}

public enum AntigravityQuota {
    /// The quota buckets of the statusline snapshot, grouped by model family with the 5-hour window first.
    /// Disabled buckets, fractions outside 0...1, past resets and unknown key suffixes are left out.
    public static func parse(_ data: Data, now: Date) -> [AgentQuotaUsage] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let buckets = json["quota"] as? [String: Any] else { return [] }
        let formatter = ISO8601DateFormatter()
        var grouped: [String: [AgentQuotaWindow]] = [:]
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key] as? [String: Any],
                  bucket["disabled"] as? Bool != true,
                  let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue,
                  (0...1).contains(remaining) else { continue }
            let reset = (bucket["reset_time"] as? String).flatMap(formatter.date(from:))
            if let reset, reset <= now { continue }
            let base: String
            let label: String
            if key.hasSuffix("-5h") {
                base = String(key.dropLast(3)); label = "5h"
            } else if key.hasSuffix("-weekly") {
                base = String(key.dropLast(7)); label = "Week"
            } else { continue }
            let name: String = switch base {
            case "gemini": "Gemini"
            case "gemini-argon-wtu": "Argon"
            case "3p": "Other"
            default: base.replacingOccurrences(of: "-", with: " ").capitalized
            }
            grouped[name, default: []].append(AgentQuotaWindow(label: label, used: (1 - remaining) * 100, resets: reset))
        }
        let order = ["Gemini", "Argon", "Other"]
        return grouped.map { AgentQuotaUsage(name: $0.key, windows: $0.value.sorted { $0.label == "5h" && $1.label != "5h" }) }
            .sorted { (order.firstIndex(of: $0.name) ?? 99, $0.name) < (order.firstIndex(of: $1.name) ?? 99, $1.name) }
    }
}
