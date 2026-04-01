import AppKit
import FeatureUI
import Foundation
import RoutingDomain
import SwiftUI

private enum RoomControlStartupMode {
    case standard
    case bootstrapCheck

    static var current: Self {
        let environment = ProcessInfo.processInfo.environment
        if environment["BETR_ROOM_CONTROL_BOOTSTRAP_CHECK"] == "1" {
            return .bootstrapCheck
        }
        return .standard
    }
}

@main
struct RoomControlDesktopApplication: App {
    private let startupMode = RoomControlStartupMode.current
    @StateObject private var store = RoomControlWorkspaceStore()

    init() {
        Self.configureApplicationIcon()
        if startupMode == .bootstrapCheck {
            Task { @MainActor in
                await Self.runBootstrapCheckAndTerminate()
            }
        }
    }

    var body: some Scene {
        WindowGroup("BETR Room Control") {
            Group {
                if startupMode == .standard {
                RestoredRoomControlShellView(store: store)
                    .frame(minWidth: 1380, minHeight: 860)
                } else {
                    Text("Running bundled BETRCoreAgent bootstrap check...")
                    .frame(width: 360, height: 60)
                    .padding()
                }
            }
        }
        .defaultSize(
            width: startupMode == .standard ? 1440 : 360,
            height: startupMode == .standard ? 900 : 120
        )
    }

    @MainActor
    private static func runBootstrapCheckAndTerminate() async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            let bootstrapper = RoomControlCoreAgentBootstrapper()
            let status = try await bootstrapper.ensureStarted(
                skipPrivilegedNetworkHelperInstall: true
            )
            let client = BETRCoreAgentClient()
            let workspaceSnapshot = try await client.waitForAgentAvailability()
            try await client.startObservingEvents { _ in }
            await client.stopObservingEvents()
            let payload = RoomControlBootstrapCheckPayload(
                mode: status.mode.rawValue,
                executablePath: status.executablePath,
                plistPath: status.plistPath,
                loaded: status.loaded,
                note: status.note,
                outputCount: workspaceSnapshot.outputs.count,
                sourceCount: workspaceSnapshot.sources.count,
                statusMessage: workspaceSnapshot.discoverySummary,
                observedOutputID: nil,
                eventObservationReady: true
            )
            let data = try encoder.encode(payload)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            NSApplication.shared.terminate(nil)
            exit(EXIT_SUCCESS)
        } catch {
            let payload = RoomControlBootstrapCheckFailure(
                errorDescription: error.localizedDescription
            )
            if let data = try? encoder.encode(payload) {
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data("\n".utf8))
            } else {
                FileHandle.standardError.write(Data("bootstrap-check failed\n".utf8))
            }
            NSApplication.shared.terminate(nil)
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func configureApplicationIcon() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        } else if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
                  let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

private struct RoomControlBootstrapCheckPayload: Encodable {
    let mode: String
    let executablePath: String
    let plistPath: String
    let loaded: Bool
    let note: String
    let outputCount: Int
    let sourceCount: Int
    let statusMessage: String?
    let observedOutputID: String?
    let eventObservationReady: Bool
}

private struct RoomControlBootstrapCheckFailure: Encodable {
    let errorDescription: String
}
