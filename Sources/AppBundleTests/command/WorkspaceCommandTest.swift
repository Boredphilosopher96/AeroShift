@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseWorkspaceCommand() {
        testParseCommandFail("workspace my mail", msg: "ERROR: Unknown argument 'mail'", exitCode: 2)
        testParseCommandFail("workspace 'my mail'", msg: "ERROR: Whitespace characters are forbidden in workspace names", exitCode: 2)
        assertEquals(parseCommand("workspace").errorOrNil, "ERROR: Argument '(<workspace-name>|next|prev)' is mandatory")
        testParseCommandSucc("workspace next", WorkspaceCmdArgs(target: .relative(.next)))
        testParseCommandSucc("workspace --auto-back-and-forth W", WorkspaceCmdArgs(target: .direct(.parse("W").getOrDie()), autoBackAndForth: true))
        assertEquals(parseCommand("workspace --wrap-around W").errorOrNil, "--wrapAround requires using (next|prev) argument")
        assertEquals(parseCommand("workspace --auto-back-and-forth next").errorOrNil, "--auto-back-and-forth is incompatible with (next|prev)")
        testParseCommandSucc("workspace next --wrap-around", WorkspaceCmdArgs(target: .relative(.next), wrapAround: true))
        assertEquals(parseCommand("workspace --stdin foo").errorOrNil, "--stdin and --no-stdin require using (next|prev) argument")
        testParseCommandSucc("workspace --stdin next", WorkspaceCmdArgs(target: .relative(.next)).copy(\.explicitStdinFlag, true))
        testParseCommandSucc("workspace --no-stdin next", WorkspaceCmdArgs(target: .relative(.next)).copy(\.explicitStdinFlag, false))
    }

    func testWorkspaceSwitchRestoresLastFocusedWindowEvenIfTreeMruChangesWhileAway() {
        let workspaceA = Workspace.get(byName: "a")
        var focusedWindow: Window!
        workspaceA.rootTilingContainer.apply {
            focusedWindow = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(focusedWindow.focusWindow(), true)

        let workspaceB = Workspace.get(byName: "b")
        workspaceB.rootTilingContainer.apply {
            TestWindow.new(id: 3, parent: $0)
        }
        assertEquals(workspaceB.focusWorkspace(), true)
        assertEquals(focus.windowOrNil?.windowId, 3)

        TestWindow.new(id: 4, parent: workspaceA.rootTilingContainer)
        assertEquals(workspaceA.mostRecentWindowRecursive?.windowId, 4)

        assertEquals(workspaceA.focusWorkspace(), true)
        assertEquals(focus.windowOrNil?.windowId, 1)
    }
}
