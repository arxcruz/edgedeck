import XCTest
@testable import EdgeAgents

/// Runs the embedded Python bridges for real, with HOME pointing at a temporary folder.
final class BridgeScriptTests: XCTestCase {
    private var home: URL!
    private var agents: URL { home.appendingPathComponent("Library/Application Support/EdgeDeck/agents") }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "python3 isn't installed")
        home = FileManager.default.temporaryDirectory.appendingPathComponent("edgedeck-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func run(script: String, arguments: [String], input: Data) throws -> (out: String, status: Int32) {
        let file = home.appendingPathComponent("script.py")
        try Data(script.utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [file.path] + arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    private func bridge(_ kind: String, _ event: String = "", payload: [String: Any]) throws -> String {
        try run(script: AgentConnection.script, arguments: [kind, event], input: JSONSerialization.data(withJSONObject: payload)).out
    }

    private func recorded(_ kind: String) throws -> [AgentEvent] {
        AgentEvent.latest(in: try String(contentsOf: agents.appendingPathComponent(kind + ".jsonl"), encoding: .utf8))
    }

    func testCodexEventIsRecordedInTheFormatTheAppReads() throws {
        _ = try bridge("codex", payload: ["hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/work/app",
                                          "tool_name": "Bash", "transcript_path": "/t.jsonl",
                                          "tool_input": ["command": "secret"], "prompt": "secret"])
        let event = try XCTUnwrap(recorded("codex").first)
        XCTAssertEqual(event.id, "s1")
        XCTAssertEqual(event.event, "PreToolUse")
        XCTAssertEqual(event.cwd, "/work/app")
        XCTAssertEqual(event.tool, "Bash")
        XCTAssertEqual(event.transcript, "/t.jsonl")
        XCTAssertNotNil(event.pid)
        XCTAssertEqual(event.date.timeIntervalSinceNow, 0, accuracy: 30)
        XCTAssertEqual(event.state, .running("Bash"))
    }

    func testNeitherPromptNorToolInputIsKept() throws {
        _ = try bridge("codex", payload: ["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                                          "prompt": "my-secret-prompt", "tool_input": ["command": "my-secret-command"]])
        let text = try String(contentsOf: agents.appendingPathComponent("codex.jsonl"), encoding: .utf8)
        XCTAssertFalse(text.contains("my-secret"))
    }

    func testAntigravityEventUsesItsOwnFieldNames() throws {
        let out = try bridge("antigravity", "PreToolUse", payload: ["conversationId": "c1", "workspacePaths": ["/w/a", "/w/b"],
                                                           "toolCall": ["name": "run_command"], "transcriptPath": "/x/t"])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), #"{"decision":"allow"}"#)
        let event = try XCTUnwrap(recorded("antigravity").first)
        XCTAssertEqual(event.id, "c1")
        XCTAssertEqual(event.event, "PreToolUse")
        XCTAssertEqual(event.cwd, "/w/a")
        XCTAssertEqual(event.tool, "run_command")
        XCTAssertEqual(event.transcript, "/x/t")
    }

    func testAntigravityAnswersEveryOtherEventWithAnEmptyObject() throws {
        let out = try bridge("antigravity", "Stop", payload: ["conversationId": "c1"])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
    }

    func testEventsWithoutASessionIdAreIgnored() throws {
        _ = try bridge("codex", "Stop", payload: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.appendingPathComponent("codex.jsonl").path))
    }

    func testAnUnknownAgentIsIgnored() throws {
        let out = try bridge("other", "Stop", payload: ["session_id": "s1"])
        XCTAssertEqual(out, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path))
    }

    func testGarbageInputNeverFailsTheAgent() throws {
        let result = try run(script: AgentConnection.script, arguments: ["codex", "Stop"], input: Data("not json".utf8))
        XCTAssertEqual(result.status, 0)
    }

    func testEventsAppendInOrderAndTheNewestWins() throws {
        _ = try bridge("codex", payload: ["hook_event_name": "UserPromptSubmit", "session_id": "s1"])
        Thread.sleep(forTimeInterval: 0.02)
        _ = try bridge("codex", payload: ["hook_event_name": "Stop", "session_id": "s1"])
        let events = try recorded("codex")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.state, .idle)
    }

    // MARK: Statusline

    private func statusline(_ previous: String, _ payload: [String: Any]) throws -> String {
        try run(script: AgentConnection.statuslineScript, arguments: previous.isEmpty ? [] : [previous],
                input: JSONSerialization.data(withJSONObject: payload)).out
    }

    func testTheStatuslineSavesTheQuotaAndTheAppParsesIt() throws {
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        _ = try statusline("", ["quota": ["gemini-5h": ["remaining_fraction": 0.4, "reset_time": reset]], "other": "ignored"])
        let snapshot = agents.appendingPathComponent("antigravity-statusline.json")
        let saved = try Data(contentsOf: snapshot)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("ignored"))
        let quota = AntigravityQuota.parse(saved, now: Date())
        XCTAssertEqual(quota.first?.name, "Gemini")
        XCTAssertEqual(quota.first?.windows.first?.used ?? 0, 60, accuracy: 0.001)
    }

    func testTheStatuslineHandsTheInputToTheOriginalCommandAndPrintsItsOutput() throws {
        let out = try statusline("/usr/bin/tr a-z A-Z", ["quota": [:], "word": "hello"])
        XCTAssertTrue(out.contains("HELLO"))
        let plain = try statusline("", ["word": "hello"])
        XCTAssertEqual(plain, "")
    }

    func testWithoutQuotaNothingIsSaved() throws {
        _ = try statusline("", ["word": "hello"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.appendingPathComponent("antigravity-statusline.json").path))
    }
}
