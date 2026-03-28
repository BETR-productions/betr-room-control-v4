import AppKit
import BETRCoreXPC
import ClipPlayerDomain
import Combine
import HostWizardDomain
import PersistenceDomain
import PresentationDomain
import RoomControlUIContracts
import RoutingDomain
import SwiftUI
import TimerDomain
import UniformTypeIdentifiers

@MainActor
public final class RoomControlWorkspaceStore: ObservableObject {
    public enum RestartPromptContext: String, Identifiable {
        case startOver
        case apply

        public var id: String { rawValue }
    }

    @Published public private(set) var shellState: FeatureShellState?
    @Published public private(set) var availableDisplays: [String] = []
    @Published public private(set) var presentationState = PresentationXPCState()
    @Published public private(set) var presentationHealth = PresentationControlHealthSnapshot()
    @Published public private(set) var isBootstrapped = false
    @Published public private(set) var isPerformingAction = false
    @Published public private(set) var hostValidation = NDIWizardValidationSnapshot()
    @Published public private(set) var hostWizardProgressState = NDIWizardProgressState()
    @Published public private(set) var hostInterfaceSummaries: [HostInterfaceSummary] = []
    @Published public private(set) var timerRuntimeSnapshot = TimerRuntimeSnapshot()
    @Published public private(set) var clipPlayerRuntimeSnapshot = ClipPlayerRuntimeSnapshot()
    @Published public private(set) var capacitySnapshot = RoomControlCapacitySnapshot()
    @Published public private(set) var lastStatusMessage: String?
    @Published public var lastErrorMessage: String?
    @Published public private(set) var startupBlockerMessage: String?
    @Published public private(set) var startupBlockerRequiresInstall = false
    @Published public private(set) var coreAgentLogPath: String = ""
    @Published public private(set) var networkHelperLogPath: String = ""
    @Published public private(set) var coreAgentLogExcerpt: String = "No BETRCoreAgent log has been loaded yet."
    @Published public private(set) var networkHelperLogExcerpt: String = "No privileged network helper log has been loaded yet."
    @Published public var pendingRestartPromptContext: RestartPromptContext?
    @Published public var operatorShellUIState = RoomControlOperatorShellUIState()
    @Published public var hostDraft = HostWizardDraft()
    @Published public var presentationDraft = PresentationWorkspaceDraft()
    @Published public var clipPlayerDraft = ClipPlayerDraft.empty
    @Published public var timerDraft = TimerWorkspaceDraft()

    private let productIdentifier: String
    private let rootDirectory: String
    private let stateStore: RoomControlStateStore
    private let coreAgentClient: BETRCoreAgentClient
    private let coreAgentBootstrapper: RoomControlCoreAgentBootstrapper
    private let programTileRegistry: OutputLiveTileRegistry
    private let previewTileRegistry: OutputLiveTileRegistry
    private lazy var clipPlayerProducerController = ClipPlayerProducerController(
        coreAgentClient: coreAgentClient
    ) { [weak self] snapshot in
        Task { @MainActor [weak self] in
            self?.clipPlayerRuntimeSnapshot = snapshot
        }
    }
    private lazy var timerProducerController = TimerProducerController(
        coreAgentClient: coreAgentClient
    ) { [weak self] snapshot in
        Task { @MainActor [weak self] in
            self?.timerRuntimeSnapshot = snapshot
        }
    }
    private var eventObservationTask: Task<Void, Never>?
    private var diagnosticLogRefreshTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var restoringPersistedState = false

    public init(
        productIdentifier: String = "com.betr.room-control",
        rootDirectory: String = "/Users/joshperlman/Library/Application Support/BETR/com-betr-room-control-v4",
        coreAgentClient: BETRCoreAgentClient = BETRCoreAgentClient(),
        coreAgentBootstrapper: RoomControlCoreAgentBootstrapper = RoomControlCoreAgentBootstrapper(),
        liveTileRegistry: OutputLiveTileRegistry = OutputLiveTileRegistry()
    ) {
        self.productIdentifier = productIdentifier
        self.rootDirectory = rootDirectory
        self.stateStore = RoomControlStateStore(rootDirectory: rootDirectory)
        self.coreAgentClient = coreAgentClient
        self.coreAgentBootstrapper = coreAgentBootstrapper
        self.programTileRegistry = liveTileRegistry
        self.previewTileRegistry = OutputLiveTileRegistry()
        self.programTileRegistry.setAttachmentFetcher { [coreAgentClient] outputID, attachmentID in
            await coreAgentClient.fetchOutputPreviewAttachment(outputID: outputID, attachmentID: attachmentID)
        }
        self.previewTileRegistry.setAttachmentFetcher { [coreAgentClient] outputID, attachmentID in
            await coreAgentClient.fetchSelectedPreviewAttachment(outputID: outputID, attachmentID: attachmentID)
        }
        self.coreAgentLogPath = Self.preferredLogPath(from: Self.coreAgentLogURLs())
        self.networkHelperLogPath = Self.preferredLogPath(from: Self.networkHelperLogURLs())
        bindPersistence()
        refreshHostInterfaces()
    }

