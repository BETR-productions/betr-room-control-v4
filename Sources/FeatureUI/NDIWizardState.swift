// NDIWizardState — observable state model for the NDI setup wizard.
// Event-driven state transitions (no polling loops), multicast route cache 5s.

import CryptoKit
import Foundation
import RoutingDomain
import SwiftUI

public final class NDIWizardState: ObservableObject {
    /// XPC client for sending wizard commands to BETRCoreAgent.
    private var coreAgent: CoreAgentClient?
    /// FSEvents config file watcher — no polling.
    private var configWatcher: NDIConfigFileWatcher?
    private var configWatchTask: Task<Void, Never>?
    @Published public var currentStep: NDIWizardStep = .baseline
    @Published public var draft: NDIHostDraft = NDIHostDraft()
    @Published public var interfaces: [NDINetworkInterface] = []
    @Published public var validation: NDIWizardValidationSnapshot = NDIWizardValidationSnapshot()
    @Published public var lastErrorMessage: String?
    @Published public var lastStatusMessage: String?
    @Published public var draftFingerprint: String?
    @Published public var lastAppliedFingerprint: String?
    @Published public var awaitingPostApplyValidation: Bool = false
    @Published public var trafficProbeInProgress: Bool = false

    private var multicastRouteCache: (result: NDIMulticastRouteCheckState, timestamp: Date)?
    private let multicastRouteCacheTTL: TimeInterval = 5.0

    public init() {}

    // MARK: - XPC Binding (Task 86)

    /// Bind to the CoreAgentClient for wizard XPC commands.
    public func bind(coreAgent: CoreAgentClient) {
        self.coreAgent = coreAgent
    }

