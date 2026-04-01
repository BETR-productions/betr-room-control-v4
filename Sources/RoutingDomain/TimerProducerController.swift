import CoreNDIPlatform
import Foundation
import TimerDomain

public actor TimerProducerController {
    public static let managedSourceID = "managed:timer"
    public static let senderName = "BETR Room Control (Timer)"

    private enum Timing {
        static let width = 1920
        static let height = 1080
        static let frameRateNumerator = 30_000
        static let frameRateDenominator = 1_001
        static let sampleRate = 48_000
        static let channelCount = 2
    }

    private let coreAgentClient: BETRCoreAgentClient
    private let stateUpdate: @Sendable (TimerRuntimeSnapshot) -> Void

    private var configuredState: SimpleTimerState?
    private var runState: TimerRunState = .stopped
    private var remainingSeconds = 600
    private var runningBaseRemainingSeconds = 600
    private var runningStartedAt: Date?
    private var lastTickAt: Date?
    private var lastRenderedAt: Date?
    private var sourceEpoch: Int64 = 0
    private var videoSequence: UInt64 = 0
    private var audioSequence: UInt64 = 0
    private var tickTask: Task<Void, Never>?
    private var isRegistered = false

    public init(
        coreAgentClient: BETRCoreAgentClient,
        stateUpdate: @escaping @Sendable (TimerRuntimeSnapshot) -> Void = { _ in }
    ) {
        self.coreAgentClient = coreAgentClient
        self.stateUpdate = stateUpdate
    }

    public func configure(state: SimpleTimerState?) async {
        configuredState = state
        if runState == .stopped {
            remainingSeconds = initialRemainingSeconds(for: state, now: Date())
        }

        if state?.outputEnabled == true {
            do {
                try await ensureRegistered()
                await renderCurrentFrame()
            } catch {
                await publishStateUpdate()
            }
        } else {
            await unregisterIfNeeded()
            lastRenderedAt = nil
            await publishStateUpdate()
        }
    }

    public func start(state: SimpleTimerState) async {
        configuredState = state
        let now = Date()
        let initialRemaining = initialRemainingSeconds(for: state, now: now)
        remainingSeconds = initialRemaining
        runningBaseRemainingSeconds = initialRemaining
        runningStartedAt = now
        runState = .running
        lastTickAt = now
        if state.outputEnabled {
            try? await ensureRegistered()
        }
        startTickLoopIfNeeded()
        await renderCurrentFrame()
        await publishStateUpdate()
    }

    public func pause() async {
        guard runState == .running else { return }
        let now = Date()
        remainingSeconds = currentRemainingSeconds(at: now)
        runningStartedAt = nil
        runState = .paused
        tickTask?.cancel()
        tickTask = nil
        lastTickAt = now
        await renderCurrentFrame()
        await publishStateUpdate()
    }

    public func resume() async {
        guard runState == .paused, let configuredState else { return }
        let now = Date()
        runningBaseRemainingSeconds = remainingSeconds
        runningStartedAt = now
        runState = .running
        lastTickAt = now
        if configuredState.outputEnabled {
            try? await ensureRegistered()
        }
        startTickLoopIfNeeded()
        await renderCurrentFrame()
        await publishStateUpdate()
    }

    public func stop() async {
        tickTask?.cancel()
        tickTask = nil
        runState = .stopped
        runningStartedAt = nil
        remainingSeconds = initialRemainingSeconds(for: configuredState, now: Date())
        lastTickAt = Date()
        await renderCurrentFrame()
        await publishStateUpdate()
    }

    public func restart(state: SimpleTimerState) async {
        await start(state: state)
    }

    public func snapshot() -> TimerRuntimeSnapshot {
        TimerRuntimeSnapshot(
            configuredState: configuredState,
            runState: runState,
            remainingSeconds: remainingSeconds,
            outputEnabled: configuredState?.outputEnabled ?? false,
            senderReady: isRegistered && configuredState?.outputEnabled == true,
            senderConnectionCount: 0,
            displayText: formattedTime(remainingSeconds),
            lastTickAt: lastTickAt,
            lastRenderedAt: lastRenderedAt
        )
    }

    public func shutdown() async {
        tickTask?.cancel()
        tickTask = nil
        configuredState = nil
        runState = .stopped
        runningStartedAt = nil
        await unregisterIfNeeded()
        await publishStateUpdate()
    }
}

