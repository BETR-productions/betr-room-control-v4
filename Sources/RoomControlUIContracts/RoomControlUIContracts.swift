import Foundation
import CoreNDIHost
import TimerDomain

public enum OutputPreviewState: String, Sendable, Equatable {
    case live
    case fault
    case unavailable
}

public enum OutputAudioPresenceState: String, Sendable, Equatable {
    case live
    case muted
    case silent
}

public enum OutputStatusPill: String, Sendable, Equatable, CaseIterable, Identifiable {
    case live = "LIVE"
    case pvw = "PVW"
    case pgm = "PGM"
    case audio = "AUDIO"
    case muted = "MUTED"
    case solo = "SOLO"
    case fault = "FAULT"
    case degraded = "DEGRADED"
    case arming = "ARMING"
    case error = "ERROR"

    public var id: String { rawValue }
}

public enum OutputConfidencePreviewMode: String, Sendable, Equatable {
    case pendingProgram
    case armedPreview
}

public struct OutputLiveTileModel: Sendable, Equatable {
    public let sourceID: String?
    public let previewState: OutputPreviewState
    // These fields represent the audio currently published by the output live
    // tile, not selected-preview audio and not source-readiness telemetry.
    public let audioPresenceState: OutputAudioPresenceState
    public let leftLevel: Double
    public let rightLevel: Double
    public let playoutFaultStageID: String?
    public let lastSuccessfulProgramSurfaceSequence: UInt64?

    public init(
        sourceID: String? = nil,
        previewState: OutputPreviewState = .unavailable,
        audioPresenceState: OutputAudioPresenceState = .silent,
        leftLevel: Double = 0,
        rightLevel: Double = 0,
        playoutFaultStageID: String? = nil,
        lastSuccessfulProgramSurfaceSequence: UInt64? = nil
    ) {
        self.sourceID = sourceID
        self.previewState = previewState
        self.audioPresenceState = audioPresenceState
        self.leftLevel = leftLevel
        self.rightLevel = rightLevel
        self.playoutFaultStageID = playoutFaultStageID
        self.lastSuccessfulProgramSurfaceSequence = lastSuccessfulProgramSurfaceSequence
    }
}

public struct OutputConfidencePreviewModel: Sendable, Equatable {
    public let sourceID: String?
    public let sourceName: String?
    public let mode: OutputConfidencePreviewMode
    public let isReady: Bool
    public let previewState: OutputPreviewState
    public let audioPresenceState: OutputAudioPresenceState
    public let leftLevel: Double
    public let rightLevel: Double

    public init(
        sourceID: String? = nil,
        sourceName: String? = nil,
        mode: OutputConfidencePreviewMode = .armedPreview,
        isReady: Bool = false,
        previewState: OutputPreviewState = .unavailable,
        audioPresenceState: OutputAudioPresenceState = .silent,
        leftLevel: Double = 0,
        rightLevel: Double = 0
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.mode = mode
        self.isReady = isReady
        self.previewState = previewState
        self.audioPresenceState = audioPresenceState
        self.leftLevel = leftLevel
        self.rightLevel = rightLevel
    }
}

public struct RoomControlOutputSlotState: Sendable, Equatable, Identifiable {
    public let id: String
    public var label: String
    public var sourceID: String?
    public var sourceName: String?
    public var isAvailable: Bool
    public var isPreview: Bool
    public var isProgram: Bool

    public init(
        id: String,
        label: String,
        sourceID: String? = nil,
        sourceName: String? = nil,
        isAvailable: Bool = true,
        isPreview: Bool = false,
        isProgram: Bool = false
    ) {
        self.id = id
        self.label = label
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.isAvailable = isAvailable
        self.isPreview = isPreview
        self.isProgram = isProgram
    }
}

public struct RoomControlOutputCardState: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var rasterLabel: String
    public var videoFormatPresetID: String
    public var listenerCount: Int
    public var slots: [RoomControlOutputSlotState]
    public var programSlotID: String?
    public var previewSlotID: String?
    public var isAudioMuted: Bool
    public var isSoloedLocally: Bool
    public var pendingProgramReady: Bool
    public var selectedSourceFormatLabel: String?
    public var statusPills: [OutputStatusPill]
    public var liveTile: OutputLiveTileModel
    public var confidencePreview: OutputConfidencePreviewModel?

    public init(
        id: String,
        title: String,
        rasterLabel: String,
        videoFormatPresetID: String = "1080p2997",
        listenerCount: Int = 0,
        slots: [RoomControlOutputSlotState],
        programSlotID: String? = nil,
        previewSlotID: String? = nil,
        isAudioMuted: Bool = false,
        isSoloedLocally: Bool = false,
        pendingProgramReady: Bool = false,
        selectedSourceFormatLabel: String? = nil,
        statusPills: [OutputStatusPill] = [],
        liveTile: OutputLiveTileModel = OutputLiveTileModel(),
        confidencePreview: OutputConfidencePreviewModel? = nil
    ) {
        self.id = id
        self.title = title
        self.rasterLabel = rasterLabel
        self.videoFormatPresetID = videoFormatPresetID
        self.listenerCount = listenerCount
        self.slots = slots
        self.programSlotID = programSlotID
        self.previewSlotID = previewSlotID
        self.isAudioMuted = isAudioMuted
        self.isSoloedLocally = isSoloedLocally
        self.pendingProgramReady = pendingProgramReady
        self.selectedSourceFormatLabel = selectedSourceFormatLabel
        self.statusPills = statusPills
        self.liveTile = liveTile
        self.confidencePreview = confidencePreview
    }
}

public extension RoomControlOutputCardState {
    var programSlot: RoomControlOutputSlotState? {
        slots.first(where: { $0.id == programSlotID })
    }

    var previewSlot: RoomControlOutputSlotState? {
        slots.first(where: { $0.id == previewSlotID })
    }

    var programSourceID: String? {
        programSlot?.sourceID
    }

    var previewSourceID: String? {
        previewSlot?.sourceID
    }

    var programSourceName: String? {
        programSlot?.sourceName
    }

