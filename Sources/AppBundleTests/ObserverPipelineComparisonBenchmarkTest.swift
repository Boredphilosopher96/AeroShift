@testable import AppBundle
import Common
import Foundation
import XCTest

final class ObserverPipelineComparisonBenchmarkTest: XCTestCase {
    func testPrintLegacyVsPlannerComparison() {
        let scenarios = BenchmarkScenario.allCases
        let scales: [(rawEvents: Int, appCount: Int)] = [
            (1_000, 1),
            (1_000, 10),
            (1_000, 100),
            (10_000, 1),
            (10_000, 10),
            (10_000, 100),
            (100_000, 1),
            (100_000, 10),
            (100_000, 100),
        ]

        for scenario in scenarios {
            print("")
            print("SCENARIO \(scenario.rawValue)")
            print("events apps | legacy ev/s | planner ev/s | legacy intents | planner intents | legacy p95 ms | planner p95 ms | legacy max ms | planner max ms")
            for scale in scales {
                let workload = scenario.makeWorkload(rawEvents: scale.rawEvents, appCount: scale.appCount)
                let legacy = benchmarkMetrics(workload, using: LegacyObserverPipeline())
                let planner = benchmarkMetrics(workload, using: PlannerObserverPipeline())

                XCTAssertLessThanOrEqual(planner.intentCount, legacy.intentCount, "\(scenario.rawValue) \(scale)")

                let row = [
                    "\(scale.rawEvents) \(scale.appCount)",
                    formatRate(legacy.eventsPerSecond),
                    formatRate(planner.eventsPerSecond),
                    String(legacy.intentCount),
                    String(planner.intentCount),
                    formatMs(legacy.p95LatencyNs),
                    formatMs(planner.p95LatencyNs),
                    formatMs(legacy.maxLatencyNs),
                    formatMs(planner.maxLatencyNs),
                ].joined(separator: " | ")
                print(row)
            }
        }
    }
}

private enum BenchmarkScenario: String, CaseIterable {
    case createStorm
    case mixedFocusCreate
    case geometryStorm
    case interactiveGeometryStorm

    func makeWorkload(rawEvents: Int, appCount: Int) -> [BenchmarkEvent] {
        let spacingNs: UInt64 = 100_000 // 0.1 ms between raw events
        let windowCount = max(1, appCount * 10)
        return (0 ..< rawEvents).map { index in
            let pid = pid_t(index % appCount + 1)
            let timestampNs = UInt64(index) * spacingNs
            let windowId = UInt32(index % windowCount + 1)
            return switch self {
                case .createStorm:
                    BenchmarkEvent(id: index, kind: .axWindowCreated, pid: pid, windowId: UInt32(index + 1), timestampNs: timestampNs, mouseDown: false)
                case .mixedFocusCreate:
                    BenchmarkEvent(
                        id: index,
                        kind: index.isMultiple(of: 2) ? .axWindowCreated : .axFocusedWindowChanged,
                        pid: pid,
                        windowId: windowId,
                        timestampNs: timestampNs,
                        mouseDown: false
                    )
                case .geometryStorm:
                    BenchmarkEvent(
                        id: index,
                        kind: index.isMultiple(of: 2) ? .axWindowMoved : .axWindowResized,
                        pid: pid,
                        windowId: windowId,
                        timestampNs: timestampNs,
                        mouseDown: false
                    )
                case .interactiveGeometryStorm:
                    BenchmarkEvent(
                        id: index,
                        kind: index.isMultiple(of: 2) ? .axWindowMoved : .axWindowResized,
                        pid: pid,
                        windowId: windowId,
                        timestampNs: timestampNs,
                        mouseDown: true
                    )
            }
        }
    }
}

private struct BenchmarkEvent {
    let id: Int
    let kind: ObserverIngressEventKind
    let pid: pid_t?
    let windowId: UInt32?
    let timestampNs: UInt64
    let mouseDown: Bool
}

