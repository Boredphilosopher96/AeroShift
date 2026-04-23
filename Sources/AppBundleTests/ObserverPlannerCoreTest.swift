@testable import AppBundle
import Common
import XCTest

final class ObserverPlannerCoreTest: XCTestCase {
    func testLeadingEdgeRefreshFiresImmediatelyAndQueuesTrailingRepair() {
        var core = ObserverPlannerCore()
        core.ingest(event(.axWindowCreated, pid: 42, windowId: 100, at: 0))
        assertEquals(core.drainImmediate(), [.refreshApp(42)])
        core.ingest(event(.axFocusedWindowChanged, pid: 42, windowId: 100, at: 1))
        assertEquals(core.drainImmediate(), [])

        assertEquals(core.pendingShortRefreshPidCount, 1)
        assertEquals(core.drainShortIfReady(at: observerPlannerShortDebounceNs - 1), [])
        assertEquals(core.drainShortIfReady(at: observerPlannerShortDebounceNs), [.refreshApp(42)])
    }

    func testGeometryLaneCoalescesByWindowAndKeepsLatestIntent() {
        var core = ObserverPlannerCore()
        core.ingest(event(.axWindowMoved, pid: 7, windowId: 200, at: 0))
        core.ingest(event(.axWindowResized, pid: 7, windowId: 200, at: 1))

        assertEquals(core.pendingGeometryIntentCount, 1)
        assertEquals(core.drainGeometryIfReady(at: observerPlannerGeometryDebounceNs - 1), [])
        assertEquals(core.drainGeometryIfReady(at: observerPlannerGeometryDebounceNs), [.mouseResize(200, 7)])
    }

    func testInteractiveGeometryFiresImmediately() {
        var core = ObserverPlannerCore()
        core.ingest(event(.axWindowMoved, pid: 7, windowId: 200, at: 0, mouseDown: true))

        assertEquals(core.drainImmediate(), [.mouseMove(200, 7)])
        assertEquals(core.pendingGeometryIntentCount, 0)
    }

    func testImmediateLaneDrainsUncertainAppsOnLeftMouseUp() {
        var core = ObserverPlannerCore()
        core.ingest(event(.axWindowCreated, pid: 1, windowId: 10, at: 0, mouseDown: true))
        assertEquals(core.drainImmediate(), [.refreshApp(1)])
        core.ingest(event(.axWindowResized, pid: 2, windowId: 20, at: 1, mouseDown: true))
        assertEquals(core.drainImmediate(), [.mouseResize(20, 2)])
        assertEquals(core.pendingUncertainPidCount, 2)

        core.ingest(event(.leftMouseUp, pid: nil, windowId: nil, at: 2))
        assertEquals(
            core.drainImmediate(),
            [.resetManipulatedMouse, .syncMonitorFocus(testLeftMouseUpContext), .refreshApp(1), .refreshApp(2)],
        )
        assertEquals(core.pendingUncertainPidCount, 0)
    }

    func testDegradedObserverEscalatesAfterThreshold() {
        var core = ObserverPlannerCore()

        core.ingest(event(.observerDegraded, pid: 5, windowId: nil, at: 0))
        assertEquals(core.drainShortIfReady(at: observerPlannerShortDebounceNs), [.refreshApp(5)])

        core.ingest(event(.observerDegraded, pid: 5, windowId: nil, at: 10))
        assertEquals(core.drainShortIfReady(at: 10 + observerPlannerShortDebounceNs), [.refreshApp(5)])

        core.ingest(event(.observerDegraded, pid: 5, windowId: nil, at: 20))
        assertEquals(
            core.drainShortIfReady(at: 20 + observerPlannerShortDebounceNs),
            [.fullRefresh(.degradedObserver(5))],
        )
    }

    func testMissingPidEscalatesToConfidenceLossFullRefresh() {
        var core = ObserverPlannerCore()
        core.ingest(event(.axWindowCreated, pid: nil, windowId: 55, at: 0))

        assertEquals(
            core.drainShortIfReady(at: observerPlannerShortDebounceNs),
            [.fullRefresh(.plannerConfidenceLoss("axWindowCreated missing pid"))],
        )
    }

