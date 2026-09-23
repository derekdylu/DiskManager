import AppKit
import SwiftUI

@main
struct DiskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var chat = ChatState()

    var body: some Scene {
        WindowGroup("DiskManager") {
            ContentView()
                .environmentObject(state)
                .environmentObject(chat)
                .environmentObject(L10n.shared)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensures a proper window and Dock icon even when run directly via swift run
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