private protocol BenchmarkPipeline {
    mutating func ingest(_ event: BenchmarkEvent)
    mutating func finish()
    var intentCount: Int { get }
    var latenciesNs: [UInt64] { get }
}

private struct LegacyObserverPipeline: BenchmarkPipeline {
    private(set) var intentCount = 0
    private(set) var latenciesNs: [UInt64] = []

    mutating func ingest(_ event: BenchmarkEvent) {
        latenciesNs.append(0)
        switch event.kind {
            case .didHideApplication:
                intentCount += 1

            case .leftMouseUp:
                intentCount += 2

            case .axWindowMoved:
                intentCount += 1

            case .axWindowResized:
                intentCount += 1

            default:
                intentCount += 1
        }
    }

    mutating func finish() {}
}

private struct PlannerObserverPipeline: BenchmarkPipeline {
    private var core = ObserverPlannerCore()
    private(set) var intentCount = 0
    private(set) var latenciesNs: [UInt64] = []
    private var pendingPidEvents: [pid_t: [UInt64]] = [:]
    private var pendingMovedEvents: [UInt32: [UInt64]] = [:]
    private var pendingResizedEvents: [UInt32: [UInt64]] = [:]
    private var pendingHideEvents: [pid_t: [UInt64]] = [:]
    private var pendingLeftMouseUpEvents: [UInt64] = []

    mutating func ingest(_ event: BenchmarkEvent) {
        drain(at: event.timestampNs)
        registerPending(event)
        core.ingest(
            .init(kind: event.kind, pid: event.pid, windowId: event.windowId, timestampNs: event.timestampNs),
            isLeftMouseButtonDown: event.mouseDown
        )
        apply(core.drainImmediate(), at: event.timestampNs)
    }

    mutating func finish() {
        while core.shortDeadlineNs != nil || core.geometryDeadlineNs != nil {
            let nextShort = core.shortDeadlineNs ?? .max
            let nextGeometry = core.geometryDeadlineNs ?? .max
            drain(at: min(nextShort, nextGeometry))
        }
    }

    private mutating func drain(at nowNs: UInt64) {
        apply(core.drainImmediate(), at: nowNs)
        apply(core.drainShortIfReady(at: nowNs), at: nowNs)
        apply(core.drainGeometryIfReady(at: nowNs), at: nowNs)
    }

    private mutating func registerPending(_ event: BenchmarkEvent) {
        switch event.kind {
            case .axWindowMoved:
                if let windowId = event.windowId {
                    pendingMovedEvents[windowId, default: []].append(event.timestampNs)
                }
            case .axWindowResized:
                if let windowId = event.windowId {
                    pendingResizedEvents[windowId, default: []].append(event.timestampNs)
                }
            case .didHideApplication:
                if let pid = event.pid {
                    pendingHideEvents[pid, default: []].append(event.timestampNs)
                }
            case .leftMouseUp:
                pendingLeftMouseUpEvents.append(event.timestampNs)
            default:
                if let pid = event.pid, event.kind.isPidRefreshKind {
                    pendingPidEvents[pid, default: []].append(event.timestampNs)
                }
        }
    }

    private mutating func apply(_ intents: [PlannerIntent], at nowNs: UInt64) {
        guard !intents.isEmpty else { return }
        intentCount += intents.count
        for intent in intents {
            switch intent {
                case .refreshApp(let pid):
                    flushPidEvents(pid, at: nowNs)

                case .fullRefresh:
                    for pid in Array(pendingPidEvents.keys) {
                        flushPidEvents(pid, at: nowNs)
                    }
                    for windowId in Array(pendingMovedEvents.keys) {
                        flushMovedEvents(windowId, at: nowNs)
                    }
                    for windowId in Array(pendingResizedEvents.keys) {
                        flushResizedEvents(windowId, at: nowNs)
                    }
                    for pid in Array(pendingHideEvents.keys) {
                        flushHideEvents(pid, at: nowNs)
                    }
                    flushLeftMouseUpEvents(at: nowNs)

                case .mouseMove(let windowId):
                    flushMovedEvents(windowId, at: nowNs)

                case .mouseResize(let windowId):
                    flushResizedEvents(windowId, at: nowNs)

                case .resetManipulatedMouse:
                    break

                case .handleHideApp(let pid):
                    flushHideEvents(pid, at: nowNs)

                case .syncMonitorFocus:
                    flushLeftMouseUpEvents(at: nowNs)
            }
        }
    }