private extension TimerProducerController {
    var descriptor: LocalProducerDescriptor {
        LocalProducerDescriptor(
            id: Self.managedSourceID,
            displayName: "Timer",
            advertisedSourceName: Self.senderName,
            videoFormat: .bgra8,
            audioFormat: .float32PlanarStereo48k
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
        try? await coreAgentClient.unregisterLocalProducer(sourceID: Self.managedSourceID)
        isRegistered = false
        sourceEpoch = 0
        videoSequence = 0
        audioSequence = 0
    }

    func startTickLoopIfNeeded() {
        tickTask?.cancel()
        tickTask = Task {
            await runTickLoop()
        }
    }

    func runTickLoop() async {
        while !Task.isCancelled, runState == .running {
            let now = Date()
            let nextRemaining = currentRemainingSeconds(at: now)
            if nextRemaining != remainingSeconds {
                remainingSeconds = nextRemaining
                lastTickAt = now
                await renderCurrentFrame()
                await publishStateUpdate()
                if nextRemaining == 0 {
                    runState = .stopped
                    runningStartedAt = nil
                    tickTask = nil
                    await renderCurrentFrame()
                    await publishStateUpdate()
                    return
                }
            }

            let fractional = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            let nextSleep = max(0.05, 1.0 - fractional)
            try? await Task.sleep(nanoseconds: UInt64(nextSleep * 1_000_000_000))
        }
    }

    func currentRemainingSeconds(at now: Date) -> Int {
        guard runState == .running, let runningStartedAt else {
            return remainingSeconds
        }
        let elapsed = now.timeIntervalSince(runningStartedAt)
        return max(0, Int(ceil(Double(runningBaseRemainingSeconds) - elapsed)))
    }

    func initialRemainingSeconds(for state: SimpleTimerState?, now: Date) -> Int {
        guard let state else { return 600 }
        switch state.mode {
        case .duration:
            return max(1, state.durationSeconds ?? state.remainingSeconds ?? 600)
        case .endTime:
            guard let endTime = state.endTime else { return 0 }
            return max(0, Int(ceil(endTime.timeIntervalSince(now))))
        }
    }

    func renderCurrentFrame() async {
        guard let configuredState else {
            return
        }

        guard configuredState.outputEnabled else {
            lastRenderedAt = nil
            return
        }

        do {
            try await ensureRegistered()
        } catch {
            return
        }

        let title = switch runState {
        case .running:
            "Timer Running"
        case .paused:
            "Timer Paused"
        case .stopped:
            "Timer Ready"
        }
        let subtitle = switch runState {
        case .running:
            configuredState.mode == .endTime ? "End-time countdown active" : "Duration countdown active"
        case .paused:
            "Paused locally in BETR Room Control"
        case .stopped:
            configuredState.outputEnabled ? "Timer output is ready to route" : "Timer output is disabled"
        }

        guard let pixelData = TimerFrameRenderer.render(
            width: Timing.width,
            height: Timing.height,
            title: title,
            subtitle: subtitle,
            timeText: formattedTime(remainingSeconds),
            isRunning: runState == .running
        ) else {
            return
        }

        let mediaTimestampNanoseconds = Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded())
        videoSequence &+= 1
        try? await coreAgentClient.pushLocalVideoFrame(
            sourceID: Self.managedSourceID,
            sourceEpoch: sourceEpoch,
            sequence: videoSequence,
            width: Timing.width,
            height: Timing.height,
            lineStride: Timing.width * 4,
            pixelData: pixelData,
            timecodeNs: mediaTimestampNanoseconds
        )

        let sampleCount = halfFrameAudioSampleCount()
        let channelStride = sampleCount * MemoryLayout<Float>.size
        let pcmFloat32LE = Data(count: channelStride * Timing.channelCount)
        audioSequence &+= 1
        try? await coreAgentClient.pushLocalAudioBuffer(
            sourceID: Self.managedSourceID,
            sourceEpoch: sourceEpoch,
            sequence: audioSequence,
            sampleRate: Timing.sampleRate,
            channels: Timing.channelCount,
            sampleCount: sampleCount,
            channelStrideInBytes: channelStride,
            pcmFloat32LE: pcmFloat32LE,
            timestampNanoseconds: mediaTimestampNanoseconds
        )

        lastRenderedAt = Date()
    }

    func halfFrameAudioSampleCount() -> Int {
        let frameDurationSeconds = Double(Timing.frameRateDenominator) / Double(Timing.frameRateNumerator)
        let sampleCount = Double(Timing.sampleRate) * frameDurationSeconds * 0.5
        return max(1, Int(sampleCount.rounded()))
    }

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

    func nextSourceEpoch() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    func publishStateUpdate() async {
        stateUpdate(snapshot())
    }
}
