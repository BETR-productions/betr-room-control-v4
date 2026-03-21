// TimerProducer — local producer for countdown/end-time timer overlay.
// Registers with BETRCoreAgent, renders via CoreText, pushes frames via IOSurface XPC.
// Pushes video at output frame rate (29.97fps). Renders new frame only when time text changes.
// Uses OutputAudioBufferSizing for correct frame-aligned silent audio — never 480 or 48000 samples.

import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import RoomControlXPCContracts

// MARK: - Timer Producer

public actor TimerProducer {
    // MARK: - Producer registration

    private var producerID: String?
    private var coreCommands: BETRCoreXPCCommands?
    private var videoFormat: VideoFrameFormat

    // MARK: - Timer state

    private var mode: TimerMode = .duration(seconds: TimerConstants.defaultDurationSeconds)
    private var runState: TimerRunState = .stopped
    private var remainingSeconds: Int = TimerConstants.defaultDurationSeconds
    private var runningBaseRemainingSeconds: Int = TimerConstants.defaultDurationSeconds
    private var runningStartedAt: Date?

    // MARK: - Frame delivery

    private var surface: IOSurface?
    private var frameRateTask: Task<Void, Never>?
    private var audioBufferIndex: UInt64 = 0

    // MARK: - Frame caching (Task 56: reuse when time string unchanged)

    private var cachedFrameData: Data?
    private var cachedTimeText: String?

    // MARK: - Callbacks

    private let stateDidChange: (@Sendable () -> Void)?

    // MARK: - Init

    public init(
        width: Int = TimerConstants.defaultWidth,
        height: Int = TimerConstants.defaultHeight,
        frameRateNumerator: Int = TimerConstants.defaultFrameRateNumerator,
        frameRateDenominator: Int = TimerConstants.defaultFrameRateDenominator,
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
            name: TimerConstants.producerName,
            producerProtocol: .ioSurface,
            hasVideo: true,
            hasAudio: true
        )
        guard let data = try? JSONEncoder().encode(descriptor) else { return }
        commands.registerLocalProducer(descriptorData: data) { [weak self] success, _ in
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
        renderAndPushCurrentFrame()
        startFrameRateTask()
        notifyStateChange()
    }

    // MARK: - Controls

    public func setDuration(seconds: Int) {
        mode = .duration(seconds: max(1, seconds))
        if runState == .stopped {
            remainingSeconds = max(1, seconds)
        }
        invalidateFrameCache()
        renderAndPushCurrentFrame()
        notifyStateChange()
    }

    public func setEndTime(target: Date) {
        mode = .endTime(target: target)
        if runState == .stopped {
            remainingSeconds = max(0, Int(ceil(target.timeIntervalSince(Date()))))
        }
        invalidateFrameCache()
        renderAndPushCurrentFrame()
        notifyStateChange()
    }

    public func start() {
        let now = Date()
        let initial = initialRemainingSeconds(now: now)
        remainingSeconds = initial
        runningBaseRemainingSeconds = initial
        runningStartedAt = now
        runState = .running
        audioBufferIndex = 0
        invalidateFrameCache()
        renderAndPushCurrentFrame()
        startFrameRateTask()
        notifyStateChange()
    }

    public func stop() {
        frameRateTask?.cancel()
        frameRateTask = nil
        runState = .stopped
        runningStartedAt = nil
        remainingSeconds = initialRemainingSeconds(now: Date())
        audioBufferIndex = 0
        invalidateFrameCache()
        renderAndPushCurrentFrame()
        notifyStateChange()
    }

    public func pause() {
        guard runState == .running else { return }
        let now = Date()
        remainingSeconds = computeRemainingSeconds(at: now)
        runningStartedAt = nil
        runState = .paused
        invalidateFrameCache()
        renderAndPushCurrentFrame()
        notifyStateChange()
    }

    public func resume() {
        guard runState == .paused else { return }
        let now = Date()
        runningBaseRemainingSeconds = remainingSeconds
        runningStartedAt = now
        runState = .running
        audioBufferIndex = 0
        invalidateFrameCache()
        renderAndPushCurrentFrame()
        startFrameRateTask()
        notifyStateChange()
    }

    public func restart() {
        stop()
        start()
    }

    // MARK: - Snapshot

    public func snapshot() -> TimerSnapshot {
        TimerSnapshot(
            mode: mode,
            runState: runState,
            remainingSeconds: remainingSeconds,
            displayText: formattedTime(remainingSeconds),
            producerID: producerID,
            capturedAt: Date()
        )
    }

    // MARK: - Shutdown

    public func shutdown() {
        frameRateTask?.cancel()
        frameRateTask = nil
        runState = .stopped
        runningStartedAt = nil
        unregister()
        surface = nil
        cachedFrameData = nil
        cachedTimeText = nil
    }
}

// MARK: - Frame-Rate Push Loop (Task 57)

private extension TimerProducer {
    func startFrameRateTask() {
        frameRateTask?.cancel()
        guard runState == .running else { return }
        frameRateTask = Task { await runFrameRateLoop() }
    }

