@testable import AppBundle
import XCTest

@MainActor
final class TreeTopologyTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFacadeReportsParentChildrenAndLeafOrder() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let nested = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: nested)
        let window3 = TestWindow.new(id: 3, parent: nested)

        assertEquals(TreeTopology.shared.parent(of: nested) === root, true)
        assertEquals(TreeTopology.shared.children(of: root), [nested, window1])
        assertEquals(TreeTopology.shared.ownIndex(of: window3), 1)
        assertEquals(TreeTopology.shared.leafWindows(in: workspace).map(\.windowId), [2, 3, 1])
        assertEquals(TreeTopology.shared.parents(of: window2).map { $0 as TreeNode }, [nested, root, workspace])
    }

    func testFacadeBindUnbindAndReparentPreserveOrder() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let container = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)

        let binding = TreeTopology.shared.unbind(window2).orDie()
        assertEquals(binding.parent, root)
        assertEquals(TreeTopology.shared.children(of: root), [container, window1])

        TreeTopology.shared.bind(window2, to: container, adaptiveWeight: WEIGHT_AUTO, index: 0)
        assertEquals(TreeTopology.shared.parent(of: window2) === container, true)
        assertEquals(TreeTopology.shared.children(of: container), [window2])
        assertEquals(TreeTopology.shared.leafWindows(in: workspace).map(\.windowId), [2, 1])
    }

    func testObjectBackedChunkedChildrenPreserveOrderAndIndexes() {
        config.treeSiblingChunkSize = 4
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let windows = (0 ..< 10).map { TestWindow.new(id: UInt32($0), parent: root) }

        assertEquals(TreeTopology.shared.usesChunkedChildren(root), true)
        assertEquals(TreeTopology.shared.children(of: root), windows)
        for (index, window) in windows.enumerated() {
            assertEquals(TreeTopology.shared.ownIndex(of: window), index)
            assertEquals(TreeTopology.shared.parent(of: window) === root, true)
        }

        windows[5].unbindFromParent()
        assertEquals(TreeTopology.shared.children(of: root).map { ($0 as! Window).windowId }, [0, 1, 2, 3, 4, 6, 7, 8, 9])

        windows[5].bind(to: root, adaptiveWeight: 1, index: 2)
        assertEquals(TreeTopology.shared.children(of: root).map { ($0 as! Window).windowId }, [0, 1, 5, 2, 3, 4, 6, 7, 8, 9])
        assertEquals(TreeTopology.shared.ownIndex(of: windows[5]), 2)
    }

    func testChunkThresholdBoundaries() {
        config.treeSiblingChunkSize = 64
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer

        for id in 0 ..< 63 {
            TestWindow.new(id: UInt32(id), parent: root)
        }
        assertEquals(TreeTopology.shared.usesChunkedChildren(root), false)
        TestWindow.new(id: 63, parent: root)
        assertEquals(TreeTopology.shared.usesChunkedChildren(root), false)
        TestWindow.new(id: 64, parent: root)
        assertEquals(TreeTopology.shared.usesChunkedChildren(root), true)
    }

    func testFacadeDirectionalLookupAndSnappedLeaf() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let left = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        let right = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 1, parent: left)
        let current = TestWindow.new(id: 2, parent: left)
        let upRight = TestWindow.new(id: 3, parent: right)
        TestWindow.new(id: 4, parent: right)
        _ = upRight.focusWindow()

        let closest = TreeTopology.shared.closestParent(from: current, hasChildrenInDirection: .right, withLayout: nil)
        assertEquals(closest?.parent, root)
        assertEquals(closest?.ownIndex, 0)
        assertEquals(TreeTopology.shared.findLeafWindow(in: right, snappedTo: .left)?.windowId, 3)
    }

    func testFacadeSnappedLeafOnEmptyWorkspaceReturnsNil() {
        let workspace = Workspace.get(byName: "empty")

        assertNil(TreeTopology.shared.findLeafWindow(in: workspace, snappedTo: .left))
        assertEquals(TreeTopology.shared.children(of: workspace).filterIsInstance(of: TilingContainer.self).count, 1)
    }

    func testFacadeSwapWindowsPreservesParentsAndDfsOrder() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        let window3 = TestWindow.new(id: 3, parent: root)

        TreeTopology.shared.swapWindows(window1, window3)

        assertEquals(TreeTopology.shared.children(of: root), [window3, window2, window1])
        assertEquals(TreeTopology.shared.leafWindows(in: workspace).map(\.windowId), [3, 2, 1])
        assertEquals(TreeTopology.shared.parent(of: window1) === root, true)
        assertEquals(TreeTopology.shared.parent(of: window3) === root, true)
    }

    func testFacadeSwapWindowsAcrossParentsPreservesBindings() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let left = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        let right = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        let window1 = TestWindow.new(id: 1, parent: left)
        let window2 = TestWindow.new(id: 2, parent: left)
        let window3 = TestWindow.new(id: 3, parent: right)
        let window4 = TestWindow.new(id: 4, parent: right)

        TreeTopology.shared.swapWindows(window2, window3)

        assertEquals(TreeTopology.shared.children(of: left), [window1, window3])
        assertEquals(TreeTopology.shared.children(of: right), [window2, window4])
        assertEquals(TreeTopology.shared.parent(of: window2) === right, true)
        assertEquals(TreeTopology.shared.parent(of: window3) === left, true)
        assertEquals(TreeTopology.shared.leafWindows(in: workspace).map(\.windowId), [1, 3, 2, 4])
    }
}
