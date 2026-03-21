// ShellViewState — lightweight view-model types for the operator shell.
// Backed by RoutingDomain / PersistenceDomain at runtime; these types
// decouple FeatureUI from store implementation details.
//
// Routing actions dispatch XPC commands via CoreAgentClient and update
// local UI state optimistically. Incoming XPC events reconcile truth.

import Foundation
import IOSurface
import SwiftUI
import RoutingDomain
import RoomControlXPCContracts
import os

// MARK: - Operation Modes

public enum OperationMode: String, Sendable {
    case rehearsal
    case live
}

public enum PlaybackMode: String, Sendable {
    case manual
    case schedule
}

// MARK: - Output Slot

public struct OutputSlotState: Identifiable, Sendable {
    public let id: String
    public var sourceID: String?
    public var displayName: String?
    public var isAvailable: Bool
    public var warmBadge: WarmBadge

    public init(id: String, sourceID: String? = nil, displayName: String? = nil, isAvailable: Bool = true, warmBadge: WarmBadge = .cold) {
        self.id = id
        self.sourceID = sourceID
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.warmBadge = warmBadge
    }
}

// MARK: - Output Card

public struct OutputCardState: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var slots: [OutputSlotState]
    public var programSlotID: String?
    public var previewSlotID: String?
    public var listenerCount: Int

    public init(
        id: String,
        name: String,
        slots: [OutputSlotState] = [],
        programSlotID: String? = nil,
        previewSlotID: String? = nil,
        listenerCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.slots = slots
        self.programSlotID = programSlotID
        self.previewSlotID = previewSlotID
        self.listenerCount = listenerCount
    }
}

// MARK: - Source

public struct SourceState: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var isOnline: Bool
    public var warmBadge: WarmBadge

    public init(id: String, name: String, isOnline: Bool = true, warmBadge: WarmBadge = .cold) {
        self.id = id
        self.name = name
        self.isOnline = isOnline
        self.warmBadge = warmBadge
    }
}

// MARK: - Capacity

public struct CapacitySnapshot: Sendable {
    public var configuredOutputs: Int
    public var discoveredSources: Int
    public var fallbackOutputs: Int
    public var activeRx: Int
    public var activeTx: Int
    public var cpuPercent: Double?
    public var nicInboundMbps: Double?
    public var nicOutboundMbps: Double?
    public var nicUtilizationPercent: Double?
    public var estimatedGPUPressure: Double?
    public var remainingHeadroom: Int?
    public var sdkVersion: String?

    public init(
        configuredOutputs: Int = 0,
        discoveredSources: Int = 0,
        fallbackOutputs: Int = 0,
        activeRx: Int = 0,
        activeTx: Int = 0,
        cpuPercent: Double? = nil,
        nicInboundMbps: Double? = nil,
        nicOutboundMbps: Double? = nil,
        nicUtilizationPercent: Double? = nil,
        estimatedGPUPressure: Double? = nil,
        remainingHeadroom: Int? = nil,
        sdkVersion: String? = nil
    ) {
        self.configuredOutputs = configuredOutputs
        self.discoveredSources = discoveredSources
        self.fallbackOutputs = fallbackOutputs
        self.activeRx = activeRx
        self.activeTx = activeTx
        self.cpuPercent = cpuPercent
        self.nicInboundMbps = nicInboundMbps
        self.nicOutboundMbps = nicOutboundMbps
        self.nicUtilizationPercent = nicUtilizationPercent
        self.estimatedGPUPressure = estimatedGPUPressure
        self.remainingHeadroom = remainingHeadroom
        self.sdkVersion = sdkVersion
    }
}

// MARK: - Shell State

@MainActor
public final class ShellViewState: ObservableObject {
    private static let log = Logger(subsystem: "com.betr.room-control", category: "ShellViewState")

    @Published public var operationMode: OperationMode = .rehearsal
    @Published public var playbackMode: PlaybackMode = .manual
    @Published public var cards: [OutputCardState] = []
    @Published public var sources: [SourceState] = []
    @Published public var capacity: CapacitySnapshot = CapacitySnapshot()
    @Published public var leadingColumnWidth: Double = 340
    @Published public var centerColumnWidth: Double = 340
    @Published public var showSettings: Bool = false
    @Published public var currentTransitionKind: TransitionKind = .cut
    @Published public var meterSnapshots: [String: MeterSnapshot] = [:]
    @Published public var healthSnapshot: AgentHealthSnapshot?

    /// Render feeds for IOSurface thumbnails, keyed by sourceID.
    /// Each slot cell looks up its render feed by sourceID.
    public private(set) var thumbnailFeeds: [String: OutputTileRenderFeed] = [:]
    /// Monotonic sequence counter for thumbnail updates — triggers SwiftUI refresh.
    @Published public var thumbnailSequence: UInt64 = 0

