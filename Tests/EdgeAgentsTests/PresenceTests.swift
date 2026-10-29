import XCTest
@testable import EdgeAgents

final class PresenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A made-up process table.
    private struct Process { var name: String; var terminal = true; var cwd: String? }

    private func probe(_ table: [Int32: Process]) -> ProcessProbe {
        ProcessProbe(isAlive: { table[$0] != nil },
                     name: { table[$0]?.name ?? "" },
                     hasTerminal: { table[$0]?.terminal ?? false },
                     workingDirectory: { table[$0]?.cwd },
                     pids: { name in table.filter { $0.value.name.lowercased().contains(name) }.map(\.key).sorted() })
    }

    private func event(_ name: String = "Stop", tool: String? = nil, age: TimeInterval = 10, cwd: String = "/work/app",
                       pid: Int32? = nil, transcript: String = "") -> AgentEvent {
        var row: [String: Any] = ["id": "s", "event": name, "ts": now.timeIntervalSince1970 - age, "cwd": cwd, "transcript": transcript]
        if let tool { row["tool"] = tool }
        if let pid { row["pid"] = pid }
        return AgentEvent(row)!
    }

    private func rollout(age: TimeInterval = 10, cwd: String = "/work/app") -> CodexRollout {
        CodexRollout(id: "r", cwd: cwd, updated: now.addingTimeInterval(-age), state: .idle, quota: nil)
    }

    // MARK: Event state

    func testEventNamesMapToStates() {
        XCTAssertEqual(event("Stop").state, .idle)
        XCTAssertEqual(event("Interrupt").state, .idle)
        XCTAssertEqual(event("PermissionRequest", tool: "Bash").state, .needsYou("Bash"))
        XCTAssertEqual(event("PreToolUse", tool: "Edit").state, .running("Edit"))
        XCTAssertEqual(event("PreToolUse").state, .running(""))
        XCTAssertEqual(event("UserPromptSubmit").state, .thinking)
    }

    // MARK: Hook events

    func testSenderStillRunningTheAgentInATerminalIsAliveWithItsPid() {
        let found = AgentPresence.resolve(event(pid: 10), kind: .codex, desktopAppRunning: false,
                                          probe: probe([Int32(10): Process(name: "codex")]), now: now)
        XCTAssertEqual(found, AgentPresence.Found(pid: 10))
    }

    func testSenderMatchesTheAgentsProcessNamesCaseInsensitively() {
        let table: [Int32: Process] = [10: Process(name: "Antigravity-CLI")]
        XCTAssertNotNil(AgentPresence.resolve(event(pid: 10), kind: .antigravity, desktopAppRunning: false, probe: probe(table), now: now))
        XCTAssertNil(AgentPresence.resolve(event(pid: 10), kind: .codex, desktopAppRunning: false, probe: probe(table), now: now))
    }

    func testSenderThatReusedItsPidForAnotherProgramIsGone() {
        let found = AgentPresence.resolve(event(pid: 10), kind: .codex, desktopAppRunning: false,
                                          probe: probe([Int32(10): Process(name: "vim")]), now: now)
        XCTAssertNil(found)
    }

    func testSenderThatExitedIsGone() {
        XCTAssertNil(AgentPresence.resolve(event(pid: 10), kind: .codex, desktopAppRunning: false, probe: probe([:]), now: now))
    }

    func testSenderWithoutATerminalIsNotAliveByItself() {
        // Codex's background app-server keeps running after the app quits.
        let daemon = probe([Int32(10): Process(name: "codex", terminal: false)])
        XCTAssertNil(AgentPresence.resolve(event(pid: 10), kind: .codex, desktopAppRunning: false, probe: daemon, now: now))
    }

    func testSenderWithoutATerminalLivesWhileTheDesktopAppRunsAndTheEventIsRecent() {
        let daemon = probe([Int32(10): Process(name: "codex", terminal: false)])
        XCTAssertEqual(AgentPresence.resolve(event(age: 10, pid: 10), kind: .codex, desktopAppRunning: true, probe: daemon, now: now),
                       AgentPresence.Found(pid: nil))
        XCTAssertNil(AgentPresence.resolve(event(age: 400, pid: 10), kind: .codex, desktopAppRunning: true, probe: daemon, now: now))
    }

    func testEventWithoutPidFindsTheTerminalAgentInItsFolder() {
        let table: [Int32: Process] = [20: Process(name: "codex", cwd: "/elsewhere"), 21: Process(name: "codex", cwd: "/work/app")]
        let found = AgentPresence.resolve(event(), kind: .codex, desktopAppRunning: false, probe: probe(table), now: now)
        XCTAssertEqual(found, AgentPresence.Found(pid: 21))
    }

    func testEventWithoutPidIgnoresAgentsWithoutATerminalOrInOtherFolders() {
        let table: [Int32: Process] = [20: Process(name: "codex", terminal: false, cwd: "/work/app"), 21: Process(name: "codex", cwd: "/elsewhere")]
        XCTAssertNil(AgentPresence.resolve(event(), kind: .codex, desktopAppRunning: false, probe: probe(table), now: now))
    }

    func testEventWithAPidDoesNotFallBackToSearchingByFolder() {
        let table: [Int32: Process] = [21: Process(name: "codex", cwd: "/work/app")]
        XCTAssertNil(AgentPresence.resolve(event(pid: 10), kind: .codex, desktopAppRunning: false, probe: probe(table), now: now))
    }

    func testDesktopAppKeepsARecentEventAliveButNotAnOldOne() {
        let none = probe([:])
        XCTAssertEqual(AgentPresence.resolve(event(age: 299), kind: .codex, desktopAppRunning: true, probe: none, now: now),
                       AgentPresence.Found(pid: nil))
        XCTAssertNil(AgentPresence.resolve(event(age: 300), kind: .codex, desktopAppRunning: true, probe: none, now: now))
        XCTAssertNil(AgentPresence.resolve(event(age: 10), kind: .codex, desktopAppRunning: false, probe: none, now: now))
    }

    func testAntigravityCLITranscriptIsNotTheDesktopApps() {
        let none = probe([:])
        let cli = event(transcript: "/Users/me/.gemini/antigravity-cli/conversations/s.pb")
        XCTAssertNil(AgentPresence.resolve(cli, kind: .antigravity, desktopAppRunning: true, probe: none, now: now))
        XCTAssertNotNil(AgentPresence.resolve(event(transcript: "/Users/me/.gemini/antigravity/s.pb"), kind: .antigravity,
                                              desktopAppRunning: true, probe: none, now: now))
    }

    // MARK: Codex rollouts

    func testRolloutIsAliveWhileTheDesktopAppRuns() {
        XCTAssertEqual(AgentPresence.resolve(rollout(), desktopAppRunning: true, probe: probe([:]), now: now),
                       AgentPresence.Found(pid: nil))
    }

    func testRolloutFindsTheTerminalCodexInItsFolder() {
        let table: [Int32: Process] = [30: Process(name: "codex", cwd: "/other"), 31: Process(name: "codex", cwd: "/work/app")]
        XCTAssertEqual(AgentPresence.resolve(rollout(), desktopAppRunning: false, probe: probe(table), now: now),
                       AgentPresence.Found(pid: 31))
    }

    func testRolloutWithNoAppAndNoProcessIsOver() {
        XCTAssertNil(AgentPresence.resolve(rollout(), desktopAppRunning: false, probe: probe([:]), now: now))
    }

    func testRolloutQuietForFiveMinutesIsOver() {
        XCTAssertNotNil(AgentPresence.resolve(rollout(age: 299), desktopAppRunning: true, probe: probe([:]), now: now))
        XCTAssertNil(AgentPresence.resolve(rollout(age: 300), desktopAppRunning: true, probe: probe([:]), now: now))
    }
}