    var previewSourceName: String? {
        previewSlot?.sourceName
    }
}

public struct RouterWorkspaceSourceState: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let details: String
    public let provenance: String
    public let routedOutputIDs: [String]
    public let sortPriority: Int
    public let latestVideoFormatLabel: String?
    public let isConnected: Bool
    public let isWarming: Bool
    public let isWarm: Bool
    public let inputAVSkewMs: Double?
    public let syncReady: Bool
    public let gateReasons: [String]
    public let fanoutCount: Int
    public let audioRequired: Bool
    public let videoRecent: Bool
    public let audioRecent: Bool

    public init(
        id: String,
        name: String,
        details: String = "",
        provenance: String = "finder",
        routedOutputIDs: [String] = [],
        sortPriority: Int = 100,
        latestVideoFormatLabel: String? = nil,
        isConnected: Bool = false,
        isWarming: Bool = false,
        isWarm: Bool = false,
        inputAVSkewMs: Double? = nil,
        syncReady: Bool = false,
        gateReasons: [String] = [],
        fanoutCount: Int = 0,
        audioRequired: Bool = true,
        videoRecent: Bool = false,
        audioRecent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.provenance = provenance
        self.routedOutputIDs = routedOutputIDs.sorted()
        self.sortPriority = sortPriority
        self.latestVideoFormatLabel = latestVideoFormatLabel
        self.isConnected = isConnected
        self.isWarming = isWarming
        self.isWarm = isWarm
        self.inputAVSkewMs = inputAVSkewMs
        self.syncReady = syncReady
        self.gateReasons = gateReasons
        self.fanoutCount = fanoutCount
        self.audioRequired = audioRequired
        self.videoRecent = videoRecent
        self.audioRecent = audioRecent
    }

    public var provenanceLabel: String {
        switch provenance {
        case "finder":
            return "FINDER"
        case "senderListener":
            return "LISTENER"
        case "both":
            return "BOTH"
        default:
            return provenance.uppercased()
        }
    }

    public var readinessLabel: String {
        if isWarm {
            return "WARM"
        }
        if isWarming {
            return "WARMING"
        }
        if isConnected {
            return "CONNECTED"
        }
        return "DISCOVERED"
    }
}

public struct RouterWorkspaceSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let agentInstanceID: String
    public let agentStartedAt: Date
    public var cards: [RoomControlOutputCardState]
    public var sources: [RouterWorkspaceSourceState]
    public var discoverySummary: String
    public var hostInterfaceInventory: BETRCoreHostInterfaceInventorySnapshot?

    public init(
        generatedAt: Date = Date(),
        agentInstanceID: String = "",
        agentStartedAt: Date = .distantPast,
        cards: [RoomControlOutputCardState],
        sources: [RouterWorkspaceSourceState],
        discoverySummary: String = "mDNS",
        hostInterfaceInventory: BETRCoreHostInterfaceInventorySnapshot? = nil
    ) {
        self.generatedAt = generatedAt
        self.agentInstanceID = agentInstanceID
        self.agentStartedAt = agentStartedAt
        self.cards = cards
        self.sources = sources
        self.discoverySummary = discoverySummary
        self.hostInterfaceInventory = hostInterfaceInventory
    }
}

public struct RoomControlCapacitySnapshot: Sendable, Equatable {
    public let capturedAt: Date
    public let configuredOutputs: Int
    public let discoveredSources: Int
    public let processCPUPercent: Double?
    public let selectedNICThroughputMbps: Double?

    public init(
        capturedAt: Date = Date(),
        configuredOutputs: Int = 0,
        discoveredSources: Int = 0,
        processCPUPercent: Double? = nil,
        selectedNICThroughputMbps: Double? = nil
    ) {
        self.capturedAt = capturedAt
        self.configuredOutputs = configuredOutputs
        self.discoveredSources = discoveredSources
        self.processCPUPercent = processCPUPercent
        self.selectedNICThroughputMbps = selectedNICThroughputMbps
    }
}

public struct RoomControlOperatorShellUIState: Codable, Sendable, Equatable {
    public var leadingColumnWidth: Double
    public var centerColumnWidth: Double
    public var settingsPresented: Bool

    public init(
        leadingColumnWidth: Double = 340,
        centerColumnWidth: Double = 340,
        settingsPresented: Bool = false
    ) {
        self.leadingColumnWidth = leadingColumnWidth
        self.centerColumnWidth = centerColumnWidth
        self.settingsPresented = settingsPresented
    }
}

public enum NDIWizardPersistedStep: String, Sendable, Equatable, CaseIterable, Identifiable {
    case quickStart
    case interface
    case discovery
    case multicast
    case naming
    case apply
    case validation
    case advanced
    case logs

    public var id: String { rawValue }
}

public struct NDIWizardProgressState: Sendable, Equatable {
    public var currentStep: NDIWizardPersistedStep
    public var completedSteps: Set<NDIWizardPersistedStep>

    public init(
        currentStep: NDIWizardPersistedStep = .interface,
        completedSteps: Set<NDIWizardPersistedStep> = []
    ) {
        self.currentStep = currentStep
        self.completedSteps = completedSteps
    }
}

public struct HostWizardDraft: Codable, Sendable, Equatable {
    public var showLocationName: String
    public var showNetworkCIDR: String
    public var ownershipMode: BETRNDIHostOwnershipMode
    public var selectedInterfaceID: String
    public var discoveryServersText: String
    public var mdnsEnabled: Bool
    public var multicastEnabled: Bool
    public var multicastReceiveEnabled: Bool
    public var multicastTransmitEnabled: Bool
    public var multicastPrefix: String
    public var multicastNetmask: String
    public var multicastTTL: Int
    public var groupsText: String
    public var extraIPsText: String
    public var receiveSubnetsText: String
    public var sourceFilter: String
    public var nodeLabel: String
    public var senderPrefix: String
    public var outputPrefix: String

