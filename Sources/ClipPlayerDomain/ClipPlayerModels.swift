import CoreNDIOutput
import Foundation

public enum ClipPlayerConstants {
    public static let managedSourceID = "managed:clip-player"
    public static let managedSourceLabel = "Clip Player"
    public static let senderBaseName = "BETR Room Control (Clip Player)"
    public static let senderProfileID = "clip-player-output"
    public static let defaultImageDwellSeconds = 5.0
    public static let defaultTransitionDurationMs = 500
    public static let defaultFrameRateNumerator = 30_000
    public static let defaultFrameRateDenominator = 1_001
}

public enum ClipPlayerItemType: String, Codable, Sendable, Equatable {
    case image
    case video

    public static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg"]
    public static let supportedVideoExtensions: Set<String> = ["mov", "mp4"]
    public static let allSupportedExtensions = supportedImageExtensions.union(supportedVideoExtensions)

    public static func type(for url: URL) -> ClipPlayerItemType? {
        let ext = url.pathExtension.lowercased()
        if supportedImageExtensions.contains(ext) {
            return .image
        }
        if supportedVideoExtensions.contains(ext) {
            return .video
        }
        return nil
    }
}

public enum ClipPlayerPlaybackMode: String, Codable, Sendable, Equatable, CaseIterable {
    case sequential
    case random
}

public enum ClipPlayerTransitionType: String, Codable, Sendable, Equatable, CaseIterable {
    case cut
    case fade
}

public enum ClipPlayerRunState: String, Codable, Sendable, Equatable {
    case stopped
    case playing
    case paused
}

public struct ClipPlayerItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let fileBookmark: Data?
    public let filePath: String
    public let type: ClipPlayerItemType
    public let dwellSeconds: Double
    public let sortOrder: Int

    public init(
        id: String = UUID().uuidString,
        fileName: String,
        fileBookmark: Data? = nil,
        filePath: String,
        type: ClipPlayerItemType,
        dwellSeconds: Double = ClipPlayerConstants.defaultImageDwellSeconds,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.fileName = fileName
        self.fileBookmark = fileBookmark
        self.filePath = filePath
        self.type = type
        self.dwellSeconds = max(1, dwellSeconds)
        self.sortOrder = max(0, sortOrder)
    }

    public func updating(
        fileName: String? = nil,
        fileBookmark: Data? = nil,
        filePath: String? = nil,
        dwellSeconds: Double? = nil,
        sortOrder: Int? = nil
    ) -> ClipPlayerItem {
        ClipPlayerItem(
            id: id,
            fileName: fileName ?? self.fileName,
            fileBookmark: fileBookmark ?? self.fileBookmark,
            filePath: filePath ?? self.filePath,
            type: type,
            dwellSeconds: dwellSeconds ?? self.dwellSeconds,
            sortOrder: sortOrder ?? self.sortOrder
        )
    }
}

public struct ClipPlayerSavedState: Codable, Sendable, Equatable {
    public let items: [ClipPlayerItem]
    public let playbackMode: ClipPlayerPlaybackMode
    public let transitionType: ClipPlayerTransitionType
    public let transitionDurationMs: Int
    public let currentItemIndex: Int
    public let wasPlaying: Bool

    public init(
        items: [ClipPlayerItem] = [],
        playbackMode: ClipPlayerPlaybackMode = .sequential,
        transitionType: ClipPlayerTransitionType = .fade,
        transitionDurationMs: Int = ClipPlayerConstants.defaultTransitionDurationMs,
        currentItemIndex: Int = 0,
        wasPlaying: Bool = false
    ) {
        let sortedItems = items.sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
            }
            return lhs.sortOrder < rhs.sortOrder
        }
        self.items = sortedItems.enumerated().map { index, item in
            item.updating(sortOrder: index)
        }
        self.playbackMode = playbackMode
        self.transitionType = transitionType
        self.transitionDurationMs = max(100, transitionDurationMs)
        self.currentItemIndex = max(0, min(currentItemIndex, max(0, sortedItems.count - 1)))
        self.wasPlaying = wasPlaying
    }

    public static let empty = ClipPlayerSavedState()
}