    func testLanePriorityIsImmediateThenShortThenGeometry() {
        var core = ObserverPlannerCore()
        core.ingest(event(.axWindowMoved, pid: 1, windowId: 11, at: 0))
        assertEquals(core.drainImmediate(), [])
        core.ingest(event(.axWindowCreated, pid: 2, windowId: 21, at: 1))
        assertEquals(core.drainImmediate(), [.refreshApp(2)])
        core.ingest(event(.axFocusedWindowChanged, pid: 2, windowId: 21, at: 2))
        assertEquals(core.drainImmediate(), [])
        core.ingest(event(.leftMouseUp, pid: nil, windowId: nil, at: 3))
        assertEquals(core.drainImmediate(), [.resetManipulatedMouse, .syncMonitorFocus(testLeftMouseUpContext)])
        assertEquals(core.drainShortIfReady(at: 1 + observerPlannerShortDebounceNs), [.refreshApp(2)])
        assertEquals(core.drainGeometryIfReady(at: observerPlannerGeometryDebounceNs), [.mouseMove(11, 1)])
    }

    @MainActor
    func testLeftMouseUpRepairPlanFallsBackToFullRefreshWhenWorkspaceHasNoTrackedWindows() {
        setUpWorkspacesForTests()

        let context = LeftMouseUpContext(monitorTopLeftCorner: mainMonitor.rect.topLeftCorner)
        assertEquals(planLeftMouseUpRepair(context), .fullRefresh)
    }
}

final class ObserverPlannerSimulationTest: XCTestCase {
    func testRegressionAppLaunchWindowConvergesWithoutRestart() {
        var harness = PlannerSimulationHarness(
            actual: .init(appWindows: [:], focusedPid: nil),
            estimated: .init(appWindows: [:], focusedPid: nil),
        )

        harness.actual.openWindow(pid: 1, windowId: 100)
        harness.actual.focusedPid = 1
        harness.ingest(.didLaunchApplication, pid: 1, windowId: nil)
        harness.ingest(.axWindowCreated, pid: 1, windowId: 100)
        harness.drainAll()

        assertEquals(harness.estimated, harness.actual)
    }

    func testRegressionNewWindowOfExistingAppConverges() {
        var harness = PlannerSimulationHarness(
            actual: .init(appWindows: [1: [10]], focusedPid: 1),
            estimated: .init(appWindows: [1: [10]], focusedPid: 1),
        )

        harness.actual.openWindow(pid: 1, windowId: 11)
        harness.ingest(.axWindowCreated, pid: 1, windowId: 11)
        harness.drainAll()

        assertEquals(harness.estimated, harness.actual)
    }

    func testRegressionCreateDuringMouseDownRecoversOnLeftMouseUp() {
        var harness = PlannerSimulationHarness(
            actual: .init(appWindows: [1: [10]], focusedPid: 1),
            estimated: .init(appWindows: [1: [10]], focusedPid: 1),
        )

        harness.actual.openWindow(pid: 1, windowId: 12)
        harness.ingest(.axWindowCreated, pid: 1, windowId: 12, mouseDown: true)
        harness.ingest(.leftMouseUp, pid: nil, windowId: nil)
        harness.drainAll()

        assertEquals(harness.estimated, harness.actual)
        XCTAssertTrue(harness.appliedIntents.contains(.refreshApp(1)))
    }

    func testRegressionDestroyWithoutReliableNotificationRecoversOnLeftMouseUp() {
        var harness = PlannerSimulationHarness(
            actual: .init(appWindows: [1: [10, 11]], focusedPid: 1),
            estimated: .init(appWindows: [1: [10, 11]], focusedPid: 1),
        )

        harness.actual.closeWindow(pid: 1, windowId: 11)
        harness.ingest(.leftMouseUp, pid: nil, windowId: nil)
        harness.drainAll()

        assertEquals(harness.estimated, harness.actual)
        XCTAssertTrue(harness.appliedIntents.contains(.syncMonitorFocus(testLeftMouseUpContext)))
    }

    func testRegressionFocusedWindowStormStillCoalesces() {
        var harness = PlannerSimulationHarness(
            actual: .init(appWindows: [2: [20]], focusedPid: 2),
            estimated: .init(appWindows: [2: [20]], focusedPid: 2),
        )

        for _ in 0 ..< 20 {
            harness.ingest(.axFocusedWindowChanged, pid: 2, windowId: 20)
        }
        harness.drainAll()

        assertEquals(harness.appliedIntents.count(where: { $0 == .refreshApp(2) }), 2)
    }