    public init(
        showLocationName: String = "BETR NDI",
        showNetworkCIDR: String = "192.168.55.0/24",
        ownershipMode: BETRNDIHostOwnershipMode = .betrOnly,
        selectedInterfaceID: String = "",
        discoveryServersText: String = "192.168.55.11",
        mdnsEnabled: Bool = false,
        multicastEnabled: Bool = true,
        multicastReceiveEnabled: Bool = true,
        multicastTransmitEnabled: Bool = true,
        multicastPrefix: String = "239.255.0.0",
        multicastNetmask: String = "255.255.0.0",
        multicastTTL: Int = 1,
        groupsText: String = "",
        extraIPsText: String = "",
        receiveSubnetsText: String = "",
        sourceFilter: String = "",
        nodeLabel: String = "BETR Room Control",
        senderPrefix: String = "BETR",
        outputPrefix: String = "Output"
    ) {
        self.showLocationName = showLocationName
        self.showNetworkCIDR = showNetworkCIDR
        self.ownershipMode = ownershipMode
        self.selectedInterfaceID = selectedInterfaceID
        self.discoveryServersText = discoveryServersText
        self.mdnsEnabled = mdnsEnabled
        self.multicastEnabled = multicastEnabled
        self.multicastReceiveEnabled = multicastReceiveEnabled
        self.multicastTransmitEnabled = multicastTransmitEnabled
        self.multicastPrefix = multicastPrefix
        self.multicastNetmask = multicastNetmask
        self.multicastTTL = multicastTTL
        self.groupsText = groupsText
        self.extraIPsText = extraIPsText
        self.receiveSubnetsText = receiveSubnetsText
        self.sourceFilter = sourceFilter
        self.nodeLabel = nodeLabel
        self.senderPrefix = senderPrefix
        self.outputPrefix = outputPrefix
    }
}

public enum NDIWizardCheckState: String, Sendable, Equatable {
    case passed
    case warning
    case blocked
}

public enum NDIWizardDiscoveryState: String, Sendable, Equatable {
    case noDiscoveryConfigured = "no_discovery_configured"
    case error
    case waiting
    case connected
    case visible
}

public enum NDIWizardTrafficProbeState: String, Sendable, Equatable {
    case notRun = "not_run"
    case noTrafficObserved = "no_traffic_observed"
    case selectedInterfaceTrafficObserved = "selected_interface_traffic_observed"
    case nonSelectedInterfaceTrafficObserved = "non_selected_interface_traffic_observed"
    case suspectedLeak = "suspected_leak"
}

public struct NDIWizardDiscoveryServerRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let configuredURL: String
    public let normalizedEndpoint: String
    public let host: String
    public let port: Int
    public let senderListenerCreateSucceeded: Bool
    public let senderListenerConnected: Bool
    public let senderListenerServerURL: String?
    public let receiverListenerCreateSucceeded: Bool
    public let receiverListenerConnected: Bool
    public let receiverListenerServerURL: String?

    public init(
        id: String,
        configuredURL: String,
        normalizedEndpoint: String? = nil,
        host: String,
        port: Int,
        senderListenerCreateSucceeded: Bool = false,
        senderListenerConnected: Bool,
        senderListenerServerURL: String? = nil,
        receiverListenerCreateSucceeded: Bool = false,
        receiverListenerConnected: Bool,
        receiverListenerServerURL: String? = nil
    ) {
        self.id = id
        self.configuredURL = configuredURL
        self.normalizedEndpoint = normalizedEndpoint ?? id
        self.host = host
        self.port = port
        self.senderListenerCreateSucceeded = senderListenerCreateSucceeded
        self.senderListenerConnected = senderListenerConnected
        self.senderListenerServerURL = senderListenerServerURL
        self.receiverListenerCreateSucceeded = receiverListenerCreateSucceeded
        self.receiverListenerConnected = receiverListenerConnected
        self.receiverListenerServerURL = receiverListenerServerURL
    }
}

public struct NDIWizardDiscoveryServerDebugRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let normalizedEndpoint: String
    public let validatedAddress: String?
    public let listenerDebugState: String
    public let lastStateChangeAt: Date?
    public let senderCreateFunctionAvailable: Bool
    public let receiverCreateFunctionAvailable: Bool
    public let senderCandidateAddresses: [String]
    public let receiverCandidateAddresses: [String]
    public let senderAttachAttemptCount: Int
    public let receiverAttachAttemptCount: Int
    public let senderLastAttemptedAddress: String?
    public let receiverLastAttemptedAddress: String?
    public let senderAttachFailureReason: String?
    public let receiverAttachFailureReason: String?

    public init(
        id: String,
        normalizedEndpoint: String,
        validatedAddress: String? = nil,
        listenerDebugState: String = "detached",
        lastStateChangeAt: Date? = nil,
        senderCreateFunctionAvailable: Bool = false,
        receiverCreateFunctionAvailable: Bool = false,
        senderCandidateAddresses: [String] = [],
        receiverCandidateAddresses: [String] = [],
        senderAttachAttemptCount: Int = 0,
        receiverAttachAttemptCount: Int = 0,
        senderLastAttemptedAddress: String? = nil,
        receiverLastAttemptedAddress: String? = nil,
        senderAttachFailureReason: String? = nil,
        receiverAttachFailureReason: String? = nil
    ) {
        self.id = id
        self.normalizedEndpoint = normalizedEndpoint
        self.validatedAddress = validatedAddress
        self.listenerDebugState = listenerDebugState
        self.lastStateChangeAt = lastStateChangeAt
        self.senderCreateFunctionAvailable = senderCreateFunctionAvailable
        self.receiverCreateFunctionAvailable = receiverCreateFunctionAvailable
        self.senderCandidateAddresses = senderCandidateAddresses
        self.receiverCandidateAddresses = receiverCandidateAddresses
        self.senderAttachAttemptCount = senderAttachAttemptCount
        self.receiverAttachAttemptCount = receiverAttachAttemptCount
        self.senderLastAttemptedAddress = senderLastAttemptedAddress
        self.receiverLastAttemptedAddress = receiverLastAttemptedAddress
        self.senderAttachFailureReason = senderAttachFailureReason
        self.receiverAttachFailureReason = receiverAttachFailureReason
    }
}

public struct NDIWizardDiscoveryDebugSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let sdkBootstrapState: String
    public let configDirectory: String?
    public let configPath: String?
    public let sdkLoadedPath: String?
    public let sdkVersion: String?
    public let discoveryServers: [NDIWizardDiscoveryServerDebugRow]

    public init(
        generatedAt: Date = Date(),
        sdkBootstrapState: String = "uninitialized",
        configDirectory: String? = nil,
        configPath: String? = nil,
        sdkLoadedPath: String? = nil,
        sdkVersion: String? = nil,
        discoveryServers: [NDIWizardDiscoveryServerDebugRow] = []
    ) {
        self.generatedAt = generatedAt
        self.sdkBootstrapState = sdkBootstrapState
        self.configDirectory = configDirectory
        self.configPath = configPath
        self.sdkLoadedPath = sdkLoadedPath
        self.sdkVersion = sdkVersion
        self.discoveryServers = discoveryServers
    }
}

public struct NDINetworkTrafficDelta: Sendable, Identifiable, Equatable {
    public let id: String
    public let interfaceBSDName: String
    public let rxPacketsDelta: Int64
    public let txPacketsDelta: Int64
    public let isSelected: Bool

    public var totalPacketsDelta: Int64 {
        rxPacketsDelta + txPacketsDelta
    }

    public init(
        id: String,
        interfaceBSDName: String,
        rxPacketsDelta: Int64,
        txPacketsDelta: Int64,
        isSelected: Bool
    ) {
        self.id = id
        self.interfaceBSDName = interfaceBSDName
        self.rxPacketsDelta = rxPacketsDelta
        self.txPacketsDelta = txPacketsDelta
        self.isSelected = isSelected
    }
}

public struct NDIWizardTrafficProbeSnapshot: Sendable, Equatable {
    public let startedAt: Date
    public let finishedAt: Date
    public let durationSeconds: Double
    public let state: NDIWizardTrafficProbeState
    public let selectedInterface: NDINetworkTrafficDelta?
    public let nonSelectedInterfaces: [NDINetworkTrafficDelta]
    public let notes: [String]

    public init(
        startedAt: Date = Date(),
        finishedAt: Date = Date(),
        durationSeconds: Double = 10,
        state: NDIWizardTrafficProbeState = .notRun,
        selectedInterface: NDINetworkTrafficDelta? = nil,
        nonSelectedInterfaces: [NDINetworkTrafficDelta] = [],
        notes: [String] = []
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
        self.state = state
        self.selectedInterface = selectedInterface
        self.nonSelectedInterfaces = nonSelectedInterfaces
        self.notes = notes
    }

    public var checkState: NDIWizardCheckState {
        switch state {
        case .selectedInterfaceTrafficObserved:
            return .passed
        case .notRun, .noTrafficObserved, .nonSelectedInterfaceTrafficObserved, .suspectedLeak:
            return .warning
        }
    }

    public var summary: String {
        switch state {
        case .notRun:
            return "No bounded traffic probe has been run yet."
        case .noTrafficObserved:
            return "No packet delta was observed on the selected NIC during the manual probe window."
        case .selectedInterfaceTrafficObserved:
            return "Observed traffic on the selected BETR NIC."
        case .nonSelectedInterfaceTrafficObserved:
            return "Traffic changed on non-selected interfaces, but not on the selected BETR NIC."
        case .suspectedLeak:
            return "Traffic changed on the selected BETR NIC and at least one non-selected interface during the bounded probe window."
        }
    }

    public var nextAction: String {
        switch state {
        case .notRun:
            return "Run the 10-second traffic probe while a known source is sending on the room network."
        case .noTrafficObserved:
            return "Verify the show NIC, Discovery Server, and the sending source."
        case .selectedInterfaceTrafficObserved:
            return "Confirm actual source visibility in BETR or NDI Discovery next."
        case .nonSelectedInterfaceTrafficObserved:
            return "Recheck the selected NIC and route pinning before trusting receive or send."
        case .suspectedLeak:
            return "Review live route pinning and selected-NIC ownership before going live."
        }
    }
}

public struct NDIReceiverTelemetryRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceName: String
    public let connectionCount: Int
    public let videoQueueDepth: Int
    public let audioQueueDepth: Int
    public let droppedVideoFrames: Int
    public let droppedAudioFrames: Int
    public let lastVideoPullDurationUs: Int64?
    public let lastAudioPullDurationUs: Int64?
    public let lastVideoPullIntervalUs: Int64?
    public let lastAudioRequestedSampleCount: Int?
    public let estimatedVideoLatencyMs: Double?
    public let estimatedAudioLatencyMs: Double?
    public let latestVideoTimestamp100ns: Int64?
    public let latestAudioTimestamp100ns: Int64?
    public let inputAVSkewMs: Double?
    public let videoRecent: Bool
    public let audioRecent: Bool
    public let audioRequired: Bool
    public let queueSane: Bool
    public let dropDeltaSane: Bool
    public let syncReady: Bool
    public let warmAttemptDroppedVideoFrames: Int
    public let warmAttemptDroppedAudioFrames: Int
    public let consumerCount: Int
    public let fanoutCount: Int
    public let gateReasons: [String]

    public init(
        id: String,
        sourceName: String,
        connectionCount: Int = 0,
        videoQueueDepth: Int = 0,
        audioQueueDepth: Int = 0,
        droppedVideoFrames: Int = 0,
        droppedAudioFrames: Int = 0,
        lastVideoPullDurationUs: Int64? = nil,
        lastAudioPullDurationUs: Int64? = nil,
        lastVideoPullIntervalUs: Int64? = nil,
        lastAudioRequestedSampleCount: Int? = nil,
        estimatedVideoLatencyMs: Double? = nil,
        estimatedAudioLatencyMs: Double? = nil,
        latestVideoTimestamp100ns: Int64? = nil,
        latestAudioTimestamp100ns: Int64? = nil,
        inputAVSkewMs: Double? = nil,
        videoRecent: Bool = false,
        audioRecent: Bool = false,
        audioRequired: Bool = true,
        queueSane: Bool = true,
        dropDeltaSane: Bool = true,
        syncReady: Bool = false,
        warmAttemptDroppedVideoFrames: Int = 0,
        warmAttemptDroppedAudioFrames: Int = 0,
        consumerCount: Int = 0,
        fanoutCount: Int = 0,
        gateReasons: [String] = []
    ) {
        self.id = id
        self.sourceName = sourceName
        self.connectionCount = connectionCount
        self.videoQueueDepth = videoQueueDepth
        self.audioQueueDepth = audioQueueDepth
        self.droppedVideoFrames = droppedVideoFrames
        self.droppedAudioFrames = droppedAudioFrames
        self.lastVideoPullDurationUs = lastVideoPullDurationUs
        self.lastAudioPullDurationUs = lastAudioPullDurationUs
        self.lastVideoPullIntervalUs = lastVideoPullIntervalUs
        self.lastAudioRequestedSampleCount = lastAudioRequestedSampleCount
        self.estimatedVideoLatencyMs = estimatedVideoLatencyMs
        self.estimatedAudioLatencyMs = estimatedAudioLatencyMs
        self.latestVideoTimestamp100ns = latestVideoTimestamp100ns
        self.latestAudioTimestamp100ns = latestAudioTimestamp100ns
        self.inputAVSkewMs = inputAVSkewMs
        self.videoRecent = videoRecent
        self.audioRecent = audioRecent
        self.audioRequired = audioRequired
        self.queueSane = queueSane
        self.dropDeltaSane = dropDeltaSane
        self.syncReady = syncReady
        self.warmAttemptDroppedVideoFrames = warmAttemptDroppedVideoFrames
        self.warmAttemptDroppedAudioFrames = warmAttemptDroppedAudioFrames
        self.consumerCount = consumerCount
        self.fanoutCount = fanoutCount
        self.gateReasons = gateReasons
    }
}

public struct NDIOutputTelemetryRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let senderConnectionCount: Int
    public let senderReady: Bool
    public let activeSourceID: String?
    public let previewSourceID: String?
    public let isSoloedLocally: Bool
    public let audioPresenceState: OutputAudioPresenceState
    public let leftLevel: Double
    public let rightLevel: Double
    public let videoQueueDepth: Int
    public let videoQueueAgeMs: Double?
    public let audioQueueDepthMs: Double?
    public let audioDriftDebtSamples: Int?
    public let senderRestartCount: Int
    public let videoTimestampDiscontinuityCount: Int
    public let audioTimestampDiscontinuityCount: Int
    public let activeSourceFanoutCount: Int
    public let previewSourceFanoutCount: Int
    public let activeSourceSyncReady: Bool
    public let previewSourceSyncReady: Bool
    public let activeSourceInputAVSkewMs: Double?
    public let previewSourceInputAVSkewMs: Double?
    public let activeSourceGateReasons: [String]
    public let previewSourceGateReasons: [String]

    public init(
        id: String,
        senderConnectionCount: Int = 0,
        senderReady: Bool = false,
        activeSourceID: String? = nil,
        previewSourceID: String? = nil,
        isSoloedLocally: Bool = false,
        audioPresenceState: OutputAudioPresenceState = .silent,
        leftLevel: Double = 0,
        rightLevel: Double = 0,
        videoQueueDepth: Int = 0,
        videoQueueAgeMs: Double? = nil,
        audioQueueDepthMs: Double? = nil,
        audioDriftDebtSamples: Int? = nil,
        senderRestartCount: Int = 0,
        videoTimestampDiscontinuityCount: Int = 0,
        audioTimestampDiscontinuityCount: Int = 0,
        activeSourceFanoutCount: Int = 0,
        previewSourceFanoutCount: Int = 0,
        activeSourceSyncReady: Bool = false,
        previewSourceSyncReady: Bool = false,
        activeSourceInputAVSkewMs: Double? = nil,
        previewSourceInputAVSkewMs: Double? = nil,
        activeSourceGateReasons: [String] = [],
        previewSourceGateReasons: [String] = []
    ) {
        self.id = id
        self.senderConnectionCount = senderConnectionCount
        self.senderReady = senderReady
        self.activeSourceID = activeSourceID
        self.previewSourceID = previewSourceID
        self.isSoloedLocally = isSoloedLocally
        self.audioPresenceState = audioPresenceState
        self.leftLevel = leftLevel
        self.rightLevel = rightLevel
        self.videoQueueDepth = videoQueueDepth
        self.videoQueueAgeMs = videoQueueAgeMs
        self.audioQueueDepthMs = audioQueueDepthMs
        self.audioDriftDebtSamples = audioDriftDebtSamples
        self.senderRestartCount = senderRestartCount
        self.videoTimestampDiscontinuityCount = videoTimestampDiscontinuityCount
        self.audioTimestampDiscontinuityCount = audioTimestampDiscontinuityCount
        self.activeSourceFanoutCount = activeSourceFanoutCount
        self.previewSourceFanoutCount = previewSourceFanoutCount
        self.activeSourceSyncReady = activeSourceSyncReady
        self.previewSourceSyncReady = previewSourceSyncReady
        self.activeSourceInputAVSkewMs = activeSourceInputAVSkewMs
        self.previewSourceInputAVSkewMs = previewSourceInputAVSkewMs
        self.activeSourceGateReasons = activeSourceGateReasons
        self.previewSourceGateReasons = previewSourceGateReasons
    }
}

