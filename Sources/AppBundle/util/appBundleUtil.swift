import AppKit
import Common
import Darwin
import Dispatch
import Foundation
import os

let signposter = OSSignposter(subsystem: aeroshiftAppId, category: .pointsOfInterest)

let myPid = NSRunningApplication.current.processIdentifier
let lockScreenAppBundleId = "com.apple.loginwindow"
@MainActor private var terminationSignalSources: [DispatchSourceSignal] = []

@MainActor
func interceptTermination(_ _signal: Int32) {
    signal(_signal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: _signal, queue: .main)
    source.setEventHandler {
        Task { @MainActor in
            defer { Darwin.exit(_signal) }
            do {
                try await terminationHandler.beforeTermination()
            } catch {
                eprint("Failed to restore windows before termination: \(error)")
            }
        }
    }
    source.resume()
    terminationSignalSources.append(source)
}

@MainActor
func initTerminationHandler() {
    unsafe _terminationHandler = AppServerTerminationHandler()
}

private struct AppServerTerminationHandler: TerminationHandler {
    func beforeTermination() async {
        await makeAllWindowsVisibleAndRestoreSize()
        await toggleReleaseServerIfDebug(.on)
    }
}

@MainActor
private func makeAllWindowsVisibleAndRestoreSize() async {
    for window in MacWindow.allWindows {
        await makeWindowVisibleAndRestoreSize(window)
    }
}

@MainActor
private func makeWindowVisibleAndRestoreSize(_ window: MacWindow) async {
    do {
        // Termination cleanup must be best-effort because some windows may already be gone or unbound.
        let windowRect = try? await window.getAxRect()
        let knownVisibleRect = window.nodeWorkspace?.workspaceMonitor.visibleRect ?? window.nodeMonitor?.visibleRect
        let (topLeft, size) = makeVisibleRestorationFrame(
            knownVisibleRect: knownVisibleRect,
            currentWindowRect: windowRect,
            preferredSize: window.lastFloatingSize,
        )
        try await window.setAxFrameBlocking(topLeft, size)
    } catch {
        eprint("Failed to restore window \(window.windowId) before termination: \(error)")
    }
}

func makeVisibleRestorationFrame(
    knownVisibleRect: Rect?,
    currentWindowRect: Rect?,
    preferredSize: CGSize?,
) -> (topLeft: CGPoint, size: CGSize) {
    let monitorVisibleRect = knownVisibleRect ?? currentWindowRect?.center.monitorApproximation.visibleRect ?? mainMonitor.visibleRect
    return makeVisibleRestorationFrame(
        monitorVisibleRect: monitorVisibleRect,
        preferredSize: preferredSize ?? currentWindowRect?.size,
    )
}

func makeVisibleRestorationFrame(monitorVisibleRect: Rect, preferredSize: CGSize?) -> (topLeft: CGPoint, size: CGSize) {
    let preferredSize = preferredSize ?? monitorVisibleRect.size
    let size = CGSize(
        width: min(preferredSize.width, monitorVisibleRect.width),
        height: min(preferredSize.height, monitorVisibleRect.height),
    )
    let topLeft = CGPoint(
        x: monitorVisibleRect.topLeftX + (monitorVisibleRect.width - size.width) / 2,
        y: monitorVisibleRect.topLeftY + (monitorVisibleRect.height - size.height) / 2,
    )
    return (topLeft, size)
}

@MainActor
func terminateApp() -> Never {
    NSApplication.shared.terminate(nil)
    die("Unreachable code")
}

extension String {
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(self, forType: .string)
    }
}

func - (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x - b.x, y: a.y - b.y)
}

func + (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x + b.x, y: a.y + b.y)
}

extension CGPoint: ConvenienceCopyable {}

extension CGPoint {
    func distance(toOuterFrame rect: Rect) -> CGFloat {
        // Subtract 1 from maxX/maxY because the right/bottom bounds are
        // exclusive.
        let dx = max(rect.minX - x, 0, x - (rect.maxX - 1))
        let dy = max(rect.minY - y, 0, y - (rect.maxY - 1))
        return CGPoint(x: dx, y: dy).vectorLength
    }

    func coerce(in rect: Rect) -> CGPoint? {
        guard let xRange = rect.minX.until(incl: rect.maxX - 1) else { return nil }
        guard let yRange = rect.minY.until(incl: rect.maxY - 1) else { return nil }
        return CGPoint(x: x.coerce(in: xRange), y: y.coerce(in: yRange))
    }

    func addingXOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x + offset, y: y) }
    func addingYOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x, y: y + offset) }
    func addingOffset(_ orientation: Orientation, _ offset: CGFloat) -> CGPoint { orientation == .h ? addingXOffset(offset) : addingYOffset(offset) }

    func getProjection(_ orientation: Orientation) -> Double { orientation == .h ? x : y }

    var vectorLength: CGFloat { sqrt(x * x + y * y) }

    var monitorApproximation: Monitor { monitors.minByOrDie { distance(toOuterFrame: $0.rect) } }
}

extension CGFloat {
    func div(_ denominator: Int) -> CGFloat? {
        denominator == 0 ? nil : self / CGFloat(denominator)
    }

    func coerce(in range: ClosedRange<CGFloat>) -> CGFloat {
        switch true {
            case self > range.upperBound: range.upperBound
            case self < range.lowerBound: range.lowerBound
            default: self
        }
    }
}

extension CGPoint: @retroactive Hashable { // todo migrate to self written Point
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

#if DEBUG
    let isDebug = true
#else
    let isDebug = false
#endif

@inlinable
func checkCancellation() throws(CancellationError) {
    if Task.isCancelled {
        throw CancellationError()
    }
}
