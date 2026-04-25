@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class LayoutVisibilityRecoveryTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFloatingWindowHiddenAtBottomRightIsPulledBackIntoVisibleRect() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(
            id: 1,
            parent: workspace,
            rect: Rect(topLeftX: 1919, topLeftY: 1079, width: 300, height: 200),
        )

        try await workspace.layoutWorkspace()

        let rect = try await window.getAxRect().orDie()
        assertEquals(rect.topLeftCorner, CGPoint(x: 1620, y: 880))
    }

    func testFloatingWindowHiddenAtBottomLeftIsPulledBackIntoVisibleRect() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(
            id: 1,
            parent: workspace,
            rect: Rect(topLeftX: -299, topLeftY: 1079, width: 300, height: 200),
        )

        try await workspace.layoutWorkspace()

        let rect = try await window.getAxRect().orDie()
        assertEquals(rect.topLeftCorner, CGPoint(x: 0, y: 880))
    }

    func testVisibleFloatingWindowKeepsUserPosition() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(
            id: 1,
            parent: workspace,
            rect: Rect(topLeftX: 120, topLeftY: 130, width: 300, height: 200),
        )

        try await workspace.layoutWorkspace()

        let rect = try await window.getAxRect().orDie()
        assertEquals(rect.topLeftCorner, CGPoint(x: 120, y: 130))
    }

    func testMostlyOffscreenFloatingWindowThatIsNotAtHideCornerKeepsUserPosition() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(
            id: 1,
            parent: workspace,
            rect: Rect(topLeftX: 1880, topLeftY: 1040, width: 300, height: 200),
        )

        try await workspace.layoutWorkspace()

        let rect = try await window.getAxRect().orDie()
        assertEquals(rect.topLeftCorner, CGPoint(x: 1880, y: 1040))
    }

    func testRestorationFrameIsCenteredInMonitorVisibleRectOrigin() {
        let frame = makeVisibleRestorationFrame(
            monitorVisibleRect: Rect(topLeftX: 2000, topLeftY: 120, width: 1000, height: 800),
            preferredSize: CGSize(width: 400, height: 200),
        )

        assertEquals(frame.topLeft, CGPoint(x: 2300, y: 420))
        assertEquals(frame.size, CGSize(width: 400, height: 200))
    }

    func testRestorationFrameCapsOversizedWindowsToVisibleRect() {
        let frame = makeVisibleRestorationFrame(
            monitorVisibleRect: Rect(topLeftX: 2000, topLeftY: 120, width: 1000, height: 800),
            preferredSize: CGSize(width: 1400, height: 900),
        )

        assertEquals(frame.topLeft, CGPoint(x: 2000, y: 120))
        assertEquals(frame.size, CGSize(width: 1000, height: 800))
    }

    func testRestorationFrameUsesVisibleRectWhenPreferredSizeIsMissing() {
        let frame = makeVisibleRestorationFrame(
            monitorVisibleRect: Rect(topLeftX: 2000, topLeftY: 120, width: 1000, height: 800),
            preferredSize: nil,
        )

        assertEquals(frame.topLeft, CGPoint(x: 2000, y: 120))
        assertEquals(frame.size, CGSize(width: 1000, height: 800))
    }
}
