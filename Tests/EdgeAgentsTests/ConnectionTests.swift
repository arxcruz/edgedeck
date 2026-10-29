import XCTest
@testable import EdgeAgents

final class ConnectionTests: XCTestCase {
    private var temp: URL!
    private var connection: AgentConnection!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("edgedeck-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        connection = AgentConnection(home: temp.appendingPathComponent("home"), root: temp.appendingPathComponent("support/agents"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: Helpers

    private func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func backups(of url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(url.lastPathComponent + ".edgedeck-") && $0.hasSuffix(".bak") }
    }

    private func commands(in hooks: [String: Any], event: String) -> [String] {
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                               "PreCompact", "PostCompact", "Stop", "Interrupt", "SessionEnd"]

    // MARK: Shell words

    func testQuotedWordsComeBackAsTheyWentIn() {
        for word in ["plain", "with space", "it's", "a'b'c", "", "$HOME \"x\"", "tab\there"] {
            XCTAssertEqual(Shell.words(Shell.quote(word)), [word], word)
        }
        XCTAssertEqual(Shell.words("/usr/bin/python3 \(Shell.quote("/a b/c.py")) \(Shell.quote(""))"),
                       ["/usr/bin/python3", "/a b/c.py", ""])
    }

    // MARK: Codex

    func testConnectingCodexAddsOurHookToEveryEvent() throws {
        XCTAssertFalse(connection.connected(.codex))
        _ = try connection.connect(.codex)
        let hooks = try XCTUnwrap(read(connection.config(.codex))["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(codexEvents))
        for event in codexEvents {
            let found = commands(in: hooks, event: event)
            XCTAssertEqual(found.count, 1, event)
            XCTAssertTrue(found[0].hasSuffix(" codex"), event)
            XCTAssertTrue(found[0].contains(connection.bridge.path), event)
        }
        XCTAssertTrue(connection.connected(.codex))
        XCTAssertTrue(FileManager.default.fileExists(atPath: connection.bridge.path))
    }

    func testConnectingCodexTwiceDoesNotDuplicateHooks() throws {
        _ = try connection.connect(.codex)
        _ = try connection.connect(.codex)
        let hooks = try XCTUnwrap(read(connection.config(.codex))["hooks"] as? [String: Any])
        for event in codexEvents { XCTAssertEqual(commands(in: hooks, event: event).count, 1, event) }
    }

    func testConnectingCodexKeepsEverythingElse() throws {
        let theirs: [String: Any] = ["type": "command", "command": "/usr/local/bin/mine", "timeout": 5]
        try write(["model": "x", "hooks": ["Stop": [["hooks": [theirs]]], "Custom": [["hooks": [theirs]]]]],
                  to: connection.config(.codex))
        _ = try connection.connect(.codex)
        let root = try read(connection.config(.codex))
        XCTAssertEqual(root["model"] as? String, "x")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(commands(in: hooks, event: "Custom"), ["/usr/local/bin/mine"])
        XCTAssertEqual(commands(in: hooks, event: "Stop").first, "/usr/local/bin/mine")
        XCTAssertEqual(commands(in: hooks, event: "Stop").count, 2)
    }

    func testDisconnectingCodexRemovesOnlyOurHooks() throws {
        let theirs: [String: Any] = ["type": "command", "command": "/usr/local/bin/mine"]
        try write(["model": "x", "hooks": ["Stop": [["hooks": [theirs]]]]], to: connection.config(.codex))
        _ = try connection.connect(.codex)
        _ = try connection.disconnect(.codex)
        let root = try read(connection.config(.codex))
        XCTAssertEqual(root["model"] as? String, "x")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["Stop"])
        XCTAssertEqual(commands(in: hooks, event: "Stop"), ["/usr/local/bin/mine"])
        XCTAssertFalse(connection.connected(.codex))
    }

    func testDisconnectingCodexLeavesNoEmptyHooksBehind() throws {
        try write(["model": "x"], to: connection.config(.codex))
        _ = try connection.connect(.codex)
        _ = try connection.disconnect(.codex)
        let root = try read(connection.config(.codex))
        XCTAssertNil(root["hooks"])
        XCTAssertEqual(root["model"] as? String, "x")
    }

    func testChangingAnExistingCodexConfigBacksItUpFirst() throws {
        try write(["model": "x"], to: connection.config(.codex))
        XCTAssertEqual(backups(of: connection.config(.codex)).count, 0)
        _ = try connection.connect(.codex)
        XCTAssertEqual(backups(of: connection.config(.codex)).count, 1)
        let backup = connection.config(.codex).deletingLastPathComponent()
            .appendingPathComponent(backups(of: connection.config(.codex))[0])
        XCTAssertEqual(try read(backup)["model"] as? String, "x")
        XCTAssertNil(try read(backup)["hooks"])
    }

    func testTwoChangesInTheSameSecondKeepBothBackups() throws {
        try write(["model": "x"], to: connection.config(.codex))
        _ = try connection.connect(.codex)
        _ = try connection.disconnect(.codex)
        _ = try connection.connect(.codex)
        XCTAssertEqual(backups(of: connection.config(.codex)).count, 3)
    }

    func testANewCodexConfigNeedsNoBackup() throws {
        _ = try connection.connect(.codex)
        XCTAssertEqual(backups(of: connection.config(.codex)).count, 0)
    }

    func testCodexConfigsItCannotMergeAreRefusedAndLeftAlone() throws {
        let url = connection.config(.codex)
        for bad: Any in [["hooks": "nope"], ["hooks": ["Stop": "nope"]], ["hooks": ["Stop": [1]]]] {
            try write(bad, to: url)
            let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try connection.connect(.codex))
            XCTAssertThrowsError(try connection.disconnect(.codex))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        try Data("[1, 2]".utf8).write(to: url)
        XCTAssertThrowsError(try connection.connect(.codex))
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try connection.connect(.codex))
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
    }