    /// Pushes video + audio at output frame rate (29.97fps).
    /// Renders a new frame only when the time text changes (once per second).
    /// Holds the cached frame otherwise.
    func runFrameRateLoop() async {
        let frameDurationNs = UInt64(
            Double(videoFormat.frameRateDenominator) / Double(videoFormat.frameRateNumerator) * 1_000_000_000
        )
        var frameStart = ContinuousClock.now

        while !Task.isCancelled, runState == .running {
            let now = Date()
            let nextRemaining = computeRemainingSeconds(at: now)

            if nextRemaining != remainingSeconds {
                remainingSeconds = nextRemaining
                invalidateFrameCache()
                notifyStateChange()

                if nextRemaining == 0 {
                    renderAndPushCurrentFrame()
                    runState = .stopped
                    runningStartedAt = nil
                    frameRateTask = nil
                    notifyStateChange()
                    return
                }
            }

            renderAndPushCurrentFrame()
            pushSilentAudio()

            // PTS-paced sleep to maintain frame rate
            frameStart = frameStart + .nanoseconds(Int(frameDurationNs))
            let sleepUntil = frameStart
            let remaining = sleepUntil - .now
            if remaining > .zero {
                try? await Task.sleep(for: remaining) // DOCUMENTED EXCEPTION: timer frame pacing, not media hot path
            }
        }
    }

    func computeRemainingSeconds(at now: Date) -> Int {
        guard runState == .running, let runningStartedAt else {
            return remainingSeconds
        }
        let elapsed = now.timeIntervalSince(runningStartedAt)
        return max(0, Int(ceil(Double(runningBaseRemainingSeconds) - elapsed)))
    }

    func initialRemainingSeconds(now: Date) -> Int {
        switch mode {
        case .duration(let seconds):
            return max(1, seconds)
        case .endTime(let target):
            return max(0, Int(ceil(target.timeIntervalSince(now))))
        }
    }
}

// MARK: - Frame Rendering & Push

private extension TimerProducer {
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

    func invalidateFrameCache() {
        cachedFrameData = nil
        cachedTimeText = nil
    }

    func renderAndPushCurrentFrame() {
        let timeText = formattedTime(remainingSeconds)
        let title: String
        let subtitle: String
        switch runState {
        case .running:
            title = "Timer Running"
            switch mode {
            case .endTime: subtitle = "End-time countdown active"
            case .duration: subtitle = "Duration countdown active"
            }
        case .paused:
            title = "Timer Paused"
            subtitle = "Paused locally in BETR Room Control"
        case .stopped:
            title = "Timer Ready"
            subtitle = "Idle timer sender is on-air"
        }

        // Task 56: Reuse frame when time string unchanged (same second)
        let pixelData: Data
        if let cached = cachedFrameData, cachedTimeText == timeText {
            pixelData = cached
        } else {
            guard let rendered = TimerFrameRenderer.render(
                width: videoFormat.width,
                height: videoFormat.height,
                title: title,
                subtitle: subtitle,
                timeText: timeText,
                isRunning: runState == .running
            ) else {
                return
            }
            pixelData = rendered
            cachedFrameData = rendered
            cachedTimeText = timeText
        }

        pushVideoFrame(pixelData)
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

        guard let formatData = try? JSONEncoder().encode(videoFormat) else { return }
        coreCommands.pushLocalVideoFrame(
            producerID: producerID,
            surfaceID: IOSurfaceGetID(surface),
            formatData: formatData
        ) { _ in }
    }

    /// Push silent audio using OutputAudioBufferSizing for correct frame-aligned sizes.
    /// Task 58: Never 480 or 48000 sample blocks.
    func pushSilentAudio() {
        guard let coreCommands, let producerID else { return }

        // Two audio buffers per video frame
        for _ in 0..<2 {
            let sampleCount = OutputAudioBufferSizing.sampleCount(
                forFrameIndex: audioBufferIndex,
                sampleRate: 48_000,
                frameRateNumerator: videoFormat.frameRateNumerator,
                frameRateDenominator: videoFormat.frameRateDenominator
            )

            let audioFormat = AudioFrameFormat(
                sampleRate: 48_000,
                channels: 2,
                samplesPerBuffer: sampleCount
            )
            let channelStride = sampleCount * MemoryLayout<Float>.size
            let silentPCM = Data(count: channelStride * audioFormat.channels)

            guard let formatData = try? JSONEncoder().encode(audioFormat) else { continue }
            coreCommands.pushLocalAudioBuffer(
                producerID: producerID,
                bufferData: silentPCM,
                formatData: formatData
            ) { _ in }

            audioBufferIndex += 1
        }
    }
}

// MARK: - Formatting

private extension TimerProducer {
    func formattedTime(_ totalSeconds: Int) -> String {
        let safeSeconds = max(0, totalSeconds)
        let hours = safeSeconds / 3600
        let minutes = (safeSeconds % 3600) / 60
        let seconds = safeSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Notifications

private extension TimerProducer {
    func notifyStateChange() {
        stateDidChange?()
    }
}
