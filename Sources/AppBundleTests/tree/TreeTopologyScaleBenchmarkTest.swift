@testable import AppBundle
import XCTest

@MainActor
final class TreeTopologyScaleBenchmarkTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testPrintTreeTopologyScaleBenchmark() {
        for count in [100, 1000, 5000, 10000] {
            benchmarkWideTree(count: count)
            setUpWorkspacesForTests()
            benchmarkMixedTree(count: count)
            setUpWorkspacesForTests()
        }
    }

    private func benchmarkWideTree(count: Int) {
        let workspace = Workspace.get(byName: "wide-\(count)")
        let root = workspace.rootTilingContainer
        for id in 0 ..< count {
            TestWindow.new(id: UInt32(id), parent: root)
        }
        let lookupTarget = root.children[count / 2]
        let duration = measureSeconds {
            _ = TreeTopology.shared.leafWindows(in: workspace)
            _ = TreeTopology.shared.ownIndex(of: lookupTarget)
            _ = TreeTopology.shared.closestParent(from: lookupTarget, hasChildrenInDirection: .right, withLayout: nil)
        }
        print("TreeTopology wide count=\(count) seconds=\(duration)")
    }

    private func benchmarkMixedTree(count: Int) {
        let workspace = Workspace.get(byName: "mixed-\(count)")
        var parent: NonLeafTreeNodeObject = workspace.rootTilingContainer
        for id in 0 ..< count {
            if id.isMultiple(of: 10) {
                parent = TilingContainer.newVTiles(parent: parent, adaptiveWeight: 1)
            }
            TestWindow.new(id: UInt32(id), parent: parent)
        }
        let duration = measureSeconds {
            _ = TreeTopology.shared.leafWindows(in: workspace)
            _ = TreeTopology.shared.mostRecentWindow(in: workspace)
            _ = TreeTopology.shared.anyLeafWindow(in: workspace)
        }
        print("TreeTopology mixed count=\(count) seconds=\(duration)")
    }

    private func measureSeconds(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }
}
