import AVFoundation
import ClipPlayerDomain
import CoreGraphics
import CoreNDIOutput
import CoreNDIPlatform
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct ClipPlayerVideoFrameSample {
    let ptsSeconds: Double
    let frameData: Data
}

private struct ClipPlayerAudioSliceSample {
    let ptsSeconds: Double
    let sampleCount: Int
    let pcmPlanarFloat32: Data
}

public actor ClipPlayerProducerController {
    private enum PlaybackGeometry {
        static let width = 1920
        static let height = 1080
        static let frameRateNumerator = ClipPlayerConstants.defaultFrameRateNumerator
        static let frameRateDenominator = ClipPlayerConstants.defaultFrameRateDenominator
        static let sampleRate = 48_000
        static let channelCount = 2
    }

    private let coreAgentClient: BETRCoreAgentClient
    private let stateUpdate: @Sendable (ClipPlayerRuntimeSnapshot) -> Void

    private var savedState = ClipPlayerSavedState.empty
    private var runState: ClipPlayerRunState = .stopped
    private var currentItemIndex: Int?
    private var currentItemID: String?
    private var currentItemName: String?
    private var playbackTask: Task<Void, Never>?
    private var lastErrorMessage: String?
    private var holdFrameCache: [String: Data] = [:]
    private var imageFrameCache: [String: Data] = [:]
    private var resolvedURLs: [String: URL] = [:]
    private var playableIndices: [Int] = []
    private var activeSecurityScopeURLs: [URL] = []
    private var sourceEpoch: Int64 = 0
    private var videoSequence: UInt64 = 0
    private var audioSequence: UInt64 = 0
    private var isUsingHoldSlate = true
    private var didApplyInitialState = false
    private var lastSubmittedFrame: Data?
    private var latestPreviewSnapshot: OutputPreviewSnapshot?
    private var shuffleOrder: [Int] = []
    private var shufflePosition = 0
    private var isRegistered = false

    public init(
        coreAgentClient: BETRCoreAgentClient,
        stateUpdate: @escaping @Sendable (ClipPlayerRuntimeSnapshot) -> Void = { _ in }
    ) {
        self.coreAgentClient = coreAgentClient
        self.stateUpdate = stateUpdate
    }

    public func applyState(_ savedState: ClipPlayerSavedState) async {
        let currentIDBeforeUpdate = currentItemID
        self.savedState = savedState
        refreshResolvedURLs()
        syncCurrentItemAfterStateUpdate(preservingItemID: currentIDBeforeUpdate)

        do {
            try await ensureRegistered()
        } catch {
            lastErrorMessage = "Unable to register Clip Player as a BETR-managed source."
            await publishStateUpdate()
            return
        }

        if playableIndices.isEmpty {
            await stopInternal(showHold: true, resetIndex: false)
            didApplyInitialState = true
            return
        }

        if !didApplyInitialState {
            didApplyInitialState = true
            if savedState.wasPlaying {
                await startPlayback(at: currentItemIndex ?? savedState.currentItemIndex)
            } else {
                await ensureIdleVisualState()
            }
        } else if runState == .stopped {
            await ensureIdleVisualState()
        } else if runState == .paused {
            await renderPausedFrameForCurrentItem()
        } else if runState == .playing, let currentItemID {
            let currentItemStillExists = self.savedState.items.contains(where: { $0.id == currentItemID })
            if !currentItemStillExists {
                await startPlayback(at: currentItemIndex ?? savedState.currentItemIndex)
            } else {
                await publishStateUpdate()
            }
        }
    }

    public func play() async {
        guard !playableIndices.isEmpty else {
            await stopInternal(showHold: true, resetIndex: false)
            return
        }
        await startPlayback(at: currentItemIndex ?? savedState.currentItemIndex)
    }

    public func pause() async {
        guard runState == .playing else { return }
        playbackTask?.cancel()
        playbackTask = nil
        runState = .paused
        await publishStateUpdate()
    }

    public func stop() async {
        await stopInternal(showHold: true, resetIndex: true)
    }

    public func selectItem(index: Int) async {
        guard savedState.items.indices.contains(index) else { return }

        currentItemIndex = index
        currentItemID = savedState.items[index].id
        currentItemName = savedState.items[index].fileName

        if runState == .playing {
            await startPlayback(at: index)
        } else if runState == .paused {
            await renderPausedFrameForCurrentItem()
        } else {
            await ensureIdleVisualState()
        }
    }

    public func nextItem() async {
        guard !playableIndices.isEmpty else { return }
        let nextIndex = nextPlayableIndex(after: currentItemIndex ?? savedState.currentItemIndex)
        currentItemIndex = nextIndex
        if runState == .playing {
            await startPlayback(at: nextIndex)
        } else if runState == .paused {
            await renderPausedFrameForCurrentItem()
        } else {
            await ensureIdleVisualState()
        }
    }

    public func previousItem() async {
        guard !playableIndices.isEmpty else { return }
        let previousIndex = previousPlayableIndex(before: currentItemIndex ?? savedState.currentItemIndex)
        currentItemIndex = previousIndex
        if runState == .playing {
            await startPlayback(at: previousIndex)
        } else if runState == .paused {
            await renderPausedFrameForCurrentItem()
        } else {
            await ensureIdleVisualState()
        }
    }

    public func snapshot() -> ClipPlayerRuntimeSnapshot {
        let preview: OutputPreviewSnapshot? =
            if runState == .playing || runState == .paused || isUsingHoldSlate {
                latestPreviewSnapshot
            } else {
                nil
            }

        let selectionPreview: OutputPreviewSnapshot? =
            switch runState {
            case .playing:
                nil
            case .paused:
                latestPreviewSnapshot ?? selectedItemPreview()
            case .stopped:
                selectedItemPreview()
            }

        let items = savedState.items.map { item in
            let isPlayable = resolvedURLs[item.id] != nil
            return ClipPlayerRuntimeItemState(
                id: item.id,
                fileName: item.fileName,
                filePath: item.filePath,
                type: item.type,
                dwellSeconds: item.dwellSeconds,
                sortOrder: item.sortOrder,
                isPlayable: isPlayable,
                isMissing: !isPlayable
            )
        }

        return ClipPlayerRuntimeSnapshot(
            runState: runState,
            senderName: ClipPlayerConstants.senderBaseName,
            senderReady: isRegistered,
            isUsingHoldSlate: isUsingHoldSlate,
            currentItemIndex: currentItemIndex,
            currentItemID: currentItemID,
            currentItemName: currentItemName,
            totalItemCount: savedState.items.count,
            playableItemCount: playableIndices.count,
            playbackMode: savedState.playbackMode,
            transitionType: savedState.transitionType,
            transitionDurationMs: savedState.transitionDurationMs,
            preview: preview,
            selectionPreview: selectionPreview,
            outputProfile: outputProfile,
            items: items,
            lastErrorMessage: lastErrorMessage
        )
    }

    public func shutdown() async {
        playbackTask?.cancel()
        playbackTask = nil
        releaseSecurityScopes()
        imageFrameCache.removeAll()
        holdFrameCache.removeAll()
        latestPreviewSnapshot = nil
        await unregisterIfNeeded()
        await publishStateUpdate()
    }
}