public struct NDIWizardValidationSnapshot: Sendable, Equatable {
    public let checkedAt: Date
    public let agentInstanceID: String
    public let agentStartedAt: Date
    public let committedInterfaceBSDName: String?
    public let committedInterfaceCIDR: String?
    public let committedServiceName: String?
    public let committedHardwarePortLabel: String?
    public let resolvedRuntimeInterfaceBSDName: String?
    public let resolvedRuntimeInterfaceCIDR: String?
    public let resolvedRuntimeServiceName: String?
    public let resolvedRuntimeHardwarePortLabel: String?
    public let selectedInterfaceBSDName: String?
    public let selectedInterfaceCIDR: String?
    public let activeDiscoveryServerURL: String?
    public let runtimeConfigFingerprint: String?
    public let expectedConfigFingerprint: String?
    public let runtimeConfigDirectory: String?
    public let runtimeConfigPath: String?
    public let runtimeConfigMatchesCommittedProfile: Bool
    public let runtimeConfigMismatchReasons: [String]
    public let discoveryDetailState: NDIWizardDiscoveryState
    public let sdkBootstrapState: String
    public let sdkVersion: String?
    public let sdkLoadedPath: String?
    public let finderSourceVisibilityCount: Int
    public let listenerSenderVisibilityCount: Int
    public let localSourceVisibilityCount: Int
    public let remoteSourceVisibilityCount: Int
    public let senderListenerConnected: Bool
    public let receiverListenerConnected: Bool
    public let senderAdvertiserVisibilityCount: Int
    public let receiverAdvertiserVisibilityCount: Int
    public let sourceFilterActive: Bool
    public let sourceFilterValue: String?
    public let senderVisibilityCount: Int
    public let receiverVisibilityCount: Int
    public let multicastRouteSummary: String
    public let multicastRouteNextAction: String
    public let multicastRouteExists: Bool
    public let multicastRoutePinnedToCommittedInterface: Bool
    public let multicastRouteOwnerBSDName: String?
    public let multicastRouteSelectedBSDName: String?
    public let discoveryServers: [NDIWizardDiscoveryServerRow]
    public let receiverTelemetry: [NDIReceiverTelemetryRow]
    public let outputTelemetry: [NDIOutputTelemetryRow]
    public let trafficProbe: NDIWizardTrafficProbeSnapshot?
    public let lastBETRRestartAt: Date?

    public init(
        checkedAt: Date = Date(),
        agentInstanceID: String = "",
        agentStartedAt: Date = .distantPast,
        committedInterfaceBSDName: String? = nil,
        committedInterfaceCIDR: String? = nil,
        committedServiceName: String? = nil,
        committedHardwarePortLabel: String? = nil,
        resolvedRuntimeInterfaceBSDName: String? = nil,
        resolvedRuntimeInterfaceCIDR: String? = nil,
        resolvedRuntimeServiceName: String? = nil,
        resolvedRuntimeHardwarePortLabel: String? = nil,
        selectedInterfaceBSDName: String? = nil,
        selectedInterfaceCIDR: String? = nil,
        activeDiscoveryServerURL: String? = nil,
        runtimeConfigFingerprint: String? = nil,
        expectedConfigFingerprint: String? = nil,
        runtimeConfigDirectory: String? = nil,
        runtimeConfigPath: String? = nil,
        runtimeConfigMatchesCommittedProfile: Bool = false,
        runtimeConfigMismatchReasons: [String] = [],
        discoveryDetailState: NDIWizardDiscoveryState = .noDiscoveryConfigured,
        sdkBootstrapState: String = "uninitialized",
        sdkVersion: String? = nil,
        sdkLoadedPath: String? = nil,
        finderSourceVisibilityCount: Int = 0,
        listenerSenderVisibilityCount: Int = 0,
        localSourceVisibilityCount: Int = 0,
        remoteSourceVisibilityCount: Int = 0,
        senderListenerConnected: Bool = false,
        receiverListenerConnected: Bool = false,
        senderAdvertiserVisibilityCount: Int = 0,
        receiverAdvertiserVisibilityCount: Int = 0,
        sourceFilterActive: Bool = false,
        sourceFilterValue: String? = nil,
        senderVisibilityCount: Int = 0,
        receiverVisibilityCount: Int = 0,
        multicastRouteSummary: String = "Run Apply + Restart Now so BETR can install and verify the multicast route on the selected NIC.",
        multicastRouteNextAction: String = "Apply the profile and confirm route ownership again.",
        multicastRouteExists: Bool = false,
        multicastRoutePinnedToCommittedInterface: Bool = false,
        multicastRouteOwnerBSDName: String? = nil,
        multicastRouteSelectedBSDName: String? = nil,
        discoveryServers: [NDIWizardDiscoveryServerRow] = [],
        receiverTelemetry: [NDIReceiverTelemetryRow] = [],
        outputTelemetry: [NDIOutputTelemetryRow] = [],
        trafficProbe: NDIWizardTrafficProbeSnapshot? = nil,
        lastBETRRestartAt: Date? = nil
    ) {
        self.checkedAt = checkedAt
        self.agentInstanceID = agentInstanceID
        self.agentStartedAt = agentStartedAt
        self.committedInterfaceBSDName = committedInterfaceBSDName
        self.committedInterfaceCIDR = committedInterfaceCIDR
        self.committedServiceName = committedServiceName
        self.committedHardwarePortLabel = committedHardwarePortLabel
        self.resolvedRuntimeInterfaceBSDName = resolvedRuntimeInterfaceBSDName
        self.resolvedRuntimeInterfaceCIDR = resolvedRuntimeInterfaceCIDR
        self.resolvedRuntimeServiceName = resolvedRuntimeServiceName
        self.resolvedRuntimeHardwarePortLabel = resolvedRuntimeHardwarePortLabel
        self.selectedInterfaceBSDName = selectedInterfaceBSDName
        self.selectedInterfaceCIDR = selectedInterfaceCIDR
        self.activeDiscoveryServerURL = activeDiscoveryServerURL
        self.runtimeConfigFingerprint = runtimeConfigFingerprint
        self.expectedConfigFingerprint = expectedConfigFingerprint
        self.runtimeConfigDirectory = runtimeConfigDirectory
        self.runtimeConfigPath = runtimeConfigPath
        self.runtimeConfigMatchesCommittedProfile = runtimeConfigMatchesCommittedProfile
        self.runtimeConfigMismatchReasons = runtimeConfigMismatchReasons
        self.discoveryDetailState = discoveryDetailState
        self.sdkBootstrapState = sdkBootstrapState
        self.sdkVersion = sdkVersion
        self.sdkLoadedPath = sdkLoadedPath
        self.finderSourceVisibilityCount = finderSourceVisibilityCount
        self.listenerSenderVisibilityCount = listenerSenderVisibilityCount
        self.localSourceVisibilityCount = localSourceVisibilityCount
        self.remoteSourceVisibilityCount = remoteSourceVisibilityCount
        self.senderListenerConnected = senderListenerConnected
        self.receiverListenerConnected = receiverListenerConnected
        self.senderAdvertiserVisibilityCount = senderAdvertiserVisibilityCount
        self.receiverAdvertiserVisibilityCount = receiverAdvertiserVisibilityCount
        self.sourceFilterActive = sourceFilterActive
        self.sourceFilterValue = sourceFilterValue
        self.senderVisibilityCount = senderVisibilityCount
        self.receiverVisibilityCount = receiverVisibilityCount
        self.multicastRouteSummary = multicastRouteSummary
        self.multicastRouteNextAction = multicastRouteNextAction
        self.multicastRouteExists = multicastRouteExists
        self.multicastRoutePinnedToCommittedInterface = multicastRoutePinnedToCommittedInterface
        self.multicastRouteOwnerBSDName = multicastRouteOwnerBSDName
        self.multicastRouteSelectedBSDName = multicastRouteSelectedBSDName
        self.discoveryServers = discoveryServers
        self.receiverTelemetry = receiverTelemetry
        self.outputTelemetry = outputTelemetry
        self.trafficProbe = trafficProbe
        self.lastBETRRestartAt = lastBETRRestartAt
    }