public struct ClipPlayerDraft: Codable, Sendable, Equatable {
    public var items: [ClipPlayerItem]
    public var playbackMode: ClipPlayerPlaybackMode
    public var transitionType: ClipPlayerTransitionType
    public var transitionDurationMs: Int
    public var currentItemIndex: Int
    public var wasPlaying: Bool

    public init(savedState: ClipPlayerSavedState = .empty) {
        self.items = savedState.items
        self.playbackMode = savedState.playbackMode
        self.transitionType = savedState.transitionType
        self.transitionDurationMs = savedState.transitionDurationMs
        self.currentItemIndex = savedState.currentItemIndex
        self.wasPlaying = savedState.wasPlaying
    }

    public func asSavedState() -> ClipPlayerSavedState {
        ClipPlayerSavedState(
            items: items,
            playbackMode: playbackMode,
            transitionType: transitionType,
            transitionDurationMs: transitionDurationMs,
            currentItemIndex: currentItemIndex,
            wasPlaying: wasPlaying
        )
    }

    public static let empty = ClipPlayerDraft()
}

public struct ClipPlayerRuntimeItemState: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let filePath: String
    public let type: ClipPlayerItemType
    public let dwellSeconds: Double
    public let sortOrder: Int
    public let isPlayable: Bool
    public let isMissing: Bool

    public init(
        id: String,
        fileName: String,
        filePath: String,
        type: ClipPlayerItemType,
        dwellSeconds: Double,
        sortOrder: Int,
        isPlayable: Bool,
        isMissing: Bool
    ) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
        self.type = type
        self.dwellSeconds = dwellSeconds
        self.sortOrder = sortOrder
        self.isPlayable = isPlayable
        self.isMissing = isMissing
    }
}

public struct ClipPlayerRuntimeSnapshot: Codable, Sendable, Equatable {
    public let capturedAt: Date
    public let runState: ClipPlayerRunState
    public let senderName: String
    public let senderReady: Bool
    public let isUsingHoldSlate: Bool
    public let currentItemIndex: Int?
    public let currentItemID: String?
    public let currentItemName: String?
    public let totalItemCount: Int
    public let playableItemCount: Int
    public let playbackMode: ClipPlayerPlaybackMode
    public let transitionType: ClipPlayerTransitionType
    public let transitionDurationMs: Int
    public let preview: OutputPreviewSnapshot?
    public let selectionPreview: OutputPreviewSnapshot?
    public let outputProfile: OutputProfile?
    public let items: [ClipPlayerRuntimeItemState]
    public let lastErrorMessage: String?

    public init(
        capturedAt: Date = Date(),
        runState: ClipPlayerRunState = .stopped,
        senderName: String = ClipPlayerConstants.senderBaseName,
        senderReady: Bool = false,
        isUsingHoldSlate: Bool = true,
        currentItemIndex: Int? = nil,
        currentItemID: String? = nil,
        currentItemName: String? = nil,
        totalItemCount: Int = 0,
        playableItemCount: Int = 0,
        playbackMode: ClipPlayerPlaybackMode = .sequential,
        transitionType: ClipPlayerTransitionType = .fade,
        transitionDurationMs: Int = ClipPlayerConstants.defaultTransitionDurationMs,
        preview: OutputPreviewSnapshot? = nil,
        selectionPreview: OutputPreviewSnapshot? = nil,
        outputProfile: OutputProfile? = nil,
        items: [ClipPlayerRuntimeItemState] = [],
        lastErrorMessage: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.runState = runState
        self.senderName = senderName
        self.senderReady = senderReady
        self.isUsingHoldSlate = isUsingHoldSlate
        self.currentItemIndex = currentItemIndex
        self.currentItemID = currentItemID
        self.currentItemName = currentItemName
        self.totalItemCount = totalItemCount
        self.playableItemCount = playableItemCount
        self.playbackMode = playbackMode
        self.transitionType = transitionType
        self.transitionDurationMs = transitionDurationMs
        self.preview = preview
        self.selectionPreview = selectionPreview
        self.outputProfile = outputProfile
        self.items = items.sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
            }
            return lhs.sortOrder < rhs.sortOrder
        }
        self.lastErrorMessage = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