    public func start() {
        Task { [weak self] in
            guard let self else { return }
            self.startupBlockerMessage = nil
            self.startupBlockerRequiresInstall = false
            self.lastErrorMessage = nil
            self.lastStatusMessage = nil
            await self.restorePersistedStateIfNeeded()
            var bootstrapSucceeded = false
            do {
                let bootstrapStatus = try await self.coreAgentBootstrapper.ensureStarted()
                _ = try await self.coreAgentClient.waitForAgentAvailability()
                self.lastStatusMessage = bootstrapStatus.note
                bootstrapSucceeded = true
            } catch let error as RoomControlCoreAgentBootstrapError {
                switch error {
                case .installRequired:
                    self.startupBlockerMessage = error.localizedDescription
                    self.startupBlockerRequiresInstall = true
                    self.isBootstrapped = true
                    return
                default:
                    self.startupBlockerMessage = error.localizedDescription
                    self.startupBlockerRequiresInstall = false
                    self.isBootstrapped = true
                    return
                }
            } catch let error as RoomControlPrivilegedNetworkHelperBootstrapError {
                self.startupBlockerMessage = error.localizedDescription
                self.startupBlockerRequiresInstall = false
                self.isBootstrapped = true
                return
            } catch {
                self.startupBlockerMessage = "Starting BETRCoreAgent failed. \(error.localizedDescription)"
                self.startupBlockerRequiresInstall = false
                self.isBootstrapped = true
                return
            }
            await self.syncManagedLocalProducersFromDrafts()
            await self.reloadShellStateFromCore()
            self.hostValidation = await self.coreAgentClient.currentValidationSnapshot()
            self.refreshDiagnosticLogs()
            if bootstrapSucceeded {
                self.beginCoreEventObservation()
            }
            self.isBootstrapped = true
        }
    }

    public func shutdown() {
        eventObservationTask?.cancel()
        eventObservationTask = nil
        diagnosticLogRefreshTask?.cancel()
        diagnosticLogRefreshTask = nil
        persistenceTask?.cancel()
        persistenceTask = nil
        Task { [coreAgentClient] in
            await coreAgentClient.stopObservingEvents()
        }
        Task { [clipPlayerProducerController, timerProducerController] in
            await clipPlayerProducerController.shutdown()
            await timerProducerController.shutdown()
        }
    }

    public func assignSource(_ sourceID: String, to outputID: String, slotID: String) {
        performAction(
            "Assigning \(slotID)",
            operation: { [coreAgentClient] in
                try await coreAgentClient.assignSource(sourceID: sourceID, outputID: outputID, slotID: slotID)
            },
            onSuccess: {
                self.lastStatusMessage = "Assigned \(slotID) on \(outputID) to \(sourceID)."
            }
        )
    }

    public func clearOutputSlot(_ outputID: String, slotID: String) {
        performAction(
            "Clearing \(slotID)",
            operation: { [coreAgentClient] in
                try await coreAgentClient.clearSlot(outputID: outputID, slotID: slotID)
            },
            onSuccess: {
                self.lastStatusMessage = "Cleared \(slotID) on \(outputID)."
            }
        )
    }

    public func setPreviewSlot(_ outputID: String, slotID: String?) {
        let description = slotID == nil ? "Clearing preview" : "Arming preview"
        performAction(
            description,
            operation: { [coreAgentClient] in
                try await coreAgentClient.setPreview(outputID: outputID, slotID: slotID)
            },
            onSuccess: {
                self.lastStatusMessage = slotID == nil
                    ? "Cleared preview on \(outputID)."
                    : "Preview is now armed from \(slotID!) on \(outputID)."
            }
        )
    }