    public var totalReceiveConnectionCount: Int {
        receiverTelemetry.reduce(0) { $0 + $1.connectionCount }
    }

    public var totalDroppedVideoFrames: Int {
        receiverTelemetry.reduce(0) { $0 + $1.droppedVideoFrames }
    }

    public var worstCurrentQueueDepth: Int {
        let receiverDepth = receiverTelemetry.map { max($0.videoQueueDepth, $0.audioQueueDepth) }.max() ?? 0
        let outputDepth = outputTelemetry.map(\.videoQueueDepth).max() ?? 0
        return max(receiverDepth, outputDepth)
    }

    public var worstEstimatedLatencyMs: Double? {
        let receiverLatency = receiverTelemetry.compactMap(\.estimatedVideoLatencyMs).max()
        let outputLatency = outputTelemetry.compactMap(\.videoQueueAgeMs).max()
        switch (receiverLatency, outputLatency) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    public var latencyBucketLabel: String {
        guard let worstEstimatedLatencyMs else { return "n/a" }
        if worstEstimatedLatencyMs < 16.7 { return "<1f" }
        if worstEstimatedLatencyMs < 33.4 { return "1-2f" }
        if worstEstimatedLatencyMs < 50 { return "2-3f" }
        return ">3f"
    }

    public func outputTelemetry(for outputID: String) -> NDIOutputTelemetryRow? {
        outputTelemetry.first(where: { $0.id == outputID })
    }

    public func receiverTelemetry(for sourceID: String?) -> NDIReceiverTelemetryRow? {
        guard let sourceID else { return nil }
        return receiverTelemetry.first(where: { $0.id == sourceID })
    }

    public var discoveryState: NDIWizardCheckState {
        switch discoveryDetailState {
        case .visible:
            return .passed
        case .noDiscoveryConfigured:
            return .warning
        case .error:
            return .blocked
        case .waiting, .connected:
            return .warning
        }
    }

    public var discoverySummary: String {
        switch discoveryDetailState {
        case .noDiscoveryConfigured:
            return "No Discovery Server is configured for the current runtime path."
        case .error:
            return "BETR could not create a live Discovery Server listener from the committed SDK configuration."
        case .waiting:
            return "Discovery listeners exist, but the SDK has not reported a connected Discovery Server yet."
        case .connected:
            return "Discovery listeners are connected to the Discovery Server, but no remote source catalog is visible yet."
        case .visible:
            return "Discovery is working and remote source visibility is present."
        }
    }

    public var discoveryNextAction: String {
        let hostApplyLooksSettled = runtimeConfigMatchesCommittedProfile && multicastRoutePinnedToCommittedInterface

        switch discoveryDetailState {
        case .noDiscoveryConfigured:
            return "Add the room Discovery Server address and apply the BETR profile again."
        case .error:
            if hostApplyLooksSettled {
                return "The BETR host profile is already committed. Stay focused on the Discovery Server endpoint and SDK listener creation instead of applying again."
            }
            return "Restart BETR on the committed profile once, then treat any repeat failure as SDK listener setup trouble."
        case .waiting:
            if hostApplyLooksSettled {
                return "The BETR host profile is already in place. Leave Apply + Restart alone and watch the SDK listener state on the committed NIC."
            }
            return "Give BETR a clean apply-and-relaunch cycle, then refresh validation again."
        case .connected:
            return "Discovery is connected. Check whether remote sources are actively publishing into the room catalog."
        case .visible:
            return "Discovery is live. Move to actual source receive and send verification next."
        }
    }

    public var configFingerprintMatches: Bool {
        guard let expectedConfigFingerprint else { return runtimeConfigFingerprint != nil }
        return runtimeConfigFingerprint == expectedConfigFingerprint
    }

    public var configState: NDIWizardCheckState {
        guard runtimeConfigDirectory != nil, runtimeConfigPath != nil else { return .blocked }
        guard runtimeConfigMatchesCommittedProfile else { return .blocked }
        guard let runtimeConfigFingerprint else { return .blocked }
        guard let expectedConfigFingerprint else { return .passed }
        return runtimeConfigFingerprint == expectedConfigFingerprint ? .passed : .warning
    }

    public var configSummary: String {
        guard let runtimeConfigDirectory, let runtimeConfigPath else {
            return "BETR has not reported the active runtime config directory and file path yet."
        }
        guard runtimeConfigMatchesCommittedProfile else {
            if runtimeConfigMismatchReasons.isEmpty {
                return "BETR is not consuming a runtime config that matches the committed host profile."
            }
            return "BETR runtime config does not match the committed host profile: \(runtimeConfigMismatchReasons.joined(separator: " | "))."
        }
        guard let expectedConfigFingerprint else {
            return "BETR is booted from \(runtimeConfigDirectory) and parsed \(runtimeConfigPath). No post-apply fingerprint is waiting for verification."
        }
        guard let runtimeConfigFingerprint else {
            return "BETR parsed the committed config at \(runtimeConfigPath), but did not report a runtime fingerprint yet."
        }
        if runtimeConfigFingerprint == expectedConfigFingerprint {
            return "BETR is booted from \(runtimeConfigDirectory) and the parsed runtime config matches the committed host profile."
        }
        return "BETR parsed the committed runtime config at \(runtimeConfigPath), but the reported runtime fingerprint \(runtimeConfigFingerprint) does not match the expected committed fingerprint \(expectedConfigFingerprint)."
    }

    public var multicastRouteState: NDIWizardCheckState {
        if multicastRoutePinnedToCommittedInterface {
            return .passed
        }
        if multicastRouteExists {
            return .warning
        }
        return .blocked
    }

    public var remoteHostProofReady: Bool {
        let resolvedMatchesCommitted = resolvedRuntimeInterfaceBSDName == nil
            || committedInterfaceBSDName == nil
            || resolvedRuntimeInterfaceBSDName == committedInterfaceBSDName
        return configState == .passed
            && multicastRoutePinnedToCommittedInterface
            && resolvedMatchesCommitted
    }

    public var remoteHostProofSummary: String {
        let committed = committedInterfaceBSDName ?? committedServiceName ?? "unknown"
        let resolved = resolvedRuntimeInterfaceBSDName ?? resolvedRuntimeServiceName ?? "unknown"
        let routeOwner = multicastRouteOwnerBSDName ?? "unknown"
        return "Committed NIC \(committed), runtime NIC \(resolved), multicast route owner \(routeOwner)."
    }

    public var sourceCatalogSummary: String {
        if sourceFilterActive, let sourceFilterValue {
            return "Catalog narrowed by source filter `\(sourceFilterValue)`."
        }
        if remoteSourceVisibilityCount == 0, localSourceVisibilityCount > 0 {
            let noun = localSourceVisibilityCount == 1 ? "source is" : "sources are"
            return "Only \(localSourceVisibilityCount) local BETR \(noun) visible. Finder sees \(finderSourceVisibilityCount); sender listener sees \(listenerSenderVisibilityCount)."
        }
        return "Finder sees \(finderSourceVisibilityCount) sources; sender listener sees \(listenerSenderVisibilityCount)."
    }

    public var overallReady: Bool {
        configState == .passed
            && discoveryDetailState == .visible
            && multicastRoutePinnedToCommittedInterface
    }
}

public struct PresentationWorkspaceDraft: Codable, Sendable, Equatable {
    public var selectedSlotID: String?
    public var filePath: String
    public var appName: String
    public var startSlide: Int

