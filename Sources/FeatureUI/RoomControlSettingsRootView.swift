import AppKit
import CoreNDIHost
import HostWizardDomain
import RoutingDomain
import RoomControlUIContracts
import SwiftUI

struct RoomControlSettingsRootView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RoomControlWorkspaceStore
    @ObservedObject var updateChecker: UpdateChecker
    @State private var discoveryServerEntryText: String = ""
    @State private var discoveryServerEntryError: String?

    private let wizardSteps: [NDIWizardPersistedStep] = [.interface, .discovery, .naming, .apply, .validation]

    var body: some View {
        VStack(spacing: 0) {
            settingsChrome
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                ndiTab
                    .tabItem { Label("NDI", systemImage: "network") }
                logsTab
                    .tabItem { Label("Logs", systemImage: "doc.text") }
                updateTab
                    .tabItem { Label("Update", systemImage: "arrow.down.circle") }
            }
        }
        .frame(minWidth: 980, minHeight: 780)
        .background(BrandTokens.dark)
        .preferredColorScheme(.dark)
        .onAppear {
            normalizeDiscoveryServerDraftIfPossible()
            store.refreshHostInterfaces()
            store.refreshHostValidation()
            updateChecker.checkForUpdate()
        }
        .onChange(of: store.hostDraft.showNetworkCIDR) { _, _ in
            store.refreshHostInterfaces()
        }
        .alert(item: $store.pendingRestartPromptContext) { context in
            Alert(
                title: Text("Restart BETR Room Control now?"),
                message: Text(restartPromptMessage(for: context)),
                primaryButton: .default(Text("Restart Now")) {
                    restartApplication()
                },
                secondaryButton: .cancel(Text("Later"))
            )
        }
    }

    private var settingsChrome: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(BrandTokens.display(size: 18, weight: .semibold))
                    .foregroundStyle(BrandTokens.offWhite)
                Text("Room settings, NDI setup, logs, and updates.")
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
            Spacer()
            if let lastErrorMessage = store.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.red)
                    .lineLimit(2)
                    .frame(maxWidth: 380, alignment: .trailing)
            }
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandTokens.gold)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(BrandTokens.toolbarDark)
        .overlay(alignment: .bottom) {
            Divider().background(BrandTokens.charcoal)
        }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("General")

                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        keyValueRow("App", RoomControlPublicRelease.appName)
                        keyValueRow("Bundle ID", RoomControlPublicRelease.bundleIdentifier)
                        keyValueRow("Release Feed", RoomControlPublicRelease.releaseRepository)
                        keyValueRow("Persistent Root", store.shellState?.rootDirectory ?? "Unavailable")
                        keyValueRow("Current Wizard Step", stepTitle(currentStep))
                        keyValueRow("Discovery", discoverySummaryMessage)
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        wizardSectionHeader(
                            "Current Runtime",
                            subtitle: "Keep the main operator settings surfaces visible without forcing the NDI wizard to carry every app-wide detail."
                        )

                        keyValueRow("Committed NIC", store.hostValidation.committedInterfaceBSDName ?? "Not applied yet")
                        keyValueRow("Runtime NIC", store.hostValidation.resolvedRuntimeInterfaceBSDName ?? "Not reported")
                        keyValueRow("Route Owner", store.hostValidation.multicastRouteOwnerBSDName ?? "Not reported")
                        keyValueRow("Discovery Server", store.hostValidation.activeDiscoveryServerURL ?? "mDNS only")

                        if let lastStatusMessage = store.lastStatusMessage {
                            Text(lastStatusMessage)
                                .font(BrandTokens.display(size: 11))
                                .foregroundStyle(BrandTokens.warmGrey)
                        }

                        if let lastErrorMessage = store.lastErrorMessage {
                            validationStatusBlock(
                                title: "Last Action",
                                state: .blocked,
                                message: lastErrorMessage
                            )
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var ndiTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear
                        .frame(height: 1)
                        .id("ndi-wizard-top")

                    settingsHeader("BETR NDI Setup Wizard")
                    wizardOverviewCard

                    HStack(alignment: .top, spacing: 18) {
                        wizardRail
                            .frame(width: 290)
                        wizardMainColumn
                    }
                }
                .padding(20)
            }
            .onChange(of: store.hostWizardProgressState.currentStep) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("ndi-wizard-top", anchor: .top)
                }
            }
        }
    }

    private var logsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("Logs")

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        wizardSectionHeader(
                            "Runtime Diagnostics",
                            subtitle: "Keep the same settings navigation shape operators expect while surfacing the startup and live-core details that matter during this bridge wave."
                        )

                        keyValueRow("Bootstrap", store.startupBlockerMessage ?? "Installed bundle accepted")
                        keyValueRow("Discovery State", store.hostValidation.discoveryDetailState.rawValue)
                        keyValueRow("Config Fingerprint", store.hostValidation.runtimeConfigFingerprint ?? "Not reported")
                        keyValueRow("Expected Fingerprint", store.hostValidation.expectedConfigFingerprint ?? "Not waiting")
                        keyValueRow("Finder Sources", "\(store.hostValidation.finderSourceVisibilityCount)")
                        keyValueRow("Listener Senders", "\(store.hostValidation.listenerSenderVisibilityCount)")
                        keyValueRow("Receive Connections", "\(store.hostValidation.totalReceiveConnectionCount)")
                        keyValueRow("Video Drops", "\(store.hostValidation.totalDroppedVideoFrames)")
                        keyValueRow("Worst Queue", "\(store.hostValidation.worstCurrentQueueDepth)")
                        keyValueRow("Latency", store.hostValidation.latencyBucketLabel)
                        keyValueRow("Core Agent Log", store.coreAgentLogPath)
                        keyValueRow("Network Helper Log", store.networkHelperLogPath)
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        wizardSectionHeader(
                            "Output Telemetry",
                            subtitle: "These counters come from the active program outputs and show sender connectivity, queue pressure, drift debt, and continuity trouble."
                        )

                        if store.hostValidation.outputTelemetry.isEmpty {
                            Text("No output telemetry is available from BETRCoreAgent yet.")
                                .font(BrandTokens.display(size: 11))
                                .foregroundStyle(BrandTokens.warmGrey)
                        } else {
                            ForEach(store.hostValidation.outputTelemetry) { telemetry in
                                telemetryCard(
                                    title: telemetry.id,
                                    rows: [
                                        ("Sender Connections", "\(telemetry.senderConnectionCount)"),
                                        ("Sender Ready", telemetry.senderReady ? "Yes" : "No"),
                                        ("Active Source", telemetry.activeSourceID ?? "None"),
                                        ("Preview Source", telemetry.previewSourceID ?? "None"),
                                        ("Fallback", telemetry.fallbackActive ? "Yes" : "No"),
                                        ("Video Queue", "\(telemetry.videoQueueDepth)"),
                                        ("Queue Age", telemetry.videoQueueAgeMs.map { String(format: "%.1f ms", $0) } ?? "n/a"),
                                        ("Audio Queue", telemetry.audioQueueDepthMs.map { String(format: "%.1f ms", $0) } ?? "n/a"),
                                        ("Audio Drift Debt", telemetry.audioDriftDebtSamples.map(String.init) ?? "n/a"),
                                        ("Sender Restarts", "\(telemetry.senderRestartCount)"),
                                        ("Video TS Discontinuity", "\(telemetry.videoTimestampDiscontinuityCount)"),
                                        ("Audio TS Discontinuity", "\(telemetry.audioTimestampDiscontinuityCount)")
                                    ]
                                )
                            }
                        }
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        wizardSectionHeader(
                            "Receive Telemetry",
                            subtitle: "These counters come from the live receiver sessions and the NDI SDK receive APIs instead of a synthetic heartbeat."
                        )

                        if store.hostValidation.receiverTelemetry.isEmpty {
                            Text("No receiver telemetry is available from BETRCoreAgent yet.")
                                .font(BrandTokens.display(size: 11))
                                .foregroundStyle(BrandTokens.warmGrey)
                        } else {
                            ForEach(store.hostValidation.receiverTelemetry) { telemetry in
                                telemetryCard(
                                    title: telemetry.sourceName,
                                    rows: [
                                        ("Connections", "\(telemetry.connectionCount)"),
                                        ("Video Queue", "\(telemetry.videoQueueDepth)"),
                                        ("Audio Queue", "\(telemetry.audioQueueDepth)"),
                                        ("Dropped Video", "\(telemetry.droppedVideoFrames)"),
                                        ("Dropped Audio", "\(telemetry.droppedAudioFrames)"),
                                        ("Video Pull Wait", telemetry.lastVideoPullDurationUs.map { "\($0) us" } ?? "n/a"),
                                        ("Audio Pull Wait", telemetry.lastAudioPullDurationUs.map { "\($0) us" } ?? "n/a"),
                                        ("Video Pull Interval", telemetry.lastVideoPullIntervalUs.map { "\($0) us" } ?? "n/a"),
                                        ("Audio Request", telemetry.lastAudioRequestedSampleCount.map(String.init) ?? "n/a"),
                                        ("Video Latency", telemetry.estimatedVideoLatencyMs.map { String(format: "%.1f ms", $0) } ?? "n/a"),
                                        ("Audio Latency", telemetry.estimatedAudioLatencyMs.map { String(format: "%.1f ms", $0) } ?? "n/a")
                                    ]
                                )
                            }
                        }
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        wizardSectionHeader(
                            "Discovery Server Status",
                            subtitle: "Show the exact server rows, listener attach state, and candidate addresses the helper is trying right now."
                        )

                        if store.hostValidation.discoveryServers.isEmpty {
                            Text("No discovery server rows are available from BETRCoreAgent yet.")
                                .font(BrandTokens.display(size: 11))
                                .foregroundStyle(BrandTokens.warmGrey)
                        } else {
                            ForEach(store.hostValidation.discoveryServers) { server in
                                discoveryServerCard(server)
                            }
                        }
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        wizardSectionHeader(
                            "Current Messages",
                            subtitle: "These are the current operator-facing startup and runtime messages from the live V4 path."
                        )

                        if let lastStatusMessage = store.lastStatusMessage {
                            validationStatusBlock(
                                title: "Status",
                                state: .passed,
                                message: lastStatusMessage
                            )
                        } else {
                            Text("No status messages have been recorded in this session yet.")
                                .font(BrandTokens.display(size: 11))
                                .foregroundStyle(BrandTokens.warmGrey)
                        }

                        if let lastErrorMessage = store.lastErrorMessage {
                            validationStatusBlock(
                                title: "Error",
                                state: .blocked,
                                message: lastErrorMessage
                            )
                        }
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        wizardSectionHeader(
                            "BETRCoreAgent Log Tail",
                            subtitle: "These are the latest helper-side startup and discovery lines captured from the installed LaunchAgent."
                        )
                        diagnosticLogBlock(store.coreAgentLogExcerpt)
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        wizardSectionHeader(
                            "Privileged Helper Log Tail",
                            subtitle: "Use this to confirm route pinning and restore activity when network control is involved."
                        )
                        diagnosticLogBlock(store.networkHelperLogExcerpt)
                    }
                }
            }
            .padding(20)
        }
    }

    private var updateTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("Update")
                releaseUpdateCard
            }
            .padding(20)
        }
    }

    private func telemetryCard(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(BrandTokens.display(size: 12, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)

            LazyVGrid(columns: [
                GridItem(.flexible(minimum: 180), spacing: 12, alignment: .leading),
                GridItem(.flexible(minimum: 180), spacing: 12, alignment: .leading)
            ], spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    keyValueRow(row.0, row.1)
                }
            }
        }
        .padding(12)
        .background(BrandTokens.cardBlack)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func settingsHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandTokens.display(size: 24, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)
            Text(headerSubtitle(for: title))
                .font(BrandTokens.display(size: 12))
                .foregroundStyle(BrandTokens.warmGrey)
        }
    }

    private var wizardOverviewCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                wizardSectionHeader(
                    "NDI Setup",
                    subtitle: "Choose the show NIC first, then discovery, apply, and validate before you trust live NDI."
                )

                HStack(spacing: 8) {
                    statePill(selectedInterfacePillLabel, state: selectedInterfacePillState)
                    statePill("DISCOVERY", state: store.hostValidation.discoveryState)
                    statePill("ROUTE", state: store.hostValidation.multicastRouteState)
                    statePill(store.hostDraft.ownershipMode == .betrOnly ? "BETR-ONLY" : "GLOBAL", state: store.hostDraft.ownershipMode == .betrOnly ? .passed : .warning)
                    statePill(store.hostValidation.overallReady ? "READY" : "CHECK", state: store.hostValidation.overallReady ? .passed : .warning)
                }

                Text(discoverySummaryMessage)
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.warmGrey)

                if let lastStatusMessage = store.lastStatusMessage {
                    Text(lastStatusMessage)
                        .font(BrandTokens.display(size: 11))
                        .foregroundStyle(BrandTokens.warmGrey)
                }

                if let lastErrorMessage = store.lastErrorMessage {
                    validationStatusBlock(
                        title: "Last NDI Action Failed",
                        state: .blocked,
                        message: lastErrorMessage
                    )
                }

                HStack(spacing: 12) {
                    Button("Use BETR Defaults") {
                        store.applyBETRRoomNDIDefaults()
                    }
                    Button("Start Over") {
                        store.startOverHostWizard()
                    }
                    Button("Refresh Validation") {
                        store.refreshHostValidation()
                        store.setHostWizardStep(.validation)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func headerSubtitle(for title: String) -> String {
        switch title {
        case "General":
            return "App-wide release, runtime, and room status details live here again instead of being buried inside the NDI wizard."
        case "BETR NDI Setup Wizard":
            return "Choose the show NIC, set discovery and multicast, apply, then validate."
        case "Logs":
            return "Startup and runtime diagnostics stay visible in their own settings section again so operators do not have to hunt through the NDI wizard for status."
        case "Update":
            return "Public identity and updater path stay aligned to the shipping Room Control line."
        default:
            return "BETR Room Control settings."
        }
    }

    private var wizardRail: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                wizardSectionHeader(
                    "Steps",
                    subtitle: "Work top to bottom. Apply, then validate."
                )

                ForEach(wizardSteps, id: \.rawValue) { step in
                    Button {
                        withAnimation {
                            store.setHostWizardStep(step)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(stepNumber(step))")
                                .font(BrandTokens.mono(size: 11))
                                .foregroundStyle(currentStep == step ? BrandTokens.offWhite : BrandTokens.warmGrey)
                                .frame(width: 24, height: 24)
                                .background(
                                    Capsule()
                                        .fill(currentStep == step ? BrandTokens.gold : BrandTokens.charcoal)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(stepTitle(step))
                                    .font(BrandTokens.display(size: 12, weight: .semibold))
                                    .foregroundStyle(BrandTokens.offWhite)
                                Text(stepSubtitle(step))
                                    .font(BrandTokens.display(size: 10))
                                    .foregroundStyle(BrandTokens.warmGrey)
                            }

                            Spacer(minLength: 8)
                            statePill(stepPillLabel(step), state: stepState(step))
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(currentStep == step ? BrandTokens.charcoal : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var wizardMainColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                HStack {
                    wizardSectionHeader(
                        "Step \(stepNumber(currentStep)) of \(wizardSteps.count) · \(stepTitle(currentStep))",
                        subtitle: stepDescription(currentStep)
                    )
                    Spacer()
                    statePill(stepPillLabel(currentStep), state: stepState(currentStep))
                }
            }

            stepContent(currentStep)

            settingsCard {
                HStack {
                    Button("Back") {
                        guard let previousStep else { return }
                        withAnimation {
                            store.setHostWizardStep(previousStep)
                        }
                    }
                    .disabled(previousStep == nil)

                    Spacer()

                    Button(nextStep == nil ? "Done" : "Next") {
                        guard let nextStep else {
                            dismiss()
                            return
                        }
                        withAnimation {
                            store.setHostWizardStep(nextStep)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandTokens.gold)
            }
        }
    }

    private var releaseUpdateCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                wizardSectionHeader(
                    "Release + Update",
                    subtitle: "Public identity and updater path stay aligned to the shipping Room Control line. Date-based versions are encoded as 0.x.x.x inside the bundle and release tag."
                )

                keyValueRow("App", RoomControlPublicRelease.appName)
                keyValueRow("Bundle ID", RoomControlPublicRelease.bundleIdentifier)
                keyValueRow("Release Feed", RoomControlPublicRelease.releaseRepository)
                keyValueRow("Current", updateChecker.currentVersion)
                keyValueRow("Build", updateChecker.buildVersion)
                keyValueRow("Latest", updateChecker.latestVersion ?? "Unknown")

                if let lastCheckTime = updateChecker.lastCheckTime {
                    keyValueRow("Last Check", lastCheckTime.formatted(date: .abbreviated, time: .shortened))
                }

                HStack(spacing: 8) {
                    statePill(updateChecker.updateAvailable ? "UPDATE READY" : "CURRENT", state: updateChecker.updateAvailable ? .warning : .passed)
                    statePill(updateChecker.downloadPhaseText.uppercased(), state: updateChecker.downloadPhase == .failed ? .blocked : .warning)
                }

                if let checkError = updateChecker.checkError, !checkError.isEmpty {
                    validationStatusBlock(
                        title: "Release Feed Check",
                        state: .warning,
                        message: checkError
                    )
                }

                if let downloadError = updateChecker.downloadError, !downloadError.isEmpty {
                    validationStatusBlock(
                        title: "Updater Download",
                        state: .blocked,
                        message: downloadError
                    )
                }

                if let detail = updateChecker.downloadDetailText, !detail.isEmpty {
                    Text(detail)
                        .font(BrandTokens.mono(size: 11))
                        .foregroundStyle(BrandTokens.warmGrey)
                }

                HStack(spacing: 12) {
                    Button("Check for Update") {
                        updateChecker.checkForUpdate()
                    }
                    Button("Download") {
                        updateChecker.downloadUpdate()
                    }
                    .disabled(!updateChecker.updateAvailable || updateChecker.isDownloading)
                    Button("Install") {
                        updateChecker.installUpdate()
                    }
                    .disabled(!updateChecker.readyToInstall || updateChecker.isInstalling)
                    Button("Open Release Page") {
                        updateChecker.openDownloadPage()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func stepContent(_ step: NDIWizardPersistedStep) -> some View {
        switch step {
        case .interface:
            interfaceStep
        case .discovery:
            discoveryStep
        case .naming:
            sourceFilterStep
        case .apply:
            applyStep
        case .validation:
            validationStep
        default:
            interfaceStep
        }
    }

    private var interfaceStep: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                wizardSectionHeader(
                    "Select The Show NIC",
                    subtitle: "Choose the NIC that should carry NDI discovery and multicast for this room."
                )

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Show Network")
                            .font(BrandTokens.display(size: 11, weight: .medium))
                            .foregroundStyle(BrandTokens.warmGrey)
                        TextField("", text: $store.hostDraft.showNetworkCIDR)
                            .textFieldStyle(.roundedBorder)
                            .font(BrandTokens.mono(size: 12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Show NIC")
                            .font(BrandTokens.display(size: 11, weight: .medium))
                            .foregroundStyle(BrandTokens.warmGrey)
                        Picker("Show NIC", selection: $store.hostDraft.selectedInterfaceID) {
                            ForEach(store.hostInterfaceSummaries) { summary in
                                Text(summary.stableDropdownLabel).tag(summary.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                HStack(spacing: 12) {
                    Button("Refresh Interfaces") {
                        store.refreshHostInterfaceInventory()
                    }
                    .buttonStyle(.bordered)

                    Text(
                        store.hostInterfaceSummaries.isEmpty
                            ? "No usable interfaces found on this Mac."
                            : "\(store.hostInterfaceSummaries.count) interface\(store.hostInterfaceSummaries.count == 1 ? "" : "s") found on this Mac."
                    )
                    .font(BrandTokens.display(size: 10))
                    .foregroundStyle(BrandTokens.warmGrey)
                }

                if store.hostInterfaceSummaries.isEmpty {
                    validationStatusBlock(
                        title: "No Interfaces Found",
                        state: .blocked,
                        message: "BETR could not enumerate eligible network interfaces on this Mac."
                    )
                } else {
                    selectedInterfaceSummaryCard
                }
            }
        }
    }

    @ViewBuilder
    private var selectedInterfaceSummaryCard: some View {
        if let selectedInterfaceSummary {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected NIC")
                            .font(BrandTokens.display(size: 11, weight: .medium))
                            .foregroundStyle(BrandTokens.warmGrey)
                        Text(selectedInterfaceSummary.hardwarePortLabel)
                            .font(BrandTokens.display(size: 14, weight: .semibold))
                            .foregroundStyle(BrandTokens.offWhite)
                        Text(selectedInterfaceSummary.stableDropdownLabel)
                            .font(BrandTokens.mono(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if selectedInterfaceSummary.matchesShowNetwork {
                            statePill("SHOW", state: .passed)
                        }
                        statePill(
                            selectedInterfaceSummary.supportsMulticast ? "MCAST" : "NO MCAST",
                            state: selectedInterfaceSummary.supportsMulticast ? .passed : .warning
                        )
                        statePill(
                            selectedInterfaceIsLive ? "LIVE" : "DRAFT",
                            state: selectedInterfaceIsLive ? .passed : .warning
                        )
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        keyValueRow("BSD Name", selectedInterfaceSummary.bsdName)
                        keyValueRow("Address", selectedInterfaceSummary.primaryIPv4CIDR ?? "No IPv4")
                        keyValueRow("Service", selectedInterfaceSummary.serviceSummary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        keyValueRow("Committed NIC", store.hostValidation.committedInterfaceBSDName ?? "Not applied yet")
                        keyValueRow("Runtime NIC", store.hostValidation.resolvedRuntimeInterfaceBSDName ?? "Not reported")
                        keyValueRow("Route Owner", store.hostValidation.multicastRouteOwnerBSDName ?? "Not reported")
                    }
                }

                Text(selectedInterfaceSummary.matchesShowNetwork
                    ? "This NIC matches the show network and is ready for Apply + Restart."
                    : "This NIC does not match the show network field above. Double-check the CIDR before you apply."
                )
                .font(BrandTokens.display(size: 10))
                .foregroundStyle(selectedInterfaceSummary.matchesShowNetwork ? BrandTokens.warmGrey : .orange)
            }
            .padding(12)
            .background(BrandTokens.cardBlack)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            validationStatusBlock(
                title: "Select A Show NIC",
                state: .blocked,
                message: "Choose the NIC that should carry NDI discovery and multicast before you move on."
            )
        }
    }

    private var discoveryStep: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                wizardSectionHeader(
                    "Discovery Server And Multicast",
                    subtitle: "Use the same dual-discovery path as before: NDI-FIND plus Discovery Server listener telemetry, pinned to the chosen NIC."
                )

                Toggle("Enable mDNS", isOn: $store.hostDraft.mdnsEnabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Discovery Servers")
                        .font(BrandTokens.display(size: 11, weight: .medium))
                        .foregroundStyle(BrandTokens.warmGrey)
                    discoveryServerComposer
                    Text("Press Enter to lock each server. Paste comma- or newline-separated lists when you need to add more than one.")
                        .font(BrandTokens.display(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                }

                Toggle("Enable Multicast", isOn: $store.hostDraft.multicastEnabled)
                    .toggleStyle(.switch)

                HStack(spacing: 12) {
                    Toggle("Receive", isOn: $store.hostDraft.multicastReceiveEnabled)
                    Toggle("Transmit", isOn: $store.hostDraft.multicastTransmitEnabled)
                }
                .toggleStyle(.switch)

                HStack(spacing: 12) {
                    LabeledField(label: "Prefix", text: $store.hostDraft.multicastPrefix)
                    LabeledField(label: "Netmask", text: $store.hostDraft.multicastNetmask)
                }

                Stepper("TTL \(store.hostDraft.multicastTTL)", value: $store.hostDraft.multicastTTL, in: 1...255)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Receive Subnets")
                        .font(BrandTokens.display(size: 11, weight: .medium))
                        .foregroundStyle(BrandTokens.warmGrey)
                    TextField("Leave blank for same-VLAN multicast", text: $store.hostDraft.receiveSubnetsText, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .font(BrandTokens.mono(size: 12))
                    Text("Only set receive subnets when the network team intentionally routed multicast between subnets.")
                        .font(BrandTokens.display(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                }

                validationStatusBlock(
                    title: "Discovery",
                    state: store.hostValidation.discoveryState,
                    message: discoverySummaryMessage,
                    nextAction: discoveryNextAction
                )

                validationStatusBlock(
                    title: "Multicast Route",
                    state: store.hostValidation.multicastRouteState,
                    message: store.hostValidation.multicastRouteSummary,
                    nextAction: store.hostValidation.multicastRouteNextAction
                )
            }
        }
    }

    private var sourceFilterStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                wizardSectionHeader(
                    "Source Filter And Naming",
                    subtitle: "Keep source filter and naming explicit so the source list stays easy to trust."
                )

                    LabeledField(label: "Node Label", text: $store.hostDraft.nodeLabel)
                    LabeledField(label: "Source Filter", text: $store.hostDraft.sourceFilter)
                    LabeledField(label: "Groups", text: $store.hostDraft.groupsText)

                    HStack(spacing: 12) {
                        LabeledField(label: "Sender Prefix", text: $store.hostDraft.senderPrefix)
                        LabeledField(label: "Output Prefix", text: $store.hostDraft.outputPrefix)
                    }

                    validationStatusBlock(
                        title: "Source Catalog",
                        state: store.hostValidation.discoveryState,
                        message: store.hostValidation.sourceCatalogSummary,
                        nextAction: "Confirm the merged finder and listener catalog looks right before you take a live source."
                    )
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                wizardSectionHeader(
                    "Advanced",
                    subtitle: "Keep uncommon controls available without turning the main flow into a wall of options."
                )

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ownership")
                                .font(BrandTokens.display(size: 11, weight: .medium))
                                .foregroundStyle(BrandTokens.warmGrey)
                            Picker("Ownership", selection: $store.hostDraft.ownershipMode) {
                                Text("BETR Only").tag(BETRNDIHostOwnershipMode.betrOnly)
                                Text("Global Takeover").tag(BETRNDIHostOwnershipMode.globalTakeover)
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Extra IPs")
                            .font(BrandTokens.display(size: 11, weight: .medium))
                            .foregroundStyle(BrandTokens.warmGrey)
                        TextField("Optional manual IP hints", text: $store.hostDraft.extraIPsText, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                            .font(BrandTokens.mono(size: 12))
                    }

                    Text(store.hostDraft.ownershipMode == .betrOnly
                        ? "BETR-only keeps BETR in charge of apply and reset while mirroring the committed profile into the shared NDI path so discovery behaves like the older approach."
                        : "Global takeover keeps the same shared NDI path, but should be used only when you intentionally want BETR to own the full Mac NDI runtime for adjacent tooling.")
                        .font(BrandTokens.display(size: 11))
                        .foregroundStyle(store.hostDraft.ownershipMode == .betrOnly ? BrandTokens.warmGrey : .orange)
                }
            }
        }
    }

    private var applyStep: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                wizardSectionHeader(
                    "Apply And Restart",
                    subtitle: "Write the BETR-owned NDI config, restart cleanly, then validate fingerprints and route ownership."
                )

                keyValueRow("Committed NIC", store.hostValidation.committedInterfaceBSDName ?? selectedInterfaceSummary?.bsdName ?? "Not applied yet")
                keyValueRow("Discovery Server", store.hostDraft.discoveryServersText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mDNS only" : store.hostDraft.discoveryServersText.replacingOccurrences(of: "\n", with: ", "))
                keyValueRow("Filter", store.hostDraft.sourceFilter.nilIfEmpty ?? "None")
                keyValueRow("Node Label", store.hostDraft.nodeLabel.nilIfEmpty ?? "BETR Room Control")
                keyValueRow("Expected Fingerprint", store.hostValidation.expectedConfigFingerprint ?? "Pending apply")

                validationStatusBlock(
                    title: "Network Safety",
                    state: .passed,
                    message: "Apply + Restart now persists only the selected BETR NIC, discovery configuration, and multicast route ownership. It does not disable Wi-Fi or internet-facing services."
                )

                HStack(spacing: 12) {
                    Button("Use BETR Defaults") {
                        store.applyBETRRoomNDIDefaults()
                    }
                    Button("Apply + Restart Now") {
                        store.applyHostSettings()
                    }
                    .tint(BrandTokens.gold)
                    Button("Start Over") {
                        store.startOverHostWizard()
                    }
                }
                .buttonStyle(.borderedProminent)

                validationStatusBlock(
                    title: "Runtime Config",
                    state: store.hostValidation.configState,
                    message: store.hostValidation.configSummary
                )
            }
        }
    }

    private var validationStep: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                wizardSectionHeader(
                    "Validate Runtime Truth",
                    subtitle: "Confirm fingerprints, route owner, listener state, and source visibility before you trust live NDI."
                )

                validationStatusBlock(
                    title: "Discovery",
                    state: store.hostValidation.discoveryState,
                    message: discoverySummaryMessage,
                    nextAction: discoveryNextAction
                )

                validationStatusBlock(
                    title: "Runtime Config",
                    state: store.hostValidation.configState,
                    message: store.hostValidation.configSummary
                )

                validationStatusBlock(
                    title: "Remote Host Proof",
                    state: store.hostValidation.remoteHostProofReady ? .passed : .warning,
                    message: store.hostValidation.remoteHostProofSummary
                )

                validationStatusBlock(
                    title: "Source Catalog",
                    state: store.hostValidation.discoveryState,
                    message: store.hostValidation.sourceCatalogSummary
                )

                if let trafficProbe = store.hostValidation.trafficProbe {
                    validationStatusBlock(
                        title: "Traffic Probe",
                        state: trafficProbe.checkState,
                        message: trafficProbe.summary,
                        nextAction: trafficProbe.nextAction
                    )
                }

                HStack(spacing: 12) {
                    Button("Refresh Validation") {
                        store.refreshHostValidation()
                    }
                    Button("Back To Discovery") {
                        store.setHostWizardStep(.discovery)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var discoveryPresentationEntries: [DiscoveryServerPresentationEntry] {
        DiscoveryServerPresentationBuilder.entries(
            configuredText: store.hostDraft.discoveryServersText,
            runtimeRows: store.hostValidation.discoveryServers
        )
    }

    private var sortedDiscoveryPresentationEntries: [DiscoveryServerPresentationEntry] {
        DiscoveryServerPresentationBuilder.sortedForPopover(discoveryPresentationEntries)
    }

    private var discoveryAggregateStatus: DiscoveryAggregateStatus {
        DiscoveryServerPresentationBuilder.aggregate(
            configuredText: store.hostDraft.discoveryServersText,
            runtimeRows: store.hostValidation.discoveryServers,
            mdnsEnabled: store.hostDraft.mdnsEnabled
        )
    }

    private var discoverySummaryMessage: String {
        if discoveryAggregateStatus.usesMDNSOnly {
            return "mDNS-only discovery is active. Add a Discovery Server only when the room network requires it."
        }
        if discoveryAggregateStatus.totalCount > 1,
           discoveryAggregateStatus.healthyCount > 0,
           discoveryAggregateStatus.healthyCount < discoveryAggregateStatus.totalCount {
            return "Discovery is usable through \(discoveryAggregateStatus.healthyCount) of \(discoveryAggregateStatus.totalCount) configured servers, but one or more still need attention."
        }
        if discoveryAggregateStatus.totalCount > 0,
           discoveryAggregateStatus.healthyCount == 0,
           store.hostValidation.discoveryDetailState != .noDiscoveryConfigured {
            return "No configured Discovery Server is healthy yet. Check the server rows below for the exact endpoint that is failing."
        }
        return store.hostValidation.discoverySummary
    }

    private var discoveryNextAction: String {
        if discoveryAggregateStatus.usesMDNSOnly {
            return "If the room depends on a Discovery Server, add it here and apply the BETR profile again."
        }
        if discoveryAggregateStatus.totalCount > 1,
           discoveryAggregateStatus.healthyCount > 0,
           discoveryAggregateStatus.healthyCount < discoveryAggregateStatus.totalCount {
            return "Discovery is up through at least one server. Keep working, but fix the degraded server row before you trust redundancy."
        }
        if discoveryAggregateStatus.totalCount > 0,
           discoveryAggregateStatus.healthyCount == 0,
           store.hostValidation.runtimeConfigMatchesCommittedProfile,
           store.hostValidation.multicastRoutePinnedToCommittedInterface {
            return "The BETR host profile is already in place. Stay focused on Discovery Server reachability and listener connection state instead of applying again."
        }
        return store.hostValidation.discoveryNextAction
    }

    private var discoveryServerComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiscoveryTokenFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(discoveryPresentationEntries) { entry in
                    discoveryTokenChip(entry)
                }

                DiscoveryServerEntryField(
                    text: $discoveryServerEntryText,
                    placeholder: "Add Discovery Server",
                    onSubmit: commitDiscoveryServerEntry,
                    onDeleteBackwardWhenEmpty: removeLastDiscoveryServer,
                    onPasteText: commitDiscoveryServerEntry
                )
                .frame(minWidth: 220, maxWidth: 280)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(BrandTokens.panelDark)
                .clipShape(Capsule())
            }

            if let discoveryServerEntryError {
                Text(discoveryServerEntryError)
                    .font(BrandTokens.display(size: 10))
                    .foregroundStyle(BrandTokens.red)
            }
        }
        .padding(10)
        .background(BrandTokens.cardBlack)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(BrandTokens.charcoal, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var currentStep: NDIWizardPersistedStep {
        wizardSteps.contains(store.hostWizardProgressState.currentStep) ? store.hostWizardProgressState.currentStep : .interface
    }

    private var previousStep: NDIWizardPersistedStep? {
        guard let index = wizardSteps.firstIndex(of: currentStep), index > 0 else { return nil }
        return wizardSteps[index - 1]
    }

    private var nextStep: NDIWizardPersistedStep? {
        guard let index = wizardSteps.firstIndex(of: currentStep), index < wizardSteps.count - 1 else { return nil }
        return wizardSteps[index + 1]
    }

    private var selectedInterfaceSummary: HostInterfaceSummary? {
        store.hostInterfaceSummaries.first(where: { $0.id == store.hostDraft.selectedInterfaceID })
    }

    private var selectedInterfacePillLabel: String {
        if let selectedInterfaceSummary {
            return selectedInterfaceSummary.matchesShowNetwork ? "SHOW NIC" : "NIC"
        }
        return "NO NIC"
    }

    private var selectedInterfacePillState: NDIWizardCheckState {
        guard let selectedInterfaceSummary else { return .blocked }
        return selectedInterfaceSummary.matchesShowNetwork ? .passed : .warning
    }

    private func stepNumber(_ step: NDIWizardPersistedStep) -> Int {
        (wizardSteps.firstIndex(of: step) ?? 0) + 1
    }

    private func stepTitle(_ step: NDIWizardPersistedStep) -> String {
        switch step {
        case .interface:
            return "Select NIC"
        case .discovery:
            return "Discovery + Multicast"
        case .naming:
            return "Naming + Advanced"
        case .apply:
            return "Apply + Restart"
        case .validation:
            return "Validate"
        default:
            return "Wizard"
        }
    }

    private func stepSubtitle(_ step: NDIWizardPersistedStep) -> String {
        switch step {
        case .interface:
            return "Commit the room-side show NIC."
        case .discovery:
            return "Set Discovery Server and multicast truth."
        case .naming:
            return "Naming, filters, and uncommon controls."
        case .apply:
            return "Write config and restart BETR."
        case .validation:
            return "Confirm fingerprints and route truth."
        default:
            return "Wizard step."
        }
    }

    private func stepDescription(_ step: NDIWizardPersistedStep) -> String {
        switch step {
        case .interface:
            return "Choose the NIC that should carry room-side NDI."
        case .discovery:
            return "Set discovery and multicast for the chosen NIC."
        case .naming:
            return "Set naming, source filters, and uncommon controls."
        case .apply:
            return "Apply the safe host profile and restart BETR cleanly."
        case .validation:
            return "Validate discovery, config, fingerprints, and route ownership."
        default:
            return "Wizard step."
        }
    }

    private func normalizeDiscoveryServerDraftIfPossible() {
        let currentText = store.hostDraft.discoveryServersText
        guard DiscoveryServerDraftCodec.canSafelyNormalize(currentText) else { return }
        let normalizedText = DiscoveryServerDraftCodec.normalizedText(from: currentText)
        guard normalizedText != currentText else { return }
        store.hostDraft.discoveryServersText = normalizedText
    }

    private func commitDiscoveryServerEntry(_ rawInput: String? = nil) {
        let input = (rawInput ?? discoveryServerEntryText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.isEmpty == false else { return }

        do {
            store.hostDraft.discoveryServersText = try DiscoveryServerDraftCodec.merge(
                rawInput: input,
                into: store.hostDraft.discoveryServersText
            )
            discoveryServerEntryText = ""
            discoveryServerEntryError = nil
        } catch let error as DiscoveryServerDraftError {
            discoveryServerEntryError = error.errorDescription
        } catch {
            discoveryServerEntryError = "BETR could not parse that Discovery Server entry."
        }
    }

    private func removeDiscoveryServer(_ normalizedEndpoint: String) {
        store.hostDraft.discoveryServersText = DiscoveryServerDraftCodec.remove(
            normalizedEndpoint: normalizedEndpoint,
            from: store.hostDraft.discoveryServersText
        )
        discoveryServerEntryError = nil
    }

    private func removeLastDiscoveryServer() {
        guard let lastEntry = DiscoveryServerDraftCodec.normalizedEntries(from: store.hostDraft.discoveryServersText).last else {
            return
        }
        removeDiscoveryServer(lastEntry.normalizedEndpoint)
    }

    private var selectedInterfaceIsLive: Bool {
        guard let selectedInterfaceSummary else { return false }
        return store.hostValidation.committedInterfaceBSDName == selectedInterfaceSummary.bsdName
            || store.hostValidation.resolvedRuntimeInterfaceBSDName == selectedInterfaceSummary.bsdName
            || store.hostValidation.multicastRouteOwnerBSDName == selectedInterfaceSummary.bsdName
    }

    private func stepState(_ step: NDIWizardPersistedStep) -> NDIWizardCheckState {
        switch step {
        case .interface:
            return selectedInterfacePillState
        case .discovery:
            return combinedState(store.hostValidation.discoveryState, store.hostValidation.multicastRouteState)
        case .naming:
            return .passed
        case .apply:
            return store.hostValidation.configState
        case .validation:
            return store.hostValidation.overallReady ? .passed : .warning
        default:
            return .warning
        }
    }

    private func stepPillLabel(_ step: NDIWizardPersistedStep) -> String {
        if step == .apply, stepState(step) == .passed {
            return "APPLIED"
        }
        switch stepState(step) {
        case .passed:
            return "READY"
        case .warning:
            return "CHECK"
        case .blocked:
            return "BLOCK"
        }
    }

    private func combinedState(_ lhs: NDIWizardCheckState, _ rhs: NDIWizardCheckState) -> NDIWizardCheckState {
        if lhs == .blocked || rhs == .blocked {
            return .blocked
        }
        if lhs == .warning || rhs == .warning {
            return .warning
        }
        return .passed
    }

    private func restartPromptMessage(for context: RoomControlWorkspaceStore.RestartPromptContext) -> String {
        switch context {
        case .startOver:
            return "Start Over restored normal macOS networking and cleared BETR's saved network ownership. Restart now to reload BETR cleanly."
        case .apply:
            return "BETR wrote the committed NDI profile, discovery settings, and multicast ownership plan. Restart now so runtime validation reflects the reloaded BETR path."
        @unknown default:
            return "Restart now to apply the pending BETR changes."
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .background(BrandTokens.panelDark)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func wizardSectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(BrandTokens.display(size: 14, weight: .semibold))
                .foregroundStyle(BrandTokens.gold)
            Text(subtitle)
                .font(BrandTokens.display(size: 11))
                .foregroundStyle(BrandTokens.warmGrey)
        }
    }

    private func statePill(_ label: String, state: NDIWizardCheckState) -> some View {
        let tint: Color
        switch state {
        case .passed:
            tint = BrandTokens.timerGreen
        case .warning:
            tint = BrandTokens.timerYellow
        case .blocked:
            tint = BrandTokens.red
        }

        return Text(label)
            .font(BrandTokens.mono(size: 10))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func validationStatusBlock(
        title: String,
        state: NDIWizardCheckState,
        message: String,
        nextAction: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(BrandTokens.display(size: 12, weight: .semibold))
                    .foregroundStyle(BrandTokens.offWhite)
                Spacer()
                statePill(titleForState(state), state: state)
            }
            Text(message)
                .font(BrandTokens.display(size: 11))
                .foregroundStyle(BrandTokens.warmGrey)
            if let nextAction, nextAction.isEmpty == false {
                Text(nextAction)
                    .font(BrandTokens.display(size: 10))
                    .foregroundStyle(BrandTokens.offWhite.opacity(0.82))
            }
        }
        .padding(12)
        .background(BrandTokens.cardBlack)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func keyValueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(BrandTokens.display(size: 11, weight: .medium))
                .foregroundStyle(BrandTokens.warmGrey)
                .frame(width: 148, alignment: .leading)
            Text(value)
                .font(BrandTokens.mono(size: 11))
                .foregroundStyle(BrandTokens.offWhite)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func discoveryTokenChip(_ entry: DiscoveryServerPresentationEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(discoveryTint(for: entry.visualState))
                .frame(width: 8, height: 8)
            Text(entry.label)
                .font(BrandTokens.mono(size: 11))
                .foregroundStyle(BrandTokens.offWhite)
            Button {
                removeDiscoveryServer(entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(discoveryTint(for: entry.visualState).opacity(0.14))
        .overlay(
            Capsule()
                .stroke(discoveryTint(for: entry.visualState), lineWidth: 1)
        )
        .clipShape(Capsule())
    }

    private func discoveryServerCard(_ server: NDIWizardDiscoveryServerRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(discoveryTint(for: server.discoveryVisualState))
                    .frame(width: 10, height: 10)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.normalizedEndpoint)
                        .font(BrandTokens.display(size: 12, weight: .semibold))
                        .foregroundStyle(BrandTokens.offWhite)
                    Text(server.discoveryDetailText)
                        .font(BrandTokens.display(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                }
                Spacer()
                statePill(server.discoveryStatusWord, state: discoveryCheckState(for: server.discoveryVisualState))
            }

            HStack(spacing: 8) {
                statePill(server.tcpReachable ? "TCP" : "NO TCP", state: server.tcpReachable ? .passed : .blocked)
                statePill(senderPillLabel(for: server), state: senderPillState(for: server))
                statePill(receiverPillLabel(for: server), state: receiverPillState(for: server))
            }

            keyValueRow("Configured", server.configuredURL)
            keyValueRow("Validated", server.validatedAddress ?? "Not validated")
            keyValueRow("Lifecycle", server.discoveryLifecycleLabel)
            keyValueRow("Degraded", server.degradedReason?.replacingOccurrences(of: "_", with: " ") ?? "None")

            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    keyValueRow("Host", "\(server.host):\(server.port)")
                    keyValueRow("Sender Create Fn", server.senderCreateFunctionAvailable ? "available" : "missing")
                    keyValueRow("Receiver Create Fn", server.receiverCreateFunctionAvailable ? "available" : "missing")
                    keyValueRow("Sender Attempts", "\(server.senderAttachAttemptCount)")
                    keyValueRow("Receiver Attempts", "\(server.receiverAttachAttemptCount)")
                    keyValueRow("Sender Last", server.senderLastAttemptedAddress ?? "Not attempted")
                    keyValueRow("Receiver Last", server.receiverLastAttemptedAddress ?? "Not attempted")
                    keyValueRow("Sender Failure", server.senderAttachFailureReason ?? "None")
                    keyValueRow("Receiver Failure", server.receiverAttachFailureReason ?? "None")
                    keyValueRow(
                        "Sender Candidates",
                        server.senderCandidateAddresses.isEmpty ? "None" : server.senderCandidateAddresses.joined(separator: ", ")
                    )
                    keyValueRow(
                        "Receiver Candidates",
                        server.receiverCandidateAddresses.isEmpty ? "None" : server.receiverCandidateAddresses.joined(separator: ", ")
                    )
                }
                .padding(.top, 6)
            }
            .font(BrandTokens.display(size: 11, weight: .medium))
            .foregroundStyle(BrandTokens.offWhite)
        }
        .padding(12)
        .background(BrandTokens.cardBlack)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func discoveryCheckState(for visualState: DiscoveryServerVisualState) -> NDIWizardCheckState {
        switch visualState {
        case .connected:
            return .passed
        case .warning, .draftOnly:
            return .warning
        case .error:
            return .blocked
        }
    }

    private func senderPillLabel(for server: NDIWizardDiscoveryServerRow) -> String {
        if server.senderListenerConnected {
            return "SEND LIVE"
        }
        if server.senderListenerAttached {
            return "SEND WAIT"
        }
        return "SEND OFF"
    }

    private func senderPillState(for server: NDIWizardDiscoveryServerRow) -> NDIWizardCheckState {
        if server.senderListenerConnected {
            return .passed
        }
        if server.senderListenerAttached {
            return .warning
        }
        return .blocked
    }

    private func receiverPillLabel(for server: NDIWizardDiscoveryServerRow) -> String {
        if server.receiverListenerConnected {
            return "RECV LIVE"
        }
        if server.receiverListenerAttached {
            return "RECV WAIT"
        }
        return "RECV OFF"
    }

    private func receiverPillState(for server: NDIWizardDiscoveryServerRow) -> NDIWizardCheckState {
        if server.receiverListenerConnected {
            return .passed
        }
        if server.receiverListenerAttached {
            return .warning
        }
        return .blocked
    }

    private func discoveryTint(for visualState: DiscoveryServerVisualState) -> Color {
        switch visualState {
        case .draftOnly:
            return BrandTokens.charcoal
        case .connected:
            return BrandTokens.timerGreen
        case .warning:
            return BrandTokens.timerYellow
        case .error:
            return BrandTokens.red
        }
    }

    private func diagnosticLogBlock(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(BrandTokens.mono(size: 11))
                .foregroundStyle(BrandTokens.offWhite)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minHeight: 180, maxHeight: 260)
        .background(BrandTokens.cardBlack)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func titleForState(_ state: NDIWizardCheckState) -> String {
        switch state {
        case .passed:
            return "PASS"
        case .warning:
            return "CHECK"
        case .blocked:
            return "BLOCK"
        }
    }

    private func restartApplication() {
        store.dismissPendingRestartPrompt()
        Task { @MainActor in
            await store.prepareForCoreAgentRestart()
            do {
                try ApplicationRelauncher.relaunchAfterCurrentProcessExits()
                ApplicationRelauncher.requestApplicationTerminationForRelaunch()
            } catch {
                store.lastErrorMessage = "Restarting BETR Room Control failed. \(error.localizedDescription)"
            }
        }
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(BrandTokens.display(size: 11, weight: .medium))
                .foregroundStyle(BrandTokens.warmGrey)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(BrandTokens.mono(size: 12))
        }
    }
}

private struct DiscoveryTokenFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = arrangedRows(in: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews)
        let height = rows.last.map { $0.maxY } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangedRows(in: bounds.width, subviews: subviews)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                    proposal: ProposedViewSize(item.frame.size)
                )
            }
        }
    }

    private func arrangedRows(in availableWidth: CGFloat, subviews: Subviews) -> [DiscoveryTokenRow] {
        var rows: [DiscoveryTokenRow] = []
        var currentItems: [DiscoveryTokenRowItem] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = currentItems.isEmpty ? size.width : currentX + horizontalSpacing + size.width
            if currentItems.isEmpty == false, proposedWidth > availableWidth {
                rows.append(
                    DiscoveryTokenRow(
                        items: currentItems,
                        width: currentX,
                        maxY: currentY + rowHeight
                    )
                )
                currentY += rowHeight + verticalSpacing
                currentItems = []
                currentX = 0
                rowHeight = 0
            }

            let originX = currentItems.isEmpty ? 0 : currentX + horizontalSpacing
            let frame = CGRect(origin: CGPoint(x: originX, y: currentY), size: size)
            currentItems.append(DiscoveryTokenRowItem(index: index, frame: frame))
            currentX = frame.maxX
            rowHeight = max(rowHeight, size.height)
        }

        if currentItems.isEmpty == false {
            rows.append(
                DiscoveryTokenRow(
                    items: currentItems,
                    width: currentX,
                    maxY: currentY + rowHeight
                )
            )
        }

        return rows
    }
}

