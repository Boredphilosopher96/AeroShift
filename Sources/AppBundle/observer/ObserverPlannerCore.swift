import Collections
import Common
import Foundation

let observerPlannerShortDebounceNs: UInt64 = 2_000_000
let observerPlannerGeometryDebounceNs: UInt64 = 4_000_000
let observerPlannerDegradedObserverFailureThreshold = 3

enum ObserverIngressEventKind: String, Sendable, CaseIterable {
    case axWindowCreated
    case axFocusedWindowChanged
    case axWindowDestroyed
    case axWindowDeminiaturized
    case axWindowMiniaturized
    case axWindowMoved
    case axWindowResized
    case didLaunchApplication
    case didActivateApplication
    case didHideApplication
    case didUnhideApplication
    case didTerminateApplication
    case activeSpaceDidChange
    case screenParametersChanged
    case leftMouseUp
    case observerDegraded
}

struct ObserverIngressEvent: Sendable, Hashable {
    let kind: ObserverIngressEventKind
    let pid: pid_t?
    let windowId: UInt32?
    let timestampNs: UInt64
}

enum PlannerFullRefreshReason: Sendable, Hashable, CustomStringConvertible {
    case activeSpaceDidChange
    case screenParametersChanged
    case degradedObserver(pid_t?)
    case plannerConfidenceLoss(String)

    var description: String {
        switch self {
            case .activeSpaceDidChange:
                "activeSpaceDidChange"
            case .screenParametersChanged:
                "screenParametersChanged"
            case .degradedObserver(let pid):
                "degradedObserver(pid:\(pid.prettyDescription))"
            case .plannerConfidenceLoss(let message):
                "plannerConfidenceLoss(\(message))"
        }
    }
}

enum PlannerIntent: Sendable, Hashable, CustomStringConvertible {
    case refreshApp(pid_t)
    case fullRefresh(PlannerFullRefreshReason)
    case mouseMove(UInt32)
    case mouseResize(UInt32)
    case resetManipulatedMouse
    case handleHideApp(pid_t)
    case syncMonitorFocus

    var description: String {
        switch self {
            case .refreshApp(let pid): "refreshApp(\(pid))"
            case .fullRefresh(let reason): "fullRefresh(\(reason))"
            case .mouseMove(let windowId): "mouseMove(\(windowId))"
            case .mouseResize(let windowId): "mouseResize(\(windowId))"
            case .resetManipulatedMouse: "resetManipulatedMouse"
            case .handleHideApp(let pid): "handleHideApp(\(pid))"
            case .syncMonitorFocus: "syncMonitorFocus"
        }
    }
}

private enum PendingGeometryIntent: Sendable, Hashable {
    case mouseMove(pid_t?)
    case mouseResize(pid_t?)
}

struct ObserverPlannerCore: Sendable {
    private(set) var immediateIntents: OrderedSet<PlannerIntent> = []
    private(set) var shortDeadlineNs: UInt64? = nil
    private(set) var geometryDeadlineNs: UInt64? = nil

    private var shortTrailingRefreshes: OrderedDictionary<pid_t, UInt64> = [:]
    private var shortCooldownDeadlines: [pid_t: UInt64] = [:]
    private var shortFullRefresh: (reason: PlannerFullRefreshReason, deadlineNs: UInt64)? = nil
    private var geometryIntents: OrderedDictionary<UInt32, PendingGeometryIntent> = [:]
    private var uncertainPids: OrderedSet<pid_t> = []
    private var degradedObserverFailures: [pid_t: Int] = [:]