    func testSeededRandomizedSimulationConverges() {
        for seed in [1 as UInt64, 2, 3, 11, 29] {
            var rng = Lcg(seed: seed)
            var harness = PlannerSimulationHarness(
                actual: .init(appWindows: [1: [10], 2: [20]], focusedPid: 1),
                estimated: .init(appWindows: [1: [10], 2: [20]], focusedPid: 1),
            )
            var nextWindowId: UInt32 = 21
            var nextPid: pid_t = 3

            for step in 0 ..< 250 {
                switch rng.nextInt(6) {
                    case 0:
                        let pid: pid_t
                        if harness.actual.appWindows.isEmpty || rng.nextBool(probabilityPercent: 25) {
                            pid = nextPid
                            nextPid += 1
                            harness.ingest(.didLaunchApplication, pid: pid, windowId: nil)
                        } else {
                            pid = harness.actual.randomPid(using: &rng)
                        }
                        let mouseDown = rng.nextBool(probabilityPercent: 20)
                        harness.actual.openWindow(pid: pid, windowId: nextWindowId)
                        harness.actual.focusedPid = pid
                        harness.ingest(.axWindowCreated, pid: pid, windowId: nextWindowId, mouseDown: mouseDown)
                        nextWindowId += 1

                    case 1:
                        guard let (pid, windowId) = harness.actual.randomWindow(using: &rng) else { continue }
                        harness.actual.closeWindow(pid: pid, windowId: windowId)
                        harness.actual.focusedPid = pid
                        if rng.nextBool(probabilityPercent: 70) {
                            harness.ingest(.axWindowDestroyed, pid: pid, windowId: windowId)
                        } else {
                            harness.ingest(.leftMouseUp, pid: nil, windowId: nil)
                        }
                        if harness.actual.appWindows[pid] == nil, rng.nextBool(probabilityPercent: 60) {
                            harness.ingest(.didTerminateApplication, pid: pid, windowId: nil)
                        }

                    case 2:
                        guard let (pid, windowId) = harness.actual.randomWindow(using: &rng) else { continue }
                        harness.actual.focusedPid = pid
                        let repetitions = rng.nextInt(5) + 1
                        for _ in 0 ..< repetitions {
                            harness.ingest(.axFocusedWindowChanged, pid: pid, windowId: windowId)
                        }

                    case 3:
                        guard let (pid, windowId) = harness.actual.randomWindow(using: &rng) else { continue }
                        let mouseDown = rng.nextBool(probabilityPercent: 35)
                        harness.ingest(.axWindowMoved, pid: pid, windowId: windowId, mouseDown: mouseDown)

                    case 4:
                        guard let (pid, windowId) = harness.actual.randomWindow(using: &rng) else { continue }
                        let mouseDown = rng.nextBool(probabilityPercent: 35)
                        harness.ingest(.axWindowResized, pid: pid, windowId: windowId, mouseDown: mouseDown)

                    default:
                        if let pid = harness.actual.appWindows.keys.sorted().randomElement(using: &rng) {
                            harness.ingest(.observerDegraded, pid: pid, windowId: nil)
                        }
                }

                if step % 7 == 0 || rng.nextBool(probabilityPercent: 15) {
                    harness.ingest(.leftMouseUp, pid: nil, windowId: nil)
                    harness.drainAll()
                }
            }

            harness.ingest(.leftMouseUp, pid: nil, windowId: nil)
            harness.drainAll()
            assertEquals(harness.estimated, harness.actual, additionalMsg: "seed=\(seed)")
        }
    }
}

final class ObserverPlannerBenchmarkTest: XCTestCase {
    func testCreateStormAlgorithmicBoundsAcrossScales() {
        for rawEvents in [1000, 10000, 100_000] {
            for appCount in [1, 10, 100] {
                let stats = benchmarkCreateStorm(rawEvents: rawEvents, appCount: appCount)
                XCTAssertLessThanOrEqual(stats.intents, min(rawEvents, appCount * 2), "rawEvents=\(rawEvents) appCount=\(appCount)")
            }
        }
    }

    func testMixedFocusCreateBoundsAcrossScales() {
        for rawEvents in [1000, 10000, 100_000] {
            for appCount in [1, 10, 100] {
                let stats = benchmarkMixedFocusCreate(rawEvents: rawEvents, appCount: appCount)
                XCTAssertLessThanOrEqual(stats.intents, min(rawEvents, appCount * 2), "rawEvents=\(rawEvents) appCount=\(appCount)")
            }
        }
    }

