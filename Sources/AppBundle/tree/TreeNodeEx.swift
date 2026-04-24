import AppKit
import Common

extension TreeNode {
    var allLeafWindowsRecursive: [Window] {
        TreeTopology.shared.leafWindows(in: self)
    }

    var ownIndex: Int? {
        TreeTopology.shared.ownIndex(of: self)
    }

    var parents: [NonLeafTreeNodeObject] { TreeTopology.shared.parents(of: self) }
    var parentsWithSelf: [TreeNode] { TreeTopology.shared.parentsWithSelf(of: self) }

    /// Also see visualWorkspace
    var nodeWorkspace: Workspace? {
        self as? Workspace ?? parent?.nodeWorkspace
    }

    /// Also see: workspace
    @MainActor
    var visualWorkspace: Workspace? { nodeWorkspace ?? nodeMonitor?.activeWorkspace }

    @MainActor
    var nodeMonitor: Monitor? {
        switch self.nodeCases {
            case .workspace(let ws): ws.workspaceMonitor
            case .window: parent?.nodeMonitor
            case .tilingContainer: parent?.nodeMonitor
            case .macosFullscreenWindowsContainer: parent?.nodeMonitor
            case .macosHiddenAppsWindowsContainer: parent?.nodeMonitor
            case .macosMinimizedWindowsContainer, .macosPopupWindowsContainer: nil
        }
    }

    var mostRecentWindowRecursive: Window? {
        TreeTopology.shared.mostRecentWindow(in: self)
    }

    var anyLeafWindowRecursive: Window? {
        TreeTopology.shared.anyLeafWindow(in: self)
    }

    // Doesn't contain at least one window
    var isEffectivelyEmpty: Bool {
        anyLeafWindowRecursive == nil
    }

    @MainActor
    var hWeight: CGFloat {
        get { getWeight(.h) }
        set { setWeight(.h, newValue) }
    }

    @MainActor
    var vWeight: CGFloat {
        get { getWeight(.v) }
        set { setWeight(.v, newValue) }
    }

    /// Returns closest parent that has children in the specified direction relative to `self`
    func closestParent(
        hasChildrenInDirection direction: CardinalDirection,
        withLayout layout: Layout?,
    ) -> (parent: TilingContainer, ownIndex: Int)? {
        TreeTopology.shared.closestParent(from: self, hasChildrenInDirection: direction, withLayout: layout)
    }

    @MainActor
    func findLeafWindowRecursive(snappedTo direction: CardinalDirection) -> Window? {
        TreeTopology.shared.findLeafWindow(in: self, snappedTo: direction)
    }
}