    public init(
        selectedSlotID: String? = nil,
        filePath: String = "",
        appName: String = "PowerPoint",
        startSlide: Int = 1
    ) {
        self.selectedSlotID = selectedSlotID
        self.filePath = filePath
        self.appName = appName
        self.startSlide = max(1, startSlide)
    }
}

public struct TimerWorkspaceDraft: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case durationMinutes
        case endTime
        case showPresenter
        case showProgram
        case outputEnabled
    }

    public var mode: SimpleTimerState.Mode
    public var durationMinutes: Int
    public var endTime: Date
    public var showPresenter: Bool
    public var showProgram: Bool
    public var outputEnabled: Bool

    public init(
        mode: SimpleTimerState.Mode = .duration,
        durationMinutes: Int = 10,
        endTime: Date = Date().addingTimeInterval(10 * 60),
        showPresenter: Bool = true,
        showProgram: Bool = false,
        outputEnabled: Bool = false
    ) {
        self.mode = mode
        self.durationMinutes = max(1, durationMinutes)
        self.endTime = endTime
        self.showPresenter = showPresenter
        self.showProgram = showProgram
        self.outputEnabled = outputEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(SimpleTimerState.Mode.self, forKey: .mode) ?? .duration
        durationMinutes = max(1, try container.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 10)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
            ?? Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
        showPresenter = try container.decodeIfPresent(Bool.self, forKey: .showPresenter) ?? true
        showProgram = try container.decodeIfPresent(Bool.self, forKey: .showProgram) ?? false
        outputEnabled = try container.decodeIfPresent(Bool.self, forKey: .outputEnabled) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(showPresenter, forKey: .showPresenter)
        try container.encode(showProgram, forKey: .showProgram)
        try container.encode(outputEnabled, forKey: .outputEnabled)
    }

    public var visibleSurfaces: [TimerVisibilitySurface] {
        var surfaces: [TimerVisibilitySurface] = []
        if showPresenter {
            surfaces.append(.presenter)
        }
        if showProgram {
            surfaces.append(.program)
        }
        return surfaces
    }
}

public struct FeatureShellState: Sendable, Equatable {
    public let title: String
    public let rootDirectory: String
    public var workspace: RouterWorkspaceSnapshot
    public var hostWizardSummary: String
    public var migrationSummary: String?
    public var capacity: RoomControlCapacitySnapshot?

    public init(
        title: String,
        rootDirectory: String,
        workspace: RouterWorkspaceSnapshot,
        hostWizardSummary: String = "BETR-only",
        migrationSummary: String? = nil,
        capacity: RoomControlCapacitySnapshot? = nil
    ) {
        self.title = title
        self.rootDirectory = rootDirectory
        self.workspace = workspace
        self.hostWizardSummary = hostWizardSummary
        self.migrationSummary = migrationSummary
        self.capacity = capacity
    }
}
