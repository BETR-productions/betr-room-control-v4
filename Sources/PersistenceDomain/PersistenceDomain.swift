// PersistenceDomain — user preferences, session state, layout persistence.
// Task 54: Clip player playlist persistence (encode [ClipItem] to JSON, restore on launch).
// Task 127: Output topology persistence (save/restore output cards, slot bindings, PVW/PGM).

import ClipPlayerDomain
import Foundation
import RoomControlXPCContracts
import TimerDomain

/// Persisted column widths for three-column layout.
public struct PersistedLayout: Codable, Sendable {
    public var leadingWidth: Double
    public var centerWidth: Double

    public init(leadingWidth: Double = 340, centerWidth: Double = 340) {
        self.leadingWidth = leadingWidth
        self.centerWidth = centerWidth
    }
}

// MARK: - Clip Player Playlist Persistence (Task 54)

/// Persisted clip player playlist state.
public struct PersistedClipPlaylist: Codable, Sendable {
    public var items: [ClipItem]
    public var playbackOrder: PlaybackOrder

    public init(items: [ClipItem] = [], playbackOrder: PlaybackOrder = .sequential) {
        self.items = items
        self.playbackOrder = playbackOrder
    }
}

/// Persisted timer configuration.
public struct PersistedTimerConfig: Codable, Sendable {
    public var mode: TimerMode
    public var durationSeconds: Int

    public init(
        mode: TimerMode = .duration(seconds: TimerConstants.defaultDurationSeconds),
        durationSeconds: Int = TimerConstants.defaultDurationSeconds
    ) {
        self.mode = mode
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Output Topology Persistence (Task 127)

/// Persisted source-to-slot binding within an output card.
public struct PersistedSlotBinding: Codable, Sendable, Equatable {
    public let slotID: String
    public var sourceID: String?
    public var displayName: String?

    public init(slotID: String, sourceID: String? = nil, displayName: String? = nil) {
        self.slotID = slotID
        self.sourceID = sourceID
        self.displayName = displayName
    }
}

/// Persisted descriptor for a single NDI output (maps to one OutputCardState in UI).
public struct PersistedOutputDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var playout: PlayoutConfig
    public var slots: [PersistedSlotBinding]
    public var programSlotID: String?
    public var previewSlotID: String?

    public init(
        id: String,
        name: String,
        playout: PlayoutConfig = PlayoutConfig(),
        slots: [PersistedSlotBinding] = [],
        programSlotID: String? = nil,
        previewSlotID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.playout = playout
        self.slots = slots
        self.programSlotID = programSlotID
        self.previewSlotID = previewSlotID
    }
}

/// Top-level persisted output topology — JSON array of outputs with full slot bindings.
public struct PersistedOutputTopology: Codable, Sendable, Equatable {
    public var outputs: [PersistedOutputDescriptor]
    public var savedAt: Date

    public init(outputs: [PersistedOutputDescriptor] = [], savedAt: Date = Date()) {
        self.outputs = outputs
        self.savedAt = savedAt
    }
}

// MARK: - Persistence Store

/// File-based persistence for Room Control session state.
public final class PersistenceStore: Sendable {
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("BETRRoomControl", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Layout

    public func loadLayout() -> PersistedLayout {
        load("layout.json") ?? PersistedLayout()
    }

    public func saveLayout(_ layout: PersistedLayout) {
        save(layout, to: "layout.json")
    }

    // MARK: - Clip Player Playlist (Task 54)

    public func loadClipPlaylist() -> PersistedClipPlaylist {
        load("clip-playlist.json") ?? PersistedClipPlaylist()
    }

    public func saveClipPlaylist(_ playlist: PersistedClipPlaylist) {
        save(playlist, to: "clip-playlist.json")
    }

    // MARK: - Timer Config

    public func loadTimerConfig() -> PersistedTimerConfig {
        load("timer-config.json") ?? PersistedTimerConfig()
    }

    public func saveTimerConfig(_ config: PersistedTimerConfig) {
        save(config, to: "timer-config.json")
    }

    // MARK: - Output Topology (Task 127)

    public func loadOutputTopology() -> PersistedOutputTopology? {
        load("output-topology.json")
    }

    public func saveOutputTopology(_ topology: PersistedOutputTopology) {
        save(topology, to: "output-topology.json")
    }

    // MARK: - Generic Load/Save

    private func load<T: Decodable>(_ filename: String) -> T? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to filename: String) {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
