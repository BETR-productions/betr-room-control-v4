// RoomControlApp — SwiftUI entry point for BËTR Room Control v4.
// Wires CoreAgentClient (XPC) and CapacitySampler into ShellViewState.

import AppKit
import SwiftUI
import FeatureUI
import RoutingDomain
import RoomControlXPCContracts

// MARK: - App Delegate

final class RoomControlAppDelegate: NSObject, NSApplicationDelegate {
    let coreAgent = CoreAgentClient()
    let capacitySampler = CapacitySampler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await coreAgent.connect()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await capacitySampler.stop()
            await coreAgent.disconnect()
        }
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
                .task {
                    shellState.bind(
                        coreAgent: appDelegate.coreAgent,
                        capacitySampler: appDelegate.capacitySampler
                    )
                }
                .onDisappear {
                    shellState.unbind()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
