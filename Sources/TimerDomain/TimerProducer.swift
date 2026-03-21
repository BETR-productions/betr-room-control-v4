// TimerProducer — local producer for countdown/end-time timer overlay.
// Registers with BETRCoreAgent, renders via CoreText, pushes frames via IOSurface XPC.
// Uses OutputAudioBufferSizing (AudioFrameFormat.samplesPerBuffer) for correct frame-aligned silent audio.

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
    private var tickTask: Task<Void, Never>?

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
        notifyStateChange()
    }

    // MARK: - Controls

    public func setDuration(seconds: Int) {
        mode = .duration(seconds: max(1, seconds))
        if runState == .stopped {
            remainingSeconds = max(1, seconds)
        }
        renderAndPushCurrentFrame()
        notifyStateChange()
    }

    public func setEndTime(target: Date) {
        mode = .endTime(target: target)
        if runState == .stopped {
            remainingSeconds = max(0, Int(ceil(target.timeIntervalSince(Date()))))
        }
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
        renderAndPushCurrentFrame()
        startTickTask()
        notifyStateChange()
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        runState = .stopped
        runningStartedAt = nil
        remainingSeconds = initialRemainingSeconds(now: Date())
        renderAndPushCurrentFrame()
        notifyStateChange()
    }

    public func pause() {
        guard runState == .running else { return }
        let now = Date()
        remainingSeconds = computeRemainingSeconds(at: now)
        runningStartedAt = nil
        runState = .paused
        tickTask?.cancel()
        tickTask = nil
        renderAndPushCurrentFrame()
        notifyStateChange()
    }

    public func resume() {
        guard runState == .paused else { return }
        let now = Date()
        runningBaseRemainingSeconds = remainingSeconds
        runningStartedAt = now
        runState = .running
        renderAndPushCurrentFrame()
        startTickTask()
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
        tickTask?.cancel()
        tickTask = nil
        runState = .stopped
        runningStartedAt = nil
        unregister()
        surface = nil
    }
}

// MARK: - Tick Loop

private extension TimerProducer {
    func startTickTask() {
        tickTask?.cancel()
        tickTask = Task { await runTickLoop() }
    }

    func runTickLoop() async {
        while !Task.isCancelled, runState == .running {
            let now = Date()
            let nextRemaining = computeRemainingSeconds(at: now)
            if nextRemaining != remainingSeconds {
                remainingSeconds = nextRemaining
                renderAndPushCurrentFrame()
                notifyStateChange()
                if nextRemaining == 0 {
                    runState = .stopped
                    runningStartedAt = nil
                    tickTask = nil
                    notifyStateChange()
                    return
                }
            }

            // Sleep until next second boundary
            let fractional = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            let nextSleep = max(0.05, 1.0 - fractional)
            try? await Task.sleep(nanoseconds: UInt64(nextSleep * 1_000_000_000))
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

    func renderAndPushCurrentFrame() {
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
            subtitle = "Paused locally in BËTR Room Control"
        case .stopped:
            title = "Timer Ready"
            subtitle = "Idle timer sender is on-air"
        }

        guard let pixelData = TimerFrameRenderer.render(
            width: videoFormat.width,
            height: videoFormat.height,
            title: title,
            subtitle: subtitle,
            timeText: formattedTime(remainingSeconds),
            isRunning: runState == .running
        ) else {
            return
        }

        pushVideoFrame(pixelData)
        pushSilentAudio()
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

    /// Push silent audio using correct frame-aligned buffer sizing.
    /// Uses AudioFrameFormat.samplesPerBuffer (default 480) instead of hardcoded 48000.
    func pushSilentAudio() {
        guard let coreCommands, let producerID else { return }

        let audioFormat = AudioFrameFormat(
            sampleRate: 48_000,
            channels: 2,
            samplesPerBuffer: 480
        )
        let channelStride = audioFormat.samplesPerBuffer * MemoryLayout<Float>.size
        let silentPCM = Data(count: channelStride * audioFormat.channels)

        guard let formatData = try? JSONEncoder().encode(audioFormat) else { return }
        coreCommands.pushLocalAudioBuffer(
            producerID: producerID,
            bufferData: silentPCM,
            formatData: formatData
        ) { _ in }
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