    mutating func ingest(_ event: ObserverIngressEvent, isLeftMouseButtonDown: Bool) {
        cleanupExpiredShortCooldowns(at: event.timestampNs)
        switch event.kind {
            case .leftMouseUp:
                immediateIntents.append(.resetManipulatedMouse)
                immediateIntents.append(.syncMonitorFocus)
                for pid in uncertainPids {
                    immediateIntents.append(.refreshApp(pid))
                }
                uncertainPids.removeAll()

            case .didHideApplication:
                if let pid = event.pid {
                    immediateIntents.append(.handleHideApp(pid))
                } else {
                    queueShortFullRefresh(.plannerConfidenceLoss("didHideApplication missing pid"), at: event.timestampNs)
                }

            case .axWindowCreated, .axFocusedWindowChanged, .didActivateApplication, .didUnhideApplication:
                queueLeadingEdgeRefresh(event.pid, at: event.timestampNs, fallback: "\(event.kind.rawValue) missing pid")
                if isLeftMouseButtonDown, let pid = event.pid {
                    uncertainPids.append(pid)
                }

            case .axWindowDestroyed, .axWindowDeminiaturized, .axWindowMiniaturized, .didLaunchApplication,
                 .didTerminateApplication:
                queueTrailingRefresh(event.pid, at: event.timestampNs, fallback: "\(event.kind.rawValue) missing pid")
                if isLeftMouseButtonDown, let pid = event.pid {
                    uncertainPids.append(pid)
                }

            case .observerDegraded:
                guard let pid = event.pid else {
                    queueShortFullRefresh(.plannerConfidenceLoss("observerDegraded missing pid"), at: event.timestampNs)
                    return
                }
                let failures = degradedObserverFailures[pid, default: 0] + 1
                degradedObserverFailures[pid] = failures
                if failures >= observerPlannerDegradedObserverFailureThreshold {
                    queueShortFullRefresh(.degradedObserver(pid), at: event.timestampNs)
                } else {
                    queueTrailingRefresh(pid, at: event.timestampNs)
                }

            case .activeSpaceDidChange:
                queueShortFullRefresh(.activeSpaceDidChange, at: event.timestampNs)

            case .screenParametersChanged:
                queueShortFullRefresh(.screenParametersChanged, at: event.timestampNs)

            case .axWindowMoved:
                queueGeometryIntent(.mouseMove(event.pid), event, isLeftMouseButtonDown)

            case .axWindowResized:
                queueGeometryIntent(.mouseResize(event.pid), event, isLeftMouseButtonDown)
        }
    }

    mutating func drainImmediate() -> [PlannerIntent] {
        let result = Array(immediateIntents)
        immediateIntents.removeAll()
        return result
    }

    mutating func drainShortIfReady(at nowNs: UInt64) -> [PlannerIntent] {
        guard let shortDeadlineNs, shortDeadlineNs <= nowNs else { return [] }
        if let shortFullRefresh, shortFullRefresh.deadlineNs <= nowNs {
            self.shortFullRefresh = nil
            shortTrailingRefreshes.removeAll()
            cleanupExpiredShortCooldowns(at: nowNs)
            recomputeShortDeadline()
            return [.fullRefresh(shortFullRefresh.reason)]
        }

        let readyPids = shortTrailingRefreshes.compactMap { pid, deadlineNs in deadlineNs <= nowNs ? pid : nil }
        for pid in readyPids {
            _ = shortTrailingRefreshes.removeValue(forKey: pid)
        }
        cleanupExpiredShortCooldowns(at: nowNs)
        recomputeShortDeadline()
        return readyPids.map { .refreshApp($0) }
    }

    mutating func drainGeometryIfReady(at nowNs: UInt64) -> [PlannerIntent] {
        guard let geometryDeadlineNs, geometryDeadlineNs <= nowNs else { return [] }
        self.geometryDeadlineNs = nil
        defer { geometryIntents.removeAll() }
        return geometryIntents.map { windowId, pending in
            switch pending {
                case .mouseMove:
                    .mouseMove(windowId)
                case .mouseResize:
                    .mouseResize(windowId)
            }
        }
    }

    var pendingShortRefreshPidCount: Int { shortTrailingRefreshes.count }
    var pendingGeometryIntentCount: Int { geometryIntents.count }
    var pendingUncertainPidCount: Int { uncertainPids.count }

