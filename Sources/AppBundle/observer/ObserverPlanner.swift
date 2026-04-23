import AppKit
import Collections
import Common
import Dispatch

@MainActor
final class PlannerExecutor {
    static let shared = PlannerExecutor()

    private var pending: [PlannerIntent] = []
    private var isDraining = false

    nonisolated static func submit(_ intents: [PlannerIntent]) {
        guard !intents.isEmpty else { return }
        Task { @MainActor in
            shared.pending.append(contentsOf: intents)
            guard !shared.isDraining else { return }
            await shared.drain()
        }
    }

    private func drain() async {
        isDraining = true
        defer { isDraining = false }
        while !pending.isEmpty {
            let intent = pending.removeFirst()
            let state = signposter.beginInterval(#function, "intent: \(intent)")
            defer { signposter.endInterval(#function, state) }
            await execute(intent)
        }
    }

    private func execute(_ intent: PlannerIntent) async {
        switch intent {
            case .refreshApp(let pid):
                await runPlannerSession(.ax("planner.refreshApp(\(pid))"), normalizeLayoutAfterBody: true) {
                    try await refreshApp(pid: pid)
                }

            case .fullRefresh(let reason):
                scheduleCancellableCompleteRefreshSession(.globalObserver("planner.fullRefresh.\(reason.description)"))

            case .mouseMove(let windowId):
                guard let window = Window.get(byId: windowId) else { return }
                if await shouldHandleMouseManipulation(window) {
                    await runPlannerSession(.ax("planner.mouseMove(\(windowId))")) {
                        try await moveWithMouse(window)
                    }
                } else {
                    await runPlannerSession(.ax("planner.mouseMove.refresh(\(windowId))"), normalizeLayoutAfterBody: true) {
                        try await refreshApp(pid: window.app.pid)
                    }
                }

            case .mouseResize(let windowId):
                guard let window = Window.get(byId: windowId) else { return }
                if await shouldHandleMouseManipulation(window) {
                    await runPlannerSession(.ax("planner.mouseResize(\(windowId))")) {
                        try await resizeWithMouse(window)
                    }
                } else {
                    await runPlannerSession(.ax("planner.mouseResize.refresh(\(windowId))"), normalizeLayoutAfterBody: true) {
                        try await refreshApp(pid: window.app.pid)
                    }
                }

            case .resetManipulatedMouse:
                await runPlannerSession(.resetManipulatedWithMouse, normalizeLayoutAfterBody: true) {
                    try await resetManipulatedWithMouseIfPossible(scheduleFollowupRefresh: false)
                }

            case .handleHideApp(let pid):
                await runPlannerSession(.globalObserver(NSWorkspace.didHideApplicationNotification.rawValue), normalizeLayoutAfterBody: true) {
                    try await handleHideApplication(pid: pid)
                }

            case .syncMonitorFocus:
                await syncMonitorFocusAfterLeftMouseUp()
        }
    }

    private func runPlannerSession(
        _ event: RefreshSessionEvent,
        normalizeLayoutAfterBody: Bool = false,
        _ body: @escaping @MainActor () async throws -> (),
    ) async {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        do {
            try await runLightSession(
                event,
                token,
                scheduleFollowupRefresh: false,
                normalizeLayoutAfterBody: normalizeLayoutAfterBody,
                body: body,
            )
        } catch let error as CancellationError {
            _ = error
        } catch {
            die("Illegal error: \(error)")
        }
    }

    private func shouldHandleMouseManipulation(_ window: Window) async -> Bool {
        do {
            return try await isManipulatedWithMouse(window)
        } catch let error as CancellationError {
            _ = error
            return false
        } catch {
            die("Illegal error: \(error)")
        }
    }

    private func syncMonitorFocusAfterLeftMouseUp() async {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let clickedMonitor = mouseLocation.monitorApproximation
        if clickedMonitor.activeWorkspace != focus.workspace {
            do {
                _ = try await runLightSession(.globalObserverLeftMouseUp, token, scheduleFollowupRefresh: false) {
                    clickedMonitor.activeWorkspace.focusWorkspace()
                }
                return
            } catch let error as CancellationError {
                _ = error
                return
            } catch {
                die("Illegal error: \(error)")
            }
        }

        let pidsToRefresh = OrderedSet(clickedMonitor.activeWorkspace.allLeafWindowsRecursive.map(\.app.pid))
        guard !pidsToRefresh.isEmpty else { return }
        await runPlannerSession(.globalObserverLeftMouseUp) {
            for pid in pidsToRefresh {
                try await refreshApp(pid: pid)
            }
        }
    }
}

final class ObserverPlanner: @unchecked Sendable {
    static let shared = ObserverPlanner()

    private let queue = DispatchQueue(label: "\(aeroshiftAppId).observerPlanner")
    private var core = ObserverPlannerCore()
    private var shortTimer: DispatchSourceTimer?
    private var geometryTimer: DispatchSourceTimer?

    func publish(_ event: ObserverIngressEvent) {
        queue.async { [self] in
            let state = signposter.beginInterval(#function, "kind: \(event.kind.rawValue) pid: \(event.pid.prettyDescription) windowId: \(event.windowId.prettyDescription)")
            defer { signposter.endInterval(#function, state) }
            drainReadyLanes(at: event.timestampNs)
            core.ingest(event)
            deliver(core.drainImmediate())
            rescheduleShortTimer()
            rescheduleGeometryTimer()
        }
    }

    private func deliver(_ intents: [PlannerIntent]) {
        guard !intents.isEmpty else { return }
        PlannerExecutor.submit(intents)
    }

    private func rescheduleShortTimer() {
        guard let shortDeadlineNs = core.shortDeadlineNs else {
            shortTimer?.cancel()
            shortTimer = nil
            return
        }
        let timer = shortTimer ?? makeTimer(handler: drainShortLane)
        shortTimer = timer
        timer.schedule(deadline: .init(uptimeNanoseconds: shortDeadlineNs))
    }

    private func rescheduleGeometryTimer() {
        guard let geometryDeadlineNs = core.geometryDeadlineNs else {
            geometryTimer?.cancel()
            geometryTimer = nil
            return
        }
        let timer = geometryTimer ?? makeTimer(handler: drainGeometryLane)
        geometryTimer = timer
        timer.schedule(deadline: .init(uptimeNanoseconds: geometryDeadlineNs))
    }

    private func makeTimer(handler: @escaping @Sendable () -> ()) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    private func drainReadyLanes(at nowNs: UInt64) {
        deliver(core.drainShortIfReady(at: nowNs))
        deliver(core.drainGeometryIfReady(at: nowNs))
    }

    private func drainShortLane() {
        drainReadyLanes(at: DispatchTime.now().uptimeNanoseconds)
        rescheduleShortTimer()
    }

    private func drainGeometryLane() {
        drainReadyLanes(at: DispatchTime.now().uptimeNanoseconds)
        rescheduleGeometryTimer()
    }
}
