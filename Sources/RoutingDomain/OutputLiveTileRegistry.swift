import CoreNDIOutput
import Foundation
import IOSurface

public typealias OutputPreviewAttachmentFetcher = @Sendable (String, UInt64) async -> OutputPreviewAttachment?

private struct OutputAttachmentKey: Hashable, Sendable {
    let outputID: String
    let attachmentID: UInt64
}

public final class OutputTileRenderFeed: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let surface: IOSurface?
        public let sequence: UInt64
    }

    private let lock = NSLock()
    private var surface: IOSurface?
    private var sequence: UInt64 = 0

    public init() {}

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(surface: surface, sequence: sequence)
    }

    public func hasSurface() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return surface != nil
    }

    @discardableResult
    public func bind(surface: IOSurface, sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasBound = self.surface != nil
        self.surface = surface
        self.sequence = sequence
        return wasBound != true
    }

    @discardableResult
    public func clear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasBound = surface != nil
        surface = nil
        sequence = 0
        return wasBound
    }
}

public final class OutputLiveTileRegistry {
    private enum AttachmentFetchState: Equatable {
        case idle
        case fetching(OutputAttachmentKey)
        case failed(OutputAttachmentKey)
    }

    private struct TileState {
        var snapshot: OutputLiveTileSnapshot?
        var currentAttachmentKey: OutputAttachmentKey?
        var currentSlotIndex: Int?
        var pendingAdvance: OutputPreviewAdvance?
    }

    private let lock = NSLock()
    private var feeds: [String: OutputTileRenderFeed] = [:]
    private var tileStates: [String: TileState] = [:]
    private var attachmentFetcher: OutputPreviewAttachmentFetcher?
    private var attachmentsByKey: [OutputAttachmentKey: OutputPreviewAttachment] = [:]
    private var attachmentFetchStates: [OutputAttachmentKey: AttachmentFetchState] = [:]

    public init() {}

    public func setAttachmentFetcher(_ fetcher: OutputPreviewAttachmentFetcher?) {
        lock.lock()
        attachmentFetcher = fetcher
        lock.unlock()
    }

    public func renderFeed(for outputID: String) -> OutputTileRenderFeed {
        if let existing = withLock({ feeds[outputID] }) {
            return existing
        }

        let created = OutputTileRenderFeed()
        lock.lock()
        if let existing = feeds[outputID] {
            lock.unlock()
            return existing
        }
        feeds[outputID] = created
        lock.unlock()
        return created
    }

    public func apply(_ event: OutputPreviewEvent) {
        switch event {
        case let .attachNotice(notice):
            applyAttachmentNotice(notice)
        case let .advance(advance):
            applyAdvance(advance)
        case let .detach(outputID):
            applyDetach(outputID: outputID)
        }
    }

    public func applyAttachmentNotice(_ notice: OutputPreviewAttachmentNotice) {
        handleAttachmentNotice(notice)
    }

    public func applyAdvance(_ advance: OutputPreviewAdvance) {
        handleAdvance(advance)
    }

    public func applyDetach(outputID: String) {
        detach(outputID: outputID)
    }

    public func prune(keeping outputIDs: Set<String>) {
        let removedOutputIDs = withLock { Set(feeds.keys).subtracting(outputIDs) }
        for outputID in removedOutputIDs {
            detach(outputID: outputID)
        }

        lock.lock()
        feeds = feeds.filter { outputIDs.contains($0.key) }
        tileStates = tileStates.filter { outputIDs.contains($0.key) }
        attachmentsByKey = attachmentsByKey.filter { outputIDs.contains($0.key.outputID) }
        attachmentFetchStates = attachmentFetchStates.filter { outputIDs.contains($0.key.outputID) }
        lock.unlock()
    }

    public func clear(outputID: String) {
        detach(outputID: outputID)
    }

    private func handleAttachmentNotice(_ notice: OutputPreviewAttachmentNotice) {
        let key = OutputAttachmentKey(outputID: notice.outputID, attachmentID: notice.attachmentID)
        if withLock({ attachmentsByKey[key] }) != nil {
            resolveAttachmentBinding(for: key)
            return
        }
        requestAttachmentIfNeeded(outputID: notice.outputID, attachmentID: notice.attachmentID)
    }

    private func handleAdvance(_ advance: OutputPreviewAdvance) {
        let snapshot = advance.snapshot
        let key = OutputAttachmentKey(outputID: snapshot.outputID, attachmentID: advance.attachmentID)
        let feed = renderFeed(for: snapshot.outputID)

        var shouldRequestAttachment = false

        lock.lock()
        var state = tileStates[snapshot.outputID] ?? TileState()
        let hasBoundSurface = feed.hasSurface()
        let acceptsSnapshot = shouldAccept(snapshot, advanceKey: key, currentState: state)
        let canRecoverCurrentSequence = canRecoverCurrentSequence(
            snapshot: snapshot,
            advanceKey: key,
            currentState: state,
            hasBoundSurface: hasBoundSurface
        )
        let surface = boundSurface(outputID: key.outputID, attachmentID: key.attachmentID, slotIndex: advance.slotIndex)
        let needsAttachmentRecovery = needsAttachmentRecovery(
            advanceKey: key,
            slotIndex: advance.slotIndex,
            currentState: state,
            hasBoundSurface: hasBoundSurface
        )

        if acceptsSnapshot || canRecoverCurrentSequence || needsAttachmentRecovery {
            if acceptsSnapshot {
                state.snapshot = snapshot
                state.currentAttachmentKey = key
                state.currentSlotIndex = advance.slotIndex
            }

            if let surface, acceptsSnapshot || canRecoverCurrentSequence {
                _ = feed.bind(surface: surface, sequence: snapshot.sequence)
                state.pendingAdvance = nil
                state.currentAttachmentKey = key
                state.currentSlotIndex = advance.slotIndex
            } else if needsAttachmentRecovery {
                state.pendingAdvance = advance
                shouldRequestAttachment = true
            }

            tileStates[snapshot.outputID] = state
        }
        lock.unlock()

        if shouldRequestAttachment {
            requestAttachmentIfNeeded(outputID: snapshot.outputID, attachmentID: advance.attachmentID)
        }
    }

