@testable import FeatureUI
import BETRCoreXPC
import CoreNDIHost
import HostWizardDomain
import RoomControlUIContracts
import RoutingDomain
import XCTest

@MainActor
final class RoomControlWorkspaceStoreTests: XCTestCase {
    func testRefreshHostInterfaceInventoryLoadsCoreOwnedSnapshot() async {
        let rootDirectory = NSTemporaryDirectory() + UUID().uuidString
        let workspace = makeWorkspaceSnapshot(
            inventory: makeInventorySnapshot(
                [
                    makeRecord(id: "en7", hardwarePortLabel: "USB Ethernet", ipv4CIDR: "192.168.55.150/24"),
                    makeRecord(id: "en0", hardwarePortLabel: "Wi-Fi", ipv4CIDR: "10.10.10.12/24"),
                ]
            )
        )
        let client = BETRCoreAgentClient(
            commandTransport: { command in
                switch command {
                case .refreshHostInterfaceInventory:
                    return BETRCoreCommandResponseEnvelope.workspace(workspace)
                default:
                    return BETRCoreCommandResponseEnvelope.success
                }
            }
        )

        let store = RoomControlWorkspaceStore(
            rootDirectory: rootDirectory,
            coreAgentClient: client
        )

        store.hostDraft.showNetworkCIDR = "192.168.55.0/24"
        store.refreshHostInterfaceInventory()
        await waitForSelection("en7", in: store)

        XCTAssertEqual(store.hostInterfaceSummaries.map { $0.id }, ["en7", "en0"])
        XCTAssertEqual(store.hostDraft.selectedInterfaceID, "en7")
        store.shutdown()
    }

    func testChangingShowNetworkOnlyReranksCachedInventory() async {
        let rootDirectory = NSTemporaryDirectory() + UUID().uuidString
        let refreshCount = LockedCounter()
        let workspace = makeWorkspaceSnapshot(
            inventory: makeInventorySnapshot(
                [
                    makeRecord(id: "en0", hardwarePortLabel: "Wi-Fi", ipv4CIDR: "192.168.55.150/24"),
                    makeRecord(id: "en7", hardwarePortLabel: "USB Ethernet", ipv4CIDR: "10.10.10.12/24"),
                ]
            )
        )
        let client = BETRCoreAgentClient(
            commandTransport: { command in
                switch command {
                case .refreshHostInterfaceInventory:
                    refreshCount.increment()
                    return BETRCoreCommandResponseEnvelope.workspace(workspace)
                default:
                    return BETRCoreCommandResponseEnvelope.success
                }
            }
        )
        let store = RoomControlWorkspaceStore(
            rootDirectory: rootDirectory,
            coreAgentClient: client
        )

        store.hostDraft.showNetworkCIDR = "192.168.55.0/24"
        store.refreshHostInterfaceInventory()
        await waitForSelection("en0", in: store)

        store.hostDraft.showNetworkCIDR = "10.10.10.0/24"
        store.refreshHostInterfaces()

        XCTAssertEqual(refreshCount.value, 1)
        XCTAssertEqual(store.hostDraft.selectedInterfaceID, "en0")
        XCTAssertEqual(store.hostInterfaceSummaries.first?.id, "en0")
        XCTAssertEqual(
            store.hostInterfaceSummaries.first(where: { $0.id == "en7" })?.matchesShowNetwork,
            true
        )
        XCTAssertEqual(
            store.hostInterfaceSummaries.first(where: { $0.id == "en7" })?.isRecommended,
            true
        )
        XCTAssertEqual(
            store.hostInterfaceSummaries.first(where: { $0.id == "en0" })?.matchesShowNetwork,
            false
        )
        XCTAssertEqual(
            store.hostInterfaceSummaries.first(where: { $0.id == "en0" })?.isRecommended,
            false
        )
        store.shutdown()
    }

    func testApplyHostSettingsImmediateRestartInvokesCallbackWithoutPrompt() async {
        let rootDirectory = NSTemporaryDirectory() + UUID().uuidString
        let workspace = makeWorkspaceSnapshot(inventory: BETRCoreHostInterfaceInventorySnapshot())
        let validation = Self.makeValidationSnapshot()
        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { workspace },
            validationSnapshotProvider: { validation },
            commandTransport: { command in
                guard case .applyNDIHostProfile = command else {
                    XCTFail("Expected applyNDIHostProfile command.")
                    return .success
                }
                return .success
            }
        )
        let userDefaultsSuite = "RoomControlWorkspaceStoreTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }

        let store = RoomControlWorkspaceStore(
            rootDirectory: rootDirectory,
            coreAgentClient: client,
            coreAgentBootstrapper: makeBootstrapper(userDefaults: userDefaults)
        )
        store.hostDraft.selectedInterfaceID = "en7"

        let restarted = expectation(description: "restart callback invoked")
        store.applyHostSettings(restartBehavior: RoomControlWorkspaceStore.RestartBehavior.immediate) {
            restarted.fulfill()
        }

        await fulfillment(of: [restarted], timeout: 1.0)

        XCTAssertNil(store.pendingRestartPromptContext)
        XCTAssertEqual(store.hostWizardProgressState.currentStep, NDIWizardPersistedStep.apply)
        XCTAssertTrue(userDefaults.bool(forKey: "BETRCoreAgentPendingHostProfileRecycle"))
        store.shutdown()
    }

    private func waitForSelection(_ interfaceID: String, in store: RoomControlWorkspaceStore) async {
        for _ in 0..<50 {
            if store.hostDraft.selectedInterfaceID == interfaceID {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTFail("Timed out waiting for selected interface \(interfaceID)")
    }

    private func makeRecord(id: String, hardwarePortLabel: String, ipv4CIDR: String) -> BETRCoreHostInterfaceRecord {
        BETRCoreHostInterfaceRecord(
            id: id,
            bsdName: id,
            hardwarePortLabel: hardwarePortLabel,
            serviceName: hardwarePortLabel,
            isUp: true,
            isRunning: true,
            supportsMulticast: true,
            ipv4Addresses: [String(ipv4CIDR.split(separator: "/").first ?? "")],
            ipv4CIDRs: [ipv4CIDR]
        )
    }

    private func makeInventorySnapshot(
        _ records: [BETRCoreHostInterfaceRecord]
    ) -> BETRCoreHostInterfaceInventorySnapshot {
        BETRCoreHostInterfaceInventorySnapshot(
            interfaces: records,
            status: BETRCoreHostInspectionStatus(lastRefreshAt: Date(), lastRefreshError: nil)
        )
    }

    private func makeWorkspaceSnapshot(
        inventory: BETRCoreHostInterfaceInventorySnapshot
    ) -> BETRCoreWorkspaceSnapshotResponse {
        BETRCoreWorkspaceSnapshotResponse(
            outputs: [],
            sources: [],
            discoverySummary: "mDNS",
            hostWizardSummary: "BETR-only",
            hostInterfaceInventory: inventory
        )
    }

    private static func makeValidationSnapshot() -> BETRCoreValidationSnapshotResponse {
        BETRCoreValidationSnapshotResponse(
            hostState: BETRNDIHostStateSnapshot(
                showLocationName: "BETR NDI",
                showNetworkCIDR: "192.168.55.0/24"
            )
        )
    }

    private func makeBootstrapper(userDefaults: UserDefaults) -> RoomControlCoreAgentBootstrapper {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = temporaryDirectory.appendingPathComponent("BETR Room Control.app", isDirectory: true)
        return RoomControlCoreAgentBootstrapper(
            environment: [:],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control"),
            mainBundleVersion: "0.9.8.81",
            userDefaults: userDefaults,
            networkHelperBootstrapper: TestStorePrivilegedNetworkHelperBootstrapper(),
            runCommand: { _, _, _ in "" }
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct TestStorePrivilegedNetworkHelperBootstrapper: RoomControlPrivilegedNetworkHelperBootstrapControlling {
    func ensureInstalledIfNeeded(
        skipInstallation: Bool
    ) throws -> RoomControlPrivilegedNetworkHelperBootstrapStatus {
        RoomControlPrivilegedNetworkHelperBootstrapStatus(
            installed: true,
            promptedForInstall: false,
            executablePath: "/Library/PrivilegedHelperTools/com.betr.network-helper",
            plistPath: "/Library/LaunchDaemons/com.betr.network-helper.plist",
            note: "noop"
        )
    }
}
