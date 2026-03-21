// ClipPlayerProducer — local producer for media clip playback.
// Registers with BETRCoreAgent, decodes via AVAssetReader, pushes frames via IOSurface XPC.
// Audio pushed at OutputAudioBufferSizing.sampleCount per buffer — never 48000 samples at once.

import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import IOSurface
import RoomControlXPCContracts

// MARK: - Clip Player Producer

public actor ClipPlayerProducer {
    // MARK: - Producer registration

    private var producerID: String?
    private var coreCommands: BETRCoreXPCCommands?
    private var videoFormat: VideoFrameFormat

    // MARK: - Playback state

    private var items: [ClipItem] = []
    private var playbackOrder: PlaybackOrder = .sequential
    private var runState: ClipPlayerRunState = .stopped
    private var currentItemIndex: Int?
    private var playbackTask: Task<Void, Never>?
    private var lastErrorMessage: String?

    // MARK: - Frame delivery

    private var surface: IOSurface?
    private var videoSequence: UInt64 = 0
    private var audioSequence: UInt64 = 0
    private var audioBufferIndex: UInt64 = 0

    // MARK: - Shuffle

    private var shuffleOrder: [Int] = []
    private var shufflePosition: Int = 0

    // MARK: - Callbacks

    private let stateDidChange: (@Sendable () -> Void)?

    // MARK: - Init

    public init(
        width: Int = ClipPlayerConstants.defaultWidth,
        height: Int = ClipPlayerConstants.defaultHeight,
        frameRateNumerator: Int = ClipPlayerConstants.defaultFrameRateNumerator,
        frameRateDenominator: Int = ClipPlayerConstants.defaultFrameRateDenominator,
        stateDidChange: (@Sendable () -> Void)? = nil
    ) {
        self.videoFormat = VideoFrameFormat(
            width: width,
            height: height,
            pixelFormat: "BGRA",
            frameRateNumerator: frameRateNumerator,
            frameRateDenominator: frameRateDenominator
        )
        self.stateDidChange = stateDidChange
    }

    // MARK: - LocalProducer Registration

    public func register(with commands: BETRCoreXPCCommands) {
        coreCommands = commands
        let descriptor = LocalProducerDescriptor(
            name: ClipPlayerConstants.producerName,
            producerProtocol: .ioSurface,
            hasVideo: true,
            hasAudio: true
        )
        guard let data = try? JSONEncoder().encode(descriptor) else { return }
        commands.registerLocalProducer(descriptorData: data) { [weak self] success, errorMessage in
            guard success else { return }
            Task { [weak self] in
                await self?.didRegister(producerID: descriptor.id)
            }
        }
    }

    public func unregister() {
        guard let coreCommands, let producerID else { return }
        coreCommands.unregisterLocalProducer(producerID: producerID) { _ in }
        self.producerID = nil
    }

    private func didRegister(producerID: String) {
        self.producerID = producerID
        ensureSurface()
        notifyStateChange()
    }

    // MARK: - Playlist Management

    public func setPlaylist(items: [ClipItem], order: PlaybackOrder) {
        self.items = items
        self.playbackOrder = order
        if let currentItemIndex, currentItemIndex >= items.count {
            self.currentItemIndex = items.isEmpty ? nil : 0
        }
        if runState == .playing {
            startPlayback(at: currentItemIndex ?? 0)
        }
        notifyStateChange()
    }

    public func addItem(_ item: ClipItem) {
        items.append(item)
        notifyStateChange()
    }

    public func removeItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if let currentItemIndex {
            if index == currentItemIndex {
                self.currentItemIndex = items.isEmpty ? nil : min(currentItemIndex, items.count - 1)
            } else if index < currentItemIndex {
                self.currentItemIndex = currentItemIndex - 1
            }
        }
        notifyStateChange()
    }

    public func moveItem(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let item = items.remove(at: source)
        let insertIndex = min(destination, items.count)
        items.insert(item, at: insertIndex)
        if let currentItemIndex {
            if currentItemIndex == source {
                self.currentItemIndex = insertIndex
            } else if source < currentItemIndex, insertIndex >= currentItemIndex {
                self.currentItemIndex = currentItemIndex - 1
            } else if source > currentItemIndex, insertIndex <= currentItemIndex {
                self.currentItemIndex = currentItemIndex + 1
            }
        }
        notifyStateChange()
    }

    /// Current playlist items (for persistence).
    public func currentItems() -> [ClipItem] {
        items
    }

    /// Current playback order (for persistence).
    public func currentPlaybackOrder() -> PlaybackOrder {
        playbackOrder
    }

    // MARK: - Transport Controls

    public func play() {
        guard !items.isEmpty else {
            lastErrorMessage = "No items in playlist."
            notifyStateChange()
            return
        }
        startPlayback(at: currentItemIndex ?? 0)
    }

    public func pause() {
        guard runState == .playing else { return }
        playbackTask?.cancel()
        playbackTask = nil
        runState = .paused
        notifyStateChange()
    }

    public func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        runState = .stopped
        currentItemIndex = items.isEmpty ? nil : 0
        audioBufferIndex = 0
        notifyStateChange()
    }

    public func next() {
        guard !items.isEmpty else { return }
        let nextIdx = nextIndex(after: currentItemIndex ?? 0)
        currentItemIndex = nextIdx
        if runState == .playing {
            startPlayback(at: nextIdx)
        }
        notifyStateChange()
    }

    public func previous() {
        guard !items.isEmpty else { return }
        let prevIdx = previousIndex(before: currentItemIndex ?? 0)
        currentItemIndex = prevIdx
        if runState == .playing {
            startPlayback(at: prevIdx)
        }
        notifyStateChange()
    }

    public func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        currentItemIndex = index
        if runState == .playing {
            startPlayback(at: index)
        }
        notifyStateChange()
    }

    // MARK: - Snapshot

    public func snapshot() -> ClipPlayerSnapshot {
        let currentItem = currentItemIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }
        return ClipPlayerSnapshot(
            runState: runState,
            producerID: producerID,
            currentItemIndex: currentItemIndex,
            currentItemID: currentItem?.id,
            currentItemName: currentItem?.displayName,
            totalItemCount: items.count,
            playbackOrder: playbackOrder,
            lastErrorMessage: lastErrorMessage,
            capturedAt: Date()
        )
    }

    // MARK: - Shutdown

    public func shutdown() {
        playbackTask?.cancel()
        playbackTask = nil
        runState = .stopped
        unregister()
        surface = nil
    }
}

