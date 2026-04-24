import AppKit
import Common

open class TreeNode: Equatable, AeroAny {
    private var childStorage = TreeChildStorage<TreeNode>()
    private var childIndexCache: [ObjectIdentifier: Int] = [:]
    private var cachedLeafWindows: [Window]?
    var children: [TreeNode] { TreeTopology.shared.children(of: self) }
    fileprivate final weak var _parent: NonLeafTreeNodeObject? = nil
    final var parent: NonLeafTreeNodeObject? { TreeTopology.shared.parent(of: self) }
    private var adaptiveWeight: CGFloat
    private let _mruChildren: MruStack<TreeNode> = MruStack()
    // Usages:
    // - resize with mouse
    // - makeFloatingWindowsSeenAsTiling in focus command
    var lastAppliedLayoutVirtualRect: Rect? = nil  // as if inner gaps were always zero
    // Usages:
    // - resize with mouse
    // - drag window with mouse
    // - move-mouse command
    var lastAppliedLayoutPhysicalRect: Rect? = nil // with real inner gaps
    final var unboundStacktrace: String? = nil
    var isBound: Bool { parent != nil } // todo drop, once https://github.com/nikitabobko/AeroSpace/issues/1215 is fixed

    final func topologyStorageChildren() -> [TreeNode] { childStorage.children() }
    final func topologyStorageChildCount() -> Int { childStorage.count }
    final func topologyStorageChild(at index: Int) -> TreeNode { childStorage.child(at: index) }
    final func topologyStorageFirstIndex(of child: TreeNode) -> Int? { childIndexCache[ObjectIdentifier(child)] }
    final func topologyStorageForEachChild(_ body: (TreeNode) -> Void) { childStorage.forEachChild(body) }
    final func topologyStorageParent() -> NonLeafTreeNodeObject? { _parent }
    final func topologyStorageAdaptiveWeight() -> CGFloat { adaptiveWeight }
    final func topologySetStorageAdaptiveWeight(_ adaptiveWeight: CGFloat) { self.adaptiveWeight = adaptiveWeight }
    final func topologyInsertStorageChild(_ child: TreeNode, at index: Int, chunkSize: Int) {
        let index = childStorage.insert(child, at: index, chunkSize: chunkSize)
        shiftCachedChildIndexes(from: index, by: 1)
        childIndexCache[ObjectIdentifier(child)] = index
        invalidateLeafWindowCachesUpward()
    }
    final func topologyRemoveStorageChild(_ child: TreeNode, chunkSize: Int) -> Int? {
        guard let index = childIndexCache.removeValue(forKey: ObjectIdentifier(child)) else { return nil }
        check(childStorage.remove(at: index, chunkSize: chunkSize) === child)
        shiftCachedChildIndexes(from: index, by: -1)
        invalidateLeafWindowCachesUpward()
        return index
    }
    final func topologyStorageLeafWindows() -> [Window] {
        if let window = self as? Window {
            return [window]
        }
        if let cachedLeafWindows {
            return cachedLeafWindows
        }
        var result: [Window] = []
        result.reserveCapacity(childStorage.count)
        childStorage.forEachChild { child in
            if let window = child as? Window {
                result.append(window)
            } else {
                result.append(contentsOf: child.topologyStorageLeafWindows())
            }
        }
        cachedLeafWindows = result
        return result
    }
    final func topologySetStorageParent(_ parent: NonLeafTreeNodeObject?) { _parent = parent }
    final func topologyMostRecentStorageChild() -> TreeNode? { _mruChildren.mostRecent }
    final func topologyPushOrRaiseStorageMruChild(_ child: TreeNode) { _mruChildren.pushOrRaise(child) }
    @discardableResult
    final func topologyRemoveStorageMruChild(_ child: TreeNode) -> Bool { _mruChildren.remove(child) }
    final func topologyStorageUsesChunks() -> Bool { childStorage.usesChunks }

