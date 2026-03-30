import BETRCoreXPC
import CoreNDIDiscovery
import CoreNDIHost
import CoreNDIOutput
import CoreNDIPlatform
import HostWizardDomain
import RoomControlUIContracts
import RoutingDomain
import XCTest

private struct TestPrivilegedNetworkHelperBootstrapper: RoomControlPrivilegedNetworkHelperBootstrapControlling {
    let status: RoomControlPrivilegedNetworkHelperBootstrapStatus
    let onEnsure: (@Sendable (Bool) -> Void)?

    func ensureInstalledIfNeeded(
        skipInstallation: Bool
    ) throws -> RoomControlPrivilegedNetworkHelperBootstrapStatus {
        onEnsure?(skipInstallation)
        return status
    }
}

final class BETRCoreAgentClientTests: XCTestCase {
    func testBootstrapShellStateMapsWorkspaceSnapshot() async {
        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { Self.makeWorkspaceSnapshot() },
            validationSnapshotProvider: { Self.makeValidationSnapshot() }
        )

        let shellState = await client.bootstrapShellState(rootDirectory: "/tmp/betr-room-control-v4-tests")

        XCTAssertEqual(shellState.title, "BETR Room Control")
        XCTAssertEqual(shellState.workspace.cards.count, 2)
        XCTAssertEqual(shellState.workspace.cards.first?.title, "Program Output")
        XCTAssertEqual(shellState.workspace.sources.map(\.id).sorted(), ["ndi-presenter", "ndi-slideshow"])
        XCTAssertEqual(shellState.workspace.cards.first?.programSlotID, "S2")
        XCTAssertEqual(shellState.workspace.cards.first?.previewSlotID, "S1")
        XCTAssertTrue(shellState.workspace.cards.first?.isSoloedLocally == true)
        XCTAssertEqual(shellState.workspace.cards.first?.confidencePreview?.sourceID, "ndi-presenter")
        XCTAssertEqual(shellState.workspace.cards.first?.confidencePreview?.mode, .armedPreview)
        XCTAssertEqual(shellState.workspace.cards.first?.slots.map(\.id), ["S1", "S2", "S3", "S4", "S5", "S6"])
        XCTAssertTrue(shellState.workspace.sources.first(where: { $0.id == "ndi-slideshow" })?.isWarm == true)
        XCTAssertEqual(shellState.workspace.agentInstanceID, "agent-workspace")
        XCTAssertEqual(shellState.capacity?.configuredOutputs, 2)
        XCTAssertEqual(shellState.capacity?.discoveredSources, 2)
    }

    func testBootstrapShellStateFallsBackWhenWorkspaceSnapshotTimesOut() async {
        let client = BETRCoreAgentClient(
            operationTimeoutNanoseconds: 50_000_000,
            workspaceSnapshotProvider: {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return Self.makeWorkspaceSnapshot()
            },
            validationSnapshotProvider: { Self.makeValidationSnapshot() }
        )

        let shellState = await client.bootstrapShellState(rootDirectory: "/tmp/betr-room-control-v4-tests")

        XCTAssertEqual(shellState.workspace.cards.count, 1)
        XCTAssertEqual(shellState.workspace.cards.first?.title, "Program Output")
        XCTAssertEqual(shellState.workspace.cards.first?.programSlotID, "S2")
        XCTAssertEqual(shellState.workspace.cards.first?.slots.map(\.id), ["S1", "S2", "S3", "S4", "S5", "S6"])
        XCTAssertEqual(shellState.workspace.sources.count, 2)
    }

    func testBootstrapShellStateKeepsPreviewInArmingUntilPreviewSourceIsWarm() async {
        let workspace = BETRCoreWorkspaceSnapshotResponse(
            outputs: [
                BETRCoreWorkspaceOutputSnapshot(
                    id: "OUT-1",
                    title: "Program Output",
                    rasterLabel: "1920×1080 / 29.97",
                    slots: [
                        BETRCoreOutputSlotSnapshot(outputID: "OUT-1", slotID: "S1", label: "S1", sourceID: "ndi-presenter"),
                        BETRCoreOutputSlotSnapshot(outputID: "OUT-1", slotID: "S2", label: "S2", sourceID: nil),
                        BETRCoreOutputSlotSnapshot(outputID: "OUT-1", slotID: "S3", label: "S3", sourceID: nil),
                        BETRCoreOutputSlotSnapshot(outputID: "OUT-1", slotID: "S4", label: "S4", sourceID: nil),
                        BETRCoreOutputSlotSnapshot(outputID: "OUT-1", slotID: "S5", label: "S5", sourceID: nil),
                        BETRCoreOutputSlotSnapshot(outputID: "OUT-1", slotID: "S6", label: "S6", sourceID: nil),
                    ],
                    programSlotID: nil,
                    previewSlotID: "S1",
                    isAudioMuted: false,
                    senderReady: true,
                    fallbackActive: false,
                    liveTile: BETRCoreWorkspaceLiveTileSnapshot(
                        outputID: "OUT-1",
                        sourceID: nil,
                        fallbackActive: false,
                        audioMuted: false,
                        audioPresenceState: .silent,
                        leftLevel: 0,
                        rightLevel: 0
                    )
                )
            ],
            sources: [
                BETRCoreWorkspaceSourceSnapshot(
                    id: "ndi-presenter",
                    name: "Presenter View",
                    details: "192.168.55.21",
                    provenance: "finder",
                    routedOutputIDs: ["OUT-1"],
                    sortPriority: 0,
                    readiness: BETRCoreSourceWarmStateSnapshot(
                        id: "ndi-presenter",
                        connected: true,
                        warming: true,
                        warm: false,
                        receiverConnected: true,
                        hasVideo: true,
                        audioPrimed: false,
                        gpuPrimed: false
                    )
                )
            ],
            discoverySummary: "1 sources • ndi://192.168.55.11",
            hostWizardSummary: "en7"
        )

        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { workspace },
            validationSnapshotProvider: { Self.makeValidationSnapshot() }
        )

        let shellState = await client.bootstrapShellState(rootDirectory: "/tmp/betr-room-control-v4-tests")
        guard let card = shellState.workspace.cards.first else {
            return XCTFail("Expected one output card.")
        }

        XCTAssertEqual(card.previewSlotID, "S1")
        XCTAssertEqual(card.confidencePreview?.sourceID, "ndi-presenter")
        XCTAssertEqual(card.confidencePreview?.mode, .armedPreview)
        XCTAssertFalse(card.confidencePreview?.isReady == true)
        XCTAssertFalse(card.statusPills.contains(.live))
    }

    func testBootstrapShellStateUsesPendingProgramConfidencePreviewBeforeCutover() async {
        let workspace = Self.makeWorkspaceSnapshot(
            outputs: [
                Self.makeWorkspaceOutput(
                    id: "OUT-1",
                    slotAssignments: ["S1": "ndi-presenter", "S2": "ndi-slideshow"],
                    programSlotID: "S1",
                    previewSlotID: nil,
                    activeSourceID: "ndi-slideshow"
                )
            ]
        )

        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { workspace },
            validationSnapshotProvider: { Self.makeValidationSnapshot() }
        )

        let shellState = await client.bootstrapShellState(rootDirectory: "/tmp/betr-room-control-v4-tests")
        guard let card = shellState.workspace.cards.first else {
            return XCTFail("Expected one output card.")
        }

        XCTAssertEqual(card.programSourceID, "ndi-presenter")
        XCTAssertEqual(card.liveTile.sourceID, "ndi-slideshow")
        XCTAssertEqual(card.confidencePreview?.sourceID, "ndi-presenter")
        XCTAssertEqual(card.confidencePreview?.mode, .pendingProgram)
        XCTAssertTrue(card.confidencePreview?.isReady == true)
        XCTAssertTrue(card.statusPills.contains(.arming))
        XCTAssertFalse(card.statusPills.contains(.live))
    }

    func testCurrentValidationSnapshotMapsAgentTruth() async {
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: { Self.makeValidationSnapshot() }
        )

        let validation = await client.currentValidationSnapshot()

        XCTAssertEqual(validation.committedInterfaceBSDName, "en7")
        XCTAssertEqual(validation.activeDiscoveryServerURL, "ndi://192.168.55.11")
        XCTAssertEqual(validation.finderSourceVisibilityCount, 2)
        XCTAssertEqual(validation.listenerSenderVisibilityCount, 2)
        XCTAssertEqual(validation.localSourceVisibilityCount, 0)
        XCTAssertEqual(validation.remoteSourceVisibilityCount, 2)
        XCTAssertEqual(validation.agentInstanceID, "agent-validation")
        XCTAssertEqual(validation.discoveryDetailState, .visible)
        XCTAssertEqual(validation.discoveryState, .passed)
        XCTAssertTrue(validation.multicastRoutePinnedToCommittedInterface)
        XCTAssertEqual(validation.discoveryServers.count, 1)
        XCTAssertEqual(validation.sdkBootstrapState, "initialized")
        XCTAssertTrue(validation.discoveryServers.first?.senderListenerCreateSucceeded == true)
        XCTAssertTrue(validation.discoveryServers.first?.receiverListenerCreateSucceeded == true)
        XCTAssertEqual(validation.discoveryServers.first?.senderListenerServerURL, "ndi://192.168.55.11")
        XCTAssertEqual(validation.discoveryServers.first?.receiverListenerServerURL, "ndi://192.168.55.11")
    }

    func testCurrentDiscoveryDebugSnapshotMapsEngineeringDiagnostics() async {
        let client = BETRCoreAgentClient(
            discoveryDebugSnapshotProvider: {
                BETRCoreDiscoveryDebugSnapshotResponse(
                    generatedAt: Date(timeIntervalSince1970: 1_700_000_400),
                    sdkBootstrapState: .initialized,
                    configDirectory: "/Users/test/Library/Application Support/BETRCoreAgentV3",
                    configPath: "/Users/test/Library/Application Support/BETRCoreAgentV3/ndi-config.v1.json",
                    sdkLoadedPath: "/Library/NDI/libndi.dylib",
                    sdkVersion: "6.1.1",
                    discoveryServers: [
                        NDIDiscoveryServerDebugStatus(
                            id: "192.168.55.11:5959",
                            normalizedEndpoint: "192.168.55.11:5959",
                            validatedAddress: "192.168.55.11:5959",
                            listenerDebugState: .attachedWaiting,
                            senderCreateFunctionAvailable: true,
                            receiverCreateFunctionAvailable: true,
                            senderCandidateAddresses: ["192.168.55.11:5959"],
                            receiverCandidateAddresses: ["192.168.55.11:5959"],
                            senderAttachAttemptCount: 1,
                            receiverAttachAttemptCount: 1,
                            senderLastAttemptedAddress: "192.168.55.11:5959",
                            receiverLastAttemptedAddress: "192.168.55.11:5959"
                        )
                    ]
                )
            }
        )

        let snapshot = await client.currentDiscoveryDebugSnapshot()

        XCTAssertEqual(snapshot?.sdkBootstrapState, "initialized")
        XCTAssertEqual(snapshot?.configPath, "/Users/test/Library/Application Support/BETRCoreAgentV3/ndi-config.v1.json")
        XCTAssertEqual(snapshot?.discoveryServers.first?.listenerDebugState, "attached_waiting")
        XCTAssertEqual(snapshot?.discoveryServers.first?.senderCandidateAddresses, ["192.168.55.11:5959"])
    }

    func testCurrentValidationSnapshotKeepsConfiguredDiscoveryServerVisibleWhenListenerStatusIsMissing() async {
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: {
                Self.makeValidationSnapshot(
                    discoveryServerURLs: ["192.168.55.11"],
                    runtimeDiscoveryServers: [],
                    activeDiscoveryServerURL: nil,
                    finderSourceCount: 0,
                    listenerSourceCount: 0,
                    localFinderSourceCount: 0,
                    remoteFinderSourceCount: 0,
                    localSourceCount: 0,
                    remoteSourceCount: 0
                )
            }
        )

        let validation = await client.currentValidationSnapshot()

        XCTAssertNil(validation.activeDiscoveryServerURL)
        XCTAssertEqual(validation.discoveryDetailState, .waiting)
        XCTAssertEqual(validation.discoveryState, .warning)
        XCTAssertEqual(
            validation.discoverySummary,
            "Discovery listeners exist, but the SDK has not reported a connected Discovery Server yet."
        )
    }

    func testCurrentValidationSnapshotMapsSyncAndFanoutTelemetry() async {
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: {
                Self.makeValidationSnapshot(
                    receiverTelemetry: [
                        BETRCoreReceiverTelemetrySnapshot(
                            id: "ndi-presenter",
                            sourceName: "Presenter View",
                            connectionCount: 1,
                            videoQueueDepth: 1,
                            audioQueueDepth: 2,
                            droppedVideoFrames: 3,
                            droppedAudioFrames: 1,
                            latestVideoTimestamp100ns: 1_000,
                            latestAudioTimestamp100ns: 1_050,
                            inputAVSkewMs: 5.0,
                            videoRecent: true,
                            audioRecent: false,
                            audioRequired: true,
                            queueSane: false,
                            dropDeltaSane: false,
                            syncReady: false,
                            warmAttemptDroppedVideoFrames: 2,
                            warmAttemptDroppedAudioFrames: 1,
                            fanoutCount: 2,
                            gateReasons: [.audio, .queue, .drop]
                        )
                    ],
                    outputTelemetry: [
                        BETRCoreOutputTelemetrySnapshot(
                            id: "OUT-1",
                            senderConnectionCount: 1,
                            senderReady: true,
                            activeSourceID: "ndi-slideshow",
                            previewSourceID: "ndi-presenter",
                            activeSourceFanoutCount: 2,
                            previewSourceFanoutCount: 2,
                            activeSourceSyncReady: true,
                            previewSourceSyncReady: false,
                            activeSourceInputAVSkewMs: 0.5,
                            previewSourceInputAVSkewMs: 5.0,
                            activeSourceGateReasons: [],
                            previewSourceGateReasons: [.audio, .queue]
                        )
                    ]
                )
            }
        )

        let validation = await client.currentValidationSnapshot()
        guard let receiver = validation.receiverTelemetry(for: "ndi-presenter") else {
            return XCTFail("Expected receiver telemetry for ndi-presenter.")
        }
        guard let output = validation.outputTelemetry(for: "OUT-1") else {
            return XCTFail("Expected output telemetry for OUT-1.")
        }

        XCTAssertEqual(receiver.inputAVSkewMs, 5.0)
        XCTAssertFalse(receiver.audioRecent)
        XCTAssertFalse(receiver.queueSane)
        XCTAssertFalse(receiver.dropDeltaSane)
        XCTAssertFalse(receiver.syncReady)
        XCTAssertEqual(receiver.warmAttemptDroppedVideoFrames, 2)
        XCTAssertEqual(receiver.warmAttemptDroppedAudioFrames, 1)
        XCTAssertEqual(receiver.fanoutCount, 2)
        XCTAssertEqual(receiver.gateReasons, ["audio", "queue", "drop"])

        XCTAssertEqual(output.activeSourceFanoutCount, 2)
        XCTAssertEqual(output.previewSourceFanoutCount, 2)
        XCTAssertTrue(output.activeSourceSyncReady)
        XCTAssertFalse(output.previewSourceSyncReady)
        XCTAssertEqual(output.previewSourceInputAVSkewMs, 5.0)
        XCTAssertEqual(output.previewSourceGateReasons, ["audio", "queue"])
    }

    func testBootstrapShellStateDiscoverySummaryUsesConfiguredDiscoveryServerWhenNotYetActive() async {
        let client = BETRCoreAgentClient(
            operationTimeoutNanoseconds: 50_000_000,
            workspaceSnapshotProvider: {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return Self.makeWorkspaceSnapshot()
            },
            validationSnapshotProvider: {
                Self.makeValidationSnapshot(
                    discoveryServerURLs: ["192.168.55.11"],
                    runtimeDiscoveryServers: [],
                    activeDiscoveryServerURL: nil,
                    finderSourceCount: 0,
                    listenerSourceCount: 0,
                    localFinderSourceCount: 0,
                    remoteFinderSourceCount: 0,
                    localSourceCount: 0,
                    remoteSourceCount: 0
                )
            }
        )

        let shellState = await client.bootstrapShellState(rootDirectory: "/tmp/betr-room-control-v4-tests")

        XCTAssertEqual(shellState.workspace.discoverySummary, "0 finder • 0 listener • none")
    }

    func testWaitForAgentAvailabilityTimesOutInsteadOfHanging() async {
        let client = BETRCoreAgentClient(
            operationTimeoutNanoseconds: 50_000_000,
            workspaceSnapshotProvider: {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return Self.makeWorkspaceSnapshot()
            }
        )

        do {
            _ = try await client.waitForAgentAvailability(
                maxAttempts: 1,
                retryIntervalNanoseconds: 1_000_000,
                requestTimeoutNanoseconds: 50_000_000
            )
            XCTFail("Expected BETRCoreAgent timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    func testWaitForAgentAvailabilityRetriesAfterInitialTimeout() async throws {
        let responses = LockedBox(0)
        let client = BETRCoreAgentClient(
            operationTimeoutNanoseconds: 50_000_000,
            workspaceSnapshotProvider: {
                let attempt = responses.withLock { value in
                    let next = value + 1
                    value = next
                    return next
                }
                if attempt == 1 {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
                return Self.makeWorkspaceSnapshot()
            }
        )

        let snapshot = try await client.waitForAgentAvailability(
            maxAttempts: 2,
            retryIntervalNanoseconds: 1_000_000,
            requestTimeoutNanoseconds: 50_000_000
        )

        XCTAssertEqual(snapshot.outputs.count, 2)
        XCTAssertEqual(responses.value, 2)
    }

    func testApplyHostDraftPreservesRawDiscoveryServerInput() async throws {
        let transport = RecordingTransport()
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: { Self.makeValidationSnapshot() },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        var draft = HostWizardDraft()
        draft.showLocationName = "Ballroom A"
        draft.ownershipMode = .globalTakeover
        draft.selectedInterfaceID = "en7"
        draft.discoveryServersText = "192.168.55.11\nndi://192.168.55.12"
        draft.mdnsEnabled = false
        draft.groupsText = "stage-left\nstage-right"
        draft.extraIPsText = "192.168.55.21, 192.168.55.22"
        draft.receiveSubnetsText = "10.55.0.0/16"
        draft.sourceFilter = "Presenter"
        draft.nodeLabel = "Ballroom Router"
        draft.senderPrefix = "BALLROOM"
        draft.outputPrefix = "PGM"
        let interfaceSummary = HostInterfaceSummary(
            id: "en7",
            serviceName: "USB 10/100/1000 LAN",
            bsdName: "en7",
            hardwarePortLabel: "USB 10/100/1000 LAN",
            displayName: "USB 10/100/1000 LAN",
            linkKind: .ethernet,
            isUp: true,
            isRunning: true,
            supportsMulticast: true,
            ipv4Addresses: ["192.168.55.20"],
            ipv4CIDRs: ["192.168.55.20/24"],
            primaryIPv4Address: "192.168.55.20",
            primaryIPv4CIDR: "192.168.55.20/24",
            matchesShowNetwork: true,
            isRecommended: true
        )

        try await client.applyHostDraft(draft, interfaceSummary: interfaceSummary)

        let commands = await transport.recordedCommands()
        guard case let .applyNDIHostProfile(request)? = commands.last else {
            return XCTFail("Expected applyNDIHostProfile command.")
        }

        XCTAssertEqual(request.profile.productIdentifier, BETRCoreAgentMachServiceName)
        XCTAssertEqual(request.profile.showLocationName, "Ballroom A")
        XCTAssertEqual(request.profile.ownershipMode, .globalTakeover)
        XCTAssertEqual(request.profile.selectedInterfaceBSDName, "en7")
        XCTAssertEqual(request.profile.selectedInterfaceCIDR, "192.168.55.20/24")
        XCTAssertEqual(request.profile.selectedInterfaceHardwarePortLabel, "USB 10/100/1000 LAN")
        XCTAssertEqual(request.profile.selectedServiceName, "USB 10/100/1000 LAN")
        XCTAssertEqual(request.profile.discoveryMode, .discoveryServerOnly)
        XCTAssertEqual(request.profile.discoveryServers, ["192.168.55.11", "ndi://192.168.55.12"])
        XCTAssertEqual(request.profile.groups, ["stage-left", "stage-right"])
        XCTAssertEqual(request.profile.extraIPs, ["192.168.55.21", "192.168.55.22"])
        XCTAssertEqual(request.profile.receiveSubnets, ["10.55.0.0/16"])
        XCTAssertEqual(request.profile.sourceFilter, "Presenter")
        XCTAssertEqual(request.profile.nodeLabel, "Ballroom Router")
        XCTAssertEqual(request.profile.senderPrefix, "BALLROOM")
        XCTAssertEqual(request.profile.outputPrefix, "PGM")
    }

    func testApplyHostDraftUsesExtendedTimeoutForSlowHostControlCommands() async throws {
        let client = BETRCoreAgentClient(
            operationTimeoutNanoseconds: 50_000_000,
            commandTransport: { command in
                try await Task.sleep(nanoseconds: 100_000_000)
                guard case .applyNDIHostProfile = command else {
                    XCTFail("Expected applyNDIHostProfile command.")
                    return .success
                }
                return .success
            }
        )

        let draft = HostWizardDraft(selectedInterfaceID: "en7")
        let interfaceSummary = HostInterfaceSummary(
            id: "en7",
            serviceName: "USB Ethernet",
            bsdName: "en7",
            hardwarePortLabel: "USB Ethernet",
            displayName: "USB Ethernet",
            linkKind: .ethernet,
            isUp: true,
            isRunning: true,
            supportsMulticast: true,
            ipv4Addresses: ["192.168.55.20"],
            ipv4CIDRs: ["192.168.55.20/24"],
            primaryIPv4Address: "192.168.55.20",
            primaryIPv4CIDR: "192.168.55.20/24",
            matchesShowNetwork: true,
            isRecommended: true
        )

        try await client.applyHostDraft(draft, interfaceSummary: interfaceSummary)
    }

    func testRefreshHostInterfaceInventoryUsesExtendedTimeoutForSlowHostControlCommands() async throws {
        let expectedWorkspace = Self.makeWorkspaceSnapshot()
        let client = BETRCoreAgentClient(
            operationTimeoutNanoseconds: 50_000_000,
            commandTransport: { command in
                try await Task.sleep(nanoseconds: 100_000_000)
                guard case .refreshHostInterfaceInventory = command else {
                    XCTFail("Expected refreshHostInterfaceInventory command.")
                    return .success
                }
                return .workspace(expectedWorkspace)
            }
        )

        let shellState = try await client.refreshHostInterfaceInventory(
            rootDirectory: "/tmp/betr-room-control-v4-tests"
        )

        XCTAssertEqual(shellState.workspace.cards.count, expectedWorkspace.outputs.count)
        XCTAssertEqual(shellState.workspace.sources.count, expectedWorkspace.sources.count)
    }

    func testResetNDIHostEnvironmentUsesExtendedTimeoutForSlowHostControlCommands() async throws {
        let client = BETRCoreAgentClient(
            operationTimeoutNanoseconds: 50_000_000,
            commandTransport: { command in
                try await Task.sleep(nanoseconds: 100_000_000)
                guard case .resetNDIHostEnvironment = command else {
                    XCTFail("Expected resetNDIHostEnvironment command.")
                    return .success
                }
                return .success
            }
        )

        try await client.resetNDIHostEnvironment()
    }

    func testNonHostCommandsStillUseGenericTimeout() async {
        let client = BETRCoreAgentClient(
            operationTimeoutNanoseconds: 50_000_000,
            commandTransport: { _ in
                try await Task.sleep(nanoseconds: 100_000_000)
                return .success
            }
        )

        do {
            try await client.setOutputAudioMuted(outputID: "OUT-1", muted: true)
            XCTFail("Expected generic command timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    func testHostWizardDraftUsesSafeMulticastDefaults() {
        let draft = HostWizardDraft()

        XCTAssertEqual(draft.ownershipMode, .betrOnly)
        XCTAssertEqual(draft.multicastPrefix, "239.255.0.0")
        XCTAssertEqual(draft.multicastTTL, 1)
        XCTAssertEqual(draft.outputPrefix, "Output")
        XCTAssertFalse(draft.mdnsEnabled)
        XCTAssertEqual(draft.discoveryServersText, "192.168.55.11")
    }

    func testCurrentValidationSnapshotFlagsLocalOnlyVisibilitySeparately() async {
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: {
                Self.makeValidationSnapshot(
                    discoveryServerURLs: ["192.168.55.11"],
                    runtimeDiscoveryServers: [
                        NDIDiscoveryServerStatus(
                            configuredURL: "192.168.55.11",
                            host: "192.168.55.11",
                            port: 5959,
                            senderListenerCreateSucceeded: true,
                            receiverListenerCreateSucceeded: true,
                            senderListenerConnected: true,
                            senderListenerServerURL: "ndi://192.168.55.11",
                            receiverListenerConnected: true,
                            receiverListenerServerURL: "ndi://192.168.55.11"
                        )
                    ],
                    activeDiscoveryServerURL: "ndi://192.168.55.11",
                    finderSourceCount: 1,
                    listenerSourceCount: 0,
                    localFinderSourceCount: 1,
                    remoteFinderSourceCount: 0,
                    localSourceCount: 1,
                    remoteSourceCount: 0
                )
            }
        )

        let validation = await client.currentValidationSnapshot()

        XCTAssertEqual(validation.discoveryDetailState, .connected)
        XCTAssertEqual(validation.discoveryState, .warning)
        XCTAssertEqual(
            validation.discoverySummary,
            "Discovery listeners are connected to the Discovery Server, but no remote source catalog is visible yet."
        )
        XCTAssertEqual(
            validation.sourceCatalogSummary,
            "Only 1 local BETR source is visible. Finder sees 1; sender listener sees 0."
        )
    }

    func testCurrentValidationSnapshotTreatsRemoteFinderVisibilityAsPassedWhenListenerTelemetryIsDegraded() async {
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: {
                Self.makeValidationSnapshot(
                    discoveryServerURLs: ["192.168.55.11"],
                    runtimeDiscoveryServers: [
                        NDIDiscoveryServerStatus(
                            configuredURL: "192.168.55.11",
                            host: "192.168.55.11",
                            port: 5959,
                            senderListenerCreateSucceeded: true,
                            receiverListenerCreateSucceeded: true,
                            senderListenerConnected: false,
                            senderListenerServerURL: "ndi://192.168.55.11",
                            receiverListenerConnected: false,
                            receiverListenerServerURL: "ndi://192.168.55.11"
                        )
                    ],
                    activeDiscoveryServerURL: nil,
                    finderSourceCount: 8,
                    listenerSourceCount: 0,
                    localFinderSourceCount: 0,
                    remoteFinderSourceCount: 8,
                    localSourceCount: 0,
                    remoteSourceCount: 8
                )
            }
        )

        let validation = await client.currentValidationSnapshot()

        XCTAssertEqual(validation.discoveryDetailState, .visible)
        XCTAssertEqual(validation.discoveryState, .passed)
        XCTAssertEqual(
            validation.discoveryNextAction,
            "Discovery is live. Move to actual source receive and send verification next."
        )
        XCTAssertEqual(
            validation.discoverySummary,
            "Discovery is working and remote source visibility is present."
        )
    }

    func testCurrentValidationSnapshotDoesNotRecommendApplyAgainWhenDiscoveryOnlyIsDegraded() async {
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: {
                Self.makeValidationSnapshot(
                    discoveryServerURLs: ["192.168.55.11"],
                    runtimeDiscoveryServers: [
                        NDIDiscoveryServerStatus(
                            configuredURL: "192.168.55.11",
                            host: "192.168.55.11",
                            port: 5959,
                            normalizedEndpoint: "192.168.55.11:5959",
                            senderListenerCreateSucceeded: true,
                            receiverListenerCreateSucceeded: true,
                            senderListenerConnected: false,
                            senderListenerServerURL: nil,
                            receiverListenerConnected: false,
                            receiverListenerServerURL: nil
                        )
                    ],
                    activeDiscoveryServerURL: nil,
                    finderSourceCount: 0,
                    listenerSourceCount: 0,
                    localFinderSourceCount: 0,
                    remoteFinderSourceCount: 0,
                    localSourceCount: 0,
                    remoteSourceCount: 0
                )
            }
        )

        let validation = await client.currentValidationSnapshot()

        XCTAssertEqual(validation.discoveryDetailState, .waiting)
        XCTAssertEqual(
            validation.discoveryNextAction,
            "The BETR host profile is already in place. Leave Apply + Restart alone and watch the SDK listener state on the committed NIC."
        )
    }

    func testFetchSelectedPreviewAttachmentUsesInjectedProvider() async {
        let expected = OutputPreviewAttachment(
            outputID: "OUT-1",
            attachmentID: 44,
            width: 0,
            height: 0,
            lineStride: 0,
            pixelFormat: .bgra,
            slotCount: 0,
            surfaces: []
        )
        let client = BETRCoreAgentClient(
            selectedPreviewAttachmentProvider: { outputID, attachmentID in
                XCTAssertEqual(outputID, "OUT-1")
                XCTAssertEqual(attachmentID, 44)
                return expected
            }
        )

        let attachment = await client.fetchSelectedPreviewAttachment(outputID: "OUT-1", attachmentID: 44)

        XCTAssertEqual(attachment?.attachmentID, expected.attachmentID)
        XCTAssertEqual(attachment?.outputID, expected.outputID)
    }

    func testResetNDIHostEnvironmentSendsResetCommand() async throws {
        let transport = RecordingTransport()
        let client = BETRCoreAgentClient(
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.resetNDIHostEnvironment()

        let commands = await transport.recordedCommands()
        XCTAssertEqual(commands, [.resetNDIHostEnvironment(BETRCoreResetNDIHostEnvironmentRequest())])
    }

    func testTakeProgramUsesSlotNativeCommand() async throws {
        let transport = RecordingTransport()
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: { Self.makeValidationSnapshot() },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.takeProgram(outputID: "OUT-1", slotID: "S2")

        let commands = await transport.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .takeProgramSlot(
                    BETRCoreTakeProgramSlotRequest(
                        outputID: "OUT-1",
                        slotID: "S2"
                    )
                )
            ]
        )
    }

    func testAssignSourceConnectsAndWarmsSourceThroughAgent() async throws {
        let transport = RecordingTransport()
        let snapshots = WorkspaceSnapshotSequence([
            Self.makeWorkspaceSnapshot(
                outputs: [
                    Self.makeWorkspaceOutput(
                        id: "OUT-1",
                        slotAssignments: [:],
                        programSlotID: nil,
                        previewSlotID: nil,
                        activeSourceID: nil
                    ),
                ]
            ),
            Self.makeWorkspaceSnapshot(
                outputs: [
                    Self.makeWorkspaceOutput(
                        id: "OUT-1",
                        slotAssignments: ["S1": "ndi-slideshow"],
                        programSlotID: nil,
                        previewSlotID: nil,
                        activeSourceID: nil
                    ),
                ]
            ),
        ])
        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { await snapshots.next() },
            validationSnapshotProvider: { Self.makeValidationSnapshot(connectedSourceID: nil) },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.assignSource(sourceID: "ndi-slideshow", outputID: "OUT-1", slotID: "S1")

        let commands = await transport.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .assignOutputSlot(
                    BETRCoreAssignOutputSlotRequest(
                        outputID: "OUT-1",
                        slotID: "S1",
                        sourceID: "ndi-slideshow"
                    )
                ),
                .connectSource(
                    BETRCoreConnectSourceRequest(
                        descriptorID: "ndi-slideshow",
                        activationClass: .prewarm
                    )
                ),
                .warmSource("ndi-slideshow"),
            ]
        )
    }

    func testAssignSourceReplacesNonProgramConnectionBeforeWarmingNewSource() async throws {
        let transport = RecordingTransport()
        let snapshots = WorkspaceSnapshotSequence([
            Self.makeWorkspaceSnapshot(
                outputs: [
                    Self.makeWorkspaceOutput(
                        id: "OUT-1",
                        slotAssignments: ["S2": "ndi-presenter"],
                        programSlotID: nil,
                        previewSlotID: "S2",
                        activeSourceID: nil
                    ),
                ]
            ),
            Self.makeWorkspaceSnapshot(
                outputs: [
                    Self.makeWorkspaceOutput(
                        id: "OUT-1",
                        slotAssignments: ["S2": "ndi-slideshow"],
                        programSlotID: nil,
                        previewSlotID: nil,
                        activeSourceID: nil
                    ),
                ]
            ),
        ])
        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { await snapshots.next() },
            validationSnapshotProvider: { Self.makeValidationSnapshot() },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.assignSource(sourceID: "ndi-slideshow", outputID: "OUT-1", slotID: "S2")

        let commands = await transport.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .assignOutputSlot(
                    BETRCoreAssignOutputSlotRequest(
                        outputID: "OUT-1",
                        slotID: "S2",
                        sourceID: "ndi-slideshow"
                    )
                ),
                .connectSource(
                    BETRCoreConnectSourceRequest(
                        descriptorID: "ndi-slideshow",
                        activationClass: .prewarm
                    )
                ),
                .warmSource("ndi-slideshow"),
                .coolSource("ndi-presenter"),
                .disconnectSource(BETRCoreDisconnectSourceRequest(descriptorID: "ndi-presenter")),
            ]
        )
    }

    func testAssignSourceNoLongerBlocksWhenAnotherOutputAlreadyHasProgram() async throws {
        let transport = RecordingTransport()
        let snapshots = WorkspaceSnapshotSequence([
            Self.makeWorkspaceSnapshot(
                outputs: [
                    Self.makeWorkspaceOutput(
                        id: "OUT-1",
                        slotAssignments: ["S1": "ndi-presenter"],
                        programSlotID: "S1",
                        previewSlotID: nil,
                        activeSourceID: "ndi-presenter"
                    ),
                    Self.makeWorkspaceOutput(
                        id: "OUT-2",
                        title: "Program Output 2",
                        slotAssignments: ["S1": "ndi-slideshow"],
                        programSlotID: nil,
                        previewSlotID: nil,
                        activeSourceID: nil
                    ),
                ]
            ),
        ])
        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { await snapshots.next() },
            validationSnapshotProvider: { Self.makeValidationSnapshot() },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.assignSource(sourceID: "ndi-slideshow", outputID: "OUT-2", slotID: "S1")

        let commands = await transport.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .assignOutputSlot(
                    BETRCoreAssignOutputSlotRequest(
                        outputID: "OUT-2",
                        slotID: "S1",
                        sourceID: "ndi-slideshow"
                    )
                ),
                .connectSource(
                    BETRCoreConnectSourceRequest(
                        descriptorID: "ndi-slideshow",
                        activationClass: .prewarm
                    )
                ),
                .warmSource("ndi-slideshow"),
            ]
        )
    }

    func testAssignSourceRebindingLiveSlotKeepsCurrentLiveSourceConnectedUntilNextTake() async throws {
        let transport = RecordingTransport()
        let snapshots = WorkspaceSnapshotSequence([
            Self.makeWorkspaceSnapshot(
                outputs: [
                    Self.makeWorkspaceOutput(
                        id: "OUT-1",
                        slotAssignments: [
                            "S1": "ndi-presenter",
                            "S2": "ndi-backup",
                        ],
                        programSlotID: "S1",
                        previewSlotID: nil,
                        activeSourceID: "ndi-presenter"
                    ),
                ]
            ),
            Self.makeWorkspaceSnapshot(
                outputs: [
                    Self.makeWorkspaceOutput(
                        id: "OUT-1",
                        slotAssignments: [
                            "S1": "ndi-slideshow",
                            "S2": "ndi-backup",
                        ],
                        programSlotID: nil,
                        previewSlotID: nil,
                        activeSourceID: "ndi-presenter"
                    ),
                ]
            ),
        ])
        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { await snapshots.next() },
            validationSnapshotProvider: { Self.makeValidationSnapshot() },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.assignSource(sourceID: "ndi-slideshow", outputID: "OUT-1", slotID: "S1")

        let commands = await transport.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .assignOutputSlot(
                    BETRCoreAssignOutputSlotRequest(
                        outputID: "OUT-1",
                        slotID: "S1",
                        sourceID: "ndi-slideshow"
                    )
                ),
                .connectSource(
                    BETRCoreConnectSourceRequest(
                        descriptorID: "ndi-slideshow",
                        activationClass: .prewarm
                    )
                ),
                .warmSource("ndi-slideshow"),
            ]
        )
    }

    func testApplyLiveTileEventUpdatesCardWithoutReloadingWorkspace() async {
        let client = BETRCoreAgentClient(
            workspaceSnapshotProvider: { Self.makeWorkspaceSnapshot() },
            validationSnapshotProvider: { Self.makeValidationSnapshot() }
        )

        let initialState = await client.bootstrapShellState(rootDirectory: "/tmp/betr-room-control-v4-tests")
        let updatedState = await client.applyLiveTileEvent(
            BETRCoreLiveTileEvent(
                outputID: "OUT-1",
                snapshot: OutputLiveTileSnapshot(
                    outputID: "OUT-1",
                    sequence: 42,
                    sourceID: "ndi-slideshow",
                    previewState: .live,
                    fallbackActive: false,
                    audioMuted: true,
                    audioPresenceState: .muted,
                    leftLevel: 0.12,
                    rightLevel: 0.10
                )
            ),
            to: initialState
        )

        XCTAssertEqual(updatedState.workspace.cards.first?.liveTile.audioPresenceState, .muted)
        XCTAssertEqual(updatedState.workspace.cards.first?.liveTile.leftLevel ?? 0, 0.12, accuracy: 0.0001)
        XCTAssertTrue(updatedState.workspace.cards.first?.statusPills.contains(OutputStatusPill.muted) == true)
    }

    func testSetPreviewNilClearsPreviewThroughAgent() async throws {
        let transport = RecordingTransport()
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: { Self.makeValidationSnapshot() },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.setPreview(outputID: "OUT-1", slotID: nil)

        let commands = await transport.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .setPreviewSlot(
                    BETRCoreSetPreviewSlotRequest(
                        outputID: "OUT-1",
                        slotID: nil
                    )
                )
            ]
        )
    }

    func testSetOutputAudioMutedSendsCoreCommand() async throws {
        let transport = RecordingTransport()
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: { Self.makeValidationSnapshot() },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.setOutputAudioMuted(outputID: "OUT-1", muted: true)

        let commands = await transport.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .setOutputAudioMuted(
                    BETRCoreSetOutputAudioMutedRequest(
                        outputID: "OUT-1",
                        muted: true
                    )
                )
            ]
        )
    }

    func testSetOutputSoloedLocallySendsCoreCommand() async throws {
        let transport = RecordingTransport()
        let client = BETRCoreAgentClient(
            validationSnapshotProvider: { Self.makeValidationSnapshot() },
            commandTransport: { command in
                await transport.send(command)
            }
        )

        try await client.setOutputSoloedLocally(outputID: "OUT-2", soloed: true)

        let commands = await transport.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .setOutputSoloedLocally(
                    BETRCoreSetOutputSoloedLocallyRequest(
                        outputID: "OUT-2",
                        soloed: true
                    )
                )
            ]
        )
    }

    func testStartObservingEventsUsesInjectedProvider() async throws {
        let expectation = expectation(description: "event observed")
        let client = BETRCoreAgentClient(
            eventObservationProvider: { handler in
                handler(BETRCoreEventEnvelope(payload: .sourceWarmed("ndi-presenter")))
            }
        )

        try await client.startObservingEvents { event in
            if case let .sourceWarmed(sourceID) = event.payload {
                XCTAssertEqual(sourceID, "ndi-presenter")
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testCoreAgentBootstrapperUsesExplicitExecutablePath() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let executableURL = temporaryDirectory.appendingPathComponent("BETRCoreAgent")
        try Data("echo".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let recorder = CommandRecorder()
        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: ["BETR_CORE_AGENT_EXECUTABLE": executableURL.path],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: temporaryDirectory,
            mainExecutableURL: temporaryDirectory.appendingPathComponent("RoomControlApp"),
            runCommand: { executable, arguments, currentDirectoryURL in
                try recorder.record(
                    executable: executable,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL
                )
            }
        )

        let status = try await bootstrapper.ensureStarted()

        XCTAssertEqual(status.mode, .developerLaunchAgent)
        XCTAssertEqual(status.executablePath, executableURL.path)
        XCTAssertTrue(status.plistPath.hasSuffix("com.betr.core-agent.plist"))

        let commands = recorder.commands()
        XCTAssertEqual(commands.map(\.arguments.first), ["print", "bootstrap", "print"])
    }

    func testCoreAgentBootstrapperUsesBundledAgentForRealAppRuns() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = temporaryDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("BETR Room Control.app", isDirectory: true)
        let helperURL = appBundleURL.appendingPathComponent("Contents/Helpers/BETRCoreAgent")
        let plistURL = appBundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.betr.core-agent.plist")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try Data("echo".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try Data("<plist />".utf8).write(to: plistURL)

        let recorder = CommandRecorder()
        let networkHelperBootstrapper = TestPrivilegedNetworkHelperBootstrapper(
            status: RoomControlPrivilegedNetworkHelperBootstrapStatus(
                installed: true,
                promptedForInstall: false,
                executablePath: "/Library/PrivilegedHelperTools/com.betr.network-helper",
                plistPath: "/Library/LaunchDaemons/com.betr.network-helper.plist",
                note: "The BETR privileged network helper is already installed and up to date."
            ),
            onEnsure: nil
        )
        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: ["BETR_CORE_AGENT_EXECUTABLE": "/should/not/be/used"],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control"),
            mainBundleVersion: "0.9.8.51",
            networkHelperBootstrapper: networkHelperBootstrapper,
            runCommand: { executable, arguments, currentDirectoryURL in
                try recorder.record(
                    executable: executable,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL
                )
            }
        )

        let status = try await bootstrapper.ensureStarted()
        let generatedPlistURL = temporaryDirectory
            .appendingPathComponent("Library/LaunchAgents/com.betr.core-agent.plist")

        XCTAssertEqual(status.mode, .embeddedLaunchAgent)
        XCTAssertEqual(status.executablePath, helperURL.path)
        XCTAssertEqual(status.plistPath, generatedPlistURL.path)
        let generatedPlistContents = try String(contentsOf: generatedPlistURL, encoding: .utf8)
        XCTAssertTrue(generatedPlistContents.contains(helperURL.path))
        XCTAssertEqual(recorder.commands().map(\.arguments.first), ["print", "print", "bootstrap", "print"])
    }

    func testCoreAgentBootstrapperClearsStaleBundledAgentOnceAfterUpdate() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = temporaryDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("BETR Room Control.app", isDirectory: true)
        let helperURL = appBundleURL.appendingPathComponent("Contents/Helpers/BETRCoreAgent")
        let plistURL = appBundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.betr.core-agent.plist")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try Data("echo".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try Data("<plist />".utf8).write(to: plistURL)

        let suiteName = "BETRCoreAgentBootstrapperTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults.set("0.9.5.2", forKey: "BETRPreUpdateVersion")

        let recorder = CommandRecorder()
        let networkHelperBootstrapper = TestPrivilegedNetworkHelperBootstrapper(
            status: RoomControlPrivilegedNetworkHelperBootstrapStatus(
                installed: true,
                promptedForInstall: true,
                executablePath: "/Library/PrivilegedHelperTools/com.betr.network-helper",
                plistPath: "/Library/LaunchDaemons/com.betr.network-helper.plist",
                note: "Installed or updated the BETR privileged network helper. Future restarts should no longer ask for a password unless the helper itself changes."
            ),
            onEnsure: nil
        )
        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: [:],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control"),
            mainBundleVersion: "0.9.8.52",
            userDefaults: userDefaults,
            networkHelperBootstrapper: networkHelperBootstrapper,
            runCommand: { executable, arguments, currentDirectoryURL in
                try recorder.record(
                    executable: executable,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL
                )
            }
        )

        let status = try await bootstrapper.ensureStarted()

        XCTAssertEqual(status.mode, .embeddedLaunchAgent)
        XCTAssertTrue(status.note.contains("previous update"))
        XCTAssertEqual(
            recorder.commands().map(\.arguments.first),
            ["print", "bootout", "print", "bootstrap", "print"]
        )
        XCTAssertEqual(userDefaults.string(forKey: "BETRCoreAgentPostUpdateResetVersion"), "0.9.8.52")
    }

    func testCoreAgentBootstrapperRecyclesBundledAgentAfterMarkedHostProfileRestart() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = temporaryDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("BETR Room Control.app", isDirectory: true)
        let helperURL = appBundleURL.appendingPathComponent("Contents/Helpers/BETRCoreAgent")
        let plistURL = appBundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.betr.core-agent.plist")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try Data("echo".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try Data("<plist />".utf8).write(to: plistURL)

        let suiteName = "BETRCoreAgentBootstrapperHostRestart-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let recorder = CommandRecorder()
        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: [:],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control"),
            mainBundleVersion: "0.9.8.65",
            userDefaults: userDefaults,
            networkHelperBootstrapper: TestPrivilegedNetworkHelperBootstrapper(
                status: RoomControlPrivilegedNetworkHelperBootstrapStatus(
                    installed: true,
                    promptedForInstall: false,
                    executablePath: "/Library/PrivilegedHelperTools/com.betr.network-helper",
                    plistPath: "/Library/LaunchDaemons/com.betr.network-helper.plist",
                    note: "The BETR privileged network helper is already installed and up to date."
                ),
                onEnsure: nil
            ),
            runCommand: { executable, arguments, currentDirectoryURL in
                try recorder.record(
                    executable: executable,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL
                )
            }
        )

        await bootstrapper.markManagedAgentRestartRequired(reason: .hostApply)
        let status = try await bootstrapper.ensureStarted()

        XCTAssertEqual(status.mode, .embeddedLaunchAgent)
        XCTAssertTrue(status.note.contains("host_apply restart intent"))
        XCTAssertEqual(status.consumedRestartIntent?.reason, .hostApply)
        let commandHeads = recorder.commands().compactMap(\.arguments.first)
        XCTAssertEqual(commandHeads.first, "print")
        if let bootoutIndex = commandHeads.firstIndex(of: "bootout"),
           let bootstrapIndex = commandHeads.firstIndex(of: "bootstrap") {
            XCTAssertLessThan(bootoutIndex, bootstrapIndex)
        } else {
            XCTFail("Expected both bootout and bootstrap commands")
        }
        XCTAssertEqual(commandHeads.last, "print")
    }

    func testCoreAgentBootstrapperRejectsRealAppRunsWithoutBundledAssets() async {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = temporaryDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("BETR Room Control.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: appBundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: ["BETR_CORE_AGENT_EXECUTABLE": "/should/not/be/used"],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control"),
            networkHelperBootstrapper: TestPrivilegedNetworkHelperBootstrapper(
                status: RoomControlPrivilegedNetworkHelperBootstrapStatus(
                    installed: true,
                    promptedForInstall: false,
                    executablePath: "/Library/PrivilegedHelperTools/com.betr.network-helper",
                    plistPath: "/Library/LaunchDaemons/com.betr.network-helper.plist",
                    note: "The BETR privileged network helper is already installed and up to date."
                ),
                onEnsure: nil
            ),
            runCommand: { _, _, _ in
                XCTFail("runCommand should not be used when bundled assets are missing")
                return ""
            }
        )

        do {
            _ = try await bootstrapper.ensureStarted()
            XCTFail("Expected bundledAgentAssetsMissing")
        } catch let error as RoomControlCoreAgentBootstrapError {
            XCTAssertEqual(error, .bundledAgentAssetsMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCoreAgentBootstrapperRejectsRealAppRunsOutsideApplications() async {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = temporaryDirectory.appendingPathComponent("BETR Room Control.app", isDirectory: true)
        let helperURL = appBundleURL.appendingPathComponent("Contents/Helpers/BETRCoreAgent")
        let plistURL = appBundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.betr.core-agent.plist")
        try? FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("echo".utf8).write(to: helperURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try? Data("<plist />".utf8).write(to: plistURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: [:],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control"),
            networkHelperBootstrapper: TestPrivilegedNetworkHelperBootstrapper(
                status: RoomControlPrivilegedNetworkHelperBootstrapStatus(
                    installed: true,
                    promptedForInstall: false,
                    executablePath: "/Library/PrivilegedHelperTools/com.betr.network-helper",
                    plistPath: "/Library/LaunchDaemons/com.betr.network-helper.plist",
                    note: "The BETR privileged network helper is already installed and up to date."
                ),
                onEnsure: nil
            ),
            runCommand: { _, _, _ in
                XCTFail("runCommand should not be used when install context is invalid")
                return ""
            }
        )

        do {
            _ = try await bootstrapper.ensureStarted()
            XCTFail("Expected installRequired")
        } catch let error as RoomControlCoreAgentBootstrapError {
            XCTAssertEqual(error, .installRequired(appBundleURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCoreAgentBootstrapperSkipsPrivilegedNetworkHelperInstallDuringBootstrapCheck() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = temporaryDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("BETR Room Control.app", isDirectory: true)
        let helperURL = appBundleURL.appendingPathComponent("Contents/Helpers/BETRCoreAgent")
        let plistURL = appBundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.betr.core-agent.plist")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try Data("echo".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        try Data("<plist />".utf8).write(to: plistURL)

        let observedSkipInstall = LockedBox(false)
        let bootstrapper = RoomControlCoreAgentBootstrapper(
            environment: [:],
            homeDirectoryURL: temporaryDirectory,
            mainBundleURL: appBundleURL,
            mainExecutableURL: appBundleURL.appendingPathComponent("Contents/MacOS/BETR Room Control"),
            networkHelperBootstrapper: TestPrivilegedNetworkHelperBootstrapper(
                status: RoomControlPrivilegedNetworkHelperBootstrapStatus(
                    installed: false,
                    promptedForInstall: false,
                    executablePath: "/Library/PrivilegedHelperTools/com.betr.network-helper",
                    plistPath: "/Library/LaunchDaemons/com.betr.network-helper.plist",
                    note: "Skipped privileged helper installation during packaged bootstrap validation."
                ),
                onEnsure: { skipInstallation in
                    observedSkipInstall.value = skipInstallation
                }
            ),
            runCommand: { _, _, _ in "" }
        )

        _ = try await bootstrapper.ensureStarted(skipPrivilegedNetworkHelperInstall: true)
        XCTAssertTrue(observedSkipInstall.value)
    }

    private static func makeWorkspaceSnapshot(
        agentInstanceID: String = "agent-workspace",
        agentStartedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        outputs: [BETRCoreWorkspaceOutputSnapshot] = [
            makeWorkspaceOutput(
                id: "OUT-1",
                slotAssignments: ["S1": "ndi-presenter", "S2": "ndi-slideshow"],
                programSlotID: "S2",
                previewSlotID: "S1",
                activeSourceID: "ndi-slideshow",
                isSoloedLocally: true
            ),
            makeWorkspaceOutput(
                id: "OUT-2",
                title: "Program Output 2",
                slotAssignments: ["S1": "ndi-slideshow"],
                programSlotID: nil,
                previewSlotID: "S1",
                activeSourceID: nil
            ),
        ]
    ) -> BETRCoreWorkspaceSnapshotResponse {
        BETRCoreWorkspaceSnapshotResponse(
            agentInstanceID: agentInstanceID,
            agentStartedAt: agentStartedAt,
            outputs: outputs,
            sources: [
                BETRCoreWorkspaceSourceSnapshot(
                    id: "ndi-presenter",
                    name: "Presenter View",
                    details: "192.168.55.21",
                    provenance: "finder",
                    routedOutputIDs: ["OUT-1"],
                    sortPriority: 10,
                    readiness: BETRCoreSourceWarmStateSnapshot(
                        id: "ndi-presenter",
                        connected: true,
                        warming: false,
                        warm: true,
                        receiverConnected: true,
                        hasVideo: true,
                        audioPrimed: true,
                        gpuPrimed: true
                    )
                ),
                BETRCoreWorkspaceSourceSnapshot(
                    id: "ndi-slideshow",
                    name: "Slideshow",
                    details: "192.168.55.22",
                    provenance: "finder",
                    routedOutputIDs: ["OUT-1"],
                    sortPriority: 0,
                    readiness: BETRCoreSourceWarmStateSnapshot(
                        id: "ndi-slideshow",
                        connected: true,
                        warming: false,
                        warm: true,
                        receiverConnected: true,
                        hasVideo: true,
                        audioPrimed: true,
                        gpuPrimed: true
                    )
                ),
            ],
            discoverySummary: "2 sources • ndi://192.168.55.11",
            hostWizardSummary: "en7",
            capacity: BETRCoreCapacitySnapshot(
                configuredOutputs: outputs.count,
                discoveredSources: 2
            )
        )
    }

    private static func makeWorkspaceOutput(
        id: String,
        title: String = "Program Output",
        slotAssignments: [String: String],
        programSlotID: String?,
        previewSlotID: String?,
        activeSourceID: String?,
        isSoloedLocally: Bool = false
    ) -> BETRCoreWorkspaceOutputSnapshot {
        BETRCoreWorkspaceOutputSnapshot(
            id: id,
            title: title,
            rasterLabel: "1920×1080 / 29.97",
            listenerCount: activeSourceID == nil ? 0 : 1,
            slots: (1...6).map { index in
                let slotID = "S\(index)"
                return BETRCoreOutputSlotSnapshot(
                    outputID: id,
                    slotID: slotID,
                    label: slotID,
                    sourceID: slotAssignments[slotID]
                )
            },
            programSlotID: programSlotID,
            previewSlotID: previewSlotID,
            isAudioMuted: false,
            isSoloedLocally: isSoloedLocally,
            senderReady: true,
            fallbackActive: false,
            liveTile: BETRCoreWorkspaceLiveTileSnapshot(
                outputID: id,
                sourceID: activeSourceID,
                fallbackActive: false,
                audioMuted: false,
                audioPresenceState: activeSourceID == nil ? .silent : .live,
                leftLevel: activeSourceID == nil ? 0 : 0.35,
                rightLevel: activeSourceID == nil ? 0 : 0.34
            ),
            armedPreviewTile: previewSlotID.flatMap { slotAssignments[$0] }.map { previewSourceID in
                BETRCoreWorkspaceArmedPreviewTileSnapshot(
                    outputID: id,
                    sourceID: previewSourceID,
                    ready: true,
                    sourceName: previewSourceID == "ndi-slideshow" ? "Slideshow" : "Presenter View"
                )
            }
        )
    }

    private static func makeValidationSnapshot(
        agentInstanceID: String = "agent-validation",
        agentStartedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
        connectedSourceID: String? = "ndi-slideshow",
        programSourceID: String? = "ndi-slideshow",
        previewSourceID: String? = "ndi-presenter",
        discoveryServerURLs: [String] = ["192.168.55.11"],
        runtimeDiscoveryServers: [NDIDiscoveryServerStatus]? = nil,
        activeDiscoveryServerURL: String? = "ndi://192.168.55.11",
        finderSourceCount: Int = 2,
        listenerSourceCount: Int = 2,
        localFinderSourceCount: Int = 0,
        remoteFinderSourceCount: Int = 2,
        localSourceCount: Int = 0,
        remoteSourceCount: Int = 2,
        receiverTelemetry: [BETRCoreReceiverTelemetrySnapshot] = [],
        outputTelemetry: [BETRCoreOutputTelemetrySnapshot] = []
    ) -> BETRCoreValidationSnapshotResponse {
        let presenter = NDISourceDescriptor(
            id: "ndi-presenter",
            name: "Presenter View",
            address: "192.168.55.21",
            sourceDescription: "Presenter monitor"
        )
        let slideshow = NDISourceDescriptor(
            id: "ndi-slideshow",
            name: "Slideshow",
            address: "192.168.55.22",
            sourceDescription: "Presentation output"
        )

        let runtimeStatus = NDIRuntimeStatus(
            availability: .healthy,
            sdkBootstrapState: .initialized,
            sdkVersion: "6.1.1",
            sdkLoadedPath: "/Library/NDI/libndi.dylib",
            networkProfile: NDINetworkProfile(
                discoveryMode: .discoveryServerFirst,
                discoveryServerURLs: discoveryServerURLs,
                selectedInterfaceID: "en7"
            ),
            configFingerprint: "proof-fingerprint",
            discoveryServers: runtimeDiscoveryServers ?? [
                NDIDiscoveryServerStatus(
                    configuredURL: "192.168.55.11",
                    host: "192.168.55.11",
                    port: 5959,
                    normalizedEndpoint: "192.168.55.11:5959",
                    senderListenerCreateSucceeded: true,
                    receiverListenerCreateSucceeded: true,
                    senderListenerConnected: true,
                    senderListenerServerURL: "ndi://192.168.55.11",
                    receiverListenerConnected: true,
                    receiverListenerServerURL: "ndi://192.168.55.11"
                )
            ],
            activeDiscoveryServerURL: activeDiscoveryServerURL,
            connectedServerURLs: activeDiscoveryServerURL.map { [$0] } ?? [],
            selectedInterfaceID: "en7"
        )

        let presence = NDISourcePresenceSnapshot(
            descriptors: [presenter, slideshow],
            provenanceByID: [
                presenter.id: .finder,
                slideshow.id: .finder,
            ],
            discoveryServers: runtimeStatus.discoveryServers,
            activeDiscoveryServerURL: runtimeStatus.activeDiscoveryServerURL
        )

        let directorySnapshot = NDIDirectoryRuntimeSnapshot(
            presence: presence,
            catalog: NDISourceCatalogSnapshot(
                sources: [presenter, slideshow],
                provenanceByID: [
                    presenter.id: .finder,
                    slideshow.id: .finder,
                ],
                finderSourceCount: finderSourceCount,
                listenerSourceCount: listenerSourceCount,
                networkProfile: runtimeStatus.networkProfile,
                runtimeStatus: runtimeStatus
            ),
            sources: [
                NDIDirectorySourceRecord(
                    descriptor: presenter,
                    provenance: .finder,
                    firstSeenAt: Date(),
                    lastSeenAt: Date(),
                    activeDiscoveryServerURL: runtimeStatus.activeDiscoveryServerURL
                ),
                NDIDirectorySourceRecord(
                    descriptor: slideshow,
                    provenance: .finder,
                    firstSeenAt: Date(),
                    lastSeenAt: Date(),
                    activeDiscoveryServerURL: runtimeStatus.activeDiscoveryServerURL
                ),
            ],
            discovery: NDIDiscoverySnapshot(
                activeDiscoveryServerURL: runtimeStatus.activeDiscoveryServerURL,
                connectedServerURLs: runtimeStatus.connectedServerURLs,
                finderSourceCount: finderSourceCount,
                listenerSourceCount: listenerSourceCount,
                localFinderSourceCount: localFinderSourceCount,
                remoteFinderSourceCount: remoteFinderSourceCount,
                localSourceCount: localSourceCount,
                remoteSourceCount: remoteSourceCount,
                senderListenerConnected: runtimeStatus.discoveryServers.contains(where: { $0.senderListenerConnected }),
                receiverListenerConnected: runtimeStatus.discoveryServers.contains(where: { $0.receiverListenerConnected })
            ),
            activationTable: NDIActivationTableSnapshot(entries: [])
        )

        return BETRCoreValidationSnapshotResponse(
            agentInstanceID: agentInstanceID,
            agentStartedAt: agentStartedAt,
            hostState: BETRNDIHostStateSnapshot(
                showLocationName: "BETR Core Proof",
                showNetworkCIDR: "192.168.55.0/24",
                selectedInterfaceID: "en7",
                selectedInterfaceBSDName: "en7",
                selectedInterfaceCIDR: "192.168.55.20/24",
                discoveryServers: discoveryServerURLs,
                committedConfigFingerprint: "proof-fingerprint",
                committedConfigMatchesProfile: true,
                multicastRoute: BETRNDIMulticastRouteSnapshot(
                    probedAddress: "224.0.0.1",
                    selectedInterfaceBSDName: "en7",
                    effectiveRouteOwnerBSDName: "en7",
                    destination: "224.0.0.1",
                    netmask: "255.255.255.255",
                    routeExists: true,
                    routePinnedToCommittedInterface: true,
                    exitCode: 0,
                    rawOutput: "224.0.0.1 interface: en7"
                ),
                lastPreparedAt: Date(),
                lastOperationMessage: "Applied proof profile."
            ),
            runtimeStatus: runtimeStatus,
            directorySnapshot: directorySnapshot,
            proofOutput: BETRCoreProofOutputSnapshot(
                outputID: "OUT-1",
                senderName: "Program Output",
                activeSourceID: "ndi-slideshow",
                activeSourceEpoch: 4,
                fallbackActive: false,
                senderReady: true,
                senderConnectionCount: 1,
                videoCadenceSource: .displayLink,
                audioCadenceSource: .hardwarePull,
                routeStage: .sourceReadyCommitted,
                lastVideoSendAt: Date(),
                lastAudioSendAt: Date(),
                lastAction: "program_live"
            ),
            outputSlots: (1...6).map { index in
                let slotID = "S\(index)"
                let sourceID: String?
                switch slotID {
                case "S1":
                    sourceID = "ndi-presenter"
                case "S2":
                    sourceID = "ndi-slideshow"
                default:
                    sourceID = nil
                }
                return BETRCoreOutputSlotSnapshot(
                    outputID: "OUT-1",
                    slotID: slotID,
                    label: slotID,
                    sourceID: sourceID
                )
            },
            sourceStates: [
                BETRCoreSourceWarmStateSnapshot(
                    id: "ndi-presenter",
                    connected: connectedSourceID == "ndi-presenter",
                    warming: false,
                    warm: connectedSourceID == "ndi-presenter",
                    receiverConnected: connectedSourceID == "ndi-presenter",
                    hasVideo: connectedSourceID == "ndi-presenter",
                    audioPrimed: connectedSourceID == "ndi-presenter",
                    gpuPrimed: connectedSourceID == "ndi-presenter"
                ),
                BETRCoreSourceWarmStateSnapshot(
                    id: "ndi-slideshow",
                    connected: connectedSourceID == "ndi-slideshow",
                    warming: false,
                    warm: connectedSourceID == "ndi-slideshow",
                    receiverConnected: connectedSourceID == "ndi-slideshow",
                    hasVideo: connectedSourceID == "ndi-slideshow",
                    audioPrimed: connectedSourceID == "ndi-slideshow",
                    gpuPrimed: connectedSourceID == "ndi-slideshow"
                ),
            ],
            receiverTelemetry: receiverTelemetry,
            outputTelemetry: outputTelemetry,
            programSlotID: programSourceID == "ndi-slideshow" ? "S2" : (programSourceID == "ndi-presenter" ? "S1" : nil),
            previewSlotID: previewSourceID == "ndi-slideshow" ? "S2" : (previewSourceID == "ndi-presenter" ? "S1" : nil),
            programSourceID: programSourceID,
            previewSourceID: previewSourceID
        )
    }
}

private final class CommandRecorder {
    struct Command: Equatable {
        let executablePath: String
        let arguments: [String]
        let currentDirectoryPath: String?
    }

    private let lock = NSLock()
    private var recorded: [Command] = []

    func record(
        executable: URL,
        arguments: [String],
        currentDirectoryURL: URL?
    ) throws -> String {
        lock.lock()
        recorded.append(
            Command(
                executablePath: executable.path,
                arguments: arguments,
                currentDirectoryPath: currentDirectoryURL?.path
            )
        )
        lock.unlock()

        if arguments.first == "print" {
            throw RoomControlCoreAgentBootstrapError.commandFailed("not loaded")
        }
        return arguments.first == "bootstrap" ? "bootstrapped" : ""
    }

    func commands() -> [Command] {
        lock.lock()
        let snapshot = recorded
        lock.unlock()
        return snapshot
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private actor RecordingTransport {
    private var commands: [BETRCoreCommandEnvelope] = []

    func send(_ command: BETRCoreCommandEnvelope) -> BETRCoreCommandResponseEnvelope {
        commands.append(command)
        return .success
    }

    func recordedCommands() -> [BETRCoreCommandEnvelope] {
        commands
    }
}

private actor WorkspaceSnapshotSequence {
    private let snapshots: [BETRCoreWorkspaceSnapshotResponse]
    private var index = 0

    init(_ snapshots: [BETRCoreWorkspaceSnapshotResponse]) {
        self.snapshots = snapshots
    }

    func next() -> BETRCoreWorkspaceSnapshotResponse {
        let safeIndex = min(index, max(snapshots.count - 1, 0))
        let snapshot = snapshots[safeIndex]
        index += 1
        return snapshot
    }
}