// MARK: - Private Playback

private extension ClipPlayerProducer {
    func startPlayback(at index: Int) {
        playbackTask?.cancel()
        guard items.indices.contains(index) else {
            runState = .stopped
            notifyStateChange()
            return
        }
        runState = .playing
        currentItemIndex = index
        audioBufferIndex = 0
        if playbackOrder == .random {
            rebuildShuffleOrder(startingAt: index)
        }
        notifyStateChange()
        playbackTask = Task { await runPlaybackLoop(startingAt: index) }
    }

    func runPlaybackLoop(startingAt startIndex: Int) async {
        var nextIdx: Int? = startIndex
        while !Task.isCancelled {
            guard let itemIndex = nextIdx, items.indices.contains(itemIndex) else {
                runState = .stopped
                notifyStateChange()
                return
            }

            currentItemIndex = itemIndex
            lastErrorMessage = nil
            notifyStateChange()

            let item = items[itemIndex]

            // Task 53: Signal transition to Core's dissolve engine on clip advance.
            if itemIndex != startIndex || nextIdx != Optional(startIndex) {
                signalClipTransition(for: item)
            }

            let didPlay: Bool

            switch item.type {
            case .video:
                didPlay = await playVideoItem(item)
            case .still:
                didPlay = await playStillItem(item)
            }

            if Task.isCancelled || runState != .playing { return }

            if !didPlay {
                lastErrorMessage = "Could not play \(item.displayName)."
                notifyStateChange()
            }

            nextIdx = nextIndex(after: itemIndex)
        }
    }

