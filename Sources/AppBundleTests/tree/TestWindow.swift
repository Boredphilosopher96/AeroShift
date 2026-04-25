@testable import AppBundle
import AppKit

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?

    @MainActor
    private init(_ id: UInt32, _ app: any AbstractApp, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?) {
        _rect = rect
        super.init(id: id, app, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(
        id: UInt32,
        app: TestApp = TestApp.shared,
        parent: NonLeafTreeNodeObject,
        adaptiveWeight: CGFloat = 1,
        rect: Rect? = nil,
    ) -> TestWindow {
        let wi = TestWindow(id, app, parent, adaptiveWeight, rect)
        app._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override func getAxSize() async throws -> CGSize? {
        _rect?.size
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        var rect = _rect ?? Rect(
            topLeftX: topLeft?.x ?? 0,
            topLeftY: topLeft?.y ?? 0,
            width: size?.width ?? 0,
            height: size?.height ?? 0,
        )
        if let topLeft {
            rect.topLeftX = topLeft.x
            rect.topLeftY = topLeft.y
        }
        if let size {
            rect.width = size.width
            rect.height = size.height
        }
        _rect = rect
    }

    override var title: String {
        get async { // redundant async. todo create bug report to Swift
            description
        }
    }

    @MainActor override func getAxRect() async throws -> Rect? { // todo change to not Optional
        _rect
    }
}