private extension ClipPlayerProducerController {
    var descriptor: LocalProducerDescriptor {
        LocalProducerDescriptor(
            id: ClipPlayerConstants.managedSourceID,
            displayName: ClipPlayerConstants.managedSourceLabel,
            advertisedSourceName: ClipPlayerConstants.senderBaseName,
            videoFormat: .bgra8,
            audioFormat: .float32PlanarStereo48k
        )
    }

    var outputProfile: OutputProfile {
        OutputProfile(
            id: ClipPlayerConstants.senderProfileID,
            name: ClipPlayerConstants.senderBaseName,
            width: PlaybackGeometry.width,
            height: PlaybackGeometry.height,
            frameRateNumerator: PlaybackGeometry.frameRateNumerator,
            frameRateDenominator: PlaybackGeometry.frameRateDenominator
        )
    }

    func ensureRegistered() async throws {
        guard isRegistered == false else { return }
        _ = try await coreAgentClient.registerLocalProducer(descriptor)
        isRegistered = true
        sourceEpoch = nextSourceEpoch()
        videoSequence = 0
        audioSequence = 0
    }

    func unregisterIfNeeded() async {
        guard isRegistered else { return }
        try? await coreAgentClient.unregisterLocalProducer(sourceID: ClipPlayerConstants.managedSourceID)
        isRegistered = false
        sourceEpoch = 0
        videoSequence = 0
        audioSequence = 0
    }

