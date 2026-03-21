// ShellViewState — lightweight view-model types for the operator shell.
// Backed by RoutingDomain / PersistenceDomain at runtime; these types
// decouple FeatureUI from store implementation details.

import Foundation
import SwiftUI

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

    public init(id: String, sourceID: String? = nil, displayName: String? = nil, isAvailable: Bool = true) {
        self.id = id
        self.sourceID = sourceID
        self.displayName = displayName
        self.isAvailable = isAvailable
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

    public init(id: String, name: String, isOnline: Bool = true) {
        self.id = id
        self.name = name
        self.isOnline = isOnline
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
        self.sdkVersion = sdkVersion
    }
}

// MARK: - Shell State

public final class ShellViewState: ObservableObject {
    @Published public var operationMode: OperationMode = .rehearsal
    @Published public var playbackMode: PlaybackMode = .manual
    @Published public var cards: [OutputCardState] = []
    @Published public var sources: [SourceState] = []
    @Published public var capacity: CapacitySnapshot = CapacitySnapshot()
    @Published public var leadingColumnWidth: Double = 340
    @Published public var centerColumnWidth: Double = 340
    @Published public var showSettings: Bool = false

    public init() {}

    // MARK: - Routing Actions

    public func setPreviewSlot(_ cardID: String, slotID: String?) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx].previewSlotID = slotID
    }

    public func takeProgramSlot(_ cardID: String, slotID: String) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx].programSlotID = slotID
    }

    public func assignSource(_ sourceID: String, to cardID: String, slotID: String) {
        guard let cardIdx = cards.firstIndex(where: { $0.id == cardID }),
              let slotIdx = cards[cardIdx].slots.firstIndex(where: { $0.id == slotID }) else { return }
        cards[cardIdx].slots[slotIdx].sourceID = sourceID
        let source = sources.first(where: { $0.id == sourceID })
        cards[cardIdx].slots[slotIdx].displayName = source?.name
        cards[cardIdx].slots[slotIdx].isAvailable = source?.isOnline ?? false
    }

    public func clearSlot(_ cardID: String, slotID: String) {
        guard let cardIdx = cards.firstIndex(where: { $0.id == cardID }),
              let slotIdx = cards[cardIdx].slots.firstIndex(where: { $0.id == slotID }) else { return }
        cards[cardIdx].slots[slotIdx].sourceID = nil
        cards[cardIdx].slots[slotIdx].displayName = nil
        cards[cardIdx].slots[slotIdx].isAvailable = true
    }

    public func commitLayout(leading: Double, center: Double) {
        leadingColumnWidth = leading
        centerColumnWidth = center
    }
}
