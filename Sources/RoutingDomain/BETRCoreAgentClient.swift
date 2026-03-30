import BETRCoreXPC
import CoreNDIHost
import CoreNDIOutput
import CoreNDIPlatform
import Foundation
import HostWizardDomain
import RoomControlUIContracts

public enum BETRCoreAgentClientError: LocalizedError {
    case slotUnassigned(String)
    case operationRejected(String)
    case unsupported(String)
    case malformedResponse
    case xpcUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .slotUnassigned(slotID):
            return "No source is assigned to \(slotID) yet."
        case let .operationRejected(message),
             let .unsupported(message),
             let .xpcUnavailable(message):
            return message
        case .malformedResponse:
            return "BETRCoreAgent returned a malformed response."
        }
    }
}

private final class BETRCoreAgentReplyGate<T> {
    private let lock = NSLock()
    private var completed = false
    private let finishImpl: (Result<T, Error>) -> Void

    init(finishImpl: @escaping (Result<T, Error>) -> Void) {
        self.finishImpl = finishImpl
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard completed == false else { return }
        completed = true
        finishImpl(result)
    }
}

private final class BETRCoreAgentEventReceiver: NSObject, BETRCoreAgentMachXPCEventSink {
    private let lock = NSLock()
    private var handler: (@Sendable (BETRCoreEventEnvelope) -> Void)?

    func setHandler(_ handler: (@Sendable (BETRCoreEventEnvelope) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func receiveEvent(_ eventData: Data) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let event = try? decoder.decode(BETRCoreEventEnvelope.self, from: eventData) else {
            return
        }
        handler(event)
    }
}

public actor BETRCoreAgentClient {
    private static let hostControlOperationTimeoutNanoseconds: UInt64 = 20_000_000_000

    private let machServiceName: String
    private let operationTimeoutNanoseconds: UInt64
    private let workspaceSnapshotProvider: (@Sendable () async throws -> BETRCoreWorkspaceSnapshotResponse)?
    private let validationSnapshotProvider: (@Sendable () async throws -> BETRCoreValidationSnapshotResponse)?
    private let discoveryDebugSnapshotProvider: (@Sendable () async throws -> BETRCoreDiscoveryDebugSnapshotResponse)?
    private let commandTransport: (@Sendable (BETRCoreCommandEnvelope) async throws -> BETRCoreCommandResponseEnvelope)?
    private let outputPreviewAttachmentProvider: (@Sendable (String, UInt64) async -> OutputPreviewAttachment?)?
    private let selectedPreviewAttachmentProvider: (@Sendable (String, UInt64) async -> OutputPreviewAttachment?)?
    private let eventObservationProvider: (@Sendable (@escaping @Sendable (BETRCoreEventEnvelope) -> Void) async throws -> Void)?
    private var connection: NSXPCConnection?
    private let eventReceiver = BETRCoreAgentEventReceiver()
    private var eventSubscriptionActive = false

    public init(
        machServiceName: String = BETRCoreAgentMachServiceName,
        operationTimeoutNanoseconds: UInt64 = 3_000_000_000,
        workspaceSnapshotProvider: (@Sendable () async throws -> BETRCoreWorkspaceSnapshotResponse)? = nil,
        validationSnapshotProvider: (@Sendable () async throws -> BETRCoreValidationSnapshotResponse)? = nil,
        discoveryDebugSnapshotProvider: (@Sendable () async throws -> BETRCoreDiscoveryDebugSnapshotResponse)? = nil,
        commandTransport: (@Sendable (BETRCoreCommandEnvelope) async throws -> BETRCoreCommandResponseEnvelope)? = nil,
        outputPreviewAttachmentProvider: (@Sendable (String, UInt64) async -> OutputPreviewAttachment?)? = nil,
        selectedPreviewAttachmentProvider: (@Sendable (String, UInt64) async -> OutputPreviewAttachment?)? = nil,
        eventObservationProvider: (@Sendable (@escaping @Sendable (BETRCoreEventEnvelope) -> Void) async throws -> Void)? = nil
    ) {
        self.machServiceName = machServiceName
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        self.workspaceSnapshotProvider = workspaceSnapshotProvider
        self.validationSnapshotProvider = validationSnapshotProvider
        self.discoveryDebugSnapshotProvider = discoveryDebugSnapshotProvider
        self.commandTransport = commandTransport
        self.outputPreviewAttachmentProvider = outputPreviewAttachmentProvider
        self.selectedPreviewAttachmentProvider = selectedPreviewAttachmentProvider
        self.eventObservationProvider = eventObservationProvider
    }

    public func bootstrapShellState(rootDirectory: String) async -> FeatureShellState {
        if let workspace = try? await loadWorkspaceSnapshot() {
            return makeShellState(rootDirectory: rootDirectory, workspace: workspace)
        }
        let validation = try? await loadValidationSnapshot()
        return makeShellState(rootDirectory: rootDirectory, validation: validation)
    }

    public func currentValidationSnapshot() async -> NDIWizardValidationSnapshot {
        let validation = try? await loadValidationSnapshot()
        return makeWizardValidation(validation)
    }

    public func currentDiscoveryDebugSnapshot() async -> NDIWizardDiscoveryDebugSnapshot? {
        let snapshot = try? await loadDiscoveryDebugSnapshot()
        return snapshot.map(Self.makeDiscoveryDebugSnapshot)
    }

    public func refreshHostInterfaceInventory(rootDirectory: String) async throws -> FeatureShellState {
        let response = try await send(.refreshHostInterfaceInventory)
        guard case let .workspace(workspace) = response else {
            throw BETRCoreAgentClientError.malformedResponse
        }
        return makeShellState(rootDirectory: rootDirectory, workspace: workspace)
    }

    public func makeWizardValidationSnapshot(
        from validation: BETRCoreValidationSnapshotResponse?
    ) -> NDIWizardValidationSnapshot {
        makeWizardValidation(validation)
    }

    public func waitForAgentAvailability(
        maxAttempts: Int = 20,
        retryIntervalNanoseconds: UInt64 = 500_000_000,
        requestTimeoutNanoseconds: UInt64 = 20_000_000_000
    ) async throws -> BETRCoreWorkspaceSnapshotResponse {
        precondition(maxAttempts > 0, "maxAttempts must be positive")

        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await loadWorkspaceSnapshot(timeoutNanoseconds: requestTimeoutNanoseconds)
            } catch {
                lastError = error
                invalidateConnection()
                guard attempt < maxAttempts else { break }
                try await Task.sleep(nanoseconds: retryIntervalNanoseconds)
            }
        }

