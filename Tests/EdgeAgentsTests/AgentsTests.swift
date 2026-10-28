import XCTest
@testable import EdgeAgents

final class AgentsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var future: Double { now.timeIntervalSince1970 + 3600 }
    private func iso(_ offset: TimeInterval) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    private func data(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func lines(_ rows: [Any]) -> Data {
        Data(rows.map { String(decoding: data($0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }

    // MARK: Antigravity

    private func bucket(_ remaining: Double, reset: TimeInterval = 3600, disabled: Bool = false) -> [String: Any] {
        ["remaining_fraction": remaining, "reset_time": iso(reset), "disabled": disabled]
    }

    func testAntigravityGroupsWindowsByFamilyWithFiveHourFirst() {
        let quota = AntigravityQuota.parse(data(["quota": [
            "gemini-weekly": bucket(0.5), "gemini-5h": bucket(0.75),
            "3p-5h": bucket(1), "gemini-argon-wtu-5h": bucket(0.9),
        ]]), now: now)
        XCTAssertEqual(quota.map(\.name), ["Gemini", "Argon", "Other"])
        XCTAssertEqual(quota[0].windows.map(\.label), ["5h", "Week"])
        XCTAssertEqual(quota[0].windows[0].used, 25, accuracy: 0.001)
        XCTAssertEqual(quota[0].windows[1].used, 50, accuracy: 0.001)
    }

    func testAntigravityNamesUnknownFamiliesFromTheirKey() {
        let quota = AntigravityQuota.parse(data(["quota": ["claude-sonnet-5h": bucket(0.5)]]), now: now)
        XCTAssertEqual(quota.map(\.name), ["Claude Sonnet"])
    }

    func testAntigravityLeavesOutBucketsThatCannotBeTrusted() {
        let quota = AntigravityQuota.parse(data(["quota": [
            "gemini-5h": bucket(0.5, disabled: true),
            "gemini-weekly": bucket(1.5),
            "3p-5h": bucket(-0.1),
            "3p-weekly": bucket(0.5, reset: -1),
            "other-monthly": bucket(0.5),
        ]]), now: now)
        XCTAssertEqual(quota, [])
    }

    func testAntigravityWithoutQuotaOrWithGarbageIsEmpty() {
        XCTAssertEqual(AntigravityQuota.parse(data(["other": 1]), now: now), [])
        XCTAssertEqual(AntigravityQuota.parse(Data("not json".utf8), now: now), [])
    }

    func testAntigravityBucketWithoutResetStillShows() {
        let quota = AntigravityQuota.parse(data(["quota": ["gemini-5h": ["remaining_fraction": 0.2]]]), now: now)
        XCTAssertEqual(quota.first?.windows.first?.resets, nil)
        XCTAssertEqual(quota.first?.windows.first?.used ?? 0, 80, accuracy: 0.001)
    }

    // MARK: Claude

    func testClaudeWindowIsTrustedOnlyWhileFreshAndInRange() {
        let fresh = now.addingTimeInterval(-60), reset = now.addingTimeInterval(600)
        XCTAssertEqual(trustedClaudeWindow(used: 40, resets: reset, modified: fresh, now: now)?.used, 40)
        XCTAssertEqual(trustedClaudeWindow(used: 40, resets: nil, modified: fresh, now: now)?.used, 40)
        XCTAssertNil(trustedClaudeWindow(used: nil, resets: reset, modified: fresh, now: now))
        XCTAssertNil(trustedClaudeWindow(used: 101, resets: reset, modified: fresh, now: now))
        XCTAssertNil(trustedClaudeWindow(used: -1, resets: reset, modified: fresh, now: now))
        XCTAssertNil(trustedClaudeWindow(used: 40, resets: now.addingTimeInterval(-1), modified: fresh, now: now))
        XCTAssertNil(trustedClaudeWindow(used: 40, resets: reset, modified: now.addingTimeInterval(-3601), now: now))
    }

    // MARK: Codex rollouts

    private var meta: [String: Any] { ["type": "session_meta", "payload": ["id": "abc", "cwd": "/work/app"]] }

    private func event(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": type].merging(extra) { $1 }]
    }

    private func limits(primaryMinutes: Int = 300, primary: Double = 20, secondary: Double = 60, reset: Double? = nil) -> [String: Any] {
        let resets = reset ?? future
        return ["rate_limits": [
            "primary": ["window_minutes": primaryMinutes, "used_percent": primary, "resets_at": resets],
            "secondary": ["window_minutes": 10_080, "used_percent": secondary, "resets_at": resets],
        ]]
    }

    private func parse(_ rows: [Any]) -> CodexRollout? {
        CodexRollout.parse(head: lines([meta]), tail: lines(rows), modified: now, now: now)
    }

    func testRolloutNeedsIdAndCwdInItsFirstLine() {
        XCTAssertNil(CodexRollout.parse(head: Data("{}".utf8), tail: Data(), modified: now, now: now))
        XCTAssertNil(CodexRollout.parse(head: Data("garbage".utf8), tail: Data(), modified: now, now: now))
        let rollout = parse([])
        XCTAssertEqual(rollout?.id, "abc")
        XCTAssertEqual(rollout?.cwd, "/work/app")
        XCTAssertEqual(rollout?.state, .thinking)
    }

    func testRolloutStateIsTheLatestTaskEvent() {
        XCTAssertEqual(parse([event("task_started"), event("task_complete")])?.state, .idle)
        XCTAssertEqual(parse([event("task_complete"), event("task_started")])?.state, .thinking)
    }

    func testRolloutQuotaReadsBothWindows() {
        let quota = parse([event("token_count", limits())])?.quota
        XCTAssertEqual(quota?.name, "Codex")
        XCTAssertEqual(quota?.windows.map(\.label), ["5h", "Week"])
        XCTAssertEqual(quota?.windows.map(\.used), [20, 60])
    }

    func testRolloutQuotaUsesTheNewestReading() {
        let rows = [event("token_count", limits(primary: 10)), event("token_count", limits(primary: 30))]
        XCTAssertEqual(parse(rows)?.quota?.windows.first?.used, 30)
    }

    func testRolloutQuotaSkipsWindowsOfTheWrongLengthOutOfRangeOrReset() {
        XCTAssertEqual(parse([event("token_count", limits(primaryMinutes: 60))])?.quota?.windows.map(\.label), ["Week"])
        XCTAssertEqual(parse([event("token_count", limits(primary: 120, secondary: 120))])?.quota, nil)
        XCTAssertEqual(parse([event("token_count", limits(reset: now.timeIntervalSince1970 - 1))])?.quota, nil)
    }

    func testRolloutTailMayStartMidLine() {
        let tail = Data("""
        ,"cut off":true}
        \(String(decoding: data(event("task_complete")), as: UTF8.self))
        """.utf8)
        let rollout = CodexRollout.parse(head: lines([meta]), tail: tail, modified: now, now: now)
        XCTAssertEqual(rollout?.state, .idle)
    }

    // MARK: Hook events

    func testEventNeedsIdNameAndTimestamp() {
        XCTAssertNotNil(AgentEvent(["id": "a", "event": "Stop", "ts": 1.0]))
        XCTAssertNil(AgentEvent(["event": "Stop", "ts": 1.0]))
        XCTAssertNil(AgentEvent(["id": "a", "ts": 1.0]))
        XCTAssertNil(AgentEvent(["id": "a", "event": "Stop"]))
    }

    func testEventOptionalFieldsDefault() {
        let event = AgentEvent(["id": "a", "event": "Stop", "ts": 1.0])
        XCTAssertEqual(event?.cwd, "")
        XCTAssertEqual(event?.transcript, "")
        XCTAssertNil(event?.tool)
        XCTAssertNil(event?.pid)
        XCTAssertEqual(AgentEvent(["id": "a", "event": "Stop", "ts": 1.0, "pid": 42])?.pid, 42)
    }

    func testLatestKeepsTheNewestEventOfEachConversationAndSkipsJunk() {
        let content = """
        {"id":"a","event":"PreToolUse","ts":10,"tool":"Bash"}
        {"id":"b","event":"Stop","ts":5}
        not json
        {"id":"a","event":"Stop","ts":20}
        {"id":"a","event":"PermissionRequest","ts":15}
        {"event":"Stop","ts":30}
        """
        let latest = AgentEvent.latest(in: content).sorted { $0.id < $1.id }
        XCTAssertEqual(latest.map(\.id), ["a", "b"])
        XCTAssertEqual(latest.map(\.event), ["Stop", "Stop"])
    }
}
