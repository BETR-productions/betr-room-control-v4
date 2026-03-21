// PersistenceDomain — user preferences, session state, layout persistence.

import Foundation

/// Persisted column widths for three-column layout.
public struct PersistedLayout: Codable, Sendable {
    public var leadingWidth: Double
    public var centerWidth: Double

    public init(leadingWidth: Double = 340, centerWidth: Double = 340) {
        self.leadingWidth = leadingWidth
        self.centerWidth = centerWidth
    }
}
