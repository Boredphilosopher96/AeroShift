@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class TreeTopologyScaleBenchmarkTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testPrintTreeTopologyScaleBenchmark() {
        let label = ProcessInfo.processInfo.environment["AEROSHIFT_TREE_BENCH_BACKEND_LABEL"] ?? "current"
        for scale in benchmarkScales() {
            runBenchmarks(label: label, scale: scale)
            setUpWorkspacesForTests()
        }
    }

    func testTreeTopologySimulationInvariants() {
        for scale in simulationScales() {
            runSimulation(scale: scale)
            setUpWorkspacesForTests()
        }
    }

    private func benchmarkScales() -> [Scale] {
        var scales = simulationScales()
        if ProcessInfo.processInfo.environment["AEROSHIFT_TREE_BENCH_EXTENDED"] == "1" {
            scales += [
                Scale(workspaces: 100, windowsPerWorkspace: 500),
                Scale(workspaces: 1, windowsPerWorkspace: 10000),
            ]
        }
        return scales
    }

    private func simulationScales() -> [Scale] {
        [
            Scale(workspaces: 1, windowsPerWorkspace: 64),
            Scale(workspaces: 5, windowsPerWorkspace: 200),
            Scale(workspaces: 20, windowsPerWorkspace: 250),
            Scale(workspaces: 50, windowsPerWorkspace: 200),
        ]
    }

    private func runBenchmarks(label: String, scale: Scale) {
        let world = buildWorld(scale)
        let workspace = world.workspaces[0]
        let root = workspace.rootTilingContainer
        let middleIndex = root.children.count / 2
        let middleWindow = root.children[middleIndex] as! Window

        printMetric(label, scale, "own-index") {
            _ = TreeTopology.shared.ownIndex(of: middleWindow)
        }
        printMetric(label, scale, "ordered-traversal") {
            _ = root.children.map { ObjectIdentifier($0).hashValue }
        }
        printMetric(label, scale, "dfs-leaf-traversal") {
            _ = TreeTopology.shared.leafWindows(in: workspace)
        }
        printMetric(label, scale, "focus-dfs") {
            _ = workspace.allLeafWindowsRecursive.getOrNil(atIndex: middleIndex)
        }
        printMetric(label, scale, "focus-direction") {
            _ = TreeTopology.shared.closestParent(from: middleWindow, hasChildrenInDirection: .right, withLayout: nil)
        }
        printMetric(label, scale, "layout-traversal") {
            _ = workspace.layoutDescription
        }

        printMetric(label, scale, "insert-beginning") {
            TestWindow.new(id: world.nextWindowId(), parent: root).bind(to: root, adaptiveWeight: 1, index: 0)
        }
        printMetric(label, scale, "insert-middle") {
            TestWindow.new(id: world.nextWindowId(), parent: root).bind(to: root, adaptiveWeight: 1, index: root.children.count / 2)
        }
        printMetric(label, scale, "insert-end") {
            TestWindow.new(id: world.nextWindowId(), parent: root)
        }

        printMetric(label, scale, "close-beginning") {
            _ = root.children.first?.unbindFromParent()
        }
        printMetric(label, scale, "close-middle") {
            _ = root.children[root.children.count / 2].unbindFromParent()
        }
        printMetric(label, scale, "close-end") {
            _ = root.children.last?.unbindFromParent()
        }

        if world.workspaces.count > 1, let moving = root.children.last as? Window {
            printMetric(label, scale, "move-across-workspaces") {
                moving.bind(to: world.workspaces[1].rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }

        if root.children.count >= 4, let first = root.children.first as? Window, let last = root.children.last as? Window {
            printMetric(label, scale, "swap-same-parent") {
                TreeTopology.shared.swapWindows(first, last)
            }
        }
        if world.workspaces.count > 1,
           let left = world.workspaces[0].rootTilingContainer.children.first as? Window,
           let right = world.workspaces[1].rootTilingContainer.children.first as? Window
        {
            printMetric(label, scale, "swap-cross-parent") {
                TreeTopology.shared.swapWindows(left, right)
            }
        }
    }

    private func runSimulation(scale: Scale) {
        let world = buildWorld(scale)
        assertInvariants(scale: scale)

        for workspace in world.workspaces {
            let root = workspace.rootTilingContainer
            _ = root.children[root.children.count / 2].unbindFromParent()
            assertInvariants(scale: scale)

            TestWindow.new(id: world.nextWindowId(), parent: root).bind(to: root, adaptiveWeight: 1, index: root.children.count / 2)
            assertInvariants(scale: scale)

            if let first = root.children.first as? Window, let last = root.children.last as? Window {
                TreeTopology.shared.swapWindows(first, last)
            }
            assertInvariants(scale: scale)
        }

        if world.workspaces.count > 1 {
            let source = world.workspaces[0].rootTilingContainer
            let target = world.workspaces[1].rootTilingContainer
            (source.children.last as? Window)?.bind(to: target, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            assertInvariants(scale: scale)
        }
    }

    private func assertInvariants(scale: Scale) {
        var seenWindows: Set<UInt32> = []
        for workspace in Workspace.all {
            let leaves = TreeTopology.shared.leafWindows(in: workspace)
            for window in leaves {
                XCTAssertTrue(seenWindows.insert(window.windowId).inserted, "duplicate window \(window.windowId) scale=\(scale)")
            }
            assertParentChildConsistency(workspace)
        }
    }

    private func assertParentChildConsistency(_ node: TreeNode) {
        for (index, child) in node.children.enumerated() {
            assertEquals(TreeTopology.shared.parent(of: child) === node, true)
            assertEquals(TreeTopology.shared.ownIndex(of: child), index)
            assertParentChildConsistency(child)
        }
    }

    private func buildWorld(_ scale: Scale) -> BenchmarkWorld {
        let world = BenchmarkWorld()
        for workspaceIndex in 0 ..< scale.workspaces {
            let workspace = Workspace.get(byName: "bench-\(workspaceIndex)")
            let root = workspace.rootTilingContainer
            for _ in 0 ..< scale.windowsPerWorkspace {
                TestWindow.new(id: world.nextWindowId(), parent: root)
            }
            world.workspaces.append(workspace)
        }
        return world
    }

    private func printMetric(_ label: String, _ scale: Scale, _ operation: String, _ body: () -> Void) {
        let seconds = measureSeconds(body)
        print("TreeTopologyBenchmark backend=\(label) operation=\(operation) workspaces=\(scale.workspaces) windowsPerWorkspace=\(scale.windowsPerWorkspace) seconds=\(seconds)")
    }

    private func measureSeconds(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }
}

private final class BenchmarkWorld {
    var workspaces: [Workspace] = []
    private var nextId: UInt32 = 1

    func nextWindowId() -> UInt32 {
        defer { nextId += 1 }
        return nextId
    }
}

private struct Scale: CustomStringConvertible {
    let workspaces: Int
    let windowsPerWorkspace: Int

    var description: String {
        "\(workspaces)x\(windowsPerWorkspace)"
    }
}
