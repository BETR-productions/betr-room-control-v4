// RoutingDomain — output routing, workspace controller, source→slot assignment.

import Foundation

/// Routing assignment state for an output slot.
public enum SlotAssignment: Sendable {
    case empty
    case assigned(sourceID: String)
}