    // Task 50: AVAssetReader decode loop with IOSurface-backed CVPixelBuffer.
    // PTS-paced frame push via pushLocalVideoFrame XPC.
    func playVideoItem(_ item: ClipItem) async -> Bool {
        let readerContext = VideoReaderContext(
            url: item.url,
            width: videoFormat.width,
            height: videoFormat.height
        )
        guard let readerContext, let firstVideo = readerContext.firstVideoSample else {
            return false
        }

        pushVideoFrame(firstVideo.frameData)

        var nextVideo = readerContext.nextVideoSample()
        var nextAudio = readerContext.firstAudioSample
        let playbackStartedAt = Date()
        let zeroPTS = min(
            firstVideo.ptsSeconds,
            nextAudio?.ptsSeconds ?? firstVideo.ptsSeconds
        )

        // Audio slicing state (Task 51): re-chunk decoded audio to correct buffer sizes
        var audioSlicer = AudioSlicer(
            audioBufferIndex: audioBufferIndex,
            sampleRate: 48_000,
            frameRateNumerator: videoFormat.frameRateNumerator,
            frameRateDenominator: videoFormat.frameRateDenominator
        )

        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(playbackStartedAt)
            let nextDueSeconds = min(
                nextVideo.map { max(0, $0.ptsSeconds - zeroPTS) } ?? .infinity,
                nextAudio.map { max(0, $0.ptsSeconds - zeroPTS) } ?? .infinity
            )

            if nextDueSeconds.isInfinite { break }

            if nextDueSeconds > elapsed {
                // DOCUMENTED EXCEPTION: PTS-paced sleep for clip playback timing
                let sleepNs = UInt64(max(1_000_000, (nextDueSeconds - elapsed) * 1_000_000_000))
                try? await Task.sleep(nanoseconds: sleepNs)
                continue
            }

            if let audioSample = nextAudio,
               audioSample.ptsSeconds - zeroPTS <= elapsed + 0.001 {
                // Task 51: Slice decoded audio into OutputAudioBufferSizing chunks
                audioSlicer.feed(audioSample)
                while let chunk = audioSlicer.nextChunk() {
                    pushAudioChunk(chunk)
                }
                nextAudio = readerContext.nextAudioSample()
            }

            if let videoSample = nextVideo,
               videoSample.ptsSeconds - zeroPTS <= elapsed + 0.001 {
                pushVideoFrame(videoSample.frameData)
                nextVideo = readerContext.nextVideoSample()
            }
        }

        // Preserve audio buffer index continuity across clips
        audioBufferIndex = audioSlicer.currentAudioBufferIndex

        return true
    }

    // Task 52: Still images — repeat pushLocalVideoFrame at output frame rate for configured duration.
    // Push silence audio alongside each frame.
    func playStillItem(_ item: ClipItem) async -> Bool {
        guard let frameData = renderStillImage(at: item.url) else { return false }

        let dwellSeconds = item.durationOverride ?? ClipPlayerConstants.defaultStillDuration
        let frameDurationNs = UInt64(
            Double(videoFormat.frameRateDenominator) / Double(videoFormat.frameRateNumerator) * 1_000_000_000
        )
        let totalFrames = Int(dwellSeconds * Double(videoFormat.frameRateNumerator) / Double(videoFormat.frameRateDenominator))

        var frameStart = ContinuousClock.now

        for _ in 0..<totalFrames {
            if Task.isCancelled { return true }

            pushVideoFrame(frameData)

            // Push silence audio (two buffers per video frame)
            for _ in 0..<2 {
                let sampleCount = OutputAudioBufferSizing.sampleCount(
                    forFrameIndex: audioBufferIndex,
                    sampleRate: 48_000,
                    frameRateNumerator: videoFormat.frameRateNumerator,
                    frameRateDenominator: videoFormat.frameRateDenominator
                )
                pushSilentAudio(sampleCount: sampleCount)
                audioBufferIndex += 1
            }

            // PTS-paced frame rate sleep
            frameStart = frameStart + .nanoseconds(Int(frameDurationNs))
            let sleepUntil = frameStart
            let remaining = sleepUntil - .now
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
        }

        return true
    }
}

// MARK: - Frame Push via XPC