    public func takeProgramSlot(_ outputID: String, slotID: String) {
        performAction(
            "Taking program",
            operation: { [coreAgentClient] in
                try await coreAgentClient.takeProgram(outputID: outputID, slotID: slotID)
            },
            onSuccess: {
                self.lastStatusMessage = "\(slotID) is now live on \(outputID)."
            }
        )
    }

    public func addOutput() {
        performAction(
            "Adding output",
            operation: { [coreAgentClient] in
                try await coreAgentClient.addOutput()
            },
            onSuccess: {
                self.lastStatusMessage = "Requested a new output from BETRCoreAgent."
            }
        )
    }

    public func removeOutput(_ outputID: String) {
        performAction(
            "Removing output",
            operation: { [coreAgentClient] in
                try await coreAgentClient.removeOutput(outputID)
            },
            onSuccess: {
                self.lastStatusMessage = "Requested removal of \(outputID)."
            }
        )
    }

    public func toggleOutputAudioMuted(_ outputID: String) {
        let muted = !(shellState?.workspace.cards.first(where: { $0.id == outputID })?.isAudioMuted ?? false)
        performAction(
            muted ? "Muting output" : "Unmuting output",
            operation: { [coreAgentClient] in
                try await coreAgentClient.setOutputAudioMuted(outputID: outputID, muted: muted)
            },
            onSuccess: {
                self.lastStatusMessage = muted ? "Muted \(outputID)." : "Restored audio on \(outputID)."
            }
        )
    }

    public func toggleOutputSoloedLocally(_ outputID: String) {
        let soloed = !(shellState?.workspace.cards.first(where: { $0.id == outputID })?.isSoloedLocally ?? false)
        performAction(
            soloed ? "Soloing output" : "Unsoloing output",
            operation: { [coreAgentClient] in
                try await coreAgentClient.setOutputSoloedLocally(outputID: outputID, soloed: soloed)
            },
            onSuccess: {
                self.lastStatusMessage = soloed ? "Soloed \(outputID) locally." : "Removed local solo from \(outputID)."
            }
        )
    }

    public func refreshHostInterfaces() {
        let summaries = HostInterfaceInspector.scan(
            showNetworkCIDR: hostDraft.showNetworkCIDR,
            selectedInterfaceID: hostDraft.selectedInterfaceID.nilIfEmpty
        )
        hostInterfaceSummaries = summaries
        if summaries.contains(where: { $0.id == hostDraft.selectedInterfaceID }) == false {
            hostDraft.selectedInterfaceID = summaries.first(where: \.isRecommended)?.id
                ?? summaries.first?.id
                ?? ""
        }
    }

    public func startOverHostWizard() {
        performAction(
            "Restoring normal macOS networking",
            operation: { [coreAgentClient] in
                try await coreAgentClient.resetNDIHostEnvironment()
            },
            onSuccess: {
                await self.coreAgentBootstrapper.markManagedAgentRestartRequired()
                self.applyBETRRoomNDIDefaults()
                self.hostWizardProgressState.currentStep = .interface
                self.refreshHostInterfaces()
                self.hostValidation = await self.coreAgentClient.currentValidationSnapshot()
                self.lastStatusMessage = "Restored normal macOS networking, cleared BETR's saved host ownership, and reset the wizard to Step 1. BETR will not reapply network control until you use Apply + Restart again."
                self.pendingRestartPromptContext = .startOver
            }
        )
    }

    public func dismissPendingRestartPrompt() {
        pendingRestartPromptContext = nil
    }

    public func prepareForCoreAgentRestart() async {
        await coreAgentBootstrapper.stopManagedAgentForRelaunch()
    }

    public func setHostWizardStep(_ step: NDIWizardPersistedStep) {
        hostWizardProgressState.currentStep = step
    }

