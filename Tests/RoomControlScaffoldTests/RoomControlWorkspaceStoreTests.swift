@testable import FeatureUI
import BETRCoreXPC
import CoreNDIDiscovery
import CoreNDIHost
import CoreNDIPlatform
import HostWizardDomain
import RoomControlUIContracts
@testable import RoutingDomain
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
        let bootstrapper = makeBootstrapper(userDefaults: userDefaults)

        let store = RoomControlWorkspaceStore(
            rootDirectory: rootDirectory,
            coreAgentClient: client,
            coreAgentBootstrapper: bootstrapper
        )
        store.hostDraft.selectedInterfaceID = "en7"

        let restarted = expectation(description: "restart callback invoked")
        store.applyHostSettings(restartBehavior: RoomControlWorkspaceStore.RestartBehavior.immediate) {
            restarted.fulfill()
        }

        await fulfillment(of: [restarted], timeout: 1.0)

        XCTAssertNil(store.pendingRestartPromptContext)
        XCTAssertEqual(store.hostWizardProgressState.currentStep, NDIWizardPersistedStep.apply)
        let pendingIntent = await bootstrapper.currentManagedAgentRestartIntent()
        XCTAssertEqual(pendingIntent?.reason, .hostApply)
        store.shutdown()
    }

    func testStartUsesWaitingDiscoveryCopyAfterConsumedRestartIntent() async {
        let rootDirectory = NSTemporaryDirectory() + UUID().uuidString
        let agentStartedAt = Date()
        let workspace = makeWorkspaceSnapshot(
            inventory: BETRCoreHostInterfaceInventorySnapshot(),
            agentInstanceID: "agent-new",
            agentStartedAt: agentStartedAt
        )
        let validation = Self.makeValidationSnapshot(
            agentInstanceID: "agent-new",
            agentStartedAt: agentStartedAt,
            remoteSourceVisibilityCount: 0,
            discoveryServers: [
                NDIWizardDiscoveryServerRow(
                    id: "192.168.55.11:5959",
                    configuredURL: "192.168.55.11:5959",
                    normalizedEndpoint: "192.168.55.11:5959",
                    host: "192.168.55.11",
                    port: 5959,
                    validatedAddress: "192.168.55.11:5959",
                    listenerLifecycleState: "attached_waiting",
                    senderListenerAttached: true,
                    senderListenerConnected: false,
                    receiverListenerAttached: true,
                    receiverListenerConnected: false
                )
            ]
        )
        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { workspace },
            validationSnapshotProvider: { validation },
            eventObservationProvider: { _ in }
        )
        let userDefaultsSuite = "RoomControlWorkspaceStoreWarmupTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        defer { userDefaults.removePersistentDomain(forName: userDefaultsSuite) }
        let bootstrapper = makeBootstrapper(userDefaults: userDefaults)
        await bootstrapper.markManagedAgentRestartRequired(
            reason: .hostApply,
            expectedConfigFingerprint: "fingerprint-1"
        )

        let store = RoomControlWorkspaceStore(
            rootDirectory: rootDirectory,
            coreAgentClient: client,
            coreAgentBootstrapper: bootstrapper
        )

        store.start()
        await waitForBootstrap(in: store)

        XCTAssertEqual(store.hostValidation.discoveryDetailState, .waiting)
        XCTAssertEqual(store.effectiveDiscoverySummaryMessage, store.hostValidation.discoverySummary)
        XCTAssertEqual(store.effectiveDiscoveryNextAction, store.hostValidation.discoveryNextAction)
        XCTAssertFalse(store.effectiveDiscoverySummaryMessage.contains("warming up"))
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

    private func waitForBootstrap(in store: RoomControlWorkspaceStore) async {
        for _ in 0..<100 {
            if store.isBootstrapped {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTFail("Timed out waiting for bootstrap state.")
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
        inventory: BETRCoreHostInterfaceInventorySnapshot,
        agentInstanceID: String = "",
        agentStartedAt: Date = .distantPast
    ) -> BETRCoreWorkspaceSnapshotResponse {
        BETRCoreWorkspaceSnapshotResponse(
            agentInstanceID: agentInstanceID,
            agentStartedAt: agentStartedAt,
            outputs: [],
            sources: [],
            discoverySummary: "mDNS",
            hostWizardSummary: "BETR-only",
            hostInterfaceInventory: inventory
        )
    }

    private static func makeValidationSnapshot(
        agentInstanceID: String = "",
        agentStartedAt: Date = .distantPast,
        remoteSourceVisibilityCount: Int = 0,
        discoveryServers: [NDIWizardDiscoveryServerRow] = []
    ) -> BETRCoreValidationSnapshotResponse {
        let configuredDiscoveryServerURLs = discoveryServers.map(\.configuredURL)
        let runtimeDiscoveryServers = discoveryServers.map { row in
            NDIDiscoveryServerStatus(
                configuredURL: row.configuredURL,
                host: row.host,
                port: row.port,
                normalizedEndpoint: row.normalizedEndpoint,
                validatedAddress: row.validatedAddress,
                listenerLifecycleState: NDIListenerLifecycleState(rawValue: row.listenerLifecycleState) ?? .detached,
                lastStateChangeAt: row.lastStateChangeAt,
                degradedReason: row.degradedReason.flatMap(NDIListenerLifecycleDegradedReason.init(rawValue:)),
                senderListenerAttached: row.senderListenerAttached,
                senderListenerConnected: row.senderListenerConnected,
                senderListenerServerURL: nil,
                receiverListenerAttached: row.receiverListenerAttached,
                receiverListenerConnected: row.receiverListenerConnected,
                receiverListenerServerURL: nil,
                senderAttachDiagnostics: NDIListenerAttachDiagnostics(
                    createFunctionAvailable: row.senderCreateFunctionAvailable,
                    candidateAddresses: row.senderCandidateAddresses,
                    attachAttemptCount: row.senderAttachAttemptCount,
                    lastAttemptedAddress: row.senderLastAttemptedAddress
                ),
                receiverAttachDiagnostics: NDIListenerAttachDiagnostics(
                    createFunctionAvailable: row.receiverCreateFunctionAvailable,
                    candidateAddresses: row.receiverCandidateAddresses,
                    attachAttemptCount: row.receiverAttachAttemptCount,
                    lastAttemptedAddress: row.receiverLastAttemptedAddress
                )
            )
        }
        let runtimeStatus = runtimeDiscoveryServers.isEmpty
            ? nil
            : NDIRuntimeStatus(
                networkProfile: NDINetworkProfile(
                    discoveryMode: .discoveryServerOnly,
                    discoveryServerURLs: configuredDiscoveryServerURLs,
                    mdnsEnabled: false
                ),
                discoveryServers: runtimeDiscoveryServers
            )
        let directorySnapshot: NDIDirectoryRuntimeSnapshot? = {
            guard runtimeDiscoveryServers.isEmpty == false || remoteSourceVisibilityCount > 0 else {
                return nil
            }
            let listenerAttached = runtimeDiscoveryServers.contains { $0.senderListenerAttached || $0.receiverListenerAttached }
            let listenerConnected = runtimeDiscoveryServers.contains { $0.senderListenerConnected || $0.receiverListenerConnected }
            return NDIDirectoryRuntimeSnapshot(
                presence: NDISourcePresenceSnapshot(
                    descriptors: [],
                    discoveryServers: runtimeDiscoveryServers,
                    activeDiscoveryServerURL: runtimeDiscoveryServers.first?.configuredURL,
                    listenerAttached: listenerAttached,
                    listenerConnected: listenerConnected
                ),
                catalog: NDISourceCatalogSnapshot(
                    sources: [],
                    networkProfile: runtimeStatus?.networkProfile ?? NDINetworkProfile(),
                    runtimeStatus: runtimeStatus ?? NDIRuntimeStatus()
                ),
                sources: [],
                discovery: NDIDiscoverySnapshot(
                    activeDiscoveryServerURL: runtimeDiscoveryServers.first?.configuredURL,
                    finderSourceCount: remoteSourceVisibilityCount,
                    localFinderSourceCount: 0,
                    remoteFinderSourceCount: remoteSourceVisibilityCount,
                    localSourceCount: 0,
                    remoteSourceCount: remoteSourceVisibilityCount,
                    senderListenerAttached: runtimeDiscoveryServers.contains(where: { $0.senderListenerAttached }),
                    senderListenerConnected: runtimeDiscoveryServers.contains(where: { $0.senderListenerConnected }),
                    receiverListenerAttached: runtimeDiscoveryServers.contains(where: { $0.receiverListenerAttached }),
                    receiverListenerConnected: runtimeDiscoveryServers.contains(where: { $0.receiverListenerConnected })
                ),
                activationTable: NDIActivationTableSnapshot(entries: [])
            )
        }()

        return BETRCoreValidationSnapshotResponse(
            agentInstanceID: agentInstanceID,
            agentStartedAt: agentStartedAt,
            hostState: BETRNDIHostStateSnapshot(
                showLocationName: "BETR NDI",
                showNetworkCIDR: "192.168.55.0/24",
                discoveryServers: configuredDiscoveryServerURLs
            ),
            runtimeStatus: runtimeStatus,
            directorySnapshot: directorySnapshot
        )
    }

    private func makeBootstrapper(
        userDefaults: UserDefaults,
        runCommand: (@Sendable (URL, [String], URL?) throws -> String)? = nil
    ) -> RoomControlCoreAgentBootstrapper {
        let fileManager = FileManager.default
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationsURL = temporaryDirectory.appendingPathComponent("Applications", isDirectory: true)
        let appBundleURL = applicationsURL.appendingPathComponent("BETR Room Control.app", isDirectory: true)
        let helperURL = appBundleURL.appendingPathComponent("Contents/Helpers/BETRCoreAgent", isDirectory: false)
        let mainExecutableURL = appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control", isDirectory: false)
        let plistURL = appBundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.betr.core-agent.plist", isDirectory: false)

        try? fileManager.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: mainExecutableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: helperURL.path, contents: Data())
        fileManager.createFile(atPath: mainExecutableURL.path, contents: Data())
        fileManager.createFile(atPath: plistURL.path, contents: Data("<plist/>".utf8))
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainExecutableURL.path)

        return RoomControlCoreAgentBootstrapper(
            environment: [:],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: mainExecutableURL,
            mainBundleVersion: "0.9.8.81",
            userDefaults: userDefaults,
            networkHelperBootstrapper: TestStorePrivilegedNetworkHelperBootstrapper(),
            runCommand: runCommand ?? { _, _, _ in "" }
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