private extension ClipPlayerProducer {
    func ensureSurface() {
        let w = videoFormat.width
        let h = videoFormat.height
        if let existing = surface,
           existing.width == w,
           existing.height == h {
            return
        }

        let properties: [IOSurfacePropertyKey: Any] = [
            .width: w,
            .height: h,
            .bytesPerElement: 4,
            .bytesPerRow: w * 4,
            .allocSize: w * h * 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        surface = IOSurface(properties: properties)
    }

    func pushVideoFrame(_ frameData: Data) {
        guard let coreCommands, let producerID, let surface else { return }

        surface.lock(options: [], seed: nil)
        frameData.withUnsafeBytes { rawBuffer in
            guard let sourceBase = rawBuffer.baseAddress else { return }
            let destBase = surface.baseAddress
            let copyBytes = min(frameData.count, surface.allocationSize)
            memcpy(destBase, sourceBase, copyBytes)
        }
        surface.unlock(options: [], seed: nil)

        videoSequence &+= 1
        guard let formatData = try? JSONEncoder().encode(videoFormat) else { return }
        coreCommands.pushLocalVideoFrame(
            producerID: producerID,
            surfaceID: IOSurfaceGetID(surface),
            formatData: formatData
        ) { _ in }
    }

    func pushAudioChunk(_ chunk: AudioChunk) {
        guard let coreCommands, let producerID else { return }

        let audioFormat = AudioFrameFormat(
            sampleRate: 48_000,
            channels: 2,
            samplesPerBuffer: chunk.sampleCount
        )
        guard let formatData = try? JSONEncoder().encode(audioFormat) else { return }
        coreCommands.pushLocalAudioBuffer(
            producerID: producerID,
            bufferData: chunk.pcmPlanarFloat32,
            formatData: formatData
        ) { _ in }
    }

    func pushSilentAudio(sampleCount: Int) {
        guard let coreCommands, let producerID else { return }

        let audioFormat = AudioFrameFormat(
            sampleRate: 48_000,
            channels: 2,
            samplesPerBuffer: sampleCount
        )
        let channelStride = sampleCount * MemoryLayout<Float>.size
        let silentPCM = Data(count: channelStride * audioFormat.channels)

        guard let formatData = try? JSONEncoder().encode(audioFormat) else { return }
        coreCommands.pushLocalAudioBuffer(
            producerID: producerID,
            bufferData: silentPCM,
            formatData: formatData
        ) { _ in }
    }

    // Task 53: Signal clip transition via setProgram with transition type.
    // Core's dissolve engine handles blend between outgoing and incoming clip frames.
    func signalClipTransition(for item: ClipItem) {
        guard let coreCommands, let producerID else { return }
        let config = TransitionConfig(kind: item.transitionKind)
        guard let transitionData = try? JSONEncoder().encode(config) else { return }
        coreCommands.setProgram(
            sourceID: producerID,
            transitionData: transitionData
        ) { _, _ in }
    }
}

// MARK: - Audio Slicer (Task 51)

/// Re-chunks decoded audio into OutputAudioBufferSizing-aligned buffers.
/// AVAssetReader may return arbitrary chunk sizes; this ensures each push
/// matches the correct sample count — never 48000 samples at once.
struct AudioSlicer {
    private var residualPCM = Data()
    private var residualSampleCount = 0
    private(set) var currentAudioBufferIndex: UInt64
    private let sampleRate: Int
    private let frameRateNumerator: Int
    private let frameRateDenominator: Int
    private let channels = 2

    init(
        audioBufferIndex: UInt64,
        sampleRate: Int,
        frameRateNumerator: Int,
        frameRateDenominator: Int
    ) {
        self.currentAudioBufferIndex = audioBufferIndex
        self.sampleRate = sampleRate
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
    }

    /// Feed a decoded audio sample into the slicer.
    mutating func feed(_ sample: AudioSliceSample) {
        residualPCM.append(sample.pcmPlanarFloat32)
        residualSampleCount += sample.sampleCount
    }