    func refreshResolvedURLs() {
        releaseSecurityScopes()
        resolvedURLs.removeAll()
        playableIndices.removeAll()
        imageFrameCache = imageFrameCache.filter { key, _ in
            savedState.items.contains(where: { key.hasPrefix("\($0.id)::") })
        }

        for (index, item) in savedState.items.enumerated() {
            if let resolvedURL = resolveFileURLOnce(for: item) {
                resolvedURLs[item.id] = resolvedURL
                playableIndices.append(index)
            }
        }
    }

    func resolveFileURLOnce(for item: ClipPlayerItem) -> URL? {
        if let bookmark = item.fileBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if url.startAccessingSecurityScopedResource() {
                    activeSecurityScopeURLs.append(url)
                    return url
                }
            }
        }

        let url = URL(fileURLWithPath: item.filePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func releaseSecurityScopes() {
        for url in activeSecurityScopeURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopeURLs.removeAll()
    }

    func syncCurrentItemAfterStateUpdate(preservingItemID itemID: String?) {
        if let itemID,
           let index = savedState.items.firstIndex(where: { $0.id == itemID }) {
            currentItemIndex = index
            currentItemID = itemID
            currentItemName = savedState.items[index].fileName
            return
        }

        if playableIndices.contains(savedState.currentItemIndex) {
            currentItemIndex = savedState.currentItemIndex
        } else {
            currentItemIndex = playableIndices.first
        }

        if let currentItemIndex, savedState.items.indices.contains(currentItemIndex) {
            currentItemID = savedState.items[currentItemIndex].id
            currentItemName = savedState.items[currentItemIndex].fileName
        } else {
            currentItemID = nil
            currentItemName = nil
        }
    }

    func stopInternal(showHold: Bool, resetIndex: Bool) async {
        playbackTask?.cancel()
        playbackTask = nil
        runState = .stopped
        if resetIndex {
            currentItemIndex = playableIndices.first ?? 0
            if let currentItemIndex, savedState.items.indices.contains(currentItemIndex) {
                currentItemID = savedState.items[currentItemIndex].id
                currentItemName = savedState.items[currentItemIndex].fileName
            } else {
                currentItemID = nil
                currentItemName = nil
            }
        }
        if showHold {
            await showHoldSlate()
        } else {
            latestPreviewSnapshot = nil
            await publishStateUpdate()
        }
    }

    func ensureIdleVisualState() async {
        guard !playableIndices.isEmpty else {
            await showHoldSlate()
            return
        }
        await showHoldSlate()
    }

    func renderPausedFrameForCurrentItem() async {
        guard let currentItemIndex, savedState.items.indices.contains(currentItemIndex) else {
            return
        }
        guard let frameData = renderedFrameData(for: savedState.items[currentItemIndex]) else {
            await showHoldSlate()
            return
        }
        await beginClipItem(item: savedState.items[currentItemIndex], with: frameData)
        runState = .paused
        isUsingHoldSlate = false
        lastSubmittedFrame = frameData
        await submitSilentAudioSlice(timecodeNs: 0)
        await publishStateUpdate()
    }

    func startPlayback(at requestedIndex: Int?) async {
        playbackTask?.cancel()
        playbackTask = nil
        guard !playableIndices.isEmpty else {
            await stopInternal(showHold: true, resetIndex: false)
            return
        }
        let startIndex = normalizedPlayableIndex(for: requestedIndex)
        runState = .playing
        currentItemIndex = startIndex
        if let startIndex, savedState.items.indices.contains(startIndex) {
            currentItemID = savedState.items[startIndex].id
            currentItemName = savedState.items[startIndex].fileName
        }
        if savedState.playbackMode == .random {
            rebuildShuffleOrder(startingAt: startIndex)
        }
        await publishStateUpdate()
        playbackTask = Task {
            await self.runPlaybackLoop(startingAt: startIndex)
        }
    }

    func runPlaybackLoop(startingAt requestedIndex: Int?) async {
        var nextIndex = normalizedPlayableIndex(for: requestedIndex)
        while !Task.isCancelled {
            guard let itemIndex = nextIndex,
                  savedState.items.indices.contains(itemIndex),
                  let itemURL = resolvedURLs[savedState.items[itemIndex].id] else {
                await stopInternal(showHold: true, resetIndex: false)
                return
            }

            currentItemIndex = itemIndex
            currentItemID = savedState.items[itemIndex].id
            currentItemName = savedState.items[itemIndex].fileName
            await publishStateUpdate()

            let item = savedState.items[itemIndex]
            let didPlayItem = await playItem(item, at: itemIndex, url: itemURL)
            if Task.isCancelled || runState != .playing {
                return
            }
            if !didPlayItem {
                nextIndex = nextPlayableIndex(after: itemIndex)
                continue
            }
            nextIndex = nextPlayableIndex(after: itemIndex)
        }
    }

    func playItem(_ item: ClipPlayerItem, at index: Int, url: URL) async -> Bool {
        switch item.type {
        case .image:
            guard let targetFrame = renderedImageFrame(for: item, url: url) else {
                lastErrorMessage = "BETR could not render \(item.fileName)."
                await publishStateUpdate()
                return false
            }
            await playStillItem(item: item, frameData: targetFrame)
            return true
        case .video:
            return await playVideoItem(item: item, url: url)
        }
    }

    func playStillItem(item: ClipPlayerItem, frameData: Data) async {
        await beginClipItem(item: item, with: frameData)
        await renderTransitionIfNeeded(to: frameData)
        await submitSilentAudioSlice(timecodeNs: 0)
        lastSubmittedFrame = frameData
        isUsingHoldSlate = false
        await publishStateUpdate()
        try? await Task.sleep(nanoseconds: UInt64(item.dwellSeconds * 1_000_000_000))
    }

    func playVideoItem(item: ClipPlayerItem, url: URL) async -> Bool {
        guard let readerContext = ClipPlayerVideoReaderContext(url: url, profile: outputProfile) else {
            lastErrorMessage = "BETR could not prepare \(item.fileName)."
            await publishStateUpdate()
            return false
        }

        var nextVideo = readerContext.firstVideoSample
        guard let firstVideo = nextVideo else {
            lastErrorMessage = "BETR could not decode video frames for \(item.fileName)."
            await publishStateUpdate()
            return false
        }

        await beginClipItem(item: item, with: firstVideo.frameData)
        await renderTransitionIfNeeded(to: firstVideo.frameData)
        lastSubmittedFrame = firstVideo.frameData
        isUsingHoldSlate = false
        await publishStateUpdate()
        nextVideo = readerContext.nextVideoSample()
        var nextAudio = readerContext.firstAudioSample
        let playbackStartedAt = Date()
        let zeroPTS = min(
            firstVideo.ptsSeconds,
            nextAudio?.ptsSeconds ?? firstVideo.ptsSeconds
        )

        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(playbackStartedAt)
            let nextDueSeconds = min(
                nextVideo.map { max(0, $0.ptsSeconds - zeroPTS) } ?? .infinity,
                nextAudio.map { max(0, $0.ptsSeconds - zeroPTS) } ?? .infinity
            )

            if nextDueSeconds.isInfinite {
                break
            }

            if nextDueSeconds > elapsed {
                let sleepNs = UInt64(max(1_000_000, (nextDueSeconds - elapsed) * 1_000_000_000))
                try? await Task.sleep(nanoseconds: sleepNs)
                continue
            }

            if let audioSample = nextAudio,
               audioSample.ptsSeconds - zeroPTS <= elapsed + 0.001 {
                await publishAudioSlice(
                    sampleCount: audioSample.sampleCount,
                    pcmFloat32LE: audioSample.pcmPlanarFloat32,
                    timecodeNs: Int64(audioSample.ptsSeconds * 1_000_000_000)
                )
                nextAudio = readerContext.nextAudioSample()
            }

            if let videoSample = nextVideo,
               videoSample.ptsSeconds - zeroPTS <= elapsed + 0.001 {
                await publishVideoFrame(
                    pixelData: videoSample.frameData,
                    timecodeNs: Int64(videoSample.ptsSeconds * 1_000_000_000)
                )
                lastSubmittedFrame = videoSample.frameData
                nextVideo = readerContext.nextVideoSample()
            }
        }

        return true
    }

    func beginClipItem(item: ClipPlayerItem, with firstFrame: Data) async {
        sourceEpoch = nextSourceEpoch()
        videoSequence = 0
        audioSequence = 0
        await publishVideoFrame(pixelData: firstFrame, timecodeNs: 0)
    }

    func renderTransitionIfNeeded(to targetFrame: Data) async {
        guard savedState.transitionType == .fade,
              savedState.transitionDurationMs > 0,
              let previousFrame = lastSubmittedFrame else {
            return
        }

        let durationSeconds = Double(savedState.transitionDurationMs) / 1000.0
        let frameInterval = Double(outputProfile.frameRateDenominator) / Double(outputProfile.frameRateNumerator)
        let frameCount = max(1, Int(ceil(durationSeconds / max(0.001, frameInterval))))
        for step in 1...frameCount where !Task.isCancelled {
            let alpha = Float(step) / Float(frameCount)
            let blended = ClipPlayerFrameRenderer.blend(
                from: previousFrame,
                to: targetFrame,
                alpha: alpha
            )
            await publishVideoFrame(pixelData: blended, timecodeNs: 0)
            try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
        }
    }

    func showHoldSlate() async {
        let cacheKey = "\(outputProfile.width)x\(outputProfile.height)"
        let holdFrame = holdFrameCache[cacheKey] ?? ClipPlayerFrameRenderer.renderHoldSlate(
            width: outputProfile.width,
            height: outputProfile.height,
            title: ClipPlayerConstants.managedSourceLabel,
            subtitle: "Hold slate"
        )
        holdFrameCache[cacheKey] = holdFrame

        sourceEpoch = nextSourceEpoch()
        videoSequence = 0
        audioSequence = 0
        await publishVideoFrame(pixelData: holdFrame, timecodeNs: 0)
        await submitSilentAudioSlice(timecodeNs: 0)
        lastSubmittedFrame = holdFrame
        isUsingHoldSlate = true
        await publishStateUpdate()
    }

    func normalizedPlayableIndex(for requestedIndex: Int?) -> Int? {
        guard !playableIndices.isEmpty else { return nil }
        if let requestedIndex, playableIndices.contains(requestedIndex) {
            return requestedIndex
        }
        return playableIndices.first
    }

    func nextPlayableIndex(after index: Int) -> Int? {
        guard !playableIndices.isEmpty else { return nil }
        switch savedState.playbackMode {
        case .sequential:
            guard let currentPosition = playableIndices.firstIndex(of: index) else {
                return playableIndices.first
            }
            let nextPosition = (currentPosition + 1) % playableIndices.count
            return playableIndices[nextPosition]
        case .random:
            guard !shuffleOrder.isEmpty else {
                rebuildShuffleOrder(startingAt: index)
                return shuffleOrder.first
            }
            shufflePosition += 1
            if shufflePosition >= shuffleOrder.count {
                rebuildShuffleOrder(startingAfter: index)
            }
            return shuffleOrder[min(shufflePosition, max(0, shuffleOrder.count - 1))]
        }
    }

    func previousPlayableIndex(before index: Int) -> Int {
        guard !playableIndices.isEmpty else { return 0 }
        switch savedState.playbackMode {
        case .sequential:
            guard let currentPosition = playableIndices.firstIndex(of: index) else {
                return playableIndices.first ?? 0
            }
            let previousPosition = (currentPosition - 1 + playableIndices.count) % playableIndices.count
            return playableIndices[previousPosition]
        case .random:
            if shuffleOrder.isEmpty {
                rebuildShuffleOrder(startingAt: index)
            }
            shufflePosition = max(0, shufflePosition - 1)
            return shuffleOrder[min(shufflePosition, max(0, shuffleOrder.count - 1))]
        }
    }

    func rebuildShuffleOrder(startingAt startIndex: Int?) {
        let preservedFirst = startIndex.flatMap { playableIndices.contains($0) ? $0 : nil }
        rebuildShuffleOrderInternal(preservedFirst: preservedFirst, avoidingImmediateRepeatOf: nil)
    }

    func rebuildShuffleOrder(startingAfter lastIndex: Int?) {
        rebuildShuffleOrderInternal(preservedFirst: nil, avoidingImmediateRepeatOf: lastIndex)
    }

    func rebuildShuffleOrderInternal(preservedFirst: Int?, avoidingImmediateRepeatOf lastIndex: Int?) {
        var order = playableIndices
        order.shuffle()
        if let preservedFirst, let existingIndex = order.firstIndex(of: preservedFirst) {
            order.swapAt(0, existingIndex)
        } else if let lastIndex,
                  order.first == lastIndex,
                  order.count > 1 {
            order.swapAt(0, 1)
        }
        shuffleOrder = order
        shufflePosition = 0
    }

    func renderedFrameData(for item: ClipPlayerItem) -> Data? {
        guard let url = resolvedURLs[item.id] else { return nil }
        switch item.type {
        case .image:
            return renderedImageFrame(for: item, url: url)
        case .video:
            guard let readerContext = ClipPlayerVideoReaderContext(url: url, profile: outputProfile) else {
                return nil
            }
            return readerContext.firstVideoSample?.frameData
        }
    }

    func renderedImageFrame(for item: ClipPlayerItem, url: URL) -> Data? {
        let cacheKey = "\(item.id)::\(outputProfile.width)x\(outputProfile.height)"
        if let cached = imageFrameCache[cacheKey] {
            return cached
        }
        guard let frame = ClipPlayerFrameRenderer.renderImage(
            at: url,
            width: outputProfile.width,
            height: outputProfile.height
        ) else {
            return nil
        }
        imageFrameCache[cacheKey] = frame
        return frame
    }

    func selectedItemPreview() -> OutputPreviewSnapshot? {
        guard let currentItemIndex, savedState.items.indices.contains(currentItemIndex) else {
            return nil
        }

        guard let frameData = renderedFrameData(for: savedState.items[currentItemIndex]) else {
            return nil
        }

        return ClipPlayerFrameRenderer.makePreviewSnapshot(
            pixelData: frameData,
            width: outputProfile.width,
            height: outputProfile.height
        )
    }

    func publishVideoFrame(pixelData: Data, timecodeNs: Int64) async {
        do {
            try await ensureRegistered()
            videoSequence &+= 1
            try await coreAgentClient.pushLocalVideoFrame(
                sourceID: ClipPlayerConstants.managedSourceID,
                sourceEpoch: sourceEpoch,
                sequence: videoSequence,
                width: outputProfile.width,
                height: outputProfile.height,
                lineStride: outputProfile.width * 4,
                pixelData: pixelData,
                timecodeNs: timecodeNs
            )
            latestPreviewSnapshot = ClipPlayerFrameRenderer.makePreviewSnapshot(
                pixelData: pixelData,
                width: outputProfile.width,
                height: outputProfile.height
            )
        } catch {
            lastErrorMessage = "BETR could not push the current Clip Player frame into the managed local-producer path."
        }
    }

    func publishAudioSlice(sampleCount: Int, pcmFloat32LE: Data, timecodeNs: Int64) async {
        do {
            try await ensureRegistered()
            audioSequence &+= 1
            try await coreAgentClient.pushLocalAudioBuffer(
                sourceID: ClipPlayerConstants.managedSourceID,
                sourceEpoch: sourceEpoch,
                sequence: audioSequence,
                sampleRate: PlaybackGeometry.sampleRate,
                channels: PlaybackGeometry.channelCount,
                sampleCount: sampleCount,
                channelStrideInBytes: sampleCount * MemoryLayout<Float>.size,
                pcmFloat32LE: pcmFloat32LE,
                timestampNanoseconds: timecodeNs
            )
        } catch {
            lastErrorMessage = "BETR could not push the current Clip Player audio into the managed local-producer path."
        }
    }

    func submitSilentAudioSlice(timecodeNs: Int64) async {
        let sampleCount = halfFrameAudioSampleCount()
        let channelStride = sampleCount * MemoryLayout<Float>.size
        let silentPCM = Data(count: channelStride * PlaybackGeometry.channelCount)
        await publishAudioSlice(sampleCount: sampleCount, pcmFloat32LE: silentPCM, timecodeNs: timecodeNs)
    }

    func halfFrameAudioSampleCount() -> Int {
        let frameDurationSeconds = Double(PlaybackGeometry.frameRateDenominator) / Double(PlaybackGeometry.frameRateNumerator)
        let sampleCount = Double(PlaybackGeometry.sampleRate) * frameDurationSeconds * 0.5
        return max(1, Int(sampleCount.rounded()))
    }

    func nextSourceEpoch() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    func publishStateUpdate() async {
        stateUpdate(snapshot())
    }
}