    func testInstalledMeansTheAgentsFolderExists() throws {
        XCTAssertFalse(connection.installed(.codex))
        XCTAssertFalse(connection.installed(.antigravity))
        try FileManager.default.createDirectory(at: connection.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        XCTAssertTrue(connection.installed(.codex))
        for folder in [".gemini/antigravity-cli", ".gemini/antigravity", ".gemini/antigravity-ide"] {
            try? FileManager.default.removeItem(at: connection.home.appendingPathComponent(".gemini"))
            XCTAssertFalse(connection.installed(.antigravity), folder)
            try FileManager.default.createDirectory(at: connection.home.appendingPathComponent(folder), withIntermediateDirectories: true)
            XCTAssertTrue(connection.installed(.antigravity), folder)
        }
    }

    // MARK: Antigravity

    private func statusLineCommand() throws -> String? {
        (try read(connection.antigravitySettings)["statusLine"] as? [String: Any])?["command"] as? String
    }

    func testConnectingAntigravityAddsHooksAndWrapsTheStatusline() throws {
        _ = try connection.connect(.antigravity)
        let hook = try XCTUnwrap(read(connection.config(.antigravity))["edgedeck"] as? [String: Any])
        XCTAssertEqual(Set(hook.keys), ["SessionStart", "PreInvocation", "PostInvocation", "Stop", "PreToolUse", "PostToolUse"])
        let command = try XCTUnwrap(statusLineCommand())
        XCTAssertTrue(command.contains(connection.statuslineBridge.path))
        XCTAssertTrue(connection.connected(.antigravity))
        let mode = try FileManager.default.attributesOfItem(atPath: connection.statuslineBridge.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testAntigravityIsNotConnectedWithoutItsStatusline() throws {
        _ = try connection.connect(.antigravity)
        try write(["colorScheme": "dark"], to: connection.antigravitySettings)
        XCTAssertFalse(connection.connected(.antigravity))
    }

    func testTheStatuslineWrapsTheExistingCommandAndDisconnectingRestoresIt() throws {
        let original = "/bin/sh -c 'echo \"it'\\''s ok\"' # a b"
        try write(["colorScheme": "dark", "trustedWorkspaces": ["/a"], "statusLine": ["type": "command", "command": original, "padding": 1]],
                  to: connection.antigravitySettings)
        _ = try connection.connect(.antigravity)
        XCTAssertEqual(Shell.words(try XCTUnwrap(statusLineCommand()))[2], original)
        _ = try connection.disconnect(.antigravity)
        let settings = try read(connection.antigravitySettings)
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String, original)
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["padding"] as? Int, 1)
        XCTAssertEqual(settings["colorScheme"] as? String, "dark")
        XCTAssertEqual(settings["trustedWorkspaces"] as? [String], ["/a"])
        XCTAssertNil(try read(connection.config(.antigravity))["edgedeck"])
        XCTAssertFalse(connection.connected(.antigravity))
    }

    func testDisconnectingWithoutAPreviousStatuslineRemovesIt() throws {
        try write(["colorScheme": "dark"], to: connection.antigravitySettings)
        _ = try connection.connect(.antigravity)
        _ = try connection.disconnect(.antigravity)
        let settings = try read(connection.antigravitySettings)
        XCTAssertNil(settings["statusLine"])
        XCTAssertEqual(settings["colorScheme"] as? String, "dark")
    }

    func testConnectingAntigravityTwiceDoesNotWrapTwice() throws {
        try write(["statusLine": ["type": "command", "command": "/bin/echo hi"]], to: connection.antigravitySettings)
        _ = try connection.connect(.antigravity)
        let once = try statusLineCommand()
        _ = try connection.connect(.antigravity)
        XCTAssertEqual(try statusLineCommand(), once)
        _ = try connection.disconnect(.antigravity)
        XCTAssertEqual(try statusLineCommand(), "/bin/echo hi")
    }

    func testAnotherHookNamedEdgedeckIsNotOverwritten() throws {
        try write(["edgedeck": ["Stop": []]], to: connection.config(.antigravity))
        XCTAssertThrowsError(try connection.connect(.antigravity))
        XCTAssertEqual((try read(connection.config(.antigravity))["edgedeck"] as? [String: Any])?.keys.sorted(), ["Stop"])
        _ = try? connection.disconnect(.antigravity)
        XCTAssertNotNil(try read(connection.config(.antigravity))["edgedeck"])
    }

    func testStatuslineSettingsItCannotWrapAreRefused() throws {
        for bad: Any in ["text", ["command": 5]] {
            try write(["statusLine": bad], to: connection.antigravitySettings)
            let before = try Data(contentsOf: connection.antigravitySettings)
            XCTAssertThrowsError(try connection.connect(.antigravity))
            XCTAssertEqual(try Data(contentsOf: connection.antigravitySettings), before)
        }
        try Data("[]".utf8).write(to: connection.antigravitySettings)
        XCTAssertThrowsError(try connection.connect(.antigravity))
    }

    func testChangingAnExistingAntigravitySettingsFileBacksItUp() throws {
        try write(["colorScheme": "dark"], to: connection.antigravitySettings)
        _ = try connection.connect(.antigravity)
        XCTAssertEqual(backups(of: connection.antigravitySettings).count, 1)
    }

    func testOtherAgentsConnectionIsUntouched() throws {
        _ = try connection.connect(.codex)
        XCTAssertFalse(connection.connected(.antigravity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: connection.config(.antigravity).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: connection.antigravitySettings.path))
    }
}