    /// The XPC client for communicating with BETRCoreAgent.
    /// Injected at app startup via `bind(coreAgent:capacitySampler:)`.
    private var coreAgent: CoreAgentClient?
    private var capacitySampler: CapacitySampler?
    private var eventTask: Task<Void, Never>?
    private var capacityTask: Task<Void, Never>?

    public init() {}

    // MARK: - Binding

    /// Bind the XPC client and capacity sampler. Call once from app startup.
    /// Starts the event loop and capacity sampling — never polls.
    public func bind(coreAgent: CoreAgentClient, capacitySampler: CapacitySampler) {
        self.coreAgent = coreAgent
        self.capacitySampler = capacitySampler
        startEventLoop()
        startCapacitySampling()
    }

    /// Tear down event loops on app termination.
    public func unbind() {
        eventTask?.cancel()
        eventTask = nil
        capacityTask?.cancel()
        capacityTask = nil
    }

    // MARK: - Event Loop (never polls — driven by XPC push)

    private func startEventLoop() {
        guard let coreAgent else { return }
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            for await event in coreAgent.events {
                guard !Task.isCancelled else { break }
                self?.handleCoreEvent(event)
            }
        }
    }

    private func handleCoreEvent(_ event: CoreAgentEvent) {
        switch event {
        case .sourcesChanged(let descriptors):
            applySources(descriptors)

        case .warmStateChanged(let sourceID, let state):
            updateWarmBadge(sourceID: sourceID, state: state)

        case .switchCompleted(_, let toSourceID):
            updateProgramIndicator(sourceID: toSourceID)

        case .switchAborted(let toSourceID, let reason):
            Self.log.warning("Switch aborted to \(toSourceID): \(reason)")

        case .metersUpdated(let snapshots):
            for snapshot in snapshots {
                meterSnapshots[snapshot.sourceID] = snapshot
            }

        case .healthUpdated(let snapshot):
            healthSnapshot = snapshot
            capacity.configuredOutputs = snapshot.outputActive ? 1 : 0
            capacity.activeRx = snapshot.activeSourceCount
            capacity.activeTx = snapshot.warmSourceCount

        case .capacityLevelChanged(_, let activeCount, _):
            capacity.activeRx = activeCount

        case .thumbnailReady(let sourceID, let surfaceID, let width, let height):
            updateThumbnail(sourceID: sourceID, surfaceID: surfaceID, width: width, height: height)

        case .connectionReady:
            Self.log.info("Core agent connection ready")
            Task { await requestInitialState() }

        case .connectionInterrupted:
            Self.log.warning("Core agent connection interrupted — waiting for reconnect")

        case .connectionInvalidated:
            Self.log.error("Core agent connection invalidated")
        }
    }

    /// Fetch initial state after XPC connection is established.
    private func requestInitialState() async {
        guard let coreAgent else { return }
        if let sources = await coreAgent.refreshSourceCatalog() {
            applySources(sources)
        }
        if let health = await coreAgent.requestHealthSnapshot() {
            healthSnapshot = health
        }
    }

    // MARK: - Capacity Sampling (1Hz)

    private func startCapacitySampling() {
        guard let capacitySampler else { return }
        capacityTask?.cancel()
        capacityTask = Task { @MainActor [weak self] in
            await capacitySampler.start()
            for await sample in capacitySampler.samples {
                guard !Task.isCancelled else { break }
                self?.applyCapacitySample(sample)
            }
        }
    }

    private func applyCapacitySample(_ sample: CapacitySample) {
        capacity.cpuPercent = sample.cpuPercent
        capacity.nicInboundMbps = sample.nicInboundMbps
        capacity.nicOutboundMbps = sample.nicOutboundMbps
        capacity.nicUtilizationPercent = sample.nicUtilizationPercent
        capacity.estimatedGPUPressure = sample.estimatedGPUPressure
        capacity.remainingHeadroom = sample.remainingHeadroom
    }

    // MARK: - Source State Application

    private func applySources(_ descriptors: [SourceDescriptor]) {
        sources = descriptors.map { descriptor in
            let existing = sources.first(where: { $0.id == descriptor.id })
            return SourceState(
                id: descriptor.id,
                name: descriptor.name,
                isOnline: true,
                warmBadge: existing?.warmBadge ?? .cold
            )
        }
        capacity.discoveredSources = sources.count

        // Update slot availability based on new source catalog
        for cardIdx in cards.indices {
            for slotIdx in cards[cardIdx].slots.indices {
                if let sourceID = cards[cardIdx].slots[slotIdx].sourceID {
                    let isOnline = sources.contains(where: { $0.id == sourceID })
                    cards[cardIdx].slots[slotIdx].isAvailable = isOnline
                    if let source = sources.first(where: { $0.id == sourceID }) {
                        cards[cardIdx].slots[slotIdx].displayName = source.name
                    }
                }
            }
        }
    }

    private func updateWarmBadge(sourceID: String, state: SourceWarmState) {
        let badge = WarmBadge(from: state)
        // Update source list
        if let idx = sources.firstIndex(where: { $0.id == sourceID }) {
            sources[idx].warmBadge = badge
        }
        // Update any slots referencing this source
        for cardIdx in cards.indices {
            for slotIdx in cards[cardIdx].slots.indices {
                if cards[cardIdx].slots[slotIdx].sourceID == sourceID {
                    cards[cardIdx].slots[slotIdx].warmBadge = badge
                }
            }
        }
    }

    private func updateThumbnail(sourceID: String, surfaceID: UInt32, width: Int, height: Int) {
        guard let surface = IOSurfaceLookup(surfaceID) else {
            Self.log.warning("thumbnailReady: IOSurface \(surfaceID) not found for source \(sourceID)")
            return
        }
        let feed = thumbnailFeeds[sourceID] ?? {
            let newFeed = OutputTileRenderFeed()
            thumbnailFeeds[sourceID] = newFeed
            return newFeed
        }()
        thumbnailSequence &+= 1
        feed.bind(surface: surface, sequence: thumbnailSequence)
    }

    private func updateProgramIndicator(sourceID: String) {
        // Find the card/slot with this source and update program indicator
        for cardIdx in cards.indices {
            for slot in cards[cardIdx].slots {
                if slot.sourceID == sourceID {
                    cards[cardIdx].programSlotID = slot.id
                    Self.log.info("Program indicator updated: card=\(self.cards[cardIdx].id) slot=\(slot.id)")
                    return
                }
            }
        }
    }

    // MARK: - Routing Actions (dispatch XPC commands)

    /// Set preview slot — dispatches setPreview XPC command.
    public func setPreviewSlot(_ cardID: String, slotID: String?) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx].previewSlotID = slotID

        // Dispatch XPC command if we have a source to preview
        if let slotID,
           let slot = cards[idx].slots.first(where: { $0.id == slotID }),
           let sourceID = slot.sourceID {
            Task {
                guard let coreAgent else { return }
                let success = await coreAgent.setPreview(sourceID: sourceID)
                if !success {
                    Self.log.error("setPreview XPC command failed for source \(sourceID)")
                }
            }
        }
    }

    /// Take program slot — dispatches setProgram XPC command with current transition.
    public func takeProgramSlot(_ cardID: String, slotID: String) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }

        // Find the source in the slot
        guard let slot = cards[idx].slots.first(where: { $0.id == slotID }),
              let sourceID = slot.sourceID else { return }

        // Optimistic UI update — set program immediately for responsive feel.
        // XPC switchCompleted event will reconcile truth.
        cards[idx].programSlotID = slotID

        // Dispatch XPC command
        let transition = TransitionConfig(kind: currentTransitionKind)
        Task {
            guard let coreAgent else { return }
            let success = await coreAgent.setProgram(sourceID: sourceID, transition: transition)
            if !success {
                Self.log.error("setProgram XPC command failed for source \(sourceID)")
                // Revert optimistic update on failure
                await MainActor.run {
                    if self.cards[idx].programSlotID == slotID {
                        self.cards[idx].programSlotID = nil
                    }
                }
            }
        }
    }

    public func assignSource(_ sourceID: String, to cardID: String, slotID: String) {
        guard let cardIdx = cards.firstIndex(where: { $0.id == cardID }),
              let slotIdx = cards[cardIdx].slots.firstIndex(where: { $0.id == slotID }) else { return }
        cards[cardIdx].slots[slotIdx].sourceID = sourceID
        let source = sources.first(where: { $0.id == sourceID })
        cards[cardIdx].slots[slotIdx].displayName = source?.name
        cards[cardIdx].slots[slotIdx].isAvailable = source?.isOnline ?? false
        cards[cardIdx].slots[slotIdx].warmBadge = source?.warmBadge ?? .cold
    }

    public func clearSlot(_ cardID: String, slotID: String) {
        guard let cardIdx = cards.firstIndex(where: { $0.id == cardID }),
              let slotIdx = cards[cardIdx].slots.firstIndex(where: { $0.id == slotID }) else { return }
        cards[cardIdx].slots[slotIdx].sourceID = nil
        cards[cardIdx].slots[slotIdx].displayName = nil
        cards[cardIdx].slots[slotIdx].isAvailable = true
        cards[cardIdx].slots[slotIdx].warmBadge = .cold
    }

    public func commitLayout(leading: Double, center: Double) {
        leadingColumnWidth = leading
        centerColumnWidth = center
    }
}