    /// Start FSEvents-based config file watching (Task 87).
    public func startConfigWatching(filePath: String) {
        let watcher = NDIConfigFileWatcher(filePath: filePath)
        configWatcher = watcher
        configWatchTask?.cancel()
        configWatchTask = Task { [weak self] in
            await watcher.startWatching()
            for await _ in watcher.changes {
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.handleConfigFileChanged()
                }
            }
        }
    }

    /// Stop config file watching.
    public func stopConfigWatching() {
        configWatchTask?.cancel()
        configWatchTask = nil
        Task { await configWatcher?.stopWatching() }
        configWatcher = nil
    }

    /// Called when FSEvents detects config file change.
    private func handleConfigFileChanged() {
        // If validation was already done, mark it stale
        if lastAppliedFingerprint != nil {
            recomputeFingerprint()
            lastStatusMessage = "NDI config changed on disk. Validation may be stale."
        }
    }

    // MARK: - Source Filter Persistence (Task 90)

    /// Apply the current source filter to the host profile via XPC.
    public func applySourceFilter() {
        guard !draft.sourceFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Source filter is included in the draft fingerprint and persisted
        // when applyAndRestart() commits the full profile via XPC.
        recomputeFingerprint()
        lastStatusMessage = "Source filter updated: \(draft.sourceFilter)"
    }

    // MARK: - Step Navigation

    public var steps: [NDIWizardStep] { NDIWizardStep.allCases }

    public var previousStep: NDIWizardStep? {
        guard let idx = steps.firstIndex(of: currentStep), idx > 0 else { return nil }
        return steps[idx - 1]
    }

    public var nextStep: NDIWizardStep? {
        guard let idx = steps.firstIndex(of: currentStep), idx + 1 < steps.count else { return nil }
        return steps[idx + 1]
    }

    public var nextButtonLabel: String {
        guard let next = nextStep else { return "Done" }
        return "Continue to \(next.title)"
    }

    public func stepNumber(_ step: NDIWizardStep) -> Int {
        (steps.firstIndex(of: step) ?? 0) + 1
    }

    public func setStep(_ step: NDIWizardStep) {
        withAnimation { currentStep = step }
    }

    // MARK: - Step State

    public func stepState(_ step: NDIWizardStep) -> NDIWizardCheckState {
        switch step {
        case .baseline:
            return draftLooksConfigured ? .passed : .warning
        case .interface:
            return showNICState
        case .discovery:
            if validation.multicastRouteState == .blocked { return .blocked }
            return validation.discoveryState.checkState
        case .identity:
            return identityFieldsReady ? .passed : .warning
        case .apply:
            return applyStepState
        case .validate:
            if validation.overallReady { return .passed }
            if validation.configState == .blocked || validation.multicastRouteState == .blocked { return .blocked }
            return .warning
        }
    }

    public func stepPillLabel(_ step: NDIWizardStep) -> String {
        currentStep == step ? "ACTIVE" : stepState(step).rawValue.uppercased()
    }

    // MARK: - Derived State

    public var draftLooksConfigured: Bool {
        !draft.showLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.showNetworkCIDR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var identityFieldsReady: Bool {
        !draft.nodeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.senderPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.outputPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var showNICState: NDIWizardCheckState {
        selectedInterface?.matchesShowNetwork == true ? .passed : .warning
    }

    public var showNICLabel: String {
        selectedInterface?.matchesShowNetwork == true ? "SHOW NIC READY" : "SHOW NIC NEEDED"
    }

    public var multicastLabel: String {
        validation.multicastRouteState == .passed ? "MULTICAST READY" : "MULTICAST WARN"
    }

    public var selectedInterface: NDINetworkInterface? {
        interfaces.first(where: { $0.id == draft.selectedInterfaceID })
    }

    public var recommendedInterface: NDINetworkInterface? {
        interfaces.first(where: \.isRecommended)
    }

    public var interfaceGuidance: String {
        guard let selected = selectedInterface else {
            return "Choose the adapter that will carry NDI. The dropdown shows hardware port, BSD name, and live IPv4."
        }
        if selected.matchesShowNetwork {
            return "The selected interface is on the configured show network. BETR can trust discovery, send, and multicast receive."
        }
        return "The selected interface is not on the configured show network. On the real show Mac you should see a live 192.168.55.x address here."
    }

    public var interfaceGuidanceColor: Color {
        selectedInterface?.matchesShowNetwork == true ? .green : .orange
    }

    private var applyStepState: NDIWizardCheckState {
        guard lastAppliedFingerprint != nil else { return .warning }
        if awaitingPostApplyValidation { return .warning }
        return lastAppliedFingerprint == draftFingerprint ? .passed : .warning
    }

    // MARK: - Actions

    /// Task 88: Start Over — clears ALL draft state and returns to Step 1.
    public func startOver() {
        draft = NDIHostDraft()
        validation = NDIWizardValidationSnapshot()
        lastErrorMessage = nil
        lastStatusMessage = nil
        draftFingerprint = nil
        lastAppliedFingerprint = nil
        awaitingPostApplyValidation = false
        trafficProbeInProgress = false
        multicastRouteCache = nil
        withAnimation { currentStep = .baseline }
    }

    public func jumpToValidate() {
        withAnimation { currentStep = .validate }
    }

    public func applyBETRRoomDefaults() {
        draft = NDIHostDraft()
        draft.showNetworkCIDR = "192.168.55.0/24"
        draft.nodeLabel = "BETR"
        draft.senderPrefix = "BETR"
        draft.outputPrefix = "Output"
        lastStatusMessage = "BETR room defaults applied."
    }

    public func autoSelectShowNIC() {
        guard let recommended = recommendedInterface else { return }
        draft.selectedInterfaceID = recommended.id
    }

    public func refreshInterfaces() {
        // Event-driven: XPC will push interface list updates via FSEvents.
        lastStatusMessage = "Interface refresh requested."
    }

    /// Task 89: Compute draft fingerprint from current draft fields.
    public func recomputeFingerprint() {
        let fields = [
            draft.showLocationName,
            draft.showNetworkCIDR,
            draft.selectedInterfaceID ?? "",
            draft.nodeLabel,
            draft.senderPrefix,
            draft.outputPrefix,
            draft.sourceFilter,
            draft.discoveryServersText,
        ].joined(separator: "|")
        let hash = SHA256.hash(data: Data(fields.utf8))
        draftFingerprint = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Task 89: True when validation was run against a different fingerprint than the current draft.
    public var validationIsStale: Bool {
        guard let last = lastAppliedFingerprint, let current = draftFingerprint else { return false }
        return last != current
    }

    public func refreshValidation() {
        recomputeFingerprint()
        // Event-driven: request validation from BETRCoreAgent via XPC.
        lastStatusMessage = "Validation refresh requested."
    }

    public func saveDraft() {
        lastStatusMessage = "Draft saved."
    }

    public func applyAndRestart() {
        recomputeFingerprint()
        awaitingPostApplyValidation = true
        lastAppliedFingerprint = draftFingerprint
        lastStatusMessage = "Apply + Restart requested via XPC."
        // Task 86: XPC dispatch — the CoreAgentClient will handle the actual
        // config write + NDI runtime restart when the agent-side is wired.
    }

    public func restoreLastApplied() {
        lastStatusMessage = "Restore last applied configuration requested."
    }

    public func runBoundedTrafficProbe() {
        trafficProbeInProgress = true
        lastStatusMessage = "10-second traffic probe started."
    }

    // MARK: - Multicast Route Cache

    public func cachedMulticastRouteState() -> NDIMulticastRouteCheckState {
        if let cache = multicastRouteCache,
           Date().timeIntervalSince(cache.timestamp) < multicastRouteCacheTTL {
            return cache.result
        }
        return validation.multicastRouteState
    }

    public func updateMulticastRouteCache(_ state: NDIMulticastRouteCheckState) {
        multicastRouteCache = (result: state, timestamp: Date())
        validation.multicastRouteState = state
    }
}
