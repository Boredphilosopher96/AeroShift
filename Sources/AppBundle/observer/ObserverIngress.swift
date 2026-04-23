import AppKit
import Common
import Dispatch
import Foundation

struct ObserverRegistrationResult {
    let subscriptions: [AxSubscription]
    let requestedNotifications: [String]
    let failedNotifications: [String]

    var hasAnyRegistration: Bool { !subscriptions.isEmpty }
    var hasFailures: Bool { !failedNotifications.isEmpty }
}

enum ObserverIngress {
    static let appAxObserverHandlers: HandlerToNotifKeyMapping = unsafe [
        (observerIngressAppAxCallback, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]),
    ]

    static let windowAxObserverHandlers: HandlerToNotifKeyMapping = unsafe [
        (observerIngressWindowLifecycleCallback, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
        (observerIngressWindowMovedCallback, [kAXMovedNotification]),
        (observerIngressWindowResizedCallback, [kAXResizedNotification]),
    ]

    @MainActor
    static func initGlobalObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { onWorkspaceNotification($0) }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { onWorkspaceNotification($0) }
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { onWorkspaceNotification($0) }
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { onWorkspaceNotification($0) }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { onWorkspaceNotification($0) }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { onWorkspaceNotification($0) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            publish(kind: .screenParametersChanged, pid: nil, windowId: nil)
        }

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            publish(kind: .leftMouseUp, pid: nil, windowId: nil)
        }
    }

    static func publish(
        kind: ObserverIngressEventKind,
        pid: pid_t?,
        windowId: UInt32?,
        timestampNs: UInt64 = DispatchTime.now().uptimeNanoseconds,
    ) {
        ObserverPlanner.shared.publish(.init(kind: kind, pid: pid, windowId: windowId, timestampNs: timestampNs))
    }

    static func publishRegistrationResult(
        _ result: ObserverRegistrationResult,
        pid: pid_t,
        windowId: UInt32?,
    ) {
        guard result.hasFailures else { return }
        let state = signposter.beginInterval(
            #function,
            "pid: \(pid) windowId: \(windowId.prettyDescription) failed: \(result.failedNotifications.joined(separator: ","))"
        )
        defer { signposter.endInterval(#function, state) }
        publish(kind: .observerDegraded, pid: pid, windowId: windowId)
    }

    private static func onWorkspaceNotification(_ notification: Notification) {
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let kind: ObserverIngressEventKind? = switch notification.name {
            case NSWorkspace.didLaunchApplicationNotification:
                .didLaunchApplication
            case NSWorkspace.didActivateApplicationNotification:
                .didActivateApplication
            case NSWorkspace.didHideApplicationNotification:
                .didHideApplication
            case NSWorkspace.didUnhideApplicationNotification:
                .didUnhideApplication
            case NSWorkspace.activeSpaceDidChangeNotification:
                .activeSpaceDidChange
            case NSWorkspace.didTerminateApplicationNotification:
                .didTerminateApplication
            default:
                nil
        }
        guard let kind else { return }
        let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        publish(kind: kind, pid: pid, windowId: nil)
    }
}

private func observerIngressAppAxCallback(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    ObserverIngress.publish(kind: notif.asObserverIngressEventKind().orDie(), pid: ax.processIdentifier, windowId: ax.containingWindowId())
}

private func observerIngressWindowLifecycleCallback(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    ObserverIngress.publish(kind: notif.asObserverIngressEventKind().orDie(), pid: ax.processIdentifier, windowId: ax.containingWindowId())
}

private func observerIngressWindowMovedCallback(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    ObserverIngress.publish(kind: notif.asObserverIngressEventKind().orDie(), pid: ax.processIdentifier, windowId: ax.containingWindowId())
}

private func observerIngressWindowResizedCallback(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    ObserverIngress.publish(kind: notif.asObserverIngressEventKind().orDie(), pid: ax.processIdentifier, windowId: ax.containingWindowId())
}

private extension CFString {
    func asObserverIngressEventKind() -> ObserverIngressEventKind? {
        switch self as String {
            case kAXWindowCreatedNotification:
                .axWindowCreated
            case kAXFocusedWindowChangedNotification:
                .axFocusedWindowChanged
            case kAXUIElementDestroyedNotification:
                .axWindowDestroyed
            case kAXWindowDeminiaturizedNotification:
                .axWindowDeminiaturized
            case kAXWindowMiniaturizedNotification:
                .axWindowMiniaturized
            case kAXMovedNotification:
                .axWindowMoved
            case kAXResizedNotification:
                .axWindowResized
            default:
                nil
        }
    }
}