    private func shiftCachedChildIndexes(from startIndex: Int, by delta: Int) {
        for (child, oldIndex) in childIndexCache where oldIndex >= startIndex {
            childIndexCache[child] = oldIndex + delta
        }
    }

    private func invalidateLeafWindowCachesUpward() {
        var node: TreeNode? = self
        while let current = node {
            current.cachedLeafWindows = nil
            node = current._parent
        }
    }

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.adaptiveWeight = adaptiveWeight
        bind(to: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    fileprivate init() {
        adaptiveWeight = 0
    }

    /// See: ``getWeight(_:)``
    func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        guard let parent else { die("Can't change weight if TreeNode doesn't have parent") }
        switch getChildParentRelation(child: self, parent: parent) {
            case .tiling(let parent):
                if parent.orientation != targetOrientation {
                    die("You can't change \(targetOrientation) weight of nodes located in \(parent.orientation) container")
                }
                if parent.layout != .tiles {
                    die("Weight can be changed only for nodes whose parent has 'tiles' layout")
                }
                topologySetStorageAdaptiveWeight(newValue)
            default:
                die("Can't change weight")
        }
    }

    /// Weight itself doesn't make sense. The parent container controls semantics of weight
    @MainActor
    func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        guard let parent else { die("Weight doesn't make sense for containers without parent") }
        return switch getChildParentRelation(child: self, parent: parent) {
            case .tiling(let parent):
                parent.orientation == targetOrientation ? topologyStorageAdaptiveWeight() : parent.getWeight(targetOrientation)
            case .rootTilingContainer: parent.getWeight(targetOrientation)
            case .floatingWindow, .macosNativeFullscreenWindow: dieT("Weight doesn't make sense for floating windows")
            case .macosNativeMinimizedWindow: dieT("Weight doesn't make sense for minimized windows")
            case .macosPopupWindow: dieT("Weight doesn't make sense for popup windows")
            case .macosNativeHiddenAppWindow: dieT("Weight doesn't make sense for windows of hidden apps")
            case .shimContainerRelation: dieT("Weight doesn't make sense for stub containers")
        }
    }

    @MainActor
    @discardableResult
    func bind(to newParent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> BindingData? {
        TreeTopology.shared.bind(self, to: newParent, adaptiveWeight: adaptiveWeight, index: index)
    }

    func markAsMostRecentChild() {
        TreeTopology.shared.markAsMostRecentChild(self)
    }

    var mostRecentChild: TreeNode? { TreeTopology.shared.mostRecentChild(of: self) }

    @discardableResult
    @MainActor
    func unbindFromParent() -> BindingData {
        TreeTopology.shared.unbind(self) ??
            dieT("\(self) is already unbound. The stacktrace where it was unbound:\n\(unboundStacktrace ?? "nil")")
    }

    nonisolated public static func == (lhs: TreeNode, rhs: TreeNode) -> Bool {
        lhs === rhs
    }

    private var userData: [String: Any] = [:]
    func getUserData<T>(key: TreeNodeUserDataKey<T>) -> T? { userData[key.key] as! T? }
    func putUserData<T>(key: TreeNodeUserDataKey<T>, data: T) {
        userData[key.key] = data
    }
    @discardableResult
    func cleanUserData<T>(key: TreeNodeUserDataKey<T>) -> T? { userData.removeValue(forKey: key.key) as! T? }
}

// periphery:ignore - Generic T is used
struct TreeNodeUserDataKey<T> {
    let key: String
}

let WEIGHT_DOESNT_MATTER = CGFloat(-2)
/// Splits containers evenly if tiling.
///
/// Reset weight is bind to workspace (aka "floating windows")
let WEIGHT_AUTO = CGFloat(-1)

let INDEX_BIND_LAST = -1

struct BindingData {
    let parent: NonLeafTreeNodeObject
    let adaptiveWeight: CGFloat
    let index: Int
}

final class NilTreeNode: TreeNode, NonLeafTreeNodeObject {
    override private init() {
        super.init()
    }
    @MainActor static let instance = NilTreeNode()
}