    func testGeometryStormBoundsAcrossScales() {
        for rawEvents in [1000, 10000, 100_000] {
            for appCount in [1, 10, 100] {
                let stats = benchmarkGeometryStorm(rawEvents: rawEvents, appCount: appCount)
                XCTAssertLessThanOrEqual(stats.intents, min(rawEvents, appCount * 10), "rawEvents=\(rawEvents) appCount=\(appCount)")
            }
        }
    }

    func testMeasureRepresentativeWindowCreateStorm() {
        measure(metrics: [XCTClockMetric()]) {
            _ = benchmarkCreateStorm(rawEvents: 100_000, appCount: 100)
        }
    }

    func testMeasureRepresentativeMixedFocusCreateBurst() {
        measure(metrics: [XCTClockMetric()]) {
            _ = benchmarkMixedFocusCreate(rawEvents: 100_000, appCount: 100)
        }
    }

    func testMeasureRepresentativeGeometryStorm() {
        measure(metrics: [XCTClockMetric()]) {
            _ = benchmarkGeometryStorm(rawEvents: 100_000, appCount: 100)
        }
    }
}

private struct PlannerSimulationHarness {
    var actual: SimulatedWorld
    var estimated: SimulatedWorld
    var core = ObserverPlannerCore()
    var nowNs: UInt64 = 0
    var appliedIntents: [PlannerIntent] = []

    mutating func ingest(
        _ kind: ObserverIngressEventKind,
        pid: pid_t?,
        windowId: UInt32?,
        mouseDown: Bool = false,
    ) {
        apply(core.drainShortIfReady(at: nowNs))
        apply(core.drainGeometryIfReady(at: nowNs))
        core.ingest(event(kind, pid: pid, windowId: windowId, at: nowNs, mouseDown: mouseDown))
        apply(core.drainImmediate())
        nowNs += 1
    }

    mutating func drainAll() {
        apply(core.drainImmediate())
        while core.shortDeadlineNs != nil || core.geometryDeadlineNs != nil {
            let nextShort = core.shortDeadlineNs ?? .max
            let nextGeometry = core.geometryDeadlineNs ?? .max
            nowNs = max(nowNs, min(nextShort, nextGeometry))
            apply(core.drainShortIfReady(at: nowNs))
            apply(core.drainGeometryIfReady(at: nowNs))
            apply(core.drainImmediate())
            nowNs += 1
        }
    }

    private mutating func apply(_ intents: [PlannerIntent]) {
        guard !intents.isEmpty else { return }
        appliedIntents.append(contentsOf: intents)
        for intent in intents {
            switch intent {
                case .refreshApp(let pid):
                    estimated.syncApp(pid, from: actual)
                case .fullRefresh:
                    estimated = actual
                case .mouseMove(let windowId, _), .mouseResize(let windowId, _):
                    if let pid = actual.owner(of: windowId) {
                        estimated.syncApp(pid, from: actual)
                    }
                case .resetManipulatedMouse, .handleHideApp:
                    break
                case .syncMonitorFocus:
                    if let pid = actual.focusedPid {
                        estimated.syncApp(pid, from: actual)
                    }
            }
        }
    }
}

private struct SimulatedWorld: Equatable {
    var appWindows: [pid_t: Set<UInt32>]
    var focusedPid: pid_t?

    mutating func openWindow(pid: pid_t, windowId: UInt32) {
        appWindows[pid, default: []].insert(windowId)
    }

    mutating func closeWindow(pid: pid_t, windowId: UInt32) {
        guard var windows = appWindows[pid] else { return }
        windows.remove(windowId)
        if windows.isEmpty {
            appWindows.removeValue(forKey: pid)
        } else {
            appWindows[pid] = windows
        }
    }

    mutating func syncApp(_ pid: pid_t, from other: SimulatedWorld) {
        if let windows = other.appWindows[pid], !windows.isEmpty {
            appWindows[pid] = windows
        } else {
            appWindows.removeValue(forKey: pid)
        }
        focusedPid = other.focusedPid
    }

    func owner(of windowId: UInt32) -> pid_t? {
        appWindows.first(where: { $0.value.contains(windowId) })?.key
    }

    func randomPid(using rng: inout Lcg) -> pid_t {
        appWindows.keys.sorted()[rng.nextInt(appWindows.count)]
    }