    private func detach(outputID: String) {
        let feed = renderFeed(for: outputID)
        _ = feed.clear()

        lock.lock()
        tileStates.removeValue(forKey: outputID)
        attachmentsByKey = attachmentsByKey.filter { $0.key.outputID != outputID }
        attachmentFetchStates = attachmentFetchStates.filter { $0.key.outputID != outputID }
        lock.unlock()
    }

    private func shouldAccept(
        _ snapshot: OutputLiveTileSnapshot,
        advanceKey: OutputAttachmentKey,
        currentState: TileState
    ) -> Bool {
        guard let currentSnapshot = currentState.snapshot else { return true }
        if currentState.currentAttachmentKey != advanceKey {
            return true
        }
        return snapshot.sequence > currentSnapshot.sequence
    }

    private func canRecoverCurrentSequence(
        snapshot: OutputLiveTileSnapshot,
        advanceKey: OutputAttachmentKey,
        currentState: TileState,
        hasBoundSurface: Bool
    ) -> Bool {
        guard let currentSnapshot = currentState.snapshot,
              currentState.currentAttachmentKey == advanceKey,
              snapshot.sequence == currentSnapshot.sequence,
              hasBoundSurface == false else {
            return false
        }
        return true
    }

    private func needsAttachmentRecovery(
        advanceKey: OutputAttachmentKey,
        slotIndex: Int?,
        currentState: TileState,
        hasBoundSurface: Bool
    ) -> Bool {
        guard slotIndex != nil else { return false }
        if attachmentsByKey[advanceKey] == nil {
            return true
        }
        return currentState.currentAttachmentKey != advanceKey || hasBoundSurface == false
    }

    private func boundSurface(
        outputID: String,
        attachmentID: UInt64,
        slotIndex: Int?
    ) -> IOSurface? {
        guard let slotIndex,
              let attachment = attachmentsByKey[OutputAttachmentKey(outputID: outputID, attachmentID: attachmentID)],
              attachment.surfaces.indices.contains(slotIndex) else {
            return nil
        }
        return attachment.surfaces[slotIndex]
    }

    private func requestAttachmentIfNeeded(outputID: String, attachmentID: UInt64) {
        let key = OutputAttachmentKey(outputID: outputID, attachmentID: attachmentID)
        let fetcher: OutputPreviewAttachmentFetcher?

        lock.lock()
        if attachmentsByKey[key] != nil {
            lock.unlock()
            resolveAttachmentBinding(for: key)
            return
        }
        if case .fetching(key) = attachmentFetchStates[key] {
            lock.unlock()
            return
        }
        attachmentFetchStates[key] = .fetching(key)
        fetcher = attachmentFetcher
        lock.unlock()

        guard let fetcher else { return }
        Task {
            let attachment = await fetcher(outputID, attachmentID)
            self.completeAttachmentFetch(outputID: outputID, attachmentID: attachmentID, attachment: attachment)
        }
    }

    private func completeAttachmentFetch(
        outputID: String,
        attachmentID: UInt64,
        attachment: OutputPreviewAttachment?
    ) {
        let key = OutputAttachmentKey(outputID: outputID, attachmentID: attachmentID)
        var didStoreAttachment = false

        lock.lock()
        guard case .fetching(key) = attachmentFetchStates[key] else {
            lock.unlock()
            return
        }

        if let attachment,
           attachment.outputID == outputID,
           attachment.attachmentID == attachmentID {
            attachmentsByKey[key] = attachment
            attachmentFetchStates[key] = .idle
            didStoreAttachment = true
        } else {
            attachmentFetchStates[key] = .failed(key)
        }
        lock.unlock()

        if didStoreAttachment {
            resolveAttachmentBinding(for: key)
        }
    }

    private func resolveAttachmentBinding(for key: OutputAttachmentKey) {
        let feed = renderFeed(for: key.outputID)
        var sequence: UInt64?
        var slotIndex: Int?

        lock.lock()
        var state = tileStates[key.outputID] ?? TileState()
        if let pendingAdvance = state.pendingAdvance,
           pendingAdvance.attachmentID == key.attachmentID {
            slotIndex = pendingAdvance.slotIndex
            sequence = pendingAdvance.snapshot.sequence
            state.pendingAdvance = nil
        } else if state.currentAttachmentKey == key {
            slotIndex = state.currentSlotIndex
            sequence = state.snapshot?.sequence
        }

        if let surface = boundSurface(outputID: key.outputID, attachmentID: key.attachmentID, slotIndex: slotIndex),
           let sequence {
            _ = feed.bind(surface: surface, sequence: sequence)
            state.currentAttachmentKey = key
            state.currentSlotIndex = slotIndex
            tileStates[key.outputID] = state
        }
        lock.unlock()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