private final class ClipPlayerVideoReaderContext {
    let reader: AVAssetReader
    let videoOutput: AVAssetReaderTrackOutput
    let audioOutput: AVAssetReaderTrackOutput?
    let firstVideoSample: ClipPlayerVideoFrameSample?
    let firstAudioSample: ClipPlayerAudioSliceSample?
    private let width: Int
    private let height: Int

    init?(url: URL, profile: OutputProfile) {
        let asset = AVAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset),
              let videoTrack = asset.tracks(withMediaType: .video).first else {
            return nil
        }

        width = profile.width
        height = profile.height

        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: profile.width,
            kCVPixelBufferHeightKey as String: profile.height,
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { return nil }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioSettings)
            trackOutput.alwaysCopiesSampleData = false
            if reader.canAdd(trackOutput) {
                reader.add(trackOutput)
                audioOutput = trackOutput
            }
        }

        guard reader.startReading() else { return nil }
        self.reader = reader
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        firstVideoSample = Self.decodeNextVideoSample(from: videoOutput, width: width, height: height)
        firstAudioSample = audioOutput.flatMap(Self.decodeNextAudioSample(from:))
    }

    func nextVideoSample() -> ClipPlayerVideoFrameSample? {
        Self.decodeNextVideoSample(from: videoOutput, width: width, height: height)
    }

    func nextAudioSample() -> ClipPlayerAudioSliceSample? {
        guard let audioOutput else { return nil }
        return Self.decodeNextAudioSample(from: audioOutput)
    }

    deinit {
        reader.cancelReading()
    }

    private static func decodeNextVideoSample(
        from output: AVAssetReaderTrackOutput,
        width: Int,
        height: Int
    ) -> ClipPlayerVideoFrameSample? {
        guard let sampleBuffer = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let destinationStride = width * 4
        var frameData = Data(count: destinationStride * height)
        frameData.withUnsafeMutableBytes { rawBuffer in
            guard let destinationBase = rawBuffer.baseAddress else { return }
            let copyRows = min(height, sourceHeight)
            let copyBytes = min(destinationStride, sourceStride)
            for row in 0..<copyRows {
                memcpy(
                    destinationBase.advanced(by: row * destinationStride),
                    baseAddress.advanced(by: row * sourceStride),
                    copyBytes
                )
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return ClipPlayerVideoFrameSample(
            ptsSeconds: pts.isNumeric ? pts.seconds : 0,
            frameData: frameData
        )
    }

    private static func decodeNextAudioSample(from output: AVAssetReaderTrackOutput) -> ClipPlayerAudioSliceSample? {
        guard let sampleBuffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }

        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0 else { return nil }

        var interleavedPCM = Data(count: byteCount)
        interleavedPCM.withUnsafeMutableBytes { rawBuffer in
            guard let destination = rawBuffer.baseAddress else { return }
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination
            )
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let channels = max(1, Int(asbdPointer.pointee.mChannelsPerFrame))
        let planarPCM = Self.planarStereoPCM(fromInterleavedFloat32LE: interleavedPCM, sampleCount: sampleCount, channels: channels)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return ClipPlayerAudioSliceSample(
            ptsSeconds: pts.isNumeric ? pts.seconds : 0,
            sampleCount: sampleCount,
            pcmPlanarFloat32: planarPCM
        )
    }

    private static func planarStereoPCM(
        fromInterleavedFloat32LE interleavedPCM: Data,
        sampleCount: Int,
        channels: Int
    ) -> Data {
        let stride = sampleCount * MemoryLayout<Float>.size
        var planarPCM = Data(count: stride * 2)
        interleavedPCM.withUnsafeBytes { sourceBuffer in
            guard let sourceBase = sourceBuffer.baseAddress else { return }
            let sourceFloats = sourceBase.assumingMemoryBound(to: Float.self)
            planarPCM.withUnsafeMutableBytes { destinationBuffer in
                guard let destinationBase = destinationBuffer.baseAddress else { return }
                let left = destinationBase.assumingMemoryBound(to: Float.self)
                let right = destinationBase.advanced(by: stride).assumingMemoryBound(to: Float.self)
                let rightChannelOffset = channels > 1 ? 1 : 0
                for sample in 0..<sampleCount {
                    let sourceIndex = sample * channels
                    left[sample] = sourceFloats[sourceIndex]
                    right[sample] = sourceFloats[sourceIndex + rightChannelOffset]
                }
            }
        }
        return planarPCM
    }
}

