// NDIWizardState — observable state model for the NDI setup wizard.
// Event-driven state transitions (no polling loops), multicast route cache 5s.

import Foundation
import SwiftUI

public final class NDIWizardState: ObservableObject {
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

    public func startOver() {
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

    public func refreshValidation() {
        // Event-driven: request validation from BETRCoreAgent via XPC.
        lastStatusMessage = "Validation refresh requested."
    }

    public func saveDraft() {
        lastStatusMessage = "Draft saved."
    }

    public func applyAndRestart() {
        awaitingPostApplyValidation = true
        lastAppliedFingerprint = draftFingerprint
        lastStatusMessage = "Apply + Restart requested."
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