    /// Extract the next correctly-sized chunk, or nil if not enough samples.
    mutating func nextChunk() -> AudioChunk? {
        let targetSamples = OutputAudioBufferSizing.sampleCount(
            forFrameIndex: currentAudioBufferIndex,
            sampleRate: sampleRate,
            frameRateNumerator: frameRateNumerator,
            frameRateDenominator: frameRateDenominator
        )

        guard residualSampleCount >= targetSamples else { return nil }

        // Planar stereo: L plane (targetSamples * 4 bytes) + R plane (targetSamples * 4 bytes)
        let bytesPerSample = MemoryLayout<Float>.size
        let channelStride = targetSamples * bytesPerSample
        let totalBytes = channelStride * channels

        // Extract from planar residual: need to extract targetSamples from each channel plane
        let residualChannelStride = residualSampleCount * bytesPerSample
        var chunk = Data(count: totalBytes)

        chunk.withUnsafeMutableBytes { destBuf in
            guard let destBase = destBuf.baseAddress else { return }
            residualPCM.withUnsafeBytes { srcBuf in
                guard let srcBase = srcBuf.baseAddress else { return }
                // Copy L plane slice
                memcpy(destBase, srcBase, channelStride)
                // Copy R plane slice
                memcpy(
                    destBase.advanced(by: channelStride),
                    srcBase.advanced(by: residualChannelStride),
                    channelStride
                )
            }
        }

        // Remove consumed samples from residual
        var newResidual = Data(count: (residualSampleCount - targetSamples) * bytesPerSample * channels)
        let remainingSamples = residualSampleCount - targetSamples
        if remainingSamples > 0 {
            let remainingChannelBytes = remainingSamples * bytesPerSample
            newResidual.withUnsafeMutableBytes { destBuf in
                guard let destBase = destBuf.baseAddress else { return }
                residualPCM.withUnsafeBytes { srcBuf in
                    guard let srcBase = srcBuf.baseAddress else { return }
                    // Copy remaining L plane
                    memcpy(destBase, srcBase.advanced(by: channelStride), remainingChannelBytes)
                    // Copy remaining R plane
                    memcpy(
                        destBase.advanced(by: remainingChannelBytes),
                        srcBase.advanced(by: residualChannelStride + channelStride),
                        remainingChannelBytes
                    )
                }
            }
        }
        residualPCM = newResidual
        residualSampleCount = remainingSamples
        currentAudioBufferIndex += 1

        return AudioChunk(sampleCount: targetSamples, pcmPlanarFloat32: chunk)
    }
}

/// A correctly-sized audio chunk ready for XPC push.
struct AudioChunk {
    let sampleCount: Int
    let pcmPlanarFloat32: Data
}

// MARK: - Image Rendering

private extension ClipPlayerProducer {
    // Task 52: CGImageSource render to BGRA pixel data.
    func renderStillImage(at url: URL) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let w = videoFormat.width
        let h = videoFormat.height
        let lineStride = w * 4
        let byteCount = lineStride * h
        var pixelData = Data(count: byteCount)
        let didRender = pixelData.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: lineStride,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return false
            }

            context.setFillColor(CGColor.black)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))

            // Letterbox/pillarbox to maintain aspect ratio
            let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let outputAspect = CGFloat(w) / CGFloat(max(1, h))
            let drawRect: CGRect
            if imageAspect > outputAspect {
                let renderWidth = CGFloat(w)
                let renderHeight = renderWidth / imageAspect
                drawRect = CGRect(
                    x: 0,
                    y: (CGFloat(h) - renderHeight) / 2,
                    width: renderWidth,
                    height: renderHeight
                )
            } else {
                let renderHeight = CGFloat(h)
                let renderWidth = renderHeight * imageAspect
                drawRect = CGRect(
                    x: (CGFloat(w) - renderWidth) / 2,
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
}

// MARK: - Index Navigation

private extension ClipPlayerProducer {
    func nextIndex(after index: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        switch playbackOrder {
        case .sequential:
            return (index + 1) % items.count
        case .random:
            if shuffleOrder.isEmpty {
                rebuildShuffleOrder(startingAt: index)
            }
            shufflePosition += 1
            if shufflePosition >= shuffleOrder.count {
                rebuildShuffleOrder(avoidingRepeatOf: index)
            }
            return shuffleOrder[min(shufflePosition, max(0, shuffleOrder.count - 1))]
        }
    }

    func previousIndex(before index: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        switch playbackOrder {
        case .sequential:
            return (index - 1 + items.count) % items.count
        case .random:
            if shuffleOrder.isEmpty {
                rebuildShuffleOrder(startingAt: index)
            }
            shufflePosition = max(0, shufflePosition - 1)
            return shuffleOrder[min(shufflePosition, max(0, shuffleOrder.count - 1))]
        }
    }

    func rebuildShuffleOrder(startingAt startIndex: Int) {
        var order = Array(items.indices)
        order.shuffle()
        if let existingIdx = order.firstIndex(of: startIndex) {
            order.swapAt(0, existingIdx)
        }
        shuffleOrder = order
        shufflePosition = 0
    }

    func rebuildShuffleOrder(avoidingRepeatOf lastIndex: Int) {
        var order = Array(items.indices)
        order.shuffle()
        if order.first == lastIndex, order.count > 1 {
            order.swapAt(0, 1)
        }
        shuffleOrder = order
        shufflePosition = 0
    }
}

// MARK: - Notifications

private extension ClipPlayerProducer {
    func notifyStateChange() {
        stateDidChange?()
    }
}