private enum ClipPlayerFrameRenderer {
    static func renderHoldSlate(width: Int, height: Int, title: String, subtitle: String) -> Data {
        let lineStride = width * 4
        let byteCount = lineStride * height
        var pixelData = Data(count: byteCount)
        pixelData.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: lineStride,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return
            }

            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
            context.fill(bounds)
            context.setFillColor(CGColor(red: 0.13, green: 0.55, blue: 0.40, alpha: 1))
            context.fill(CGRect(x: 0, y: height - max(14, height / 24), width: width, height: max(14, height / 24)))

            drawText(
                title.uppercased(),
                in: CGRect(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.57, width: CGFloat(width) * 0.84, height: CGFloat(height) * 0.14),
                fontSize: max(44, CGFloat(height) * 0.074),
                color: CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1),
                context: context
            )
            drawText(
                subtitle,
                in: CGRect(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.40, width: CGFloat(width) * 0.84, height: CGFloat(height) * 0.12),
                fontSize: max(24, CGFloat(height) * 0.036),
                color: CGColor(red: 0.70, green: 0.72, blue: 0.76, alpha: 1),
                context: context
            )
        }
        return pixelData
    }

    static func renderImage(at url: URL, width: Int, height: Int) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let lineStride = width * 4
        let byteCount = lineStride * height
        var pixelData = Data(count: byteCount)
        let didRender = pixelData.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: lineStride,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return false
            }

            context.setFillColor(CGColor.black)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let outputAspect = CGFloat(width) / CGFloat(max(1, height))
            let drawRect: CGRect
            if imageAspect > outputAspect {
                let renderWidth = CGFloat(width)
                let renderHeight = renderWidth / imageAspect
                drawRect = CGRect(
                    x: 0,
                    y: (CGFloat(height) - renderHeight) / 2,
                    width: renderWidth,
                    height: renderHeight
                )
            } else {
                let renderHeight = CGFloat(height)
                let renderWidth = renderHeight * imageAspect
                drawRect = CGRect(
                    x: (CGFloat(width) - renderWidth) / 2,
                    y: 0,
                    width: renderWidth,
                    height: renderHeight
                )
            }
            context.draw(image, in: drawRect)
            return true
        }
        return didRender ? pixelData : nil
    }

    static func blend(from: Data, to: Data, alpha: Float) -> Data {
        let clampedAlpha = max(0, min(1, alpha))
        guard from.count == to.count else { return to }

        var blended = Data(count: from.count)
        let inverseAlpha = 1 - clampedAlpha
        let byteCount = from.count
        from.withUnsafeBytes { fromBuffer in
            guard let fromBase = fromBuffer.baseAddress else { return }
            let fromBytes = fromBase.assumingMemoryBound(to: UInt8.self)
            to.withUnsafeBytes { toBuffer in
                guard let toBase = toBuffer.baseAddress else { return }
                let toBytes = toBase.assumingMemoryBound(to: UInt8.self)
                blended.withUnsafeMutableBytes { destinationBuffer in
                    guard let destinationBase = destinationBuffer.baseAddress else { return }
                    let destinationBytes = destinationBase.assumingMemoryBound(to: UInt8.self)
                    for index in 0..<byteCount {
                        let startValue = Float(fromBytes[index])
                        let endValue = Float(toBytes[index])
                        let mixedValue = (startValue * inverseAlpha) + (endValue * clampedAlpha)
                        destinationBytes[index] = UInt8(max(0, min(255, Int(mixedValue.rounded()))))
                    }
                }
            }
        }
        return blended
    }

    static func makePreviewSnapshot(
        pixelData: Data,
        width: Int,
        height: Int,
        maxWidth: Int = 320,
        maxHeight: Int = 180,
        compressionQuality: Double = 0.65
    ) -> OutputPreviewSnapshot? {
        let lineStride = width * 4
        guard width > 0, height > 0, pixelData.count >= lineStride * height else {
            return nil
        }

        let scale = min(
            1.0,
            Double(maxWidth) / Double(width),
            Double(maxHeight) / Double(height)
        )
        let thumbnailWidth = max(1, Int((Double(width) * scale).rounded(.down)))
        let thumbnailHeight = max(1, Int((Double(height) * scale).rounded(.down)))
        let thumbnailStride = thumbnailWidth * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        guard
            let provider = CGDataProvider(data: pixelData as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: lineStride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ),
            let context = CGContext(
                data: nil,
                width: thumbnailWidth,
                height: thumbnailHeight,
                bitsPerComponent: 8,
                bytesPerRow: thumbnailStride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: thumbnailWidth, height: thumbnailHeight)
        )

        guard let scaledImage = context.makeImage() else {
            return nil
        }

        let encodedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, scaledImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return OutputPreviewSnapshot(
            capturedAt: Date(),
            width: thumbnailWidth,
            height: thumbnailHeight,
            imageData: encodedData as Data
        )
    }

    private static func drawText(
        _ string: String,
        in rect: CGRect,
        fontSize: CGFloat,
        color: CGColor,
        context: CGContext
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil),
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let x = rect.midX - (bounds.width / 2)
        let y = rect.midY - (bounds.height / 2)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
