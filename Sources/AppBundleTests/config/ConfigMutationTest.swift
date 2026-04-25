@testable import AppBundle
import XCTest

@MainActor
final class ConfigMutationTest: XCTestCase {
    func testAppendNewOnWindowDetectedRule() {
        let updated = assignAppToWorkspaceInConfig("config-version = 2\n", appId: "com.example.App", workspaceName: "W")

        XCTAssertTrue(updated.contains(#"if.app-id = "com.example.App""#))
        XCTAssertTrue(updated.contains(#"run = "move-node-to-workspace W""#))
        assertEquals(parseConfig(updated).errors, [])
    }

    func testUpdateSimpleExactAppRule() {
        let updated = assignAppToWorkspaceInConfig(
            """
            [[on-window-detected]]
                if.app-id = "com.example.App"
                run = "move-node-to-workspace A"
            """,
            appId: "com.example.App",
            workspaceName: "B",
        )

        XCTAssertTrue(updated.contains(#"run = "move-node-to-workspace B""#))
        XCTAssertFalse(updated.contains(#"move-node-to-workspace A"#))
        assertEquals(parseConfig(updated).errors, [])
    }

    func testAppendWhenExistingRuleIsComplex() {
        let updated = assignAppToWorkspaceInConfig(
            """
            [[on-window-detected]]
                if.app-id = "com.example.App"
                if.window-title-regex-substring = "Editor"
                run = "move-node-to-workspace A"
            """,
            appId: "com.example.App",
            workspaceName: "B",
        )

        assertEquals(updated.components(separatedBy: "[[on-window-detected]]").count - 1, 2)
        XCTAssertTrue(updated.contains(#"if.window-title-regex-substring = "Editor""#))
        XCTAssertTrue(updated.contains(#"run = "move-node-to-workspace B""#))
        assertEquals(parseConfig(updated).errors, [])
    }

    @MainActor
    func testCommandFailsWithoutFocusedWindowWithoutWritingConfig() async throws {
        setUpWorkspacesForTests()
        let url = FileManager.default.temporaryDirectory.appending(path: "aeroshift-no-focus-\(UUID().uuidString).toml")
        try "config-version = 2\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        configUrl = url

        let result = try await parseCommand("assign-focused-app-to-workspace W").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(try String(contentsOf: url, encoding: .utf8), "config-version = 2\n")
    }

    func testCommandFailsWithoutBundleIdWithoutWritingConfig() async throws {
        setUpWorkspacesForTests()
        let url = FileManager.default.temporaryDirectory.appending(path: "aeroshift-no-bundle-id-\(UUID().uuidString).toml")
        try "config-version = 2\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        configUrl = url
        _ = TestWindow.new(
            id: 1,
            app: TestApp(rawAppBundleId: nil),
            parent: Workspace.get(byName: "1").rootTilingContainer,
        ).focusWindow()

        let result = try await parseCommand("assign-focused-app-to-workspace W").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(try String(contentsOf: url, encoding: .utf8), "config-version = 2\n")
    }

    func testCommandAppendsRuleAndMovesFocusedWindow() async throws {
        setUpWorkspacesForTests()
        let url = FileManager.default.temporaryDirectory.appending(path: "aeroshift-assign-\(UUID().uuidString).toml")
        try "config-version = 2\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        configUrl = url
        let window = TestWindow.new(
            id: 1,
            app: TestApp(rawAppBundleId: "com.example.Focus"),
            parent: Workspace.get(byName: "1").rootTilingContainer,
        )
        _ = window.focusWindow()

        let result = try await parseCommand("assign-focused-app-to-workspace W").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(window.nodeWorkspace?.name, "W")
        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"if.app-id = "com.example.Focus""#))
        XCTAssertTrue(updated.contains(#"run = "move-node-to-workspace W""#))
        assertEquals(parseConfig(updated).errors, [])
    }

    func testCommandRejectsInvalidWorkspaceName() {
        assertEquals(parseCommand("assign-focused-app-to-workspace next").errorOrNil, "ERROR: 'next' is a reserved workspace name")
    }
}