    private mutating func flushPidEvents(_ pid: pid_t, at nowNs: UInt64) {
        flush(pendingPidEvents.removeValue(forKey: pid), at: nowNs)
    }

    private mutating func flushMovedEvents(_ windowId: UInt32, at nowNs: UInt64) {
        flush(pendingMovedEvents.removeValue(forKey: windowId), at: nowNs)
    }

    private mutating func flushResizedEvents(_ windowId: UInt32, at nowNs: UInt64) {
        flush(pendingResizedEvents.removeValue(forKey: windowId), at: nowNs)
    }

    private mutating func flushHideEvents(_ pid: pid_t, at nowNs: UInt64) {
        flush(pendingHideEvents.removeValue(forKey: pid), at: nowNs)
    }

    private mutating func flushLeftMouseUpEvents(at nowNs: UInt64) {
        flush(pendingLeftMouseUpEvents, at: nowNs)
        pendingLeftMouseUpEvents.removeAll(keepingCapacity: false)
    }

    private mutating func flush(_ timestamps: [UInt64]?, at nowNs: UInt64) {
        guard let timestamps else { return }
        latenciesNs.append(contentsOf: timestamps.map { nowNs >= $0 ? nowNs - $0 : 0 })
    }

    private mutating func flush(_ timestamps: [UInt64], at nowNs: UInt64) {
        latenciesNs.append(contentsOf: timestamps.map { nowNs >= $0 ? nowNs - $0 : 0 })
    }
}

private func benchmarkMetrics<P: BenchmarkPipeline>(_ workload: [BenchmarkEvent], using pipeline: P) -> ComparisonMetrics {
    let started = DispatchTime.now().uptimeNanoseconds
    var pipeline = pipeline
    for event in workload {
        pipeline.ingest(event)
    }
    pipeline.finish()
    let runtimeNs = DispatchTime.now().uptimeNanoseconds - started
    let latencies = pipeline.latenciesNs.sorted()
    let p95Index = min(latencies.count - 1, Int(Double(latencies.count - 1) * 0.95))
    return .init(
        runtimeNs: runtimeNs,
        eventCount: workload.count,
        intentCount: pipeline.intentCount,
        p95LatencyNs: latencies[p95Index],
        maxLatencyNs: latencies.last ?? 0
    )
}

private struct ComparisonMetrics {
    let runtimeNs: UInt64
    let eventCount: Int
    let intentCount: Int
    let p95LatencyNs: UInt64
    let maxLatencyNs: UInt64

    var eventsPerSecond: Double {
        Double(eventCount) / (Double(runtimeNs) / 1_000_000_000)
    }
}

private extension ObserverIngressEventKind {
    var isPidRefreshKind: Bool {
        switch self {
            case .axWindowCreated, .axFocusedWindowChanged, .axWindowDestroyed,
                 .axWindowDeminiaturized, .axWindowMiniaturized, .didLaunchApplication,
                 .didActivateApplication, .didUnhideApplication, .didTerminateApplication,
                 .observerDegraded:
                true
            case .axWindowMoved, .axWindowResized, .didHideApplication, .activeSpaceDidChange,
                 .screenParametersChanged, .leftMouseUp:
                false
        }
    }
}

private func formatRate(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)).orDie()
}

private func formatMs(_ valueNs: UInt64) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: Double(valueNs) / 1_000_000)).orDie()
}