private struct DiscoveryTokenRow {
    let items: [DiscoveryTokenRowItem]
    let width: CGFloat
    let maxY: CGFloat
}

private struct DiscoveryTokenRowItem {
    let index: Int
    let frame: CGRect
}

private struct DiscoveryServerEntryField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: (String?) -> Void
    let onDeleteBackwardWhenEmpty: () -> Void
    let onPasteText: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> DiscoveryServerTokenTextField {
        let field = DiscoveryServerTokenTextField()
        field.delegate = context.coordinator
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = NSColor(BrandTokens.offWhite)
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = placeholder
        field.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty
        return field
    }

    func updateNSView(_ nsView: DiscoveryServerTokenTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        nsView.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DiscoveryServerEntryField

        init(parent: DiscoveryServerEntryField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            if field.stringValue.contains(",") || field.stringValue.contains("\n") {
                parent.onPasteText(field.stringValue)
                field.stringValue = ""
                parent.text = ""
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = control.stringValue
                parent.onSubmit(control.stringValue)
                return true
            }
            return false
        }
    }
}

private final class DiscoveryServerTokenTextField: NSTextField {
    var onDeleteBackwardWhenEmpty: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51, stringValue.isEmpty {
            onDeleteBackwardWhenEmpty?()
            return
        }
        super.keyDown(with: event)
    }
}
