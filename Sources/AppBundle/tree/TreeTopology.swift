import AppKit
import Common

final class TreeTopology: @unchecked Sendable {
    static let shared = TreeTopology()

    private init() {}

    func children(of node: TreeNode) -> [TreeNode] {
        node.topologyStorageChildren()
    }

    func parent(of node: TreeNode) -> NonLeafTreeNodeObject? {
        node.topologyStorageParent()
    }

    func ownIndex(of node: TreeNode) -> Int? {
        guard let parent = parent(of: node) else { return nil }
        return children(of: parent).firstIndex(of: node).orDie()
    }

    func parents(of node: TreeNode) -> [NonLeafTreeNodeObject] {
        parent(of: node).map { [$0] + parents(of: $0) } ?? []
    }

    func parentsWithSelf(of node: TreeNode) -> [TreeNode] {
        parent(of: node).map { [node] + parentsWithSelf(of: $0) } ?? [node]
    }

    func leafWindows(in node: TreeNode) -> [Window] {
        var result: [Window] = []
        visitLeafWindows(in: node, result: &result)
        return result
    }

    func mostRecentChild(of node: TreeNode) -> TreeNode? {
        node.topologyMostRecentStorageChild() ?? children(of: node).last
    }

    func mostRecentWindow(in node: TreeNode) -> Window? {
        (node as? Window) ?? mostRecentChild(of: node).flatMap { mostRecentWindow(in: $0) }
    }

