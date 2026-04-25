import AppBundle
import AppKit
import SwiftUI

// This file is shared between SPM and xcode project

final class AeroshiftApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            applicationShouldTerminateAfterAppBundleCleanup(sender)
        }
    }
}

@main
struct AeroshiftApp: App {
    @NSApplicationDelegateAdaptor(AeroshiftApplicationDelegate.self) var appDelegate
    @StateObject var viewModel = TrayMenuModel.shared
    @StateObject var messageModel = MessageModel.shared
    @Environment(\.openWindow) var openWindow: OpenWindowAction

    init() {
        initAppBundle()
    }

    var body: some Scene {
        menuBar(viewModel: viewModel)
        getMessageWindow(messageModel: messageModel)
            .onChange(of: messageModel.message) { message in
                if message != nil {
                    openWindow(id: messageWindowId)
                }
            }
    }
}