        throw lastError ?? BETRCoreAgentClientError.xpcUnavailable("BETRCoreAgent never became available.")
    }

    public func applyHostDraft(
        _ draft: HostWizardDraft,
        interfaceSummary: HostInterfaceSummary?
    ) async throws {
        let profile = Self.makeHostProfile(
            from: draft,
            interfaceSummary: interfaceSummary
        )
        _ = try await send(.applyNDIHostProfile(BETRCoreApplyNDIHostProfileRequest(profile: profile)))
    }

    public func resetNDIHostEnvironment() async throws {
        _ = try await send(.resetNDIHostEnvironment(BETRCoreResetNDIHostEnvironmentRequest()))
    }

    @discardableResult
    public func registerLocalProducer(_ descriptor: LocalProducerDescriptor) async throws -> String {
        let response = try await send(.registerLocalProducer(descriptor))
        guard case let .localProducerID(identifier) = response else {
            throw BETRCoreAgentClientError.malformedResponse
        }
        return identifier
    }

    public func unregisterLocalProducer(sourceID: String) async throws {
        _ = try await send(
            .unregisterLocalProducer(
                BETRCoreUnregisterLocalProducerRequest(sourceID: sourceID)
            )
        )
    }

    public func pushLocalVideoFrame(
        sourceID: String,
        sourceEpoch: Int64,
        sequence: UInt64,
        width: Int,
        height: Int,
        lineStride: Int,
        pixelData: Data,
        timecodeNs: Int64 = 0
    ) async throws {
        let timestampNanoseconds = timecodeNs != 0 ? timecodeNs : Int64(bitPattern: sequence)
        _ = try await send(
            .pushLocalVideoFrame(
                BETRCorePushLocalVideoFrameRequest(
                    sourceID: sourceID,
                    format: .bgra8,
                    timestampNanoseconds: timestampNanoseconds,
                    width: width,
                    height: height,
                    lineStride: lineStride,
                    pixelData: pixelData
                )
            )
        )
    }

    public func pushLocalAudioBuffer(
        sourceID: String,
        sourceEpoch: Int64,
        sequence: UInt64,
        sampleRate: Int,
        channels: Int,
        sampleCount: Int,
        channelStrideInBytes: Int,
        pcmFloat32LE: Data,
        timestampNanoseconds: Int64? = nil
    ) async throws {
        _ = try await send(
            .pushLocalAudioBuffer(
                BETRCorePushLocalAudioBufferRequest(
                    sourceID: sourceID,
                    format: .float32PlanarStereo48k,
                    timestampNanoseconds: timestampNanoseconds ?? Int64(bitPattern: sequence),
                    sampleCount: sampleCount,
                    sampleRate: sampleRate,
                    channels: channels,
                    channelStrideInBytes: channelStrideInBytes,
                    pcmFloat32LE: pcmFloat32LE
                )
            )
        )
    }

    public func takeProgram(outputID: String, slotID: String) async throws {
        _ = try await send(
            .takeProgramSlot(
                BETRCoreTakeProgramSlotRequest(
                    outputID: outputID,
                    slotID: slotID
                )
            )
        )
    }

    public func setPreview(outputID: String, slotID: String?) async throws {
        _ = try await send(
            .setPreviewSlot(
                BETRCoreSetPreviewSlotRequest(
                    outputID: outputID,
                    slotID: slotID
                )
            )
        )
    }

    public func assignSource(sourceID: String, outputID: String, slotID: String) async throws {
        let beforeWorkspace = try await loadWorkspaceSnapshot()
        let previousSourceID = assignedSourceIDIfPresent(
            outputID: outputID,
            slotID: slotID,
            workspace: beforeWorkspace
        )
        _ = try await send(
            .assignOutputSlot(
                BETRCoreAssignOutputSlotRequest(
                    outputID: outputID,
                    slotID: slotID,
                    sourceID: sourceID
                )
            )
        )

        _ = try await send(
            .connectSource(
                BETRCoreConnectSourceRequest(
                    descriptorID: sourceID,
                    activationClass: .prewarm
                )
            )
        )
        _ = try await send(.warmSource(sourceID))

        guard let previousSourceID,
              previousSourceID != sourceID else {
            return
        }

        let afterWorkspace = try await loadWorkspaceSnapshot()
        try await disconnectSourceFromAgentIfSafe(previousSourceID, workspace: afterWorkspace)
    }

    public func clearSlot(outputID: String, slotID: String) async throws {
        let beforeWorkspace = try await loadWorkspaceSnapshot()
        let removedSourceID = assignedSourceIDIfPresent(
            outputID: outputID,
            slotID: slotID,
            workspace: beforeWorkspace
        )
        guard let removedSourceID else { return }

        if isPreviewSlot(outputID: outputID, slotID: slotID, workspace: beforeWorkspace) {
            _ = try await send(.clearPreview(BETRCoreClearPreviewRequest(outputID: outputID)))
        }
        _ = try await send(
            .clearOutputSlot(
                BETRCoreClearOutputSlotRequest(
                    outputID: outputID,
                    slotID: slotID
                )
            )
        )

        let afterWorkspace = try await loadWorkspaceSnapshot()
        try await disconnectSourceFromAgentIfSafe(removedSourceID, workspace: afterWorkspace)
    }

    public func addOutput() async throws {
        _ = try await send(.addOutput(BETRCoreAddOutputRequest()))
    }

    public func removeOutput(_ outputID: String) async throws {
        _ = try await send(.removeOutput(BETRCoreRemoveOutputRequest(outputID: outputID)))
    }

    public func setOutputAudioMuted(outputID: String, muted: Bool) async throws {
        _ = try await send(
            .setOutputAudioMuted(
                BETRCoreSetOutputAudioMutedRequest(
                    outputID: outputID,
                    muted: muted
                )
            )
        )
    }

    public func setOutputSoloedLocally(outputID: String, soloed: Bool) async throws {
        _ = try await send(
            .setOutputSoloedLocally(
                BETRCoreSetOutputSoloedLocallyRequest(
                    outputID: outputID,
                    soloed: soloed
                )
            )
        )
    }

    public func refreshValidation() async throws -> NDIWizardValidationSnapshot {
        let validation = try await loadValidationSnapshot()
        return makeWizardValidation(validation)
    }

    public func refreshDiscoveryDebugSnapshot() async throws -> NDIWizardDiscoveryDebugSnapshot {
        let snapshot = try await loadDiscoveryDebugSnapshot()
        return Self.makeDiscoveryDebugSnapshot(snapshot)
    }

    public func fetchOutputPreviewAttachment(
        outputID: String,
        attachmentID: UInt64
    ) async -> OutputPreviewAttachment? {
        if let outputPreviewAttachmentProvider {
            return await outputPreviewAttachmentProvider(outputID, attachmentID)
        }

        ensureConnection()

        do {
            return try await requestOutputPreviewAttachment(outputID: outputID, attachmentID: attachmentID)
        } catch {
            return nil
        }
    }

    public func fetchSelectedPreviewAttachment(
        outputID: String,
        attachmentID: UInt64
    ) async -> OutputPreviewAttachment? {
        if let selectedPreviewAttachmentProvider {
            return await selectedPreviewAttachmentProvider(outputID, attachmentID)
        }

        ensureConnection()

        do {
            return try await requestSelectedPreviewAttachment(outputID: outputID, attachmentID: attachmentID)
        } catch {
            return nil
        }
    }

    public func probeOutputPreviewTransport(outputID: String, attachmentID: UInt64 = 0) async throws -> Bool {
        _ = try await requestOutputPreviewAttachment(outputID: outputID, attachmentID: attachmentID)
        return true
    }

    public func startObservingEvents(
        _ handler: @escaping @Sendable (BETRCoreEventEnvelope) -> Void
    ) async throws {
        if let eventObservationProvider {
            try await performTimedOperation("starting live core updates") {
                try await eventObservationProvider(handler)
            }
            return
        }

        ensureConnection()
        eventReceiver.setHandler(handler)
        guard eventSubscriptionActive == false else { return }

        let _: Void = try await withTimedReply("starting live core updates") { [self] gate in
            guard let proxy = self.connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { await self?.invalidateConnection() }
                gate.finish(.failure(error))
            }) as? BETRCoreAgentMachXPCProtocol else {
                gate.finish(.failure(BETRCoreAgentClientError.xpcUnavailable("BETRCoreAgent is unavailable.")))
                return
            }

            proxy.subscribeToEvents { [weak self] errorString in
                if let errorString {
                    gate.finish(.failure(BETRCoreAgentClientError.operationRejected(errorString as String)))
                    return
                }
                Task { await self?.markEventSubscriptionActive() }
                gate.finish(.success(()))
            }
        }
    }

    public func stopObservingEvents() async {
        eventReceiver.setHandler(nil)
        guard eventSubscriptionActive else { return }

        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            Task { await self?.invalidateConnection() }
        }) as? BETRCoreAgentMachXPCProtocol else {
            invalidateConnection()
            return
        }

        await withCheckedContinuation { continuation in
            proxy.unsubscribeFromEvents {
                continuation.resume()
            }
        }
        eventSubscriptionActive = false
    }

    private func loadWorkspaceSnapshot(
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> BETRCoreWorkspaceSnapshotResponse {
        if let workspaceSnapshotProvider {
            return try await performTimedOperation(
                "loading workspace state",
                timeoutNanoseconds: timeoutNanoseconds
            ) {
                try await workspaceSnapshotProvider()
            }
        }

        let response = try await send(.requestWorkspaceSnapshot, timeoutNanosecondsOverride: timeoutNanoseconds)
        guard case let .workspace(snapshot) = response else {
            throw BETRCoreAgentClientError.malformedResponse
        }
        return snapshot
    }

    private func loadValidationSnapshot() async throws -> BETRCoreValidationSnapshotResponse {
        if let validationSnapshotProvider {
            return try await performTimedOperation("loading validation state") {
                try await validationSnapshotProvider()
            }
        }

        let response = try await send(.requestValidationSnapshot)
        guard case let .validation(snapshot) = response else {
            throw BETRCoreAgentClientError.malformedResponse
        }
        return snapshot
    }

    private func loadDiscoveryDebugSnapshot() async throws -> BETRCoreDiscoveryDebugSnapshotResponse {
        if let discoveryDebugSnapshotProvider {
            return try await performTimedOperation("loading discovery debug state") {
                try await discoveryDebugSnapshotProvider()
            }
        }

        let response = try await send(.requestDiscoveryDebugSnapshot)
        guard case let .discoveryDebug(snapshot) = response else {
            throw BETRCoreAgentClientError.malformedResponse
        }
        return snapshot
    }

    private func requestOutputPreviewAttachment(
        outputID: String,
        attachmentID: UInt64
    ) async throws -> OutputPreviewAttachment? {
        ensureConnection()
        return try await withTimedReply("loading preview surfaces") { [self] gate in
            guard let proxy = self.connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { await self?.invalidateConnection() }
                gate.finish(.failure(error))
            }) as? BETRCoreAgentMachXPCProtocol else {
                gate.finish(.failure(BETRCoreAgentClientError.xpcUnavailable("BETRCoreAgent is unavailable.")))
                return
            }

            proxy.getOutputPreviewAttachment(
                outputID: outputID,
                attachmentIDRaw: Int64(bitPattern: attachmentID)
            ) { envelope, errorString in
                if let errorString {
                    gate.finish(.failure(BETRCoreAgentClientError.operationRejected(errorString as String)))
                    return
                }
                gate.finish(.success(envelope?.attachment))
            }
        }
    }

    private func requestSelectedPreviewAttachment(
        outputID: String,
        attachmentID: UInt64
    ) async throws -> OutputPreviewAttachment? {
        ensureConnection()
        return try await withTimedReply("loading selected preview surfaces") { [self] gate in
            guard let proxy = self.connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { await self?.invalidateConnection() }
                gate.finish(.failure(error))
            }) as? BETRCoreAgentMachXPCProtocol else {
                gate.finish(.failure(BETRCoreAgentClientError.xpcUnavailable("BETRCoreAgent is unavailable.")))
                return
            }

            proxy.getSelectedPreviewAttachment(
                outputID: outputID,
                attachmentIDRaw: Int64(bitPattern: attachmentID)
            ) { envelope, errorString in
                if let errorString {
                    gate.finish(.failure(BETRCoreAgentClientError.operationRejected(errorString as String)))
                    return
                }
                gate.finish(.success(envelope?.attachment))
            }
        }
    }

    private func send(
        _ command: BETRCoreCommandEnvelope,
        timeoutNanosecondsOverride: UInt64? = nil
    ) async throws -> BETRCoreCommandResponseEnvelope {
        let timeoutNanoseconds = timeoutNanosecondsOverride ?? commandTimeoutNanoseconds(for: command)

        if let commandTransport {
            return try await performTimedOperation(
                "sending commands to BETRCoreAgent",
                timeoutNanoseconds: timeoutNanoseconds
            ) {
                try await commandTransport(command)
            }
        }

        ensureConnection()
        let requestData = try encode(command)

        return try await withTimedReply(
            "sending commands to BETRCoreAgent",
            timeoutNanoseconds: timeoutNanoseconds
        ) { [self] gate in
            guard let proxy = self.connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { await self?.invalidateConnection() }
                gate.finish(.failure(error))
            }) as? BETRCoreAgentMachXPCProtocol else {
                gate.finish(.failure(BETRCoreAgentClientError.xpcUnavailable("BETRCoreAgent is unavailable.")))
                return
            }

            proxy.sendCommand(requestData) { responseData, errorString in
                if let errorString {
                    gate.finish(.failure(BETRCoreAgentClientError.operationRejected(errorString as String)))
                    return
                }
                guard let responseData else {
                    gate.finish(.failure(BETRCoreAgentClientError.malformedResponse))
                    return
                }
                do {
                    let response = try Self.decode(BETRCoreCommandResponseEnvelope.self, from: responseData)
                    gate.finish(.success(response))
                } catch {
                    gate.finish(.failure(error))
                }
            }
        }
    }

    private func commandTimeoutNanoseconds(for command: BETRCoreCommandEnvelope) -> UInt64 {
        switch command {
        case .applyNDIHostProfile,
             .resetNDIHostEnvironment,
             .refreshHostInterfaceInventory:
            return Self.hostControlOperationTimeoutNanoseconds
        default:
            return operationTimeoutNanoseconds
        }
    }

    private func performTimedOperation<T>(
        _ operationDescription: String,
        timeoutNanoseconds: UInt64? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            var timeoutTask: Task<Void, Never>?
            let gate = BETRCoreAgentReplyGate<T> { result in
                timeoutTask?.cancel()
                continuation.resume(with: result)
            }
            let resolvedTimeoutNanoseconds = timeoutNanoseconds ?? operationTimeoutNanoseconds

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: resolvedTimeoutNanoseconds)
                gate.finish(.failure(timeoutError(for: operationDescription)))
            }

            Task {
                do {
                    gate.finish(.success(try await operation()))
                } catch {
                    gate.finish(.failure(error))
                }
            }
        }
    }

    private func withTimedReply<T>(
        _ operationDescription: String,
        timeoutNanoseconds: UInt64? = nil,
        operation: @escaping (BETRCoreAgentReplyGate<T>) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            var timeoutTask: Task<Void, Never>?
            let gate = BETRCoreAgentReplyGate<T> { result in
                timeoutTask?.cancel()
                continuation.resume(with: result)
            }
            let resolvedTimeoutNanoseconds = timeoutNanoseconds ?? operationTimeoutNanoseconds

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: resolvedTimeoutNanoseconds)
                gate.finish(.failure(timeoutError(for: operationDescription)))
            }

            operation(gate)
        }
    }

    private func timeoutError(for operationDescription: String) -> BETRCoreAgentClientError {
        BETRCoreAgentClientError.xpcUnavailable("BETRCoreAgent timed out while \(operationDescription).")
    }

    private func ensureConnection() {
        guard connection == nil else { return }

        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = BETRCoreMachXPCInterfaceFactory.makeAgentServiceInterface()
        connection.exportedInterface = BETRCoreMachXPCInterfaceFactory.makeAgentEventSinkInterface()
        connection.exportedObject = eventReceiver
        connection.invalidationHandler = { [weak self] in
            Task { await self?.invalidateConnection() }
        }
        connection.interruptionHandler = { [weak self] in
            Task { await self?.invalidateConnection() }
        }
        connection.resume()
        self.connection = connection
    }

    private func invalidateConnection() {
        eventSubscriptionActive = false
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection = nil
    }

    private func markEventSubscriptionActive() {
        eventSubscriptionActive = true
    }

    private func assignedSourceIDIfPresent(
        outputID: String,
        slotID: String,
        workspace: BETRCoreWorkspaceSnapshotResponse
    ) -> String? {
        workspace.outputs.first(where: { $0.id == outputID })?
            .slots.first(where: { $0.slotID == slotID })?
            .sourceID
    }

    private func disconnectSourceFromAgentIfSafe(
        _ sourceID: String,
        workspace: BETRCoreWorkspaceSnapshotResponse
    ) async throws {
        let sourceStillReferenced = workspace.outputs.contains { output in
            output.programSlotID.flatMap { slotID(for: $0, in: output) } == sourceID
                || output.previewSlotID.flatMap { slotID(for: $0, in: output) } == sourceID
                || output.liveTile.sourceID == sourceID
                || output.slots.contains(where: { $0.sourceID == sourceID })
        }
        guard sourceStillReferenced == false else { return }

        _ = try await send(.coolSource(sourceID))
        _ = try await send(.disconnectSource(BETRCoreDisconnectSourceRequest(descriptorID: sourceID)))
    }

    public func applyLiveTileEvent(
        _ event: BETRCoreLiveTileEvent,
        to shellState: FeatureShellState
    ) -> FeatureShellState {
        var cards = shellState.workspace.cards
        guard let index = cards.firstIndex(where: { $0.id == event.outputID }) else {
            return shellState
        }

        var card = cards[index]
        let sourceStateByID = Dictionary(uniqueKeysWithValues: shellState.workspace.sources.map { ($0.id, $0) })
        let programSourceIsWarm = card.programSourceID.flatMap { sourceStateByID[$0]?.isWarm } ?? false
        let previewSourceIsWarm = card.previewSourceID.flatMap { sourceStateByID[$0]?.isWarm } ?? false
        card.liveTile = OutputLiveTileModel(
            sourceID: event.snapshot.sourceID,
            previewState: event.snapshot.fallbackActive ? .fallback : event.snapshot.previewState.roomControlPreviewState,
            audioPresenceState: event.snapshot.audioPresenceState.roomControlAudioPresenceState,
            leftLevel: event.snapshot.leftLevel,
            rightLevel: event.snapshot.rightLevel
        )
        card.isAudioMuted = event.snapshot.audioMuted
        card.confidencePreview = Self.makeConfidencePreview(
            liveSourceID: event.snapshot.sourceID,
            programSourceID: card.programSourceID,
            programSourceName: card.programSourceName,
            programSourceIsWarm: programSourceIsWarm,
            previewSourceID: card.previewSourceID,
            previewSourceName: card.previewSourceName,
            previewSourceIsWarm: previewSourceIsWarm,
            existing: card.confidencePreview
        )
        card.statusPills = Self.makeStatusPills(
            livePreviewState: card.liveTile.previewState,
            liveSourceID: event.snapshot.sourceID,
            desiredProgramSourceID: card.programSourceID,
            senderReady: !event.snapshot.fallbackActive,
            audioPresenceState: card.liveTile.audioPresenceState,
            isSoloedLocally: card.isSoloedLocally
        )
        cards[index] = card

        var workspace = shellState.workspace
        workspace.cards = cards
        return FeatureShellState(
            title: shellState.title,
            rootDirectory: shellState.rootDirectory,
            workspace: workspace,
            hostWizardSummary: shellState.hostWizardSummary,
            migrationSummary: shellState.migrationSummary,
            capacity: shellState.capacity
        )
    }

    public func applySelectedPreviewAdvance(
        _ advance: OutputPreviewAdvance,
        to shellState: FeatureShellState?
    ) -> FeatureShellState? {
        guard var shellState,
              let index = shellState.workspace.cards.firstIndex(where: { $0.id == advance.snapshot.outputID }) else {
            return shellState
        }

        var card = shellState.workspace.cards[index]
        guard let confidencePreview = card.confidencePreview else {
            return shellState
        }

        guard advance.snapshot.sourceID == nil || advance.snapshot.sourceID == confidencePreview.sourceID else {
            return shellState
        }

        card.confidencePreview = OutputConfidencePreviewModel(
            sourceID: confidencePreview.sourceID,
            sourceName: confidencePreview.sourceName,
            mode: confidencePreview.mode,
            isReady: confidencePreview.isReady,
            previewState: advance.snapshot.fallbackActive
                ? .fallback
                : advance.snapshot.previewState.roomControlPreviewState,
            audioPresenceState: advance.snapshot.audioPresenceState.roomControlAudioPresenceState,
            leftLevel: advance.snapshot.leftLevel,
            rightLevel: advance.snapshot.rightLevel
        )
        shellState.workspace.cards[index] = card
        return shellState
    }

    public func applySelectedPreviewDetach(
        outputID: String,
        to shellState: FeatureShellState?
    ) -> FeatureShellState? {
        guard var shellState,
              let index = shellState.workspace.cards.firstIndex(where: { $0.id == outputID }),
              let confidencePreview = shellState.workspace.cards[index].confidencePreview else {
            return shellState
        }

        var card = shellState.workspace.cards[index]
        card.confidencePreview = OutputConfidencePreviewModel(
            sourceID: confidencePreview.sourceID,
            sourceName: confidencePreview.sourceName,
            mode: confidencePreview.mode,
            isReady: confidencePreview.isReady,
            previewState: .unavailable,
            audioPresenceState: .silent,
            leftLevel: 0,
            rightLevel: 0
        )
        shellState.workspace.cards[index] = card
        return shellState
    }

    public func mergeConfidencePreviewState(
        from previous: FeatureShellState?,
        into state: FeatureShellState
    ) -> FeatureShellState {
        guard let previous else { return state }
        let previousByOutputID = Dictionary(
            uniqueKeysWithValues: previous.workspace.cards.map { ($0.id, $0.confidencePreview) }
        )

        var nextState = state
        nextState.workspace.cards = state.workspace.cards.map { card in
            guard let confidencePreview = card.confidencePreview,
                  let previousPreview = previousByOutputID[card.id] ?? nil,
                  previousPreview.sourceID == confidencePreview.sourceID,
                  previousPreview.mode == confidencePreview.mode else {
                return card
            }

            var mergedCard = card
            mergedCard.confidencePreview = OutputConfidencePreviewModel(
                sourceID: confidencePreview.sourceID,
                sourceName: confidencePreview.sourceName,
                mode: confidencePreview.mode,
                isReady: confidencePreview.isReady,
                previewState: previousPreview.previewState,
                audioPresenceState: previousPreview.audioPresenceState,
                leftLevel: previousPreview.leftLevel,
                rightLevel: previousPreview.rightLevel
            )
            return mergedCard
        }
        return nextState
    }

    private func makeShellState(
        rootDirectory: String,
        workspace: BETRCoreWorkspaceSnapshotResponse
    ) -> FeatureShellState {
        let sourceNameByID = Dictionary(uniqueKeysWithValues: workspace.sources.map { ($0.id, $0.name) })
        let sourceByID = Dictionary(uniqueKeysWithValues: workspace.sources.map { ($0.id, $0) })
        let cards = workspace.outputs.map { output in
            let programSourceID = output.programSlotID.flatMap { slotID(for: $0, in: output) }
            let previewSourceID = output.previewSlotID.flatMap { slotID(for: $0, in: output) }
            let programSourceIsWarm = programSourceID.flatMap { sourceByID[$0]?.readiness?.warm } ?? false
            let previewSourceIsWarm = previewSourceID.flatMap { sourceByID[$0]?.readiness?.warm } ?? false
            let liveTile = OutputLiveTileModel(
                sourceID: output.liveTile.sourceID,
                previewState: output.liveTile.fallbackActive ? .fallback : (output.liveTile.sourceID == nil ? .unavailable : .live),
                audioPresenceState: Self.makeAudioPresenceState(from: output.liveTile),
                leftLevel: output.liveTile.leftLevel,
                rightLevel: output.liveTile.rightLevel
            )
            let slots = output.slots.map { slot in
                RoomControlOutputSlotState(
                    id: slot.slotID,
                    label: slot.label,
                    sourceID: slot.sourceID,
                    sourceName: slot.sourceID.flatMap { sourceNameByID[$0] },
                    isAvailable: Self.slotIsAvailable(
                        sourceID: slot.sourceID,
                        workspaceSource: slot.sourceID.flatMap { sourceByID[$0] }
                    ),
                    isPreview: output.previewSlotID == slot.slotID,
                    isProgram: output.programSlotID == slot.slotID
                )
            }

            return RoomControlOutputCardState(
                id: output.id,
                title: output.title,
                rasterLabel: output.rasterLabel,
                listenerCount: output.listenerCount,
                slots: slots,
                programSlotID: output.programSlotID,
                previewSlotID: output.previewSlotID,
                isAudioMuted: output.isAudioMuted,
                isSoloedLocally: output.isSoloedLocally,
                statusPills: Self.makeStatusPills(
                    livePreviewState: liveTile.previewState,
                    liveSourceID: output.liveTile.sourceID,
                    desiredProgramSourceID: programSourceID,
                    senderReady: output.senderReady,
                    audioPresenceState: liveTile.audioPresenceState,
                    isSoloedLocally: output.isSoloedLocally
                ),
                liveTile: liveTile,
                confidencePreview: Self.makeConfidencePreview(
                    liveSourceID: output.liveTile.sourceID,
                    programSourceID: programSourceID,
                    programSourceName: programSourceID.flatMap { sourceNameByID[$0] },
                    programSourceIsWarm: programSourceIsWarm,
                    previewSourceID: previewSourceID,
                    previewSourceName: previewSourceID.flatMap { sourceNameByID[$0] },
                    previewSourceIsWarm: previewSourceIsWarm
                )
            )
        }

        let sources = workspace.sources.map { source in
            RouterWorkspaceSourceState(
                id: source.id,
                name: source.name,
                details: source.details,
                provenance: source.provenance,
                routedOutputIDs: source.routedOutputIDs,
                sortPriority: source.sortPriority,
                isConnected: source.readiness?.connected ?? false,
                isWarming: source.readiness?.warming ?? false,
                isWarm: source.readiness?.warm ?? false,
                inputAVSkewMs: source.readiness?.inputAVSkewMs,
                syncReady: source.readiness?.syncReady ?? false,
                gateReasons: source.readiness?.gateReasons.map(\.rawValue) ?? [],
                fanoutCount: source.readiness?.fanoutCount ?? 0,
                audioRequired: source.readiness?.audioRequired ?? true,
                videoRecent: source.readiness?.videoRecent ?? false,
                audioRecent: source.readiness?.audioRecent ?? false
            )
        }.sorted {
            if $0.sortPriority == $1.sortPriority {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.sortPriority < $1.sortPriority
        }

        return FeatureShellState(
            title: "BETR Room Control",
            rootDirectory: rootDirectory,
            workspace: RouterWorkspaceSnapshot(
                generatedAt: workspace.generatedAt,
                agentInstanceID: workspace.agentInstanceID,
                agentStartedAt: workspace.agentStartedAt,
                cards: cards,
                sources: sources,
                discoverySummary: workspace.discoverySummary,
                hostInterfaceInventory: workspace.hostInterfaceInventory
            ),
            hostWizardSummary: workspace.hostWizardSummary,
            migrationSummary: workspace.migrationSummary,
            capacity: workspace.capacity.map {
                RoomControlCapacitySnapshot(
                    capturedAt: workspace.generatedAt,
                    configuredOutputs: $0.configuredOutputs,
                    discoveredSources: $0.discoveredSources,
                    processCPUPercent: $0.processCPUPercent,
                    selectedNICThroughputMbps: $0.selectedNICThroughputMbps
                )
            }
        )
    }

    private func makeShellState(
        rootDirectory: String,
        validation: BETRCoreValidationSnapshotResponse?
    ) -> FeatureShellState {
        let outputID = validation?.proofOutput?.outputID ?? "OUT-1"
        let outputTitle = validation?.proofOutput?.senderName ?? "Program Output"
        let sourceRecords = validation?.directorySnapshot?.sources ?? []
        let sourceNameByID = Dictionary(uniqueKeysWithValues: sourceRecords.map { ($0.descriptor.id, $0.descriptor.name) })
        let sourceDetailsByID = Dictionary(uniqueKeysWithValues: sourceRecords.map { record in
            let details = record.descriptor.address
                ?? record.descriptor.sourceDescription
                ?? record.provenance.rawValue
            return (record.descriptor.id, details)
        })
        let sourceStateByID = Dictionary(uniqueKeysWithValues: (validation?.sourceStates ?? []).map { ($0.id, $0) })

        let slotSnapshots = validation?.outputSlots
            .filter { $0.outputID == outputID }
            .sorted { $0.slotID < $1.slotID }
            ?? Self.defaultOutputSlots(for: outputID)

        let slots = slotSnapshots.map { slot in
            let sourceID = slot.sourceID
            return RoomControlOutputSlotState(
                id: slot.slotID,
                label: slot.label,
                sourceID: sourceID,
                sourceName: sourceID.flatMap { sourceNameByID[$0] },
                isAvailable: Self.slotIsAvailable(
                    sourceID: sourceID,
                    sourceWarmState: sourceID.flatMap { sourceStateByID[$0] }
                ),
                isPreview: validation?.previewSlotID == slot.slotID,
                isProgram: validation?.programSlotID == slot.slotID
            )
        }

        let proofOutput = validation?.proofOutput
        let activeSourceState = validation?.sourceStates.first { $0.id == validation?.programSourceID }
        let previewSourceState = validation?.sourceStates.first { $0.id == validation?.previewSourceID }
        let liveSourceID = proofOutput?.activeSourceID
        let programSourceID = validation?.programSourceID
        let previewSourceIsWarm = previewSourceState?.warm ?? false
        let programSourceIsWarm = activeSourceState?.warm ?? false
        let liveTile = OutputLiveTileModel(
            sourceID: liveSourceID,
            previewState: Self.makePreviewState(from: proofOutput),
            audioPresenceState: Self.makeProofAudioPresenceState(
                proofOutput: proofOutput,
                activeSourceState: activeSourceState
            ),
            leftLevel: 0,
            rightLevel: 0
        )
        let card = RoomControlOutputCardState(
            id: outputID,
            title: outputTitle,
            rasterLabel: "1920×1080 / 29.97",
            listenerCount: proofOutput?.senderConnectionCount ?? 0,
            slots: slots,
            programSlotID: validation?.programSlotID ?? slots.first(where: \.isProgram)?.id,
            previewSlotID: validation?.previewSlotID ?? slots.first(where: \.isPreview)?.id,
            statusPills: Self.makeStatusPills(
                livePreviewState: liveTile.previewState,
                liveSourceID: liveSourceID,
                desiredProgramSourceID: programSourceID,
                senderReady: proofOutput?.senderReady ?? false,
                audioPresenceState: liveTile.audioPresenceState,
                isSoloedLocally: false
            ),
            liveTile: liveTile,
            confidencePreview: Self.makeConfidencePreview(
                liveSourceID: liveSourceID,
                programSourceID: programSourceID,
                programSourceName: programSourceID.flatMap { sourceNameByID[$0] },
                programSourceIsWarm: programSourceIsWarm,
                previewSourceID: validation?.previewSourceID,
                previewSourceName: validation?.previewSourceID.flatMap { sourceNameByID[$0] },
                previewSourceIsWarm: previewSourceIsWarm
            )
        )

        let sources = sourceRecords.map { record in
            RouterWorkspaceSourceState(
                id: record.descriptor.id,
                name: record.descriptor.name,
                details: sourceDetailsByID[record.descriptor.id] ?? "",
                provenance: record.provenance.rawValue,
                routedOutputIDs: validation?.programSourceID == record.descriptor.id ? [outputID] : [],
                sortPriority: Self.makeSortPriority(
                    sourceID: record.descriptor.id,
                    programSourceID: validation?.programSourceID,
                    previewSourceID: validation?.previewSourceID
                ),
                isConnected: sourceStateByID[record.descriptor.id]?.connected ?? false,
                isWarming: sourceStateByID[record.descriptor.id]?.warming ?? false,
                isWarm: sourceStateByID[record.descriptor.id]?.warm ?? false,
                inputAVSkewMs: sourceStateByID[record.descriptor.id]?.inputAVSkewMs,
                syncReady: sourceStateByID[record.descriptor.id]?.syncReady ?? false,
                gateReasons: sourceStateByID[record.descriptor.id]?.gateReasons.map(\.rawValue) ?? [],
                fanoutCount: sourceStateByID[record.descriptor.id]?.fanoutCount ?? 0,
                audioRequired: sourceStateByID[record.descriptor.id]?.audioRequired ?? true,
                videoRecent: sourceStateByID[record.descriptor.id]?.videoRecent ?? false,
                audioRecent: sourceStateByID[record.descriptor.id]?.audioRecent ?? false
            )
        }.sorted {
            if $0.sortPriority == $1.sortPriority {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.sortPriority < $1.sortPriority
        }

        let discoverySummary = Self.makeDiscoverySummary(validation: validation, sourceCount: sources.count)
        let workspace = RouterWorkspaceSnapshot(
            generatedAt: validation?.directorySnapshot?.generatedAt ?? Date(),
            agentInstanceID: validation?.agentInstanceID ?? "",
            agentStartedAt: validation?.agentStartedAt ?? .distantPast,
            cards: [card],
            sources: sources,
            discoverySummary: discoverySummary,
            hostInterfaceInventory: nil
        )
        return FeatureShellState(
            title: "BETR Room Control",
            rootDirectory: rootDirectory,
            workspace: workspace,
            hostWizardSummary: validation?.hostState.selectedInterfaceBSDName ?? "BETR-only",
            capacity: RoomControlCapacitySnapshot(
                configuredOutputs: 1,
                discoveredSources: sources.count,
                processCPUPercent: nil,
                selectedNICThroughputMbps: nil
            )
        )
    }

    private func makeWizardValidation(_ validation: BETRCoreValidationSnapshotResponse?) -> NDIWizardValidationSnapshot {
        guard let validation else {
            return NDIWizardValidationSnapshot(
                agentInstanceID: "",
                agentStartedAt: .distantPast,
                discoveryDetailState: .noDiscoveryConfigured,
                multicastRouteSummary: "BETRCoreAgent has not reported validation yet.",
                multicastRouteNextAction: "Start the core agent and refresh validation again."
            )
        }

        let hostState = validation.hostState
        let runtimeStatus = validation.runtimeStatus
        let expectedFingerprint = hostState.committedConfigFingerprint ?? runtimeStatus?.configFingerprint
        let discovery = validation.directorySnapshot?.discovery
        let runtimeInterfaceBSDName = runtimeStatus?.selectedInterfaceID ?? hostState.selectedInterfaceBSDName
        let runtimeInterfaceCIDR = runtimeStatus?.networkProfile.selectedInterfaceCIDRs.first ?? hostState.selectedInterfaceCIDR
        let discoveryServers = runtimeStatus?.discoveryServers.map(Self.makeDiscoveryServerRow) ?? []

        return NDIWizardValidationSnapshot(
            checkedAt: validation.directorySnapshot?.generatedAt ?? Date(),
            agentInstanceID: validation.agentInstanceID,
            agentStartedAt: validation.agentStartedAt,
            committedInterfaceBSDName: hostState.selectedInterfaceBSDName,
            committedInterfaceCIDR: hostState.selectedInterfaceCIDR,
            committedServiceName: hostState.selectedServiceName,
            committedHardwarePortLabel: hostState.selectedServiceName,
            resolvedRuntimeInterfaceBSDName: runtimeInterfaceBSDName,
            resolvedRuntimeInterfaceCIDR: runtimeInterfaceCIDR,
            resolvedRuntimeServiceName: hostState.selectedServiceName,
            resolvedRuntimeHardwarePortLabel: hostState.selectedServiceName,
            selectedInterfaceBSDName: hostState.selectedInterfaceBSDName,
            selectedInterfaceCIDR: hostState.selectedInterfaceCIDR,
            activeDiscoveryServerURL: Self.activeDiscoveryServerURL(for: validation),
            runtimeConfigFingerprint: runtimeStatus?.configFingerprint,
            expectedConfigFingerprint: expectedFingerprint,
            runtimeConfigDirectory: runtimeStatus?.configDirectory ?? hostState.committedConfigDirectory,
            runtimeConfigPath: runtimeStatus?.configPath ?? hostState.committedConfigPath,
            runtimeConfigMatchesCommittedProfile: hostState.committedConfigMatchesProfile || expectedFingerprint == runtimeStatus?.configFingerprint,
            runtimeConfigMismatchReasons: hostState.committedConfigMismatchReasons,
            discoveryDetailState: Self.makeDiscoveryState(validation: validation),
            sdkBootstrapState: runtimeStatus?.sdkBootstrapState.rawValue ?? NDISDKBootstrapState.uninitialized.rawValue,
            sdkVersion: runtimeStatus?.sdkVersion,
            sdkLoadedPath: runtimeStatus?.sdkLoadedPath,
            finderSourceVisibilityCount: discovery?.finderSourceCount ?? validation.directorySnapshot?.sources.count ?? 0,
            listenerSenderVisibilityCount: discovery?.listenerSourceCount ?? 0,
            localSourceVisibilityCount: discovery?.localSourceCount ?? 0,
            remoteSourceVisibilityCount: discovery?.remoteSourceCount ?? 0,
            senderListenerConnected: discovery?.senderListenerConnected ?? false,
            receiverListenerConnected: discovery?.receiverListenerConnected ?? false,
            senderAdvertiserVisibilityCount: discovery?.senderAdvertiserVisibilityCount ?? 0,
            receiverAdvertiserVisibilityCount: discovery?.receiverAdvertiserVisibilityCount ?? 0,
            sourceFilterActive: discovery?.sourceFilterActive ?? false,
            sourceFilterValue: discovery?.sourceFilterValue ?? runtimeStatus?.networkProfile.sourceFilter,
            senderVisibilityCount: discovery?.listenerSourceCount ?? 0,
            receiverVisibilityCount: runtimeStatus?.receiverDirectory.count ?? 0,
            multicastRouteSummary: Self.makeMulticastSummary(hostState),
            multicastRouteNextAction: Self.makeMulticastNextAction(hostState),
            multicastRouteExists: hostState.multicastRoute.routeExists,
            multicastRoutePinnedToCommittedInterface: hostState.multicastRoute.routePinnedToCommittedInterface,
            multicastRouteOwnerBSDName: hostState.multicastRoute.effectiveRouteOwnerBSDName,
            multicastRouteSelectedBSDName: hostState.multicastRoute.selectedInterfaceBSDName,
            discoveryServers: discoveryServers,
            receiverTelemetry: validation.receiverTelemetry.map(Self.makeReceiverTelemetryRow),
            outputTelemetry: validation.outputTelemetry.map(Self.makeOutputTelemetryRow),
            lastBETRRestartAt: hostState.lastPreparedAt
        )
    }

    private static func makePreviewState(from proofOutput: BETRCoreProofOutputSnapshot?) -> OutputPreviewState {
        guard let proofOutput else { return .unavailable }
        if proofOutput.fallbackActive {
            return .fallback
        }
        return proofOutput.activeSourceID == nil ? .unavailable : .live
    }

    private static func makeConfidencePreview(
        liveSourceID: String?,
        programSourceID: String?,
        programSourceName: String?,
        programSourceIsWarm: Bool,
        previewSourceID: String?,
        previewSourceName: String?,
        previewSourceIsWarm: Bool,
        existing: OutputConfidencePreviewModel? = nil
    ) -> OutputConfidencePreviewModel? {
        if let programSourceID, programSourceID != liveSourceID {
            return makeConfidencePreviewModel(
                sourceID: programSourceID,
                sourceName: programSourceName,
                mode: .pendingProgram,
                isReady: programSourceIsWarm,
                existing: existing
            )
        }

        if let previewSourceID {
            return makeConfidencePreviewModel(
                sourceID: previewSourceID,
                sourceName: previewSourceName,
                mode: .armedPreview,
                isReady: previewSourceIsWarm,
                existing: existing
            )
        }

        return nil
    }

    private static func makeConfidencePreviewModel(
        sourceID: String,
        sourceName: String?,
        mode: OutputConfidencePreviewMode,
        isReady: Bool,
        existing: OutputConfidencePreviewModel?
    ) -> OutputConfidencePreviewModel {
        let preserved = existing?.sourceID == sourceID && existing?.mode == mode ? existing : nil
        return OutputConfidencePreviewModel(
            sourceID: sourceID,
            sourceName: sourceName,
            mode: mode,
            isReady: isReady,
            previewState: preserved?.previewState ?? .unavailable,
            audioPresenceState: preserved?.audioPresenceState ?? .silent,
            leftLevel: preserved?.leftLevel ?? 0,
            rightLevel: preserved?.rightLevel ?? 0
        )
    }

    private static func makeProofAudioPresenceState(
        proofOutput: BETRCoreProofOutputSnapshot?,
        activeSourceState: BETRCoreSourceWarmStateSnapshot?
    ) -> RoomControlUIContracts.OutputAudioPresenceState {
        guard proofOutput?.lastAudioSendAt != nil else { return .silent }
        return activeSourceState?.audioPrimed == true ? .live : .silent
    }

    private static func makeAudioPresenceState(
        from liveTile: BETRCoreWorkspaceLiveTileSnapshot
    ) -> RoomControlUIContracts.OutputAudioPresenceState {
        switch liveTile.audioPresenceState {
        case .live:
            return .live
        case .muted:
            return .muted
        case .silent:
            return .silent
        }
    }

    private static func makePrimaryRoutePill(
        livePreviewState: OutputPreviewState,
        liveSourceID: String?,
        desiredProgramSourceID: String?,
        senderReady: Bool
    ) -> OutputStatusPill? {
        if livePreviewState == .fallback {
            return .fallback
        }

        if let desiredProgramSourceID {
            if livePreviewState == .live, liveSourceID == desiredProgramSourceID {
                return .live
            }
            return .arming
        }

        if livePreviewState == .live, liveSourceID != nil {
            return .live
        }

        if liveSourceID != nil, senderReady == false {
            return .error
        }

        return nil
    }

    private static func makeStatusPills(
        livePreviewState: OutputPreviewState,
        liveSourceID: String?,
        desiredProgramSourceID: String?,
        senderReady: Bool,
        audioPresenceState: RoomControlUIContracts.OutputAudioPresenceState,
        isSoloedLocally: Bool
    ) -> [OutputStatusPill] {
        var pills: [OutputStatusPill] = []

        if let primaryPill = makePrimaryRoutePill(
            livePreviewState: livePreviewState,
            liveSourceID: liveSourceID,
            desiredProgramSourceID: desiredProgramSourceID,
            senderReady: senderReady
        ) {
            pills.append(primaryPill)
        }

        if audioPresenceState == .live {
            pills.append(.audio)
        } else if audioPresenceState == .muted {
            pills.append(.muted)
        }

        if isSoloedLocally {
            pills.append(.solo)
        }

        return pills
    }

    private static func makeDiscoverySummary(
        validation: BETRCoreValidationSnapshotResponse?,
        sourceCount: Int
    ) -> String {
        let discovery = validation?.directorySnapshot?.discovery
        let serverLabel = validation.flatMap(activeDiscoveryServerURL(for:))
            ?? "none"
        let finderCount = discovery?.finderSourceCount ?? sourceCount
        let listenerCount = discovery?.listenerSourceCount ?? 0
        return "\(finderCount) finder • \(listenerCount) listener • \(serverLabel)"
    }

    private static func makeDiscoveryServerRow(
        from status: NDIDiscoveryServerStatus
    ) -> NDIWizardDiscoveryServerRow {
        NDIWizardDiscoveryServerRow(
            id: status.id,
            configuredURL: status.configuredURL,
            normalizedEndpoint: status.normalizedEndpoint,
            host: status.host,
            port: status.port,
            senderListenerCreateSucceeded: status.senderListenerCreateSucceeded,
            senderListenerConnected: status.senderListenerConnected,
            senderListenerServerURL: status.senderListenerServerURL,
            receiverListenerCreateSucceeded: status.receiverListenerCreateSucceeded,
            receiverListenerConnected: status.receiverListenerConnected,
            receiverListenerServerURL: status.receiverListenerServerURL
        )
    }

    private static func makeDiscoveryServerDebugRow(
        from status: NDIDiscoveryServerDebugStatus
    ) -> NDIWizardDiscoveryServerDebugRow {
        NDIWizardDiscoveryServerDebugRow(
            id: status.id,
            normalizedEndpoint: status.normalizedEndpoint,
            validatedAddress: status.validatedAddress,
            listenerDebugState: status.listenerDebugState.rawValue,
            lastStateChangeAt: status.lastStateChangeAt,
            senderCreateFunctionAvailable: status.senderCreateFunctionAvailable,
            receiverCreateFunctionAvailable: status.receiverCreateFunctionAvailable,
            senderCandidateAddresses: status.senderCandidateAddresses,
            receiverCandidateAddresses: status.receiverCandidateAddresses,
            senderAttachAttemptCount: status.senderAttachAttemptCount,
            receiverAttachAttemptCount: status.receiverAttachAttemptCount,
            senderLastAttemptedAddress: status.senderLastAttemptedAddress,
            receiverLastAttemptedAddress: status.receiverLastAttemptedAddress,
            senderAttachFailureReason: status.senderAttachFailureReason?.rawValue,
            receiverAttachFailureReason: status.receiverAttachFailureReason?.rawValue
        )
    }

    private static func makeDiscoveryDebugSnapshot(
        _ snapshot: BETRCoreDiscoveryDebugSnapshotResponse
    ) -> NDIWizardDiscoveryDebugSnapshot {
        NDIWizardDiscoveryDebugSnapshot(
            generatedAt: snapshot.generatedAt,
            sdkBootstrapState: snapshot.sdkBootstrapState.rawValue,
            configDirectory: snapshot.configDirectory,
            configPath: snapshot.configPath,
            sdkLoadedPath: snapshot.sdkLoadedPath,
            sdkVersion: snapshot.sdkVersion,
            discoveryServers: snapshot.discoveryServers.map(Self.makeDiscoveryServerDebugRow)
        )
    }

    private static func makeReceiverTelemetryRow(
        from snapshot: BETRCoreReceiverTelemetrySnapshot
    ) -> NDIReceiverTelemetryRow {
        NDIReceiverTelemetryRow(
            id: snapshot.id,
            sourceName: snapshot.sourceName,
            connectionCount: snapshot.connectionCount,
            videoQueueDepth: snapshot.videoQueueDepth,
            audioQueueDepth: snapshot.audioQueueDepth,
            droppedVideoFrames: Int(snapshot.droppedVideoFrames),
            droppedAudioFrames: Int(snapshot.droppedAudioFrames),
            lastVideoPullDurationUs: snapshot.lastVideoPullDurationUs,
            lastAudioPullDurationUs: snapshot.lastAudioPullDurationUs,
            lastVideoPullIntervalUs: snapshot.lastVideoPullIntervalUs,
            lastAudioRequestedSampleCount: snapshot.lastAudioRequestedSampleCount,
            estimatedVideoLatencyMs: snapshot.estimatedVideoLatencyMs,
            estimatedAudioLatencyMs: snapshot.estimatedAudioLatencyMs,
            latestVideoTimestamp100ns: snapshot.latestVideoTimestamp100ns,
            latestAudioTimestamp100ns: snapshot.latestAudioTimestamp100ns,
            inputAVSkewMs: snapshot.inputAVSkewMs,
            videoRecent: snapshot.videoRecent,
            audioRecent: snapshot.audioRecent,
            audioRequired: snapshot.audioRequired,
            queueSane: snapshot.queueSane,
            dropDeltaSane: snapshot.dropDeltaSane,
            syncReady: snapshot.syncReady,
            warmAttemptDroppedVideoFrames: Int(snapshot.warmAttemptDroppedVideoFrames),
            warmAttemptDroppedAudioFrames: Int(snapshot.warmAttemptDroppedAudioFrames),
            consumerCount: snapshot.consumerCount,
            fanoutCount: snapshot.fanoutCount,
            gateReasons: snapshot.gateReasons.map(\.rawValue)
        )
    }

    private static func makeOutputTelemetryRow(
        from snapshot: BETRCoreOutputTelemetrySnapshot
    ) -> NDIOutputTelemetryRow {
        NDIOutputTelemetryRow(
            id: snapshot.id,
            senderConnectionCount: snapshot.senderConnectionCount,
            senderReady: snapshot.senderReady,
            activeSourceID: snapshot.activeSourceID,
            previewSourceID: snapshot.previewSourceID,
            fallbackActive: snapshot.fallbackActive,
            isSoloedLocally: snapshot.isSoloedLocally,
            audioPresenceState: snapshot.audioPresenceState.roomControlAudioPresenceState,
            leftLevel: snapshot.leftLevel,
            rightLevel: snapshot.rightLevel,
            videoQueueDepth: snapshot.videoQueueDepth,
            videoQueueAgeMs: snapshot.videoQueueAgeMs,
            audioQueueDepthMs: snapshot.audioQueueDepthMs,
            audioDriftDebtSamples: snapshot.audioDriftDebtSamples,
            senderRestartCount: snapshot.senderRestartCount,
            videoTimestampDiscontinuityCount: snapshot.videoTimestampDiscontinuityCount,
            audioTimestampDiscontinuityCount: snapshot.audioTimestampDiscontinuityCount,
            activeSourceFanoutCount: snapshot.activeSourceFanoutCount,
            previewSourceFanoutCount: snapshot.previewSourceFanoutCount,
            activeSourceSyncReady: snapshot.activeSourceSyncReady,
            previewSourceSyncReady: snapshot.previewSourceSyncReady,
            activeSourceInputAVSkewMs: snapshot.activeSourceInputAVSkewMs,
            previewSourceInputAVSkewMs: snapshot.previewSourceInputAVSkewMs,
            activeSourceGateReasons: snapshot.activeSourceGateReasons.map(\.rawValue),
            previewSourceGateReasons: snapshot.previewSourceGateReasons.map(\.rawValue)
        )
    }

    private static func makeSortPriority(
        sourceID: String,
        programSourceID: String?,
        previewSourceID: String?
    ) -> Int {
        if sourceID == programSourceID { return 0 }
        if sourceID == previewSourceID { return 10 }
        return 100
    }

    private static func makeDiscoveryState(
        validation: BETRCoreValidationSnapshotResponse
    ) -> NDIWizardDiscoveryState {
        let configuredDiscoveryServers = configuredDiscoveryServers(for: validation)
        let discoveryServers = validation.runtimeStatus?.discoveryServers ?? []
        let discovery = validation.directorySnapshot?.discovery
        let remoteVisibilityCount = discovery?.remoteSourceCount ?? 0
        let hasVisibleDiscovery = remoteVisibilityCount > 0
        let sdkBootstrapState = validation.runtimeStatus?.sdkBootstrapState ?? .uninitialized
        let hasConnectedListener = discoveryServers.contains {
            $0.senderListenerConnected || $0.receiverListenerConnected
        }
        let hasCreateFailure = discoveryServers.contains {
            $0.senderListenerCreateSucceeded == false || $0.receiverListenerCreateSucceeded == false
        }

        guard configuredDiscoveryServers.isEmpty == false else {
            return .noDiscoveryConfigured
        }

        if sdkBootstrapState == .failed {
            return .error
        }

        if hasVisibleDiscovery {
            return .visible
        }

        if hasCreateFailure {
            return .error
        }

        if hasConnectedListener {
            return .connected
        }

        return .waiting
    }

    private static func activeDiscoveryServerURL(
        for validation: BETRCoreValidationSnapshotResponse
    ) -> String? {
        if let connectedServerURL = validation.directorySnapshot?.discovery.connectedServerURLs.first {
            return connectedServerURL
        }
        if let connectedServerURL = validation.runtimeStatus?.connectedServerURLs.first {
            return connectedServerURL
        }
        return validation.directorySnapshot?.discovery.activeDiscoveryServerURL
            ?? validation.runtimeStatus?.activeDiscoveryServerURL
    }

    private static func configuredDiscoveryServers(
        for validation: BETRCoreValidationSnapshotResponse
    ) -> [String] {
        let runtimeConfigured = validation.runtimeStatus?.networkProfile.discoveryServerURLs ?? []
        if runtimeConfigured.isEmpty == false {
            return runtimeConfigured
        }

        let hostConfigured = parseDelimitedValues(from: validation.hostState.discoveryServers.joined(separator: ","))
        return hostConfigured
    }

    private static func makeMulticastSummary(_ hostState: BETRNDIHostStateSnapshot) -> String {
        let route = hostState.multicastRoute
        if route.routePinnedToCommittedInterface,
           let effectiveRouteOwnerBSDName = route.effectiveRouteOwnerBSDName {
            return "Effective multicast route resolves to \(effectiveRouteOwnerBSDName)."
        }
        if route.routeExists,
           let effectiveRouteOwnerBSDName = route.effectiveRouteOwnerBSDName,
           let selectedInterfaceBSDName = route.selectedInterfaceBSDName {
            return "Multicast currently resolves to \(effectiveRouteOwnerBSDName), not the selected BETR NIC \(selectedInterfaceBSDName)."
        }
        return "BETR could not verify an effective multicast route for \(route.probedAddress)."
    }

    private static func makeMulticastNextAction(_ hostState: BETRNDIHostStateSnapshot) -> String {
        let route = hostState.multicastRoute
        if route.routePinnedToCommittedInterface {
            return "Route ownership looks right. If discovery is still warning, stay focused on Discovery Server listener connectivity."
        }
        if route.routeExists {
            return "Run Apply + Restart Now again so BETR can move multicast route ownership onto the selected NIC."
        }
        return "Run Apply + Restart Now so BETR can install and verify the multicast route on the selected NIC."
    }

    private static func makeHostProfile(
        from draft: HostWizardDraft,
        interfaceSummary: HostInterfaceSummary?
    ) -> BETRNDIHostProfile {
        let selectedInterfaceBSDName = interfaceSummary?.id.nilIfEmpty ?? draft.selectedInterfaceID.nilIfEmpty
        let selectedInterfaceCIDR = interfaceSummary?.primaryIPv4CIDR ?? draft.showNetworkCIDR.nilIfEmpty
        let selectedInterfaceAddress = selectedInterfaceCIDR?
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init)
        let discoveryServers = parseDelimitedValues(from: draft.discoveryServersText)
        let groups = parseDelimitedValues(from: draft.groupsText)
        let extraIPs = parseDelimitedValues(from: draft.extraIPsText)
        let receiveSubnets = parseDelimitedValues(from: draft.receiveSubnetsText)
        let discoveryMode: NDIDiscoveryMode
        if draft.mdnsEnabled, discoveryServers.isEmpty {
            discoveryMode = .mdnsOnly
        } else if draft.mdnsEnabled {
            discoveryMode = .discoveryServerFirst
        } else {
            discoveryMode = .discoveryServerOnly
        }

        return BETRNDIHostProfile(
            productIdentifier: BETRCoreAgentMachServiceName,
            showLocationName: draft.showLocationName,
            showNetworkCIDR: draft.showNetworkCIDR,
            ownershipMode: draft.ownershipMode,
            selectedInterfaceID: draft.selectedInterfaceID.nilIfEmpty,
            selectedInterfaceBSDName: selectedInterfaceBSDName,
            selectedInterfaceHardwarePortLabel: interfaceSummary?.hardwarePortLabel.nilIfEmpty,
            selectedInterfaceAddress: selectedInterfaceAddress,
            selectedInterfaceCIDR: selectedInterfaceCIDR,
            selectedServiceName: interfaceSummary?.serviceName?.nilIfEmpty,
            discoveryMode: discoveryMode,
            discoveryServers: discoveryServers,
            mdnsEnabled: draft.mdnsEnabled,
            groups: groups,
            extraIPs: extraIPs,
            multicastEnabled: draft.multicastEnabled,
            multicastReceiveEnabled: draft.multicastReceiveEnabled,
            multicastTransmitEnabled: draft.multicastTransmitEnabled,
            multicastPrefix: draft.multicastPrefix.nilIfEmpty,
            multicastNetmask: draft.multicastNetmask.nilIfEmpty,
            multicastTTL: draft.multicastTTL,
            receiveSubnets: receiveSubnets,
            interfaceHints: [draft.selectedInterfaceID, interfaceSummary?.serviceName, interfaceSummary?.hardwarePortLabel]
                .compactMap { $0?.nilIfEmpty },
            sourceFilter: draft.sourceFilter.nilIfEmpty,
            nodeLabel: draft.nodeLabel.nilIfEmpty ?? "BETR Room Control",
            senderPrefix: draft.senderPrefix,
            outputPrefix: draft.outputPrefix
        )
    }

    private func isPreviewSlot(
        outputID: String,
        slotID: String,
        workspace: BETRCoreWorkspaceSnapshotResponse
    ) -> Bool {
        workspace.outputs.first(where: { $0.id == outputID })?.previewSlotID == slotID
    }

    private func slotID(for slotID: String, in output: BETRCoreWorkspaceOutputSnapshot) -> String? {
        output.slots.first(where: { $0.slotID == slotID })?.sourceID
    }

    private static func slotIsAvailable(
        sourceID: String?,
        workspaceSource: BETRCoreWorkspaceSourceSnapshot?
    ) -> Bool {
        guard let sourceID else { return true }
        guard let workspaceSource else { return false }
        if let readiness = workspaceSource.readiness {
            return readiness.warm || readiness.connected || readiness.receiverConnected || readiness.hasVideo
        }
        return workspaceSource.id == sourceID
    }

    private static func slotIsAvailable(
        sourceID: String?,
        sourceWarmState: BETRCoreSourceWarmStateSnapshot?
    ) -> Bool {
        guard sourceID != nil else { return true }
        guard let sourceWarmState else { return false }
        return sourceWarmState.warm
            || sourceWarmState.connected
            || sourceWarmState.receiverConnected
            || sourceWarmState.hasVideo
    }

    private static func defaultOutputSlots(for outputID: String) -> [BETRCoreOutputSlotSnapshot] {
        (1...6).map { "S\($0)" }.map { slotID in
            BETRCoreOutputSlotSnapshot(
                outputID: outputID,
                slotID: slotID,
                label: slotID
            )
        }
    }

    private static func parseDelimitedValues(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try Self.encode(value)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension CoreNDIOutput.OutputPreviewAvailabilityState {
    var roomControlPreviewState: OutputPreviewState {
        switch self {
        case .live:
            return .live
        case .fallback:
            return .fallback
        case .unavailable:
            return .unavailable
        }
    }
}

private extension CoreNDIOutput.OutputAudioPresenceState {
    var roomControlAudioPresenceState: RoomControlUIContracts.OutputAudioPresenceState {
        switch self {
        case .live:
            return .live
        case .muted:
            return .muted
        case .silent:
            return .silent
        }
    }
}
