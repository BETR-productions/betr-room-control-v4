// ShellViewState — lightweight view-model types for the operator shell.
// Backed by RoutingDomain / PersistenceDomain at runtime; these types
// decouple FeatureUI from store implementation details.
//
// Routing actions dispatch XPC commands via CoreAgentClient and update
// local UI state optimistically. Incoming XPC events reconcile truth.

import ClipPlayerDomain
import Foundation
import IOSurface
import PresentationDomain
import SwiftUI
import RoutingDomain
import RoomControlXPCContracts
import TimerDomain
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
    public var isAudioMuted: Bool
    public var isSoloed: Bool
    public var senderName: String

    public init(
        id: String,
        name: String,
        slots: [OutputSlotState] = [],
        programSlotID: String? = nil,
        previewSlotID: String? = nil,
        listenerCount: Int = 0,
        isAudioMuted: Bool = false,
        isSoloed: Bool = false,
        senderName: String = ""
    ) {
        self.id = id
        self.name = name
        self.slots = slots
        self.programSlotID = programSlotID
        self.previewSlotID = previewSlotID
        self.listenerCount = listenerCount
        self.isAudioMuted = isAudioMuted
        self.isSoloed = isSoloed
        self.senderName = senderName
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

// MARK: - Output Create Config

/// Configuration for creating a new output via XPC.
struct OutputCreateConfig: Codable, Sendable {
    let name: String
    let slotCount: Int
}

// MARK: - Shell State

@MainActor
public final class ShellViewState: ObservableObject {
    private static let log = Logger(subsystem: "com.betr.room-control", category: "ShellViewState")

    /// Maximum number of concurrent outputs (capacity gating — Task 115).
    public static let maxOutputs = 5

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

    // MARK: - Sub-Stores (Task 131: column wiring)

    /// Clip player playlist store — injected when ClipPlayerProducer is available.
    @Published public var clipPlayerStore: ClipPlayerPlaylistStore?
    /// Timer control store — injected when TimerProducer is available.
    @Published public var timerStore: TimerControlStore?
    /// Presentation launcher store — created immediately (no external dependency).
    @Published public var presentationStore: PresentationLauncherStore = PresentationLauncherStore()

    /// Currently focused output card for keyboard navigation (Task 130).
    @Published public var focusedCardID: String?

    /// Task 135: Shared presentation store — drives launcher panel and presenter view panel.
    public let presentationStore = PresentationLauncherStore()

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

        case .switchCompleted(let outputID, _, let toSourceID):
            updateProgramIndicator(outputID: outputID, sourceID: toSourceID)

        case .switchAborted(let outputID, let toSourceID, let reason):
            Self.log.warning("Switch aborted on output \(outputID) to \(toSourceID): \(reason)")

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

        case .outputCreated(let descriptorData):
            Self.log.info("Output created event received")
            // TODO: Decode descriptorData and reconcile with local cards
            _ = descriptorData

        case .outputRemoved(let outputID):
            Self.log.info("Output removed event: \(outputID)")
            cards.removeAll { $0.id == outputID }
            capacity.configuredOutputs = cards.count

        case .outputRenamed(let outputID, let newName):
            if let idx = cards.firstIndex(where: { $0.id == outputID }) {
                cards[idx].name = newName
                cards[idx].senderName = "BETR \(newName)"
            }

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

    private func updateProgramIndicator(outputID: String, sourceID: String) {
        guard let cardIdx = cards.firstIndex(where: { $0.id == outputID }) else {
            Self.log.warning("switchCompleted for unknown output \(outputID)")
            return
        }
        for slot in cards[cardIdx].slots {
            if slot.sourceID == sourceID {
                cards[cardIdx].programSlotID = slot.id
                Self.log.info("Program indicator updated: output=\(outputID) slot=\(slot.id)")
                return
            }
        }
    }

    // MARK: - Per-Output Routing Actions (Tasks 123, 124)

    /// Set preview slot on a specific output — dispatches per-output setPreview XPC.
    public func setPreviewSlot(_ cardID: String, slotID: String?) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        // PVW != PGM enforced (Task 124)
        if let slotID, slotID == cards[idx].programSlotID { return }
        cards[idx].previewSlotID = slotID

        if let slotID {
            Task {
                guard let coreAgent else { return }
                let success = await coreAgent.setPreview(outputID: cardID, slotID: slotID)
                if !success {
                    Self.log.error("setPreview XPC failed: output=\(cardID) slot=\(slotID)")
                }
            }
        }
    }

    /// Take program slot on a specific output — dispatches per-output setProgram XPC.
    /// Each output is independent (Task 124).
    public func takeProgramSlot(_ cardID: String, slotID: String) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        guard cards[idx].slots.contains(where: { $0.id == slotID && $0.sourceID != nil }) else { return }

        // Optimistic UI update for responsive feel.
        cards[idx].programSlotID = slotID
        // Clear preview if it was this slot (PVW != PGM)
        if cards[idx].previewSlotID == slotID {
            cards[idx].previewSlotID = nil
        }

        let transition = TransitionConfig(kind: currentTransitionKind)
        Task {
            guard let coreAgent else { return }
            let success = await coreAgent.setProgram(outputID: cardID, slotID: slotID, transition: transition)
            if !success {
                Self.log.error("setProgram XPC failed: output=\(cardID) slot=\(slotID)")
                await MainActor.run {
                    if self.cards[idx].programSlotID == slotID {
                        self.cards[idx].programSlotID = nil
                    }
                }
            }
        }
    }

    /// Assign a source to a slot — dispatches assignSlotSource XPC (Task 123).
    public func assignSource(_ sourceID: String, to cardID: String, slotID: String) {
        guard let cardIdx = cards.firstIndex(where: { $0.id == cardID }),
              let slotIdx = cards[cardIdx].slots.firstIndex(where: { $0.id == slotID }) else { return }
        let source = sources.first(where: { $0.id == sourceID })

        // Optimistic local update
        cards[cardIdx].slots[slotIdx].sourceID = sourceID
        cards[cardIdx].slots[slotIdx].displayName = source?.name
        cards[cardIdx].slots[slotIdx].isAvailable = source?.isOnline ?? false
        cards[cardIdx].slots[slotIdx].warmBadge = source?.warmBadge ?? .cold

        Task {
            guard let coreAgent else { return }
            let success = await coreAgent.assignSlotSource(
                outputID: cardID,
                slotID: slotID,
                sourceID: sourceID,
                sourceNameSnapshot: source?.name
            )
            if !success {
                Self.log.error("assignSlotSource XPC failed: output=\(cardID) slot=\(slotID)")
            }
        }
    }

    /// Clear a slot on an output — dispatches clearSlot XPC (Task 123).
    public func clearSlot(_ cardID: String, slotID: String) {
        guard let cardIdx = cards.firstIndex(where: { $0.id == cardID }),
              let slotIdx = cards[cardIdx].slots.firstIndex(where: { $0.id == slotID }) else { return }
        cards[cardIdx].slots[slotIdx].sourceID = nil
        cards[cardIdx].slots[slotIdx].displayName = nil
        cards[cardIdx].slots[slotIdx].isAvailable = true
        cards[cardIdx].slots[slotIdx].warmBadge = .cold

        Task {
            guard let coreAgent else { return }
            let success = await coreAgent.clearSlot(outputID: cardID, slotID: slotID)
            if !success {
                Self.log.error("clearSlot XPC failed: output=\(cardID) slot=\(slotID)")
            }
        }
    }

    public func commitLayout(leading: Double, center: Double) {
        leadingColumnWidth = leading
        centerColumnWidth = center
    }

    // MARK: - Output Management (Tasks 121, 122, 128)

    /// Create a new output card with 6 empty slots.
    /// Returns the new card ID, or nil if at capacity.
    @discardableResult
    public func addOutput(name: String? = nil) -> String? {
        guard cards.count < Self.maxOutputs else { return nil }
        let outputNumber = cards.count + 1
        let outputName = name ?? "Output \(outputNumber)"
        let slots = (1...6).map { OutputSlotState(id: "\($0)") }
        let card = OutputCardState(
            id: UUID().uuidString,
            name: outputName,
            slots: slots,
            senderName: "BETR \(outputName)"
        )
        cards.append(card)
        focusedCardID = card.id
        capacity.configuredOutputs = cards.count

        // Dispatch XPC createOutput
        let outputConfig = OutputCreateConfig(name: outputName, slotCount: 6)
        if let configData = try? JSONEncoder().encode(outputConfig) {
            Task {
                guard let coreAgent else { return }
                _ = await coreAgent.createOutput(configData: configData)
            }
        }

        Self.log.info("Output added: \(outputName) (\(card.id))")
        return card.id
    }

    /// Remove an output card by ID.
    public func removeOutput(_ cardID: String) {
        cards.removeAll { $0.id == cardID }
        if focusedCardID == cardID {
            focusedCardID = cards.first?.id
        }
        capacity.configuredOutputs = cards.count

        Task {
            guard let coreAgent else { return }
            _ = await coreAgent.removeOutput(outputID: cardID)
        }

        Self.log.info("Output removed: \(cardID)")
    }

    /// Rename an output card.
    public func renameOutput(_ cardID: String, name: String) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx].name = name
        cards[idx].senderName = "BETR \(name)"

        Task {
            guard let coreAgent else { return }
            _ = await coreAgent.renameOutput(outputID: cardID, newName: name)
        }
    }

    /// Toggle audio mute on an output card.
    public func toggleMute(_ cardID: String) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx].isAudioMuted.toggle()
        let muted = cards[idx].isAudioMuted

        Task {
            guard let coreAgent else { return }
            _ = await coreAgent.setOutputMuted(outputID: cardID, muted: muted)
        }
    }

    /// Toggle solo on an output card (Task 140).
    /// Solo routes this output to cue/monitor. Only one output can be soloed at a time.
    public func toggleSolo(_ cardID: String) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        let wasSoloed = cards[idx].isSoloed

        // Clear all solos first (exclusive solo)
        for i in cards.indices {
            cards[i].isSoloed = false
        }

        // Toggle the target
        if !wasSoloed {
            cards[idx].isSoloed = true
        }
    }

    /// Create the default "Output 1" if no outputs exist (Task 128).
    /// Called on first launch or when persisted topology is empty.
    public func ensureDefaultOutput() {
        guard cards.isEmpty else { return }
        addOutput(name: "Output 1")
        Self.log.info("Default output created on first launch")
    }

    // MARK: - Focus Navigation (Task 130)

    /// Move focus to the next output card (Tab).
    public func focusNextCard() {
        guard !cards.isEmpty else { return }
        if let currentID = focusedCardID,
           let currentIdx = cards.firstIndex(where: { $0.id == currentID }) {
            let nextIdx = (currentIdx + 1) % cards.count
            focusedCardID = cards[nextIdx].id
        } else {
            focusedCardID = cards.first?.id
        }
    }

    /// Move focus to the previous output card (Shift+Tab).
    public func focusPreviousCard() {
        guard !cards.isEmpty else { return }
        if let currentID = focusedCardID,
           let currentIdx = cards.firstIndex(where: { $0.id == currentID }) {
            let prevIdx = (currentIdx - 1 + cards.count) % cards.count
            focusedCardID = cards[prevIdx].id
        } else {
            focusedCardID = cards.last?.id
        }
    }
}