    @MainActor
    func findLeafWindow(in node: TreeNode, snappedTo direction: CardinalDirection) -> Window? {
        switch node.nodeCases {
            case .workspace(let workspace):
                return findLeafWindow(in: workspace.rootTilingContainer, snappedTo: direction)
            case .window(let window):
                return window
            case .tilingContainer(let container):
                if direction.orientation == container.orientation {
                    return (direction.isPositive ? children(of: container).last : children(of: container).first)
                        .flatMap { findLeafWindow(in: $0, snappedTo: direction) }
                } else {
                    return mostRecentChild(of: container).flatMap { findLeafWindow(in: $0, snappedTo: direction) }
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                die("Impossible")
        }
    }

    func anyLeafWindow(in node: TreeNode) -> Window? {
        if let window = node as? Window {
            return window
        }
        for child in children(of: node) {
            if let window = anyLeafWindow(in: child) {
                return window
            }
        }
        return nil
    }

    func closestParent(
        from node: TreeNode,
        hasChildrenInDirection direction: CardinalDirection,
        withLayout layout: Layout?,
    ) -> (parent: TilingContainer, ownIndex: Int)? {
        let innermostChild = parentsWithSelf(of: node).first(where: { (candidate: TreeNode) -> Bool in
            return switch parent(of: candidate)?.cases {
                case .workspace, nil, .macosMinimizedWindowsContainer,
                     .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer:
                    true
                case .tilingContainer(let parent):
                    (layout == nil || parent.layout == layout) &&
                        parent.orientation == direction.orientation &&
                        (ownIndex(of: candidate).map { children(of: parent).indices.contains($0 + direction.focusOffset) } ?? true)
            }
        })
        guard let innermostChild else { return nil }
        switch parent(of: innermostChild)?.cases {
            case .tilingContainer(let parent):
                check(parent.orientation == direction.orientation)
                return ownIndex(of: innermostChild).map { (parent, $0) }
            case .workspace, nil, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer:
                return nil
        }
    }

    @MainActor
    func rootTilingContainer(for workspace: Workspace, defaultOrientation: () -> Orientation, defaultLayout: () -> Layout) -> TilingContainer {
        let containers = children(of: workspace).filterIsInstance(of: TilingContainer.self)
        switch containers.count {
            case 0:
                return TilingContainer(parent: workspace, adaptiveWeight: 1, defaultOrientation(), defaultLayout(), index: INDEX_BIND_LAST)
            case 1:
                return containers.singleOrNil().orDie()
            default:
                die("Workspace must contain zero or one tiling container as its child")
        }
    }

    func floatingWindows(in workspace: Workspace) -> [Window] {
        children(of: workspace).filterIsInstance(of: Window.self)
    }

    func window(at point: CGPoint, in tree: TilingContainer, virtual: Bool) -> Window? {
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                children(of: tree).first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                mostRecentChild(of: tree)
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): window(at: point, in: container, virtual: virtual)
        }
    }

    @MainActor
    func swapWindows(_ window1: Window, _ window2: Window) {
        if window1 == window2 { return }
        let parent1 = parent(of: window1)
        let parent2 = parent(of: window2)
        guard let index1 = ownIndex(of: window1) else { return }
        guard let index2 = ownIndex(of: window2) else { return }

        if parent1 === parent2 && index1 < index2 {
            let binding2 = unbind(window2).orDie()
            let binding1 = unbind(window1).orDie()

            bind(window2, to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
            bind(window1, to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
        } else {
            let binding1 = unbind(window1).orDie()
            let binding2 = unbind(window2).orDie()

            bind(window1, to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
            bind(window2, to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
        }
    }

    @MainActor
    func singletonChildContainer<T: TreeNode & NonLeafTreeNodeObject>(
        in workspace: Workspace,
        of _: T.Type,
        create: () -> T,
        errorMessage: String,
    ) -> T {
        let containers = children(of: workspace).filterIsInstance(of: T.self)
        return switch containers.count {
            case 0: create()
            case 1: containers.singleOrNil().orDie()
            default: dieT(errorMessage)
        }
    }

    @MainActor
    @discardableResult
    func bind(_ node: TreeNode, to newParent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> BindingData? {
        let result = unbindIfBound(node)

        if newParent === NilTreeNode.instance {
            return result
        }
        let relation = getChildParentRelation(child: node, parent: newParent)
        if adaptiveWeight == WEIGHT_AUTO {
            let resolvedWeight: CGFloat = switch relation {
                case .tiling(let newParent):
                    CGFloat(children(of: newParent).sumOfDouble { $0.getWeight(newParent.orientation) }).div(children(of: newParent).count) ?? 1
                case .floatingWindow, .macosNativeFullscreenWindow,
                     .rootTilingContainer, .macosNativeMinimizedWindow,
                     .shimContainerRelation, .macosPopupWindow, .macosNativeHiddenAppWindow:
                    WEIGHT_DOESNT_MATTER
            }
            node.topologySetStorageAdaptiveWeight(resolvedWeight)
        } else {
            node.topologySetStorageAdaptiveWeight(adaptiveWeight)
        }
        newParent.topologyInsertStorageChild(node, at: index != INDEX_BIND_LAST ? index : children(of: newParent).count)
        node.topologySetStorageParent(newParent)
        node.unboundStacktrace = nil
        markAsMostRecentChild(node)
        assertLocalInvariants(afterMutating: node)
        return result
    }

    @discardableResult
    func unbind(_ node: TreeNode) -> BindingData? {
        let result = unbindIfBound(node)
        if let previousParent = result?.parent {
            check(!children(of: previousParent).contains(node), "Previous parent still contains unbound child")
            for child in children(of: previousParent) {
                check(parent(of: child) === previousParent, "Previous parent's child does not point back to previous parent")
            }
            assertLocalInvariants(afterMutating: node)
        }
        return result
    }

    func markAsMostRecentChild(_ node: TreeNode) {
        guard let parent = parent(of: node) else { return }
        parent.topologyPushOrRaiseStorageMruChild(node)
        markAsMostRecentChild(parent)
    }

    func assertLocalInvariants(afterMutating node: TreeNode) {
        if let parent = parent(of: node) {
            check(children(of: parent).contains(node), "Parent does not contain child")
        }
        for child in children(of: node) {
            check(parent(of: child) === node, "Child does not point back to parent")
        }
    }

    private func visitLeafWindows(in node: TreeNode, result: inout [Window]) {
        if let node = node as? Window {
            result.append(node)
        }
        for child in children(of: node) {
            visitLeafWindows(in: child, result: &result)
        }
    }

    private func unbindIfBound(_ node: TreeNode) -> BindingData? {
        guard let parent = parent(of: node) else { return nil }

        let index = parent.topologyRemoveStorageChild(node) ?? dieT("Can't find child in its parent")
        check(parent.topologyRemoveStorageMruChild(node))
        node.topologySetStorageParent(nil)
        node.unboundStacktrace = getStringStacktrace()

        return BindingData(parent: parent, adaptiveWeight: node.topologyStorageAdaptiveWeight(), index: index)
    }
}
