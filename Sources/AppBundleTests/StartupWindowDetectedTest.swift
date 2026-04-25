@testable import AppBundle
import Common
import XCTest

@MainActor
final class StartupWindowDetectedTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testStartupReplayMovesExistingMatchingWindows() async throws {
        config.onWindowDetected = [
            WindowDetectedCallback(rawRun: [MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "W"))])
                .copy(\.matcher.appId, "com.example.Terminal"),
        ]
        let app = TestApp(rawAppBundleId: "com.example.Terminal")
        let startWorkspace = Workspace.get(byName: "1")
        let window = TestWindow.new(id: 1, app: app, parent: startWorkspace.rootTilingContainer)

        try await $_isStartup.withValue(true) {
            try await replayStartupWindowDetectedCallbacks()
        }

        assertEquals(window.nodeWorkspace?.name, "W")
    }

    func testStartupOnlyMatcherRunsOnlyDuringStartupReplay() async throws {
        config.onWindowDetected = [
            WindowDetectedCallback(
                matcher: WindowDetectedCallbackMatcher(appId: "com.example.Editor", duringAeroshiftStartup: true),
                rawRun: [MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "E"))],
            ),
        ]
        let app = TestApp(rawAppBundleId: "com.example.Editor")
        let window = TestWindow.new(id: 1, app: app, parent: Workspace.get(byName: "1").rootTilingContainer)

        try await $_isStartup.withValue(false) {
            try await tryOnWindowDetected(window)
        }
        assertEquals(window.nodeWorkspace?.name, "1")

        try await $_isStartup.withValue(true) {
            try await replayStartupWindowDetectedCallbacks()
        }
        assertEquals(window.nodeWorkspace?.name, "E")
    }

    func testNonStartupMatcherDoesNotRunDuringStartupReplay() async throws {
        config.onWindowDetected = [
            WindowDetectedCallback(
                matcher: WindowDetectedCallbackMatcher(appId: "com.example.Chat", duringAeroshiftStartup: false),
                rawRun: [MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "C"))],
            ),
        ]
        let app = TestApp(rawAppBundleId: "com.example.Chat")
        let window = TestWindow.new(id: 1, app: app, parent: Workspace.get(byName: "1").rootTilingContainer)

        try await $_isStartup.withValue(true) {
            try await replayStartupWindowDetectedCallbacks()
        }

        assertEquals(window.nodeWorkspace?.name, "1")
    }

    func testCheckFurtherCallbacksOrderingIsPreservedDuringStartupReplay() async throws {
        config.onWindowDetected = [
            WindowDetectedCallback(rawRun: [MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "A"))]),
            WindowDetectedCallback(rawRun: [MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "B"))]),
        ]
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "1").rootTilingContainer)

        try await $_isStartup.withValue(true) {
            try await replayStartupWindowDetectedCallbacks()
        }

        assertEquals(window.nodeWorkspace?.name, "A")
    }

    func testPopupWindowsAreNotProcessedDuringStartupReplay() async throws {
        config.onWindowDetected = [
            WindowDetectedCallback(rawRun: [MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "P"))]),
        ]
        let window = TestWindow.new(id: 1, parent: macosPopupWindowsContainer)

        try await $_isStartup.withValue(true) {
            try await replayStartupWindowDetectedCallbacks()
        }

        XCTAssertNil(window.nodeWorkspace)
    }

    func testSeededStartupAssignmentSimulationConverges() async throws {
        for seed in [1 as UInt64, 2, 7, 13, 29] {
            setUpWorkspacesForTests()
            var rng = StartupLcg(seed: seed)
            let workspaces = ["A", "B", "C", "D"]
            var expected: [UInt32: String] = [:]
            var callbacks: [WindowDetectedCallback] = []

            for index in 0 ..< 20 {
                let appId = "com.example.App\(index)"
                let workspace = workspaces[rng.nextInt(workspaces.count)]
                callbacks.append(WindowDetectedCallback(
                    matcher: WindowDetectedCallbackMatcher(appId: appId, duringAeroshiftStartup: rng.nextBool(probabilityPercent: 80) ? nil : true),
                    rawRun: [MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: workspace))],
                ))
                let window = TestWindow.new(
                    id: UInt32(index + 1),
                    app: TestApp(pid: Int32(index + 1), rawAppBundleId: appId),
                    parent: Workspace.get(byName: "1").rootTilingContainer,
                )
                expected[window.windowId] = workspace
            }

            config.onWindowDetected = callbacks
            try await $_isStartup.withValue(true) {
                try await replayStartupWindowDetectedCallbacks()
            }

            for window in Workspace.all.flatMap(\.allLeafWindowsRecursive) {
                assertEquals(window.nodeWorkspace?.name, expected[window.windowId], additionalMsg: "seed=\(seed)")
            }
        }
    }
}

private struct StartupLcg: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }

    mutating func nextBool(probabilityPercent: Int) -> Bool {
        nextInt(100) < probabilityPercent
    }
}
