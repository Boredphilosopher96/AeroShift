import AppKit
import Common

enum GlobalObserver {
    @MainActor
    static func initObserver() {
        ObserverIngress.initGlobalObservers()
    }
}

@MainActor
func handleHideApplication(pid _: pid_t) async throws {
    if config.automaticallyUnhideMacosHiddenApps {
        if let w = prevFocus?.windowOrNil,
           w.macAppUnsafe.nsApp.isHidden,
           // "Hide others" (cmd-alt-h) -> don't force focus
           // "Hide app" (cmd-h) -> force focus
           MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
        {
            _ = w.focusWindow()
            w.nativeFocus()
        }
        for app in MacApp.allAppsMap.values {
            app.nsApp.unhide()
        }
    }
}
