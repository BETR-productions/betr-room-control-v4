// ClipPlayerDomain — models and types for clip player producer.

import Foundation
import RoomControlXPCContracts

// MARK: - Clip Item Type

/// Media type of a clip item.
public enum ClipItemType: String, Codable, Sendable, Equatable, CaseIterable {
    case video
    case still

    public static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "hevc"]
    public static let supportedStillExtensions: Set<String> = ["jpg", "jpeg", "png"]
    public static let allSupportedExtensions = supportedVideoExtensions.union(supportedStillExtensions)

    public static func type(for url: URL) -> ClipItemType? {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) { return .video }
        if supportedStillExtensions.contains(ext) { return .still }
        return nil
    }
}

// MARK: - Clip Item

/// A single media item in the clip player playlist.
public struct ClipItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let url: URL
    public let type: ClipItemType
    public let transitionKind: TransitionKind
    public let durationOverride: TimeInterval?

    public init(
        id: UUID = UUID(),
        url: URL,
        type: ClipItemType,
        transitionKind: TransitionKind = .cut,
        durationOverride: TimeInterval? = nil
    ) {
        self.id = id
        self.url = url
        self.type = type
        self.transitionKind = transitionKind
        self.durationOverride = durationOverride
    }

    /// Display name derived from the URL filename.
    public var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Playback Order

/// Order in which clips are played.
public enum PlaybackOrder: String, Codable, Sendable, Equatable, CaseIterable {
    case sequential
    case random
}

// MARK: - Clip Player Run State

/// Runtime state of the clip player.
public enum ClipPlayerRunState: String, Codable, Sendable, Equatable {
    case stopped
    case playing
    case paused
}

// MARK: - Clip Player Snapshot

/// Observable snapshot of clip player runtime state.
public struct ClipPlayerSnapshot: Codable, Sendable, Equatable {
    public let runState: ClipPlayerRunState
    public let producerID: String?
    public let currentItemIndex: Int?
    public let currentItemID: UUID?
    public let currentItemName: String?
    public let totalItemCount: Int
    public let playbackOrder: PlaybackOrder
    public let lastErrorMessage: String?
    public let capturedAt: Date

    public init(
        runState: ClipPlayerRunState = .stopped,
        producerID: String? = nil,
        currentItemIndex: Int? = nil,
        currentItemID: UUID? = nil,
        currentItemName: String? = nil,
        totalItemCount: Int = 0,
        playbackOrder: PlaybackOrder = .sequential,
        lastErrorMessage: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.runState = runState
        self.producerID = producerID
        self.currentItemIndex = currentItemIndex
        self.currentItemID = currentItemID
        self.currentItemName = currentItemName
        self.totalItemCount = totalItemCount
        self.playbackOrder = playbackOrder
        self.lastErrorMessage = lastErrorMessage
        self.capturedAt = capturedAt
    }
}

// MARK: - Constants

public enum ClipPlayerConstants {
    public static let producerName = "BËTR Clip Player"
    public static let defaultStillDuration: TimeInterval = 5.0
    public static let defaultFrameRateNumerator = 30_000
    public static let defaultFrameRateDenominator = 1_001
    public static let defaultWidth = 1920
    public static let defaultHeight = 1080
}