    private mutating func queueLeadingEdgeRefresh(_ pid: pid_t?, at timestampNs: UInt64, fallback: String) {
        guard let pid else {
            queueShortFullRefresh(.plannerConfidenceLoss(fallback), at: timestampNs)
            return
        }
        if let cooldownDeadline = shortCooldownDeadlines[pid], cooldownDeadline > timestampNs {
            queueTrailingRefresh(pid, deadlineNs: cooldownDeadline)
        } else {
            immediateIntents.append(.refreshApp(pid))
            shortCooldownDeadlines[pid] = timestampNs + observerPlannerShortDebounceNs
        }
    }

    private mutating func queueTrailingRefresh(_ pid: pid_t?, at timestampNs: UInt64, fallback: String) {
        guard let pid else {
            queueShortFullRefresh(.plannerConfidenceLoss(fallback), at: timestampNs)
            return
        }
        queueTrailingRefresh(pid, at: timestampNs)
    }

    private mutating func queueTrailingRefresh(_ pid: pid_t, at timestampNs: UInt64) {
        let cooldownDeadline = max(shortCooldownDeadlines[pid] ?? 0, timestampNs + observerPlannerShortDebounceNs)
        shortCooldownDeadlines[pid] = cooldownDeadline
        queueTrailingRefresh(pid, deadlineNs: cooldownDeadline)
    }

    private mutating func queueTrailingRefresh(_ pid: pid_t, deadlineNs: UInt64) {
        if let existing = shortTrailingRefreshes[pid] {
            shortTrailingRefreshes[pid] = min(existing, deadlineNs)
        } else {
            shortTrailingRefreshes[pid] = deadlineNs
        }
        recomputeShortDeadline()
    }

    private mutating func queueShortFullRefresh(_ reason: PlannerFullRefreshReason, at timestampNs: UInt64) {
        let deadlineNs = timestampNs + observerPlannerShortDebounceNs
        if let shortFullRefresh {
            self.shortFullRefresh = (shortFullRefresh.reason, min(shortFullRefresh.deadlineNs, deadlineNs))
        } else {
            shortFullRefresh = (reason, deadlineNs)
        }
        recomputeShortDeadline()
    }

    private mutating func queueGeometryIntent(
        _ intent: PendingGeometryIntent,
        _ event: ObserverIngressEvent,
        _ isLeftMouseButtonDown: Bool,
    ) {
        if isLeftMouseButtonDown, let pid = event.pid {
            uncertainPids.append(pid)
        }
        if isLeftMouseButtonDown {
            switch (intent, event.windowId, event.pid) {
                case (_, let windowId?, _):
                    let plannerIntent: PlannerIntent = switch intent {
                        case .mouseMove: .mouseMove(windowId)
                        case .mouseResize: .mouseResize(windowId)
                    }
                    immediateIntents.append(plannerIntent)
                case (_, nil, let pid?):
                    immediateIntents.append(.refreshApp(pid))
                case (_, nil, nil):
                    queueShortFullRefresh(.plannerConfidenceLoss("\(event.kind.rawValue) missing pid/windowId"), at: event.timestampNs)
            }
            return
        }
        if let windowId = event.windowId {
            geometryIntents[windowId] = intent
            armGeometryDeadline(event.timestampNs)
        } else if let pid = event.pid {
            queueTrailingRefresh(pid, at: event.timestampNs)
        } else {
            queueShortFullRefresh(.plannerConfidenceLoss("\(event.kind.rawValue) missing pid/windowId"), at: event.timestampNs)
        }
    }

    private mutating func cleanupExpiredShortCooldowns(at nowNs: UInt64) {
        shortCooldownDeadlines = shortCooldownDeadlines.filter { _, deadlineNs in deadlineNs > nowNs }
    }

    private mutating func recomputeShortDeadline() {
        shortDeadlineNs = ([shortFullRefresh?.deadlineNs] + shortTrailingRefreshes.values.map(id)).compactMap(id).min()
    }

    private mutating func armGeometryDeadline(_ timestampNs: UInt64) {
        geometryDeadlineNs = geometryDeadlineNs.map { min($0, timestampNs + observerPlannerGeometryDebounceNs) }
            ?? (timestampNs + observerPlannerGeometryDebounceNs)
    }
}