    func randomWindow(using rng: inout Lcg) -> (pid_t, UInt32)? {
        guard let pid = appWindows.keys.sorted().randomElement(using: &rng),
              let windowId = appWindows[pid]?.sorted().randomElement(using: &rng)
        else {
            return nil
        }
        return (pid, windowId)
    }
}

private struct BenchmarkStats {
    let intents: Int
}

private struct Lcg: RandomNumberGenerator {
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

private func benchmarkCreateStorm(rawEvents: Int, appCount: Int) -> BenchmarkStats {
    var core = ObserverPlannerCore()
    var intents = 0
    for index in 0 ..< rawEvents {
        let timestampNs = UInt64(index)
        intents += core.drainShortIfReady(at: timestampNs).count
        intents += core.drainGeometryIfReady(at: timestampNs).count
        let pid = pid_t(index % appCount + 1)
        core.ingest(event(.axWindowCreated, pid: pid, windowId: UInt32(index + 1), at: timestampNs))
        intents += core.drainImmediate().count
    }
    if let shortDeadlineNs = core.shortDeadlineNs {
        intents += core.drainShortIfReady(at: shortDeadlineNs).count
    }
    if let geometryDeadlineNs = core.geometryDeadlineNs {
        intents += core.drainGeometryIfReady(at: geometryDeadlineNs).count
    }
    return .init(intents: intents)
}

private func benchmarkMixedFocusCreate(rawEvents: Int, appCount: Int) -> BenchmarkStats {
    var core = ObserverPlannerCore()
    var intents = 0
    for index in 0 ..< rawEvents {
        let timestampNs = UInt64(index)
        intents += core.drainShortIfReady(at: timestampNs).count
        intents += core.drainGeometryIfReady(at: timestampNs).count
        let pid = pid_t(index % appCount + 1)
        let kind: ObserverIngressEventKind = index.isMultiple(of: 2) ? .axWindowCreated : .axFocusedWindowChanged
        core.ingest(event(kind, pid: pid, windowId: UInt32(index % max(1, appCount) + 1), at: timestampNs))
        intents += core.drainImmediate().count
    }
    if let shortDeadlineNs = core.shortDeadlineNs {
        intents += core.drainShortIfReady(at: shortDeadlineNs).count
    }
    if let geometryDeadlineNs = core.geometryDeadlineNs {
        intents += core.drainGeometryIfReady(at: geometryDeadlineNs).count
    }
    return .init(intents: intents)
}

private func benchmarkGeometryStorm(rawEvents: Int, appCount: Int) -> BenchmarkStats {
    var core = ObserverPlannerCore()
    var intents = 0
    let windowCount = max(1, appCount * 10)
    for index in 0 ..< rawEvents {
        let timestampNs = UInt64(index)
        intents += core.drainShortIfReady(at: timestampNs).count
        intents += core.drainGeometryIfReady(at: timestampNs).count
        let pid = pid_t(index % appCount + 1)
        let windowId = UInt32(index % windowCount + 1)
        let kind: ObserverIngressEventKind = index.isMultiple(of: 2) ? .axWindowMoved : .axWindowResized
        core.ingest(event(kind, pid: pid, windowId: windowId, at: timestampNs))
        intents += core.drainImmediate().count
    }
    if let shortDeadlineNs = core.shortDeadlineNs {
        intents += core.drainShortIfReady(at: shortDeadlineNs).count
    }
    if let geometryDeadlineNs = core.geometryDeadlineNs {
        intents += core.drainGeometryIfReady(at: geometryDeadlineNs).count
    }
    return .init(intents: intents)
}

private func event(
    _ kind: ObserverIngressEventKind,
    pid: pid_t?,
    windowId: UInt32?,
    at timestampNs: UInt64,
    mouseDown: Bool = false,
    leftMouseUpContext: LeftMouseUpContext? = nil,
) -> ObserverIngressEvent {
    let resolvedLeftMouseUpContext = leftMouseUpContext ?? (kind == .leftMouseUp ? testLeftMouseUpContext : nil)
    return .init(
        kind: kind,
        pid: pid,
        windowId: windowId,
        timestampNs: timestampNs,
        isLeftMouseButtonDown: mouseDown,
        leftMouseUpContext: resolvedLeftMouseUpContext,
    )
}

private let testLeftMouseUpContext = LeftMouseUpContext(monitorTopLeftCorner: .zero)
