// NDIWizardSettingsView — NDI wizard UI preserved from v3 RoomControlSettingsRootView.
// Step-based wizard with validation states, NIC selection, discovery server config,
// multicast route setup, source filter config, "Start Over" returns to Step 1,
// continuous live-source discovery via event-driven XPC (no polling loops).

import SwiftUI

public struct NDIWizardSettingsView: View {
    @ObservedObject var wizard: NDIWizardState

    public init(wizard: NDIWizardState) {
        self.wizard = wizard
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 1).id("ndi-wizard-top")

                    settingsHeader("BETR NDI Setup Wizard")
                    overviewCard

                    HStack(alignment: .top, spacing: 18) {
                        stepRail.frame(width: 290)
                        mainColumn
                    }
                }
                .padding(20)
            }
            .onChange(of: wizard.currentStep) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("ndi-wizard-top", anchor: .top)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 820)
        .background(BrandTokens.dark)
        .preferredColorScheme(.dark)
        .onAppear {
            wizard.refreshInterfaces()
            wizard.refreshValidation()
        }
    }

    // MARK: - Overview Card

    private var overviewCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                wizardSectionHeader(
                    "True Wizard Flow",
                    subtitle: "Walk the operator path step by step: room defaults, NIC, discovery and multicast, naming, apply, then validate real runtime truth."
                )

                HStack(spacing: 8) {
                    statusPill(wizard.showNICLabel, state: wizard.showNICState)
                    statusPill(wizard.validation.discoveryState.badgeLabel, state: wizard.validation.discoveryState.checkState)
                    statusPill(wizard.multicastLabel, state: wizard.validation.multicastRouteState.wizardState)
                    statusPill("BETR-ONLY", state: wizard.draft.ownershipMode == .betrOnly ? .passed : .warning)
                }

                if let statusMessage = wizard.lastStatusMessage {
                    Text(statusMessage)
                        .font(BrandTokens.display(size: 11))
                        .foregroundStyle(BrandTokens.warmGrey)
                }

                if let errorMessage = wizard.lastErrorMessage {
                    validationStatusBlock(
                        title: "Last NDI Action Failed",
                        state: .blocked,
                        message: errorMessage
                    )
                }

                HStack(spacing: 12) {
                    Button("Start Over") { wizard.startOver() }
                    Button("Jump to Validate") { wizard.jumpToValidate() }
                    Button("Refresh Validation") {
                        wizard.refreshValidation()
                        wizard.jumpToValidate()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Step Rail

    private var stepRail: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                wizardSectionHeader(
                    "Steps",
                    subtitle: "Each step is its own page. Start Over sends you back to Step 1."
                )

                ForEach(wizard.steps, id: \.rawValue) { step in
                    Button {
                        wizard.setStep(step)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(wizard.stepNumber(step))")
                                .font(BrandTokens.mono(size: 11))
                                .foregroundStyle(wizard.currentStep == step ? BrandTokens.offWhite : BrandTokens.warmGrey)
                                .frame(width: 24, height: 24)
                                .background(
                                    Capsule()
                                        .fill(wizard.currentStep == step ? BrandTokens.gold : BrandTokens.charcoal)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title)
                                    .font(BrandTokens.display(size: 12, weight: .semibold))
                                    .foregroundStyle(BrandTokens.offWhite)
                                Text(step.subtitle)
                                    .font(BrandTokens.display(size: 10))
                                    .foregroundStyle(BrandTokens.warmGrey)
                            }
                            Spacer(minLength: 8)
                            statusPill(wizard.stepPillLabel(step), state: wizard.stepState(step))
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(wizard.currentStep == step ? BrandTokens.charcoal : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Main Column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                HStack {
                    wizardSectionHeader(
                        "Step \(wizard.stepNumber(wizard.currentStep)) of \(wizard.steps.count) \u{00B7} \(wizard.currentStep.title)",
                        subtitle: wizard.currentStep.description
                    )
                    Spacer()
                    statusPill(wizard.stepPillLabel(wizard.currentStep), state: wizard.stepState(wizard.currentStep))
                }
            }

            stepContent(wizard.currentStep)

            settingsCard {
                HStack {
                    Button("Back") {
                        guard let prev = wizard.previousStep else { return }
                        wizard.setStep(prev)
                    }
                    .disabled(wizard.previousStep == nil)

                    Spacer()

                    Button(wizard.nextButtonLabel) {
                        guard let next = wizard.nextStep else { return }
                        wizard.setStep(next)
                    }
                    .disabled(wizard.nextStep == nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private func stepContent(_ step: NDIWizardStep) -> some View {
        switch step {
        case .baseline:  baselineStep
        case .interface: interfaceStep
        case .discovery: discoveryStep
        case .identity:  identityStep
        case .apply:     applyStep
        case .validate:  validateStep
        }
    }

    // MARK: - Step 1: Baseline

    private var baselineStep: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                wizardSectionHeader(
                    "Room Defaults And Reset",
                    subtitle: "Start with BETR room defaults or reload the saved profile. This is also where Start Over and a true BETR-only reset live."
                )

                HStack(spacing: 12) {
                    Button("Use BETR Room Defaults") { wizard.applyBETRRoomDefaults() }
                    Button("Start Over") { wizard.startOver() }
                }
                .buttonStyle(.bordered)

                Text("This step should leave you with BETR room defaults loaded and the wizard reset to Step 1.")
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
        }
    }

    // MARK: - Step 2: Interface

    private var interfaceStep: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                wizardSectionHeader(
                    "Interface",
                    subtitle: "Pick the actual show-network adapter. This step makes BETR target the right NIC for discovery, receive, and multicast routing."
                )

                Picker("Selected NDI Interface", selection: $wizard.draft.selectedInterfaceID) {
                    Text("Select interface").tag("")
                    ForEach(wizard.interfaces) { iface in
                        Text(iface.stableDropdownLabel).tag(iface.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 12) {
                    Button("Refresh Interfaces") { wizard.refreshInterfaces() }
                    Button("Auto-Select Show NIC") { wizard.autoSelectShowNIC() }
                        .disabled(wizard.recommendedInterface == nil)
                }
                .buttonStyle(.bordered)

                if let selected = wizard.selectedInterface {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            settingsValue("Hardware Port", selected.hardwarePortLabel)
                            settingsValue("BSD Name", selected.bsdName)
                            settingsValue("Live IPv4", selected.livePrimaryIPv4CIDR ?? "Not selected")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            settingsValue("Show Network", wizard.draft.showNetworkCIDR)
                            settingsValue("Recommended", wizard.recommendedInterface?.stableDropdownLabel ?? "No matching show NIC found")
                            settingsValue("Supports Multicast", selected.supportsMulticast ? "Yes" : "No")
                        }
                    }
                }

                Text(wizard.interfaceGuidance)
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(wizard.interfaceGuidanceColor)
            }
        }
    }

    // MARK: - Step 3: Discovery + Multicast

    private var discoveryStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    wizardSectionHeader(
                        "Discovery Server",
                        subtitle: "Configure how BETR finds sources. Point Core at the right Discovery Server."
                    )

                    HStack(alignment: .top, spacing: 18) {
                        Picker("Mode", selection: $wizard.draft.discoveryMode) {
                            Text("Discovery Server First").tag(NDIDiscoveryMode.discoveryServerFirst)
                            Text("Discovery Server Only").tag(NDIDiscoveryMode.discoveryServerOnly)
                            Text("mDNS Only").tag(NDIDiscoveryMode.mdnsOnly)
                        }
                        .pickerStyle(.menu)

                        Toggle("Enable mDNS", isOn: $wizard.draft.mdnsEnabled)
                            .disabled(wizard.draft.discoveryMode == .discoveryServerOnly)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Discovery Servers")
                            .font(BrandTokens.display(size: 12, weight: .semibold))
                            .foregroundStyle(BrandTokens.offWhite)
                        TextField("one per line", text: $wizard.draft.discoveryServersText, axis: .vertical)
                            .lineLimit(2...5)
                        Text("For a BETR room, start with 192.168.55.11 on the NDI side of the network.")
                            .font(BrandTokens.display(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }

                    Text(wizard.validation.discoveryState.summary)
                        .font(BrandTokens.display(size: 11))
                        .foregroundStyle(statusColor(for: wizard.validation.discoveryState.checkState))
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    wizardSectionHeader(
                        "Multicast",
                        subtitle: "Configure the real multicast path. Route owner needs to match the committed show NIC."
                    )

                    HStack(spacing: 16) {
                        Toggle("Enable Multicast", isOn: $wizard.draft.multicastEnabled)
                        Toggle("Receive", isOn: $wizard.draft.multicastReceiveEnabled)
                        Toggle("Transmit", isOn: $wizard.draft.multicastTransmitEnabled)
                    }

                    HStack(spacing: 12) {
                        TextField("Prefix", text: $wizard.draft.multicastPrefix)
                        TextField("Netmask", text: $wizard.draft.multicastNetmask)
                        Stepper("TTL \(wizard.draft.multicastTTL)", value: $wizard.draft.multicastTTL, in: 1...64)
                            .frame(maxWidth: 160, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Receive Subnets")
                            .font(BrandTokens.display(size: 12, weight: .semibold))
                            .foregroundStyle(BrandTokens.offWhite)
                        TextField("leave blank for same-VLAN multicast", text: $wizard.draft.receiveSubnetsText, axis: .vertical)
                            .lineLimit(2...4)
                        Text("Only set Receive Subnets when the network team intentionally routed multicast between subnets.")
                            .font(BrandTokens.display(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }

                    HStack(spacing: 12) {
                        Button(wizard.trafficProbeInProgress ? "Running 10-Second Traffic Probe..." : "Run 10-Second Traffic Probe") {
                            wizard.runBoundedTrafficProbe()
                        }
                        .disabled(wizard.trafficProbeInProgress)
                        Button("Refresh Validation") { wizard.refreshValidation() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Step 4: Identity

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    wizardSectionHeader(
                        "Naming",
                        subtitle: "Set the names operators and other devices will actually see."
                    )

                    HStack(spacing: 12) {
                        TextField("Node Label", text: $wizard.draft.nodeLabel)
                        TextField("Sender Prefix", text: $wizard.draft.senderPrefix)
                        TextField("Output Prefix", text: $wizard.draft.outputPrefix)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Groups")
                            .font(BrandTokens.display(size: 12, weight: .semibold))
                            .foregroundStyle(BrandTokens.offWhite)
                        TextField("comma or line separated", text: $wizard.draft.groupsText, axis: .vertical)
                            .lineLimit(1...3)
                        Text("Leave Groups blank unless you intentionally want visibility limited to specific NDI groups.")
                            .font(BrandTokens.display(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    wizardSectionHeader(
                        "Advanced",
                        subtitle: "Uncommon controls that stay inside the naming step."
                    )

                    HStack(spacing: 12) {
                        Picker("Ownership", selection: $wizard.draft.ownershipMode) {
                            Text("BETR Only").tag(NDIHostOwnershipMode.betrOnly)
                            Text("Global Takeover").tag(NDIHostOwnershipMode.globalTakeover)
                        }
                        .pickerStyle(.menu)

                        TextField("Source Filter (optional)", text: $wizard.draft.sourceFilter)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Extra IPs")
                                .font(BrandTokens.display(size: 12, weight: .semibold))
                                .foregroundStyle(BrandTokens.offWhite)
                            TextField("optional manual IP hints", text: $wizard.draft.extraIPsText, axis: .vertical)
                                .lineLimit(2...4)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Disable Wi-Fi in proof mode", isOn: $wizard.draft.disableWiFiInProofMode)
                            Toggle("Disable bridge services in proof mode", isOn: $wizard.draft.disableBridgeServicesInProofMode)
                        }
                    }

                    Text(wizard.draft.ownershipMode == .betrOnly
                        ? "BETR-only keeps the shared Access Manager config out of the normal path. This is the default and recommended mode."
                        : "Global Takeover mirrors BETR's config into the shared machine path. Only enable this when you intentionally want BETR to behave like Access Manager for the whole Mac.")
                        .font(BrandTokens.display(size: 11))
                        .foregroundStyle(wizard.draft.ownershipMode == .betrOnly ? BrandTokens.warmGrey : .orange)
                }
            }
        }
    }

    // MARK: - Step 5: Apply

    private var applyStep: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                wizardSectionHeader(
                    "Apply + Restart",
                    subtitle: "Save keeps the draft only. Apply writes BETR's owned config, executes the network-control plan, and restarts BETR on the committed profile."
                )

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        settingsValue("Draft Config", wizard.draftFingerprint ?? "Unavailable")
                        settingsValue("Last Applied", wizard.lastAppliedFingerprint ?? "Not yet")
                        settingsValue("Runtime Config", wizard.validation.runtimeFingerprint ?? "Not reported")
                    }
                }

                if wizard.awaitingPostApplyValidation {
                    validationStatusBlock(
                        title: "Awaiting Post-Apply Proof",
                        state: .warning,
                        message: "BETR applied the committed profile and is waiting for validation on the restarted runtime. The next step is Validate."
                    )
                }

                HStack(spacing: 12) {
                    Button("Save Draft") { wizard.saveDraft() }
                    Button("Apply + Restart Now") { wizard.applyAndRestart() }
                    Button("Restore Last Applied") { wizard.restoreLastApplied() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 6: Validate

    private var validateStep: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                wizardSectionHeader(
                    "Validation",
                    subtitle: "Proves what the remote BETR host is actually doing: committed NIC, runtime NIC, route owner, discovery, source visibility."
                )

                HStack(spacing: 8) {
                    statusPill("CONFIG", state: wizard.validation.configState)
                    statusPill(wizard.validation.discoveryState.badgeLabel, state: wizard.validation.discoveryState.checkState)
                    statusPill(wizard.multicastLabel, state: wizard.validation.multicastRouteState.wizardState)
                    if wizard.validation.finderSourceCount > 0 {
                        statusPill("SOURCES \(wizard.validation.finderSourceCount)", state: .passed)
                    } else {
                        statusPill("SOURCES 0", state: .warning)
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        settingsValue("Route Owner", wizard.validation.multicastRouteOwner ?? "Unknown")
                        settingsValue("Finder Sources", "\(wizard.validation.finderSourceCount)")
                        settingsValue("SDK Version", wizard.validation.sdkVersion ?? "Unavailable")
                        settingsValue("Discovery State", wizard.validation.discoveryState.rawValue)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        settingsValue("Runtime Fingerprint", wizard.validation.runtimeFingerprint ?? "Not reported")
                        settingsValue("Expected Fingerprint", wizard.validation.expectedFingerprint ?? "Not waiting")
                        settingsValue("Sender Listener", wizard.validation.senderListenerConnected ? "Connected" : "Not connected")
                        settingsValue("Receiver Listener", wizard.validation.receiverListenerConnected ? "Connected" : "Not connected")
                    }
                }

                validationStatusBlock(
                    title: "Discovery Validation",
                    state: wizard.validation.discoveryState.checkState,
                    message: wizard.validation.discoveryState.summary
                )

                validationStatusBlock(
                    title: "Effective Multicast Route",
                    state: wizard.validation.multicastRouteState.wizardState,
                    message: "Route owner: \(wizard.validation.multicastRouteOwner ?? "unknown")"
                )

                HStack(spacing: 12) {
                    Button("Refresh Validation") { wizard.refreshValidation() }
                    Button("Run 10-Second Traffic Probe") { wizard.runBoundedTrafficProbe() }
                        .disabled(wizard.trafficProbeInProgress)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Reusable Components

    private func settingsHeader(_ title: String) -> some View {
        Text(title)
            .font(BrandTokens.display(size: 18, weight: .semibold))
            .foregroundStyle(BrandTokens.offWhite)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .background(BrandTokens.surfaceDark)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func settingsValue(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(BrandTokens.display(size: 12, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)
                .frame(width: 144, alignment: .leading)
            Text(value)
                .font(BrandTokens.mono(size: 11))
                .foregroundStyle(BrandTokens.warmGrey)
                .textSelection(.enabled)
        }
    }

    private func wizardSectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandTokens.display(size: 14, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)
            Text(subtitle)
                .font(BrandTokens.display(size: 11))
                .foregroundStyle(BrandTokens.warmGrey)
        }
    }

    private func statusPill(_ label: String, state: NDIWizardCheckState) -> some View {
        Text(label)
            .font(BrandTokens.mono(size: 9))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(statusColor(for: state))
            .clipShape(Capsule())
    }

    private func validationStatusBlock(title: String, state: NDIWizardCheckState, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(BrandTokens.display(size: 12, weight: .semibold))
                    .foregroundStyle(BrandTokens.offWhite)
                Spacer()
                statusPill(state.rawValue.uppercased(), state: state)
            }
            Text(message)
                .font(BrandTokens.display(size: 11))
                .foregroundStyle(BrandTokens.warmGrey)
        }
        .padding(10)
        .background(BrandTokens.charcoal)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusColor(for state: NDIWizardCheckState) -> Color {
        switch state {
        case .passed:  return .green
        case .warning: return .orange
        case .blocked: return .red
        }
    }
}
