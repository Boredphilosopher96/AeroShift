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

    func testQuitRestorationUsesKnownWorkspaceRectInsteadOfHiddenWindowCenter() {
        let workspaceRect = Rect(topLeftX: 2000, topLeftY: 120, width: 1000, height: 800)
        let hiddenWindowRect = Rect(topLeftX: 2999, topLeftY: 919, width: 300, height: 200)

        let frame = makeVisibleRestorationFrame(
            knownVisibleRect: workspaceRect,
            currentWindowRect: hiddenWindowRect,
            preferredSize: nil,
        )

        assertEquals(frame.topLeft, CGPoint(x: 2350, y: 420))
        assertEquals(frame.size, CGSize(width: 300, height: 200))
    }

    func testQuitRestorationPrefersSavedSizeAndCapsItToVisibleRect() {
        let workspaceRect = Rect(topLeftX: -1600, topLeftY: 100, width: 1600, height: 1000)
        let hiddenWindowRect = Rect(topLeftX: -1399, topLeftY: 1099, width: 300, height: 200)

        let frame = makeVisibleRestorationFrame(
            knownVisibleRect: workspaceRect,
            currentWindowRect: hiddenWindowRect,
            preferredSize: CGSize(width: 2000, height: 600),
        )

        assertEquals(frame.topLeft, CGPoint(x: -1600, y: 300))
        assertEquals(frame.size, CGSize(width: 1600, height: 600))
    }

    func testTerminationModeDisablesLayoutBeforeRestoringWindows() {
        TrayMenuModel.shared.isEnabled = true

        beginAppBundleTermination()

        assertEquals(TrayMenuModel.shared.isEnabled, false)
    }

    func testTerminatingAppRejectsNewLightSessionsBeforeBodyRuns() async throws {
        beginAppBundleTermination()

        do {
            _ = try await runLightSession(.menuBarButton, .forceRun) {
                XCTFail("Termination mode must reject new light-session bodies")
                return 1
            }
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testSeededQuitRestorationSimulationKeepsWindowsVisibleAndCentered() {
        let monitorRects = [
            Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            Rect(topLeftX: 1920, topLeftY: 40, width: 1440, height: 900),
            Rect(topLeftX: -1600, topLeftY: 100, width: 1600, height: 1000),
        ]

        for seed in [1 as UInt64, 2, 3, 11, 29, 97] {
            var rng = QuitRestoreLcg(seed: seed)
            for step in 0 ..< 500 {
                let monitorRect = monitorRects[rng.nextInt(monitorRects.count)]
                let windowSize = CGSize(
                    width: CGFloat(120 + rng.nextInt(1800)),
                    height: CGFloat(80 + rng.nextInt(1000)),
                )
                let currentWindowRect = randomWindowRect(
                    monitorRect: monitorRect,
                    windowSize: windowSize,
                    behavior: rng.nextInt(5),
                    rng: &rng,
                )
                let preferredSize = rng.nextBool(probabilityPercent: 45)
                    ? CGSize(width: CGFloat(80 + rng.nextInt(2200)), height: CGFloat(60 + rng.nextInt(1400)))
                    : nil

                let frame = makeVisibleRestorationFrame(
                    knownVisibleRect: monitorRect,
                    currentWindowRect: currentWindowRect,
                    preferredSize: preferredSize,
                )
                let restoredRect = Rect(
                    topLeftX: frame.topLeft.x,
                    topLeftY: frame.topLeft.y,
                    width: frame.size.width,
                    height: frame.size.height,
                )
                let expectedSize = CGSize(
                    width: min((preferredSize ?? currentWindowRect.size).width, monitorRect.width),
                    height: min((preferredSize ?? currentWindowRect.size).height, monitorRect.height),
                )
                let expectedTopLeft = CGPoint(
                    x: monitorRect.topLeftX + (monitorRect.width - expectedSize.width) / 2,
                    y: monitorRect.topLeftY + (monitorRect.height - expectedSize.height) / 2,
                )

                XCTAssertTrue(
                    restoredRect.isEffectivelyVisible(in: monitorRect),
                    "seed=\(seed) step=\(step) restoredRect=\(restoredRect) monitorRect=\(monitorRect)",
                )
                assertEquals(frame.size, expectedSize, additionalMsg: "seed=\(seed) step=\(step)")
                assertEquals(frame.topLeft, expectedTopLeft, additionalMsg: "seed=\(seed) step=\(step)")
            }
        }
    }

    func testSeededQuitLifecycleSimulationBlocksRefreshAndLightSessionRaces() {
        let monitorRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        var baselineFailures = 0

        for seed in [55 as UInt64, 89, 144, 233, 377] {
            var rng = QuitRestoreLcg(seed: seed)
            for step in 0 ..< 250 {
                let world = QuitLifecycleWorld.random(monitorRect: monitorRect, rng: &rng)

                var baseline = world
                baseline.restoreAllWindows()
                baseline.enqueuePostRestoreNoise(rng: &rng)
                baseline.runQueuedEvents()
                if !baseline.allWindowsVisible {
                    baselineFailures += 1
                }

                var fixed = world
                fixed.beginTermination()
                fixed.restoreAllWindows()
                fixed.enqueuePostRestoreNoise(rng: &rng)
                fixed.runQueuedEvents()
                XCTAssertTrue(
                    fixed.allWindowsVisible,
                    "seed=\(seed) step=\(step) fixed=\(fixed)",
                )
            }
        }

        XCTAssertGreaterThan(baselineFailures, 0)
    }
}

private func randomWindowRect(
    monitorRect: Rect,
    windowSize: CGSize,
    behavior: Int,
    rng: inout QuitRestoreLcg,
) -> Rect {
    let width = windowSize.width
    let height = windowSize.height
    let maxInsideX = max(0, Int(monitorRect.width - width))
    let maxInsideY = max(0, Int(monitorRect.height - height))
    let jitter = CGFloat(rng.nextInt(4))
    let x: CGFloat
    let y: CGFloat

    switch behavior {
        case 0:
            x = monitorRect.minX + CGFloat(rng.nextInt(maxInsideX + 1))
            y = monitorRect.minY + CGFloat(rng.nextInt(maxInsideY + 1))
        case 1:
            x = monitorRect.maxX - 1 + jitter
            y = monitorRect.maxY - 1 + jitter
        case 2:
            x = monitorRect.minX - width + 1 - jitter
            y = monitorRect.maxY - 1 + jitter
        case 3:
            x = monitorRect.maxX + CGFloat(rng.nextInt(400))
            y = monitorRect.maxY + CGFloat(rng.nextInt(400))
        default:
            x = monitorRect.minX - width - CGFloat(rng.nextInt(400))
            y = monitorRect.minY - height - CGFloat(rng.nextInt(400))
    }
    return Rect(topLeftX: x, topLeftY: y, width: width, height: height)
}

private struct QuitRestoreLcg: RandomNumberGenerator {
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

private struct QuitLifecycleWorld: CustomStringConvertible {
    private enum QueuedEvent {
        case heavyRefresh
        case lightSessionPostBodyLayout
        case geometryNotification
        case inFlightLayoutResume
        case directWindowMutation
    }

    private struct WindowState: CustomStringConvertible {
        let workspaceIsVisible: Bool
        let preferredSize: CGSize?
        var rect: Rect

        var description: String {
            "WindowState(workspaceIsVisible: \(workspaceIsVisible), preferredSize: \(String(describing: preferredSize)), rect: \(rect))"
        }
    }

    private let monitorRect: Rect
    private var windows: [WindowState]
    private var queuedEvents: [QueuedEvent] = []
    private var isTerminating = false

    var description: String {
        "QuitLifecycleWorld(isTerminating: \(isTerminating), windows: \(windows))"
    }

    static func random(monitorRect: Rect, rng: inout QuitRestoreLcg) -> QuitLifecycleWorld {
        let windowCount = 1 + rng.nextInt(8)
        var windows: [WindowState] = []
        var hasInvisibleWorkspaceWindow = false
        for index in 0 ..< windowCount {
            let workspaceIsVisible = index == 0 ? false : rng.nextBool(probabilityPercent: 40)
            hasInvisibleWorkspaceWindow = hasInvisibleWorkspaceWindow || !workspaceIsVisible
            let size = CGSize(
                width: CGFloat(120 + rng.nextInt(1200)),
                height: CGFloat(80 + rng.nextInt(800)),
            )
            let rect = randomWindowRect(
                monitorRect: monitorRect,
                windowSize: size,
                behavior: workspaceIsVisible ? rng.nextInt(2) : 1 + rng.nextInt(2),
                rng: &rng,
            )
            let preferredSize = rng.nextBool(probabilityPercent: 50)
                ? CGSize(width: CGFloat(100 + rng.nextInt(1500)), height: CGFloat(80 + rng.nextInt(900)))
                : nil
            windows.append(WindowState(workspaceIsVisible: workspaceIsVisible, preferredSize: preferredSize, rect: rect))
        }
        precondition(hasInvisibleWorkspaceWindow)
        return QuitLifecycleWorld(monitorRect: monitorRect, windows: windows)
    }

    mutating func beginTermination() {
        isTerminating = true
        queuedEvents = []
    }

    mutating func restoreAllWindows() {
        for index in windows.indices {
            let frame = makeVisibleRestorationFrame(
                knownVisibleRect: monitorRect,
                currentWindowRect: windows[index].rect,
                preferredSize: windows[index].preferredSize,
            )
            windows[index].rect = Rect(
                topLeftX: frame.topLeft.x,
                topLeftY: frame.topLeft.y,
                width: frame.size.width,
                height: frame.size.height,
            )
        }
    }

    mutating func enqueuePostRestoreNoise(rng: inout QuitRestoreLcg) {
        let count = 1 + rng.nextInt(8)
        for _ in 0 ..< count {
            let event: QueuedEvent = switch rng.nextInt(5) {
                case 0: .heavyRefresh
                case 1: .lightSessionPostBodyLayout
                case 2: .inFlightLayoutResume
                case 3: .directWindowMutation
                default: .geometryNotification
            }
            queuedEvents.append(event)
        }
    }

    mutating func runQueuedEvents() {
        while !queuedEvents.isEmpty {
            let event = queuedEvents.removeFirst()
            if isTerminating { continue }
            switch event {
                case .heavyRefresh, .lightSessionPostBodyLayout, .geometryNotification, .inFlightLayoutResume:
                    layoutWorkspaces()
                case .directWindowMutation:
                    directWindowMutation()
            }
        }
    }

    var allWindowsVisible: Bool {
        windows.allSatisfy { $0.rect.isEffectivelyVisible(in: monitorRect) }
    }

    private mutating func layoutWorkspaces() {
        for index in windows.indices where !windows[index].workspaceIsVisible {
            windows[index].rect = hiddenBottomRightRect(size: windows[index].rect.size)
        }
    }

    private mutating func directWindowMutation() {
        for index in windows.indices where !windows[index].workspaceIsVisible {
            windows[index].rect = Rect(
                topLeftX: monitorRect.maxX + 20,
                topLeftY: monitorRect.maxY + 20,
                width: windows[index].rect.width,
                height: windows[index].rect.height,
            )
        }
    }

    private func hiddenBottomRightRect(size: CGSize) -> Rect {
        Rect(
            topLeftX: monitorRect.maxX - 1,
            topLeftY: monitorRect.maxY - 1,
            width: size.width,
            height: size.height,
        )
    }
}
