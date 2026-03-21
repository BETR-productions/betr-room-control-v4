// RoomControlApp — SwiftUI entry point for BËTR Room Control v4.

import AppKit
import SwiftUI
import FeatureUI
import RoomControlXPCContracts

// MARK: - App Delegate

final class RoomControlAppDelegate: NSObject, NSApplicationDelegate {
    private var xpcConnection: NSXPCConnection?

    func applicationDidFinishLaunching(_ notification: Notification) {
        establishXPCConnection()
    }

    func applicationWillTerminate(_ notification: Notification) {
        xpcConnection?.invalidate()
        xpcConnection = nil
    }

    private func establishXPCConnection() {
        let connection = NSXPCConnection(machServiceName: RoomControlXPC.serviceName, options: [])
        // XPC interface will be configured once BETRCoreXPC protocols are complete (Task 3).
        connection.resume()
        xpcConnection = connection
    }
}

// MARK: - SwiftUI App

@main
struct RoomControlApplication: App {
    @NSApplicationDelegateAdaptor(RoomControlAppDelegate.self) var appDelegate

    @StateObject private var shellState = ShellViewState()

    var body: some Scene {
        WindowGroup {
            RoomControlShellView(state: shellState)
                .frame(minWidth: 1200, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