    public func applyHostSettings() {
        guard hostDraft.selectedInterfaceID.isEmpty == false else {
            lastErrorMessage = "Select the show interface before applying NDI settings."
            return
        }

        let draft = hostDraft
        let selectedInterfaceSummary = selectedHostInterfaceSummary()
        performAction(
            "Applying NDI settings",
            operation: { [coreAgentClient] in
                try await coreAgentClient.applyHostDraft(
                    draft,
                    interfaceSummary: selectedInterfaceSummary
                )
            },
            onSuccess: {
                await self.coreAgentBootstrapper.markManagedAgentRestartRequired()
                self.pendingRestartPromptContext = .apply
                do {
                    self.hostValidation = try await self.coreAgentClient.refreshValidation()
                } catch {
                    self.hostValidation = await self.coreAgentClient.currentValidationSnapshot()
                    self.lastStatusMessage = "Applied NDI settings, but BETR could not refresh validation until after restart. \(error.localizedDescription)"
                }
                self.completeHostWizardStep(.apply)
                self.hostWizardProgressState.currentStep = .apply
            }
        )
    }

    public func refreshHostValidation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPerformingAction = true
            self.lastErrorMessage = nil
            defer { self.isPerformingAction = false }

            do {
                self.hostValidation = try await self.coreAgentClient.refreshValidation()
                await self.reloadShellStateFromCore()
                self.refreshDiagnosticLogs()
                self.completeHostWizardStep(.validation)
                self.lastStatusMessage = "Refreshed validation from BETRCoreAgent."
            } catch {
                self.lastErrorMessage = "Refreshing validation failed. \(error.localizedDescription)"
                self.refreshDiagnosticLogs()
            }
        }
    }

    public func applyBETRRoomNDIDefaults() {
        hostDraft = HostWizardDraft()
        refreshHostInterfaces()
        hostWizardProgressState = NDIWizardProgressState(currentStep: .interface)
        lastStatusMessage = "Applied BETR room defaults to the grouped settings draft."
    }

    public func noteStatus(_ message: String) {
        lastStatusMessage = message
    }

    public func chooseClipPlayerFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Select images or videos for the Clip Player."
        guard panel.runModal() == .OK else { return }
        addClipPlayerItems(from: panel.urls)
    }

    public func addClipPlayerItems(from urls: [URL]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPerformingAction = true
            self.lastErrorMessage = nil
            defer { self.isPerformingAction = false }

            var appendedItems: [ClipPlayerItem] = []
            let startOrder = self.clipPlayerDraft.items.count
            for (index, url) in urls.enumerated() {
                guard let itemType = ClipPlayerItemType.type(for: url) else { continue }
                let bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                appendedItems.append(
                    ClipPlayerItem(
                        fileName: url.lastPathComponent,
                        fileBookmark: bookmark,
                        filePath: url.path,
                        type: itemType,
                        dwellSeconds: ClipPlayerConstants.defaultImageDwellSeconds,
                        sortOrder: startOrder + index
                    )
                )
            }

            self.clipPlayerDraft.items.append(contentsOf: appendedItems)
            self.reindexClipPlayerItems()
            await self.syncClipPlayerDraftToController()
            self.lastStatusMessage = appendedItems.isEmpty
                ? "No supported Clip Player media was added."
                : "Added \(appendedItems.count) item(s) to Clip Player."
        }
    }

    public func removeClipPlayerItem(_ itemID: String) {
        clipPlayerDraft.items.removeAll(where: { $0.id == itemID })
        reindexClipPlayerItems()
        clipPlayerDraft.currentItemIndex = min(
            clipPlayerDraft.currentItemIndex,
            max(0, clipPlayerDraft.items.count - 1)
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncClipPlayerDraftToController()
            self.lastStatusMessage = "Removed the selected Clip Player item."
        }
    }

    public func moveClipPlayerItems(from source: IndexSet, to destination: Int) {
        let trackedItemID: String?
        if let runtimeItemID = clipPlayerRuntimeSnapshot.currentItemID {
            trackedItemID = runtimeItemID
        } else if clipPlayerDraft.items.indices.contains(clipPlayerDraft.currentItemIndex) {
            trackedItemID = clipPlayerDraft.items[clipPlayerDraft.currentItemIndex].id
        } else {
            trackedItemID = nil
        }
        clipPlayerDraft.items.move(fromOffsets: source, toOffset: destination)
        reindexClipPlayerItems()
        if let trackedItemID,
           let trackedIndex = clipPlayerDraft.items.firstIndex(where: { $0.id == trackedItemID }) {
            clipPlayerDraft.currentItemIndex = trackedIndex
        }
    }

    public func commitClipPlayerReorder() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncClipPlayerDraftToController()
            self.lastStatusMessage = "Updated the Clip Player order."
        }
    }

    public func setClipPlayerItemDwell(_ itemID: String, seconds: Double) {
        guard let index = clipPlayerDraft.items.firstIndex(where: { $0.id == itemID }) else { return }
        let clampedSeconds = max(1, min(3600, seconds))
        guard clipPlayerDraft.items[index].dwellSeconds != clampedSeconds else { return }
        clipPlayerDraft.items[index] = clipPlayerDraft.items[index].updating(dwellSeconds: clampedSeconds)
        commitClipPlayerDraftChanges()
    }

    public func setClipPlayerPlaybackMode(_ mode: ClipPlayerPlaybackMode) {
        guard clipPlayerDraft.playbackMode != mode else { return }
        clipPlayerDraft.playbackMode = mode
        commitClipPlayerDraftChanges()
    }

    public func setClipPlayerTransitionType(_ transitionType: ClipPlayerTransitionType) {
        guard clipPlayerDraft.transitionType != transitionType else { return }
        clipPlayerDraft.transitionType = transitionType
        commitClipPlayerDraftChanges()
    }

    public func setClipPlayerTransitionDuration(_ durationMs: Int) {
        clipPlayerDraft.transitionDurationMs = max(100, min(2_000, durationMs))
    }

    public func commitClipPlayerDraftChanges(statusMessage: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncClipPlayerDraftToController()
            if let statusMessage {
                self.lastStatusMessage = statusMessage
            }
        }
    }

    public func selectClipPlayerItem(_ itemID: String) {
        guard let index = clipPlayerDraft.items.firstIndex(where: { $0.id == itemID }) else { return }
        clipPlayerDraft.currentItemIndex = index
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clipPlayerProducerController.selectItem(index: index)
            await self.syncProducerRuntimeSnapshots()
        }
    }

    public func playClipPlayer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clipPlayerProducerController.play()
            self.clipPlayerDraft.wasPlaying = true
            await self.syncProducerRuntimeSnapshots()
            await self.reloadShellStateFromCore()
            self.lastStatusMessage = "Started Clip Player."
        }
    }

    public func pauseClipPlayer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clipPlayerProducerController.pause()
            self.clipPlayerDraft.wasPlaying = false
            await self.syncProducerRuntimeSnapshots()
            self.lastStatusMessage = "Paused Clip Player."
        }
    }

    public func stopClipPlayer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clipPlayerProducerController.stop()
            self.clipPlayerDraft.wasPlaying = false
            await self.syncProducerRuntimeSnapshots()
            self.lastStatusMessage = "Stopped Clip Player."
        }
    }

    public func nextClipPlayerItem() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clipPlayerProducerController.nextItem()
            self.clipPlayerDraft.wasPlaying = self.clipPlayerRuntimeSnapshot.runState == .playing
            await self.syncProducerRuntimeSnapshots()
            self.lastStatusMessage = "Advanced Clip Player."
        }
    }

    public func previousClipPlayerItem() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clipPlayerProducerController.previousItem()
            self.clipPlayerDraft.wasPlaying = self.clipPlayerRuntimeSnapshot.runState == .playing
            await self.syncProducerRuntimeSnapshots()
            self.lastStatusMessage = "Moved Clip Player backward."
        }
    }

    public func saveTimerState() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncTimerDraftToController()
            self.lastStatusMessage = "Saved timer settings."
        }
    }

    public func setTimerOutputEnabled(_ enabled: Bool) {
        timerDraft.outputEnabled = enabled
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncTimerDraftToController()
            self.lastStatusMessage = enabled
                ? "Enabled BETR Room Control (Timer) as a routable local source."
                : "Disabled the routable timer source."
        }
    }

    public func startTimer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let timerState = self.timerStateFromDraft()
            await self.timerProducerController.start(state: timerState)
            await self.syncProducerRuntimeSnapshots()
            await self.reloadShellStateFromCore()
            self.lastStatusMessage = "Started the timer."
        }
    }

    public func pauseTimer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.timerProducerController.pause()
            await self.syncProducerRuntimeSnapshots()
            self.lastStatusMessage = "Paused the timer."
        }
    }

    public func resumeTimer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.timerProducerController.resume()
            await self.syncProducerRuntimeSnapshots()
            self.lastStatusMessage = "Resumed the timer."
        }
    }

    public func stopTimer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.timerProducerController.stop()
            await self.syncProducerRuntimeSnapshots()
            self.lastStatusMessage = "Stopped the timer."
        }
    }

    public func restartTimer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.timerProducerController.restart(state: self.timerStateFromDraft())
            await self.syncProducerRuntimeSnapshots()
            await self.reloadShellStateFromCore()
            self.lastStatusMessage = "Restarted the timer."
        }
    }

    public func renderFeed(for outputID: String) -> OutputTileRenderFeed {
        programRenderFeed(for: outputID)
    }

    public func programRenderFeed(for outputID: String) -> OutputTileRenderFeed {
        programTileRegistry.renderFeed(for: outputID)
    }

    public func previewRenderFeed(for outputID: String) -> OutputTileRenderFeed {
        previewTileRegistry.renderFeed(for: outputID)
    }

    private func performAction(
        _ description: String,
        operation: @escaping @Sendable () async throws -> Void,
        onSuccess: (@MainActor () async -> Void)? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPerformingAction = true
            self.lastErrorMessage = nil
            defer { self.isPerformingAction = false }

            do {
                try await operation()
                await self.reloadShellStateFromCore()
                await onSuccess?()
            } catch {
                self.lastErrorMessage = "\(description) failed. \(error.localizedDescription)"
            }
        }
    }

    private func reloadShellStateFromCore() async {
        let state = await coreAgentClient.bootstrapShellState(rootDirectory: rootDirectory)
        shellState = state
        capacitySnapshot = state.capacity ?? RoomControlCapacitySnapshot()
        let keeping = Set(state.workspace.cards.map(\.id))
        programTileRegistry.prune(keeping: keeping)
        previewTileRegistry.prune(keeping: keeping)
        await syncProducerRuntimeSnapshots()
        refreshDiagnosticLogs()
    }

    private func bindPersistence() {
        $operatorShellUIState
            .dropFirst()
            .sink { [weak self] _ in self?.schedulePersistedStateSave() }
            .store(in: &cancellables)
        $hostDraft
            .dropFirst()
            .sink { [weak self] _ in self?.schedulePersistedStateSave() }
            .store(in: &cancellables)
        $presentationDraft
            .dropFirst()
            .sink { [weak self] _ in self?.schedulePersistedStateSave() }
            .store(in: &cancellables)
        $clipPlayerDraft
            .dropFirst()
            .sink { [weak self] _ in self?.schedulePersistedStateSave() }
            .store(in: &cancellables)
        $timerDraft
            .dropFirst()
            .sink { [weak self] _ in self?.schedulePersistedStateSave() }
            .store(in: &cancellables)
    }

    private func schedulePersistedStateSave() {
        guard restoringPersistedState == false else { return }
        let persistedState = currentPersistedState()
        persistenceTask?.cancel()
        persistenceTask = Task { [stateStore] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = try? await stateStore.save(persistedState)
        }
    }

    private func currentPersistedState() -> RoomControlPersistedState {
        RoomControlPersistedState(
            uiState: RoomControlOperatorShellUIState(
                leadingColumnWidth: operatorShellUIState.leadingColumnWidth,
                centerColumnWidth: operatorShellUIState.centerColumnWidth,
                settingsPresented: false
            ),
            hostDraft: hostDraft,
            presentationDraft: presentationDraft,
            clipPlayerDraft: clipPlayerDraft,
            timerDraft: timerDraft
        )
    }

    private func restorePersistedStateIfNeeded() async {
        restoringPersistedState = true
        let persistedState = await stateStore.load()
        operatorShellUIState = RoomControlOperatorShellUIState(
            leadingColumnWidth: persistedState.uiState.leadingColumnWidth,
            centerColumnWidth: persistedState.uiState.centerColumnWidth,
            settingsPresented: false
        )
        hostDraft = persistedState.hostDraft
        presentationDraft = persistedState.presentationDraft
        clipPlayerDraft = persistedState.clipPlayerDraft
        timerDraft = persistedState.timerDraft
        refreshHostInterfaces()
        restoringPersistedState = false
    }

    private func syncManagedLocalProducersFromDrafts() async {
        await clipPlayerProducerController.applyState(clipPlayerDraft.asSavedState())
        await timerProducerController.configure(state: timerStateFromDraft())
        await syncProducerRuntimeSnapshots()
    }

    private func syncProducerRuntimeSnapshots() async {
        clipPlayerRuntimeSnapshot = await clipPlayerProducerController.snapshot()
        timerRuntimeSnapshot = await timerProducerController.snapshot()
    }

    private func syncClipPlayerDraftToController() async {
        await clipPlayerProducerController.applyState(clipPlayerDraft.asSavedState())
        await syncProducerRuntimeSnapshots()
        await reloadShellStateFromCore()
    }

    private func syncTimerDraftToController() async {
        await timerProducerController.configure(state: timerStateFromDraft())
        await syncProducerRuntimeSnapshots()
        await reloadShellStateFromCore()
    }

    private func reindexClipPlayerItems() {
        clipPlayerDraft.items = clipPlayerDraft.items.enumerated().map { index, item in
            item.updating(sortOrder: index)
        }
        clipPlayerDraft.currentItemIndex = min(
            clipPlayerDraft.currentItemIndex,
            max(0, clipPlayerDraft.items.count - 1)
        )
    }

    private func timerStateFromDraft() -> SimpleTimerState {
        let durationSeconds = max(60, timerDraft.durationMinutes * 60)
        return SimpleTimerState(
            mode: timerDraft.mode,
            durationSeconds: timerDraft.mode == .duration ? durationSeconds : nil,
            endTime: timerDraft.mode == .endTime ? timerDraft.endTime : nil,
            startedAt: nil,
            running: timerRuntimeSnapshot.runState == .running,
            remainingSeconds: timerRuntimeSnapshot.remainingSeconds,
            visibleSurfaces: timerDraft.visibleSurfaces,
            outputEnabled: timerDraft.outputEnabled
        )
    }

    private func refreshDiagnosticLogs() {
        let coreAgentLogCandidates = Self.coreAgentLogURLs()
        let networkHelperLogCandidates = Self.networkHelperLogURLs()
        coreAgentLogPath = Self.preferredLogPath(from: coreAgentLogCandidates)
        networkHelperLogPath = Self.preferredLogPath(from: networkHelperLogCandidates)

        diagnosticLogRefreshTask?.cancel()
        diagnosticLogRefreshTask = Task { [weak self] in
            async let coreAgentLogExcerpt = Self.readLogTail(
                candidates: coreAgentLogCandidates,
                unifiedLogPredicate: #"process == "BETRCoreAgent" OR subsystem == "com.betr.core-v3""#,
                missingMessage: "BETRCoreAgent has not written a log file or unified-log line yet."
            )
            async let networkHelperLogExcerpt = Self.readLogTail(
                candidates: networkHelperLogCandidates,
                unifiedLogPredicate: #"process == "BETRNetworkHelper" OR subsystem == "com.betr.network-helper""#,
                missingMessage: "The privileged network helper has not written a log file or unified-log line yet."
            )

            let excerpts = await (coreAgentLogExcerpt, networkHelperLogExcerpt)
            guard let self, Task.isCancelled == false else { return }
            self.coreAgentLogExcerpt = excerpts.0
            self.networkHelperLogExcerpt = excerpts.1
        }
    }

    nonisolated private static func coreAgentLogURLs(fileManager: FileManager = .default) -> [URL] {
        let sharedLogURL = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("BETR", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("BETRCoreAgent.log", isDirectory: false)
        let legacyLogURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("BETRCoreAgentV3", isDirectory: true)
            .appendingPathComponent("BETRCoreAgent.log", isDirectory: false)
        return [sharedLogURL, legacyLogURL]
    }

    nonisolated private static func networkHelperLogURLs() -> [URL] {
        [
            URL(fileURLWithPath: "/Library/Logs/BETR/BETRNetworkHelper.log"),
            URL(fileURLWithPath: "/Library/Logs/BETRNetworkHelper/BETRNetworkHelper.log"),
        ]
    }

    nonisolated private static func preferredLogPath(
        from candidates: [URL],
        fileManager: FileManager = .default
    ) -> String {
        candidates.first(where: { fileManager.fileExists(atPath: $0.path) })?.path
            ?? candidates.first?.path
            ?? ""
    }

    nonisolated private static func readLogTail(
        candidates: [URL],
        lineLimit: Int = 80,
        maxBytes: Int = 256 * 1024,
        unifiedLogPredicate: String? = nil,
        missingMessage: String
    ) async -> String {
        await Task.detached(priority: .utility) {
            for url in candidates {
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    continue
                }

                let fileSize = (try? handle.seekToEnd()) ?? 0
                let startOffset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
                try? handle.seek(toOffset: startOffset)

                guard let data = try? handle.readToEnd(),
                      let text = String(data: data, encoding: .utf8) else {
                    try? handle.close()
                    continue
                }
                try? handle.close()

                let lines = text
                    .split(whereSeparator: \.isNewline)
                    .suffix(max(1, lineLimit))
                    .map(String.init)
                if lines.isEmpty == false {
                    return lines.joined(separator: "\n")
                }
            }

            guard let unifiedLogPredicate,
                  let unifiedTail = readUnifiedLogTail(
                    predicate: unifiedLogPredicate,
                    lineLimit: lineLimit
                  ) else {
                return missingMessage
            }
            return "[Unified Log Fallback]\n\(unifiedTail)"
        }.value
    }

    nonisolated private static func readUnifiedLogTail(
        predicate: String,
        lineLimit: Int
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--style",
            "compact",
            "--last",
            "10m",
            "--info",
            "--predicate",
            predicate,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        let lines = output
            .split(whereSeparator: \.isNewline)
            .suffix(max(1, lineLimit))
            .map(String.init)
        guard lines.isEmpty == false else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private func beginCoreEventObservation() {
        guard eventObservationTask == nil else { return }
        eventObservationTask = Task { [weak self] in
            guard let self else { return }
            let maxAttempts = 5

            for attempt in 1...maxAttempts {
                do {
                    try Task.checkCancellation()
                    try await self.coreAgentClient.startObservingEvents { [weak self] event in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.handleCoreEvent(event)
                        }
                    }
                    if attempt > 1 {
                        self.lastStatusMessage = "Restored live core updates from BETRCoreAgent."
                    }
                    if self.lastErrorMessage?.hasPrefix("Starting live core updates failed.") == true {
                        self.lastErrorMessage = nil
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard attempt < maxAttempts else {
                        self.lastErrorMessage = "Starting live core updates failed. \(error.localizedDescription)"
                        return
                    }
                    if attempt == 1 {
                        self.lastStatusMessage = "Retrying live core updates from BETRCoreAgent."
                    }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }
        }
    }

    private func handleCoreEvent(_ event: BETRCoreEventEnvelope) async {
        switch event.payload {
        case .directoryUpdated:
            await reloadShellStateFromCore()
            hostValidation = await coreAgentClient.currentValidationSnapshot()
            lastStatusMessage = "Updated discovery and host validation from BETRCoreAgent."
        case .workspaceUpdated:
            await reloadShellStateFromCore()
            lastStatusMessage = "Updated workspace state from BETRCoreAgent."
        case let .liveTile(liveTileEvent):
            if let shellState {
                self.shellState = await coreAgentClient.applyLiveTileEvent(liveTileEvent, to: shellState)
            }
        case let .outputPreviewAttachNotice(notice):
            programTileRegistry.applyAttachmentNotice(notice)
        case let .selectedPreviewAttachNotice(notice):
            previewTileRegistry.applyAttachmentNotice(notice)
        case let .outputPreviewAdvance(advance):
            programTileRegistry.applyAdvance(advance)
        case let .selectedPreviewAdvance(advance):
            previewTileRegistry.applyAdvance(advance)
        case let .outputPreviewDetach(outputID):
            programTileRegistry.applyDetach(outputID: outputID)
        case let .selectedPreviewDetach(outputID):
            previewTileRegistry.applyDetach(outputID: outputID)
        case let .hostValidation(snapshot):
            hostValidation = await coreAgentClient.makeWizardValidationSnapshot(from: snapshot)
            lastStatusMessage = "Updated validation state from BETRCoreAgent."
        default:
            await reloadShellStateFromCore()
            break
        }
    }

    private func selectedHostInterfaceSummary() -> HostInterfaceSummary? {
        hostInterfaceSummaries.first { $0.id == hostDraft.selectedInterfaceID }
    }

    private func completeHostWizardStep(_ step: NDIWizardPersistedStep) {
        hostWizardProgressState.completedSteps.insert(step)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
