// RoutingDomain — output routing, workspace controller, source→slot assignment.

import Foundation
import RoomControlXPCContracts

// MARK: - Slot Assignment

/// Routing assignment state for an output slot.
public enum SlotAssignment: Sendable {
    case empty
    case assigned(sourceID: String)
}

// MARK: - Warm Badge State

/// Visual warm state for a source badge in the UI.
public enum WarmBadge: Sendable, Equatable {
    case cold
    case warming
    case warm
    case failed

    public init(from warmState: SourceWarmState) {
        switch warmState {
        case .cold, .cooling: self = .cold
        case .warming: self = .warming
        case .warm: self = .warm
        case .failed: self = .failed
        }
    }
}

// MARK: - Routing Workspace Snapshot

/// Immutable snapshot of the routing workspace state for UI consumption.
public struct RoutingWorkspaceSnapshot: Sendable {
    public let sources: [SourceDescriptor]
    public let warmBadges: [String: WarmBadge]
    public let programSourceID: String?
    public let previewSourceID: String?
    public let meterSnapshots: [String: MeterSnapshot]
    public let healthSnapshot: AgentHealthSnapshot?

    public init(
        sources: [SourceDescriptor] = [],
        warmBadges: [String: WarmBadge] = [:],
        programSourceID: String? = nil,
        previewSourceID: String? = nil,
        meterSnapshots: [String: MeterSnapshot] = [:],
        healthSnapshot: AgentHealthSnapshot? = nil
    ) {
        self.sources = sources
        self.warmBadges = warmBadges
        self.programSourceID = programSourceID
        self.previewSourceID = previewSourceID
        self.meterSnapshots = meterSnapshots
        self.healthSnapshot = healthSnapshot
    }
}
