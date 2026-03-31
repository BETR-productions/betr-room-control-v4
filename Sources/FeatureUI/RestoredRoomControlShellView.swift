import AppKit
import ClipPlayerDomain
import CoreNDIOutput
import RoomControlUIContracts
import RoutingDomain
import SwiftUI
import TimerDomain
import UniformTypeIdentifiers

public struct RestoredRoomControlShellView: View {
    @ObservedObject private var store: RoomControlWorkspaceStore
    @StateObject private var updateChecker = UpdateChecker()

    public init(store: RoomControlWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let startupBlockerMessage = store.startupBlockerMessage {
                startupBlocker(
                    message: startupBlockerMessage,
                    requiresInstall: store.startupBlockerRequiresInstall
                )
            } else if let shellState = store.shellState {
                VStack(spacing: 0) {
                    if let oldVersion = updateChecker.justUpdatedFrom {
                        postUpdateBanner(oldVersion: oldVersion)
                    }
                    RestoredRoomControlDashboard(store: store, shellState: shellState, updateChecker: updateChecker)
                }
                .background(BrandTokens.dark)
            } else {
                VStack(spacing: 18) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Bootstrapping BETR Room Control")
                        .font(BrandTokens.display(size: 22, weight: .semibold))
                        .foregroundStyle(BrandTokens.offWhite)
                    Text("Loading the preserved operator shell on top of BETRCoreAgent.")
                        .font(BrandTokens.display(size: 13))
                        .foregroundStyle(BrandTokens.warmGrey)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BrandTokens.dark)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.start()
            updateChecker.checkForUpdate()
        }
    }

    private func startupBlocker(message: String, requiresInstall: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: requiresInstall ? "externaldrive.badge.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(BrandTokens.gold)
            Text(requiresInstall ? "Install BETR Room Control" : "Start BETR Room Control")
                .font(BrandTokens.display(size: 24, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)
            Text(message)
                .font(BrandTokens.display(size: 13))
                .foregroundStyle(BrandTokens.warmGrey)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 720)
            Text(
                requiresInstall
                    ? "Copy the app into Applications, then launch it from there."
                    : "Quit and relaunch from Applications. If it keeps failing, reinstall the app with the BETR installer package."
            )
                .font(BrandTokens.display(size: 12, weight: .medium))
                .foregroundStyle(BrandTokens.offWhite)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(BrandTokens.dark)
    }

    private func postUpdateBanner(oldVersion: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(BrandTokens.timerGreen)
            Text("Updated: v\(oldVersion) -> v\(updateChecker.currentVersion)")
                .font(BrandTokens.display(size: 12, weight: .medium))
                .foregroundStyle(BrandTokens.offWhite)
            if let modDate = updateChecker.executableModDate {
                Text("(built \(modDate.formatted(date: .abbreviated, time: .shortened)))")
                    .font(BrandTokens.mono(size: 10))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
            Spacer()
            Button {
                updateChecker.dismissUpdateConfirmation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(BrandTokens.timerGreen.opacity(0.15))
    }
}

private struct RestoredRoomControlDashboard: View {
    @ObservedObject var store: RoomControlWorkspaceStore
    let shellState: FeatureShellState
    let updateChecker: UpdateChecker
    @State private var leadingColumnWidth: Double = 340
    @State private var centerColumnWidth: Double = 340
    @State private var discoveryPopoverPresented = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let banner = bannerMessage {
                Divider().background(BrandTokens.charcoal)
                OperatorBanner(message: banner.message, state: banner.state)
            }
            Divider().background(BrandTokens.charcoal)
            GeometryReader { geometry in
                let widths = clampedWidths(totalWidth: geometry.size.width)
                HStack(spacing: 0) {
                    leftColumn
                        .frame(width: widths.leading)
                    DividerHandle(.vertical) { delta in
                        leadingColumnWidth += delta
                    } onEnded: {
                        commitLayout(widths: widths)
                    }
                    centerColumn
                        .frame(width: widths.center)
                    DividerHandle(.vertical) { delta in
                        centerColumnWidth += delta
                    } onEnded: {
                        commitLayout(widths: widths)
                    }
                    rightColumn
                        .frame(width: widths.right)
                }
                .background(BrandTokens.dark)
            }
            Divider().background(BrandTokens.charcoal)
            CapacityStatusBar(shellState: shellState, validation: store.hostValidation)
        }
        .background(BrandTokens.dark)
        .onAppear {
            syncLayoutFromStore()
        }
        .onChange(of: store.operatorShellUIState) { _, _ in
            syncLayoutFromStore()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("BETR Room Control")
                .font(BrandTokens.display(size: 16, weight: .bold))
                .foregroundStyle(BrandTokens.gold)
            modeBadge("LIVE", tint: BrandTokens.liveRed)
            discoveryChip
            routeChip
            if updateChecker.updateAvailable, let latestVersion = updateChecker.latestVersion {
                chip("UPDATE \(latestVersion)", tint: BrandTokens.gold)
            }
            Spacer()
            Text(shellState.hostWizardSummary)
                .font(BrandTokens.mono(size: 10))
                .foregroundStyle(BrandTokens.warmGrey)
            Button("Settings") {
                store.operatorShellUIState.settingsPresented = true
            }
            .buttonStyle(.bordered)
            .tint(BrandTokens.gold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(BrandTokens.toolbarDark)
        .sheet(isPresented: $store.operatorShellUIState.settingsPresented) {
            RoomControlSettingsRootView(store: store, updateChecker: updateChecker)
                .frame(minWidth: 980, minHeight: 780)
        }
    }

    private var leftColumn: some View {
        ScrollView {
            VStack(spacing: 0) {
                PlaybackWorkspacePanel(shellState: shellState, store: store)
                Divider().background(BrandTokens.charcoal)
                ClipPlayerControlPanel(shellState: shellState, store: store)
                Divider().background(BrandTokens.charcoal)
                TimerControlPanel(store: store)
            }
        }
        .background(BrandTokens.dark)
    }

    private var centerColumn: some View {
        ScrollView {
            VStack(spacing: 0) {
                PresentationControlPanel(shellState: shellState, store: store)
                Divider().background(BrandTokens.charcoal)
                PresenterStatusPanel(store: store)
            }
        }
        .background(BrandTokens.dark)
    }

    private var rightColumn: some View {
        PreviewGridPanel(shellState: shellState, store: store)
            .background(BrandTokens.dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var discoveryChip: some View {
        Button {
            discoveryPopoverPresented.toggle()
        } label: {
            chip(discoveryAggregateStatus.label, tint: discoveryChipTint)
        }
        .buttonStyle(.plain)
        .help(discoveryHelpText)
        .popover(isPresented: $discoveryPopoverPresented, arrowEdge: .bottom) {
            DiscoveryStatusPopover(
                aggregateStatus: discoveryAggregateStatus,
                entries: sortedDiscoveryEntries,
                tintForState: discoveryTint(for:)
            )
        }
    }

    private var routeChip: some View {
        chip(
            store.hostValidation.multicastRoutePinnedToCommittedInterface ? "ROUTE PINNED" : "ROUTE CHECK",
            tint: store.hostValidation.multicastRoutePinnedToCommittedInterface ? BrandTokens.timerGreen : BrandTokens.timerYellow
        )
    }

    private var bannerMessage: (message: String, state: NDIWizardCheckState)? {
        if let lastErrorMessage = store.lastErrorMessage {
            return (lastErrorMessage, .blocked)
        }
        if store.hostValidation.overallReady == false {
            return (store.effectiveDiscoveryNextAction, .warning)
        }
        return nil
    }

    private func clampedWidths(totalWidth: CGFloat) -> (leading: CGFloat, center: CGFloat, right: CGFloat) {
        let minimumLeading: CGFloat = 280
        let minimumCenter: CGFloat = 280
        let minimumRight: CGFloat = 360
        if totalWidth <= 0 {
            return (CGFloat(leadingColumnWidth), CGFloat(centerColumnWidth), minimumRight)
        }

        let dividerAllowance: CGFloat = 12
        let maxLeading = max(minimumLeading, totalWidth - minimumCenter - minimumRight - dividerAllowance)
        let leading = min(max(CGFloat(leadingColumnWidth), minimumLeading), maxLeading)
        let maxCenter = max(minimumCenter, totalWidth - leading - minimumRight - dividerAllowance)
        let center = min(max(CGFloat(centerColumnWidth), minimumCenter), maxCenter)
        let right = max(minimumRight, totalWidth - leading - center - dividerAllowance)
        return (leading, center, right)
    }

    private func commitLayout(widths: (leading: CGFloat, center: CGFloat, right: CGFloat)) {
        store.operatorShellUIState.leadingColumnWidth = widths.leading
        store.operatorShellUIState.centerColumnWidth = widths.center
    }

    private func syncLayoutFromStore() {
        leadingColumnWidth = max(store.operatorShellUIState.leadingColumnWidth, 280)
        centerColumnWidth = max(store.operatorShellUIState.centerColumnWidth, 280)
    }

    private func chip(_ label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(label)
                .font(BrandTokens.mono(size: 10))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func modeBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(BrandTokens.mono(size: 10))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var discoveryPresentationEntries: [DiscoveryServerPresentationEntry] {
        DiscoveryServerPresentationBuilder.entries(
            configuredText: store.hostDraft.discoveryServersText,
            runtimeRows: store.hostValidation.discoveryServers
        )
    }

    private var sortedDiscoveryEntries: [DiscoveryServerPresentationEntry] {
        DiscoveryServerPresentationBuilder.sortedForPopover(discoveryPresentationEntries)
    }

    private var discoveryAggregateStatus: DiscoveryAggregateStatus {
        DiscoveryServerPresentationBuilder.aggregate(
            configuredText: store.hostDraft.discoveryServersText,
            runtimeRows: store.hostValidation.discoveryServers,
            mdnsEnabled: store.hostDraft.mdnsEnabled
        )
    }

    private var discoveryChipTint: Color {
        if discoveryAggregateStatus.usesMDNSOnly {
            return BrandTokens.gold
        }
        return discoveryTint(for: discoveryAggregateStatus.visualState)
    }

    private var discoveryHelpText: String {
        if discoveryAggregateStatus.usesMDNSOnly {
            return "mDNS-only discovery is active. Click for Discovery Server details if you add one later."
        }
        if sortedDiscoveryEntries.isEmpty {
            return "No Discovery Server is configured and mDNS is off."
        }
        let degradedEntries = sortedDiscoveryEntries.filter { $0.visualState != .connected }
        if degradedEntries.isEmpty {
            return "All configured Discovery Servers are healthy."
        }
        if let firstIssue = degradedEntries.first {
            return "Discovery is \(discoveryAggregateStatus.healthyCount)/\(discoveryAggregateStatus.totalCount) healthy. \(firstIssue.label) is \(firstIssue.statusWord.lowercased())."
        }
        return "Discovery has one or more configured server issues."
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
}

private struct DividerHandle: View {
    enum Axis {
        case vertical
    }

    let axis: Axis
    let onDrag: (Double) -> Void
    let onEnded: () -> Void
    @State private var lastTranslation: CGSize = .zero

    init(_ axis: Axis, onDrag: @escaping (Double) -> Void, onEnded: @escaping () -> Void) {
        self.axis = axis
        self.onDrag = onDrag
        self.onEnded = onEnded
    }

    var body: some View {
        Rectangle()
            .fill(BrandTokens.charcoal.opacity(0.65))
            .frame(width: 6)
            .overlay(
                Rectangle()
                    .fill(BrandTokens.gold.opacity(0.2))
                    .frame(width: 2)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDrag(value.translation.width - lastTranslation.width)
                        lastTranslation = value.translation
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        onEnded()
                    }
            )
    }
}

private struct DiscoveryStatusPopover: View {
    let aggregateStatus: DiscoveryAggregateStatus
    let entries: [DiscoveryServerPresentationEntry]
    let tintForState: (DiscoveryServerVisualState) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(aggregateStatus.label)
                .font(BrandTokens.display(size: 13, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)

            if aggregateStatus.usesMDNSOnly {
                Text("mDNS-only discovery is active. No Discovery Server is configured right now.")
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.warmGrey)
            } else if entries.isEmpty {
                Text("No Discovery Server rows are available yet.")
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.warmGrey)
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(tintForState(entry.visualState))
                                .frame(width: 8, height: 8)
                            Text(entry.label)
                                .font(BrandTokens.mono(size: 11))
                                .foregroundStyle(BrandTokens.offWhite)
                            Spacer(minLength: 12)
                            Text(entry.statusWord)
                                .font(BrandTokens.mono(size: 10))
                                .foregroundStyle(tintForState(entry.visualState))
                        }

                        if let detailText = entry.detailText, detailText.isEmpty == false {
                            Text(detailText)
                                .font(BrandTokens.display(size: 10))
                                .foregroundStyle(BrandTokens.warmGrey)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(BrandTokens.panelDark)
    }
}

private struct OperatorBanner: View {
    let message: String
    let state: NDIWizardCheckState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(message)
                .font(BrandTokens.display(size: 11, weight: .medium))
                .foregroundStyle(BrandTokens.offWhite)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(tint.opacity(0.12))
    }

    private var tint: Color {
        switch state {
        case .passed:
            return BrandTokens.timerGreen
        case .warning:
            return BrandTokens.timerYellow
        case .blocked:
            return BrandTokens.red
        }
    }
}

private struct PlaybackWorkspacePanel: View {
    let shellState: FeatureShellState
    @ObservedObject var store: RoomControlWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                panelHeader("RUN OF SHOW")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().background(BrandTokens.charcoal)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusChip("\(shellState.workspace.cards.count) outputs", tint: BrandTokens.gold)
                    statusChip("\(shellState.workspace.sources.count) sources", tint: BrandTokens.charcoal)
                    if store.clipPlayerRuntimeSnapshot.senderReady {
                        statusChip("clip live", tint: BrandTokens.timerGreen)
                    }
                    if store.timerRuntimeSnapshot.outputEnabled {
                        statusChip(
                            store.timerRuntimeSnapshot.senderReady ? "timer ready" : "timer output",
                            tint: store.timerRuntimeSnapshot.senderReady ? BrandTokens.timerGreen : BrandTokens.gold
                        )
                    }
                }

                Text(runOfShowSummary)
                    .font(BrandTokens.display(size: 12))
                    .foregroundStyle(BrandTokens.offWhite)

                Text(shellState.workspace.discoverySummary)
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.warmGrey)

                if let lastStatusMessage = store.lastStatusMessage {
                    Text(lastStatusMessage)
                        .font(BrandTokens.mono(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(BrandTokens.surfaceDark)
    }

    private var runOfShowSummary: String {
        if shellState.workspace.sources.isEmpty {
            return "No room sources are visible yet."
        }
        if shellState.workspace.cards.isEmpty {
            return "No outputs are configured yet."
        }
        return "Room sources and local tools are ready to route."
    }

    private func statusChip(_ label: String, tint: Color) -> some View {
        Text(label.uppercased())
            .font(BrandTokens.mono(size: 9))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct ClipPlayerControlPanel: View {
    let shellState: FeatureShellState
    @ObservedObject var store: RoomControlWorkspaceStore

    @State private var draggingItemID: String?
    @State private var dropActive = false

    private var runtime: ClipPlayerRuntimeSnapshot {
        store.clipPlayerRuntimeSnapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                panelHeader("CLIP PLAYER")
                Spacer()
                Text("\(runtime.playableItemCount) playable")
                    .font(BrandTokens.mono(size: 9))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(BrandTokens.charcoal.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button {
                    store.chooseClipPlayerFiles()
                } label: {
                    Label("Add Files", systemImage: "plus.circle.fill")
                        .font(BrandTokens.display(size: 11, weight: .medium))
                        .foregroundStyle(BrandTokens.gold)
                }
                .buttonStyle(.plain)
                .help("Choose one or more images or videos for the shared Clip Player.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().background(BrandTokens.charcoal)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    ClipPreviewSurface(
                        preview: runtime.preview ?? runtime.selectionPreview,
                        fallbackActive: runtime.isUsingHoldSlate
                    )
                    .frame(width: 120, height: 72)

                    VStack(alignment: .leading, spacing: 2) {
                        chipRow(clipStatusChips)
                        Text(transportTitle)
                            .font(BrandTokens.display(size: 12, weight: .medium))
                            .foregroundStyle(runtime.isUsingHoldSlate ? BrandTokens.offWhite : BrandTokens.gold)
                            .lineLimit(1)
                        Text(transportSubtitle)
                            .font(BrandTokens.mono(size: 10))
                            .foregroundStyle(BrandTokens.warmGrey)
                            .lineLimit(1)
                        Text(clipPanelInstructionText)
                            .font(BrandTokens.display(size: 10))
                            .foregroundStyle(BrandTokens.warmGrey.opacity(0.9))
                            .lineLimit(1)
                        Text(outputRouteSummary)
                            .font(BrandTokens.mono(size: 10))
                            .foregroundStyle(routeSummaryTint)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let lastErrorMessage = runtime.lastErrorMessage {
                        Text(lastErrorMessage)
                            .font(BrandTokens.mono(size: 10))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: 108, alignment: .trailing)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(dropActive ? BrandTokens.gold : BrandTokens.warmGrey)
                    Text(playlistInstructionText)
                        .font(BrandTokens.display(size: 11))
                        .foregroundStyle(dropActive ? BrandTokens.offWhite : BrandTokens.warmGrey)
                    Spacer()
                    if let currentOutputLabel {
                        Text(currentOutputLabel)
                            .font(BrandTokens.mono(size: 9))
                            .foregroundStyle(BrandTokens.offWhite)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(BrandTokens.timerGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.horizontal, 14)

                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(BrandTokens.cardBlack.opacity(0.45))

                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            dropActive ? BrandTokens.gold : BrandTokens.charcoal,
                            style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                        )

                    if store.clipPlayerDraft.items.isEmpty {
                        Button {
                            store.chooseClipPlayerFiles()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 20))
                                    .foregroundStyle(dropActive ? BrandTokens.gold : BrandTokens.charcoal)
                                Text("No media loaded")
                                    .font(BrandTokens.display(size: 12))
                                    .foregroundStyle(BrandTokens.warmGrey)
                                Text("Drag files here or click Add Files")
                                    .font(BrandTokens.display(size: 11))
                                    .foregroundStyle(dropActive ? BrandTokens.offWhite : BrandTokens.charcoal)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 92)
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                        .help("Choose multiple Clip Player files from the file picker.")
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(store.clipPlayerDraft.items) { item in
                                    clipItemRow(item)
                                        .onDrag {
                                            draggingItemID = item.id
                                            return NSItemProvider(object: item.id as NSString)
                                        }
                                        .onDrop(
                                            of: [.text],
                                            delegate: ClipPlayerDropDelegate(
                                                itemID: item.id,
                                                store: store,
                                                draggingItemID: $draggingItemID
                                            )
                                        )
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                        .frame(minHeight: 92, maxHeight: 132)
                    }

                    if dropActive {
                        Text("DROP FILES TO ADD")
                            .font(BrandTokens.mono(size: 9))
                            .foregroundStyle(BrandTokens.offWhite)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(BrandTokens.gold)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            Divider().background(BrandTokens.charcoal)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Text("Mode")
                            .font(BrandTokens.display(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Picker(
                            "",
                            selection: Binding(
                                get: { store.clipPlayerDraft.playbackMode },
                                set: { store.setClipPlayerPlaybackMode($0) }
                            )
                        ) {
                            ForEach(ClipPlayerPlaybackMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 102)
                    }

                    HStack(spacing: 4) {
                        Text("Transition")
                            .font(BrandTokens.display(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Picker(
                            "",
                            selection: Binding(
                                get: { store.clipPlayerDraft.transitionType },
                                set: { store.setClipPlayerTransitionType($0) }
                            )
                        ) {
                            ForEach(ClipPlayerTransitionType.allCases, id: \.self) { transition in
                                Text(transition.rawValue.capitalized).tag(transition)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 92)
                    }

                    Spacer()
                }

                if store.clipPlayerDraft.transitionType == .fade {
                    HStack(spacing: 8) {
                        Text("Fade")
                            .font(BrandTokens.display(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Slider(
                            value: Binding(
                                get: { Double(store.clipPlayerDraft.transitionDurationMs) },
                                set: { store.setClipPlayerTransitionDuration(Int($0.rounded())) }
                            ),
                            in: 100...2_000,
                            step: 100,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    store.commitClipPlayerDraftChanges()
                                }
                            }
                        )
                        Text("\(store.clipPlayerDraft.transitionDurationMs)ms")
                            .font(BrandTokens.mono(size: 10))
                            .foregroundStyle(BrandTokens.warmGrey)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().background(BrandTokens.charcoal)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transportTitle)
                        .font(BrandTokens.mono(size: 11))
                        .foregroundStyle(BrandTokens.gold)
                        .lineLimit(1)
                    Text(transportSubtitle)
                        .font(BrandTokens.mono(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                }

                Spacer()

                HStack(spacing: 16) {
                    transportButton(systemName: "backward.end.fill", disabled: store.clipPlayerDraft.items.isEmpty) {
                        store.previousClipPlayerItem()
                    }
                    transportButton(
                        systemName: runtime.runState == .playing ? "pause.fill" : "play.fill",
                        disabled: store.clipPlayerDraft.items.isEmpty
                    ) {
                        if runtime.runState == .playing {
                            store.pauseClipPlayer()
                        } else {
                            store.playClipPlayer()
                        }
                    }
                    transportButton(systemName: "forward.end.fill", disabled: store.clipPlayerDraft.items.isEmpty) {
                        store.nextClipPlayerItem()
                    }
                    transportButton(systemName: "stop.fill", disabled: store.clipPlayerDraft.items.isEmpty) {
                        store.stopClipPlayer()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(BrandTokens.surfaceDark)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropActive) { providers in
            handleFileDrop(providers: providers)
        }
    }

    private var runtimeTint: Color {
        switch runtime.runState {
        case .playing:
            return BrandTokens.timerGreen
        case .paused:
            return BrandTokens.timerYellow
        case .stopped:
            return BrandTokens.charcoal
        }
    }

    private var transportTitle: String {
        if let currentItemName = runtime.currentItemName?.trimmingCharacters(in: .whitespacesAndNewlines),
           currentItemName.isEmpty == false {
            return currentItemName
        }
        return store.clipPlayerDraft.items.isEmpty ? "No media loaded" : "Clip Player ready"
    }

    private var transportSubtitle: String {
        let total = max(0, runtime.totalItemCount)
        guard total > 0 else { return "0 items" }
        let position = runtime.currentItemIndex.map { "[\($0 + 1)/\(total)]" } ?? "[idle/\(total)]"
        return "\(position) • \(runtime.playableItemCount) playable"
    }

    private var clipPanelInstructionText: String {
        if runtime.runState == .playing {
            return "Shared playback is live for every output bound to Clip Player."
        }
        if store.clipPlayerDraft.items.isEmpty {
            return "Choose files in bulk or drag media in to build the shared playlist."
        }
        return "Click a row to cue it while stopped, or jump live while playback is running."
    }

    private var playlistInstructionText: String {
        if store.clipPlayerDraft.items.isEmpty {
            return "Drag images or videos here, or click Add Files."
        }
        return "Drag files into this playlist to add them, or drag rows to reorder."
    }

    private var clipStatusChips: [String] {
        [
            runtime.runState.rawValue.uppercased(),
            runtime.isUsingHoldSlate ? "HOLD" : "LIVE",
            runtime.senderReady ? "SENDER READY" : "SENDER OFFLINE",
        ]
    }

    private var clipPlayerSource: RouterWorkspaceSourceState? {
        shellState.workspace.sources.first(where: { $0.id == ClipPlayerConstants.managedSourceID })
    }

    private var currentOutputLabel: String? {
        let outputs = clipPlayerSource?.routedOutputIDs ?? []
        guard outputs.isEmpty == false else { return nil }
        if outputs.count == 1, let outputID = outputs.first {
            return "LIVE ON \(outputID)"
        }
        return "LIVE ON \(outputs.count) OUTPUTS"
    }

    private var outputRouteSummary: String {
        let outputs = clipPlayerSource?.routedOutputIDs ?? []
        if outputs.isEmpty {
            return runtime.senderReady ? "Not assigned to any output yet." : "Clip Player source is still coming online."
        }
        if outputs.count == 1, let outputID = outputs.first {
            return "Assigned live on \(outputID)."
        }
        return "Assigned live on \(outputs.joined(separator: ", "))."
    }

    private var routeSummaryTint: Color {
        (clipPlayerSource?.routedOutputIDs.isEmpty == false) ? BrandTokens.timerGreen : BrandTokens.warmGrey
    }

    private func clipItemRow(_ item: ClipPlayerItem) -> some View {
        let selectedItemID =
            store.clipPlayerDraft.items.indices.contains(store.clipPlayerDraft.currentItemIndex)
                ? store.clipPlayerDraft.items[store.clipPlayerDraft.currentItemIndex].id
                : nil
        let isSelected = selectedItemID == item.id
        let isCurrent = runtime.currentItemID == item.id
        let isPlayingCurrent = runtime.runState == .playing && isCurrent
        let isLiveOnOutput = isPlayingCurrent && (clipPlayerSource?.routedOutputIDs.isEmpty == false)
        let isMissing = runtime.items.first(where: { $0.id == item.id })?.isMissing ?? false

        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(BrandTokens.charcoal)
                .frame(width: 12)

            Image(systemName: item.type == .image ? "photo" : "film")
                .font(.system(size: 11))
                .foregroundStyle(isPlayingCurrent ? BrandTokens.gold : (isSelected ? BrandTokens.offWhite : BrandTokens.warmGrey))
                .frame(width: 16)

            Text(item.fileName)
                .font(BrandTokens.display(size: 12))
                .foregroundStyle(
                    isMissing ? BrandTokens.red
                        : (isLiveOnOutput ? BrandTokens.gold : (isCurrent ? BrandTokens.offWhite : (isSelected ? BrandTokens.offWhite : BrandTokens.warmGrey)))
                )
                .lineLimit(1)

            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(BrandTokens.red)
            }

            if isLiveOnOutput {
                rowStateBadge("LIVE", tint: BrandTokens.timerGreen)
            } else if isCurrent {
                rowStateBadge(runtime.runState == .paused ? "PAUSED" : "ACTIVE", tint: BrandTokens.gold)
            } else if isSelected {
                rowStateBadge("CUED", tint: BrandTokens.charcoal)
            }

            Spacer()

            if item.type == .image {
                HStack(spacing: 2) {
                    Text("\(Int(item.dwellSeconds))s")
                        .font(BrandTokens.mono(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                        .frame(width: 24, alignment: .trailing)
                    Stepper(
                        "",
                        value: Binding(
                            get: { item.dwellSeconds },
                            set: { store.setClipPlayerItemDwell(item.id, seconds: $0) }
                        ),
                        in: 1...60,
                        step: 1
                    )
                    .labelsHidden()
                    .scaleEffect(0.75)
                    .frame(width: 52)
                }
            } else {
                Text("auto")
                    .font(BrandTokens.mono(size: 10))
                    .foregroundStyle(BrandTokens.warmGrey)
            }

            Button {
                store.removeClipPlayerItem(item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandTokens.warmGrey)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    isLiveOnOutput ? BrandTokens.timerGreen.opacity(0.14)
                        : (isCurrent ? BrandTokens.gold.opacity(0.12)
                            : (isSelected ? BrandTokens.offWhite.opacity(0.05) : Color.clear))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isLiveOnOutput ? BrandTokens.timerGreen
                        : (isCurrent ? BrandTokens.gold
                            : (isSelected ? BrandTokens.charcoal : Color.clear)),
                    lineWidth: isLiveOnOutput || isCurrent || isSelected ? 1 : 0
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectClipPlayerItem(item.id)
        }
    }

    private func chip(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(BrandTokens.mono(size: 9))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func rowStateBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(BrandTokens.mono(size: 9))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func transportButton(
        systemName: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? BrandTokens.charcoal : BrandTokens.offWhite)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                Task { @MainActor in
                    store.addClipPlayerItems(from: [url])
                }
            }
            accepted = true
        }
        return accepted
    }
}

private struct ClipPreviewSurface: View {
    let preview: OutputPreviewSnapshot?
    let fallbackActive: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(BrandTokens.cardBlack)

            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: fallbackActive ? "photo" : "film.stack")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(fallbackActive ? BrandTokens.warmGrey : BrandTokens.gold)
                    Text(fallbackActive ? "HOLD" : "PREVIEW")
                        .font(BrandTokens.mono(size: 9))
                        .foregroundStyle(BrandTokens.offWhite)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var previewImage: NSImage? {
        guard let preview, let imageData = preview.imageData else { return nil }
        switch preview.encoding {
        case .jpeg:
            return NSImage(data: imageData)
        case .bgra8:
            guard preview.width > 0,
                  preview.height > 0,
                  preview.lineStride >= preview.width * 4,
                  imageData.count >= preview.lineStride * preview.height,
                  let provider = CGDataProvider(data: imageData as CFData),
                  let cgImage = CGImage(
                      width: preview.width,
                      height: preview.height,
                      bitsPerComponent: 8,
                      bitsPerPixel: 32,
                      bytesPerRow: preview.lineStride,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                          CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                      ),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: true,
                      intent: .defaultIntent
                  ) else {
                return nil
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: preview.width, height: preview.height))
        case .sharedSurface:
            return nil
        }
    }
}

private struct ClipPlayerDropDelegate: DropDelegate {
    let itemID: String
    let store: RoomControlWorkspaceStore
    @Binding var draggingItemID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        store.commitClipPlayerReorder()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingItemID,
              draggingItemID != itemID,
              let fromIndex = store.clipPlayerDraft.items.firstIndex(where: { $0.id == draggingItemID }),
              let toIndex = store.clipPlayerDraft.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        withAnimation(.default) {
            store.moveClipPlayerItems(
                from: IndexSet(integer: fromIndex),
                to: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct PresentationControlPanel: View {
    let shellState: FeatureShellState
    @ObservedObject var store: RoomControlWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                panelHeader("PRESENTATION")
                Spacer()
                if !store.presentationDraft.appName.isEmpty {
                    Text(store.presentationDraft.appName.uppercased())
                        .font(BrandTokens.mono(size: 9))
                        .foregroundStyle(BrandTokens.offWhite)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(BrandTokens.charcoal.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().background(BrandTokens.charcoal)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Presentation file", text: $store.presentationDraft.filePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose") {
                        choosePresentationFile()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Picker("App", selection: $store.presentationDraft.appName) {
                        Text("PowerPoint").tag("PowerPoint")
                        Text("Keynote").tag("Keynote")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)

                    Stepper("Slide \(store.presentationDraft.startSlide)", value: $store.presentationDraft.startSlide, in: 1...999)
                        .font(BrandTokens.display(size: 12))
                        .foregroundStyle(BrandTokens.offWhite)
                }

                chipRow(statusChips)

                Text(summaryLine)
                    .font(BrandTokens.display(size: 12))
                    .foregroundStyle(BrandTokens.offWhite)

                Text(detailLine)
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.warmGrey)

                if !store.presentationDraft.filePath.isEmpty {
                    Text(store.presentationDraft.filePath)
                        .font(BrandTokens.mono(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(BrandTokens.charcoal)

            HStack(spacing: 8) {
                Button("Clear") {
                    store.presentationDraft.filePath = ""
                    store.noteStatus("Cleared the presentation file path.")
                }
                .buttonStyle(.bordered)

                Button("Warm Source") {
                    store.noteStatus("Presentation warming will route through BETRCoreAgent.")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(BrandTokens.surfaceDark)
    }

    private var statusChips: [String] {
        [
            store.presentationHealth.sessionPhase.rawValue.uppercased(),
            store.presentationHealth.state.isConnected ? "CONNECTED" : "IDLE",
            "SLIDE \(store.presentationDraft.startSlide)"
        ]
    }

    private var summaryLine: String {
        if store.presentationDraft.filePath.isEmpty {
            return "Choose a presentation file before warming the routed source."
        }
        switch store.presentationHealth.sessionPhase {
        case .live:
            return "Presentation session is live on the current profile."
        case .opening:
            return "Presentation session is opening."
        case .failed:
            return "Presentation session needs attention before it can be trusted live."
        case .closed:
            return "Presentation file is staged and ready for the next launch."
        }
    }

    private var detailLine: String {
        if store.presentationDraft.filePath.isEmpty {
            return "Use the preserved center rail to stage the file, app, and opening slide."
        }
        return "Start on slide \(store.presentationDraft.startSlide) in \(store.presentationDraft.appName)."
    }

    private func choosePresentationFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.presentation, .data]
        panel.message = "Select a PowerPoint or Keynote file for the presentation source."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.presentationDraft.filePath = url.path
        if url.pathExtension.lowercased() == "key" {
            store.presentationDraft.appName = "Keynote"
        } else if ["ppt", "pptx"].contains(url.pathExtension.lowercased()) {
            store.presentationDraft.appName = "PowerPoint"
        }
        store.noteStatus("Selected presentation file \(url.lastPathComponent).")
    }
}

private struct PresenterStatusPanel: View {
    @ObservedObject var store: RoomControlWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                panelHeader("PRESENTER VIEW")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().background(BrandTokens.charcoal)

            VStack(alignment: .leading, spacing: 10) {
                chipRow([
                    store.presentationHealth.sessionPhase.rawValue.uppercased(),
                    store.presentationHealth.state.isConnected ? "CONNECTED" : "OFFLINE"
                ])

                Text(headline)
                    .font(BrandTokens.display(size: 12, weight: .semibold))
                    .foregroundStyle(BrandTokens.offWhite)

                Text(bodyCopy)
                    .font(BrandTokens.display(size: 12))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !store.presentationDraft.filePath.isEmpty {
                    Text(store.presentationDraft.filePath)
                        .font(BrandTokens.mono(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(BrandTokens.surfaceDark)
    }

    private var headline: String {
        switch store.presentationHealth.sessionPhase {
        case .live:
            return "Presenter session is open."
        case .opening:
            return "Presenter session is opening."
        case .failed:
            return "Presenter session needs recovery."
        case .closed:
            return "Presenter session is closed."
        }
    }

    private var bodyCopy: String {
        if store.presentationDraft.filePath.isEmpty {
            return "Slide notes and presenter state will appear here once a presentation file is staged and the session is running."
        }
        return "Staged in \(store.presentationDraft.appName) starting on slide \(store.presentationDraft.startSlide)."
    }
}

private struct TimerControlPanel: View {
    @ObservedObject var store: RoomControlWorkspaceStore

    var body: some View {
        let runtime = store.timerRuntimeSnapshot
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                panelHeader("TIMER")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().background(BrandTokens.charcoal)

            VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $store.timerDraft.mode) {
                Text("Duration").tag(SimpleTimerState.Mode.duration)
                Text("End Time").tag(SimpleTimerState.Mode.endTime)
            }
            .pickerStyle(.segmented)

            if store.timerDraft.mode == .duration {
                Stepper(
                    "Duration \(store.timerDraft.durationMinutes) min",
                    value: $store.timerDraft.durationMinutes,
                    in: 1...720
                )
                .font(BrandTokens.display(size: 12))
                .foregroundStyle(BrandTokens.offWhite)
            } else {
                DatePicker(
                    "End Time",
                    selection: $store.timerDraft.endTime,
                    displayedComponents: [.hourAndMinute]
                )
            }

            Toggle("Presenter visible", isOn: $store.timerDraft.showPresenter)
            Toggle("Program visible", isOn: $store.timerDraft.showProgram)
            Toggle(
                "Output",
                isOn: Binding(
                    get: { store.timerDraft.outputEnabled },
                    set: { store.setTimerOutputEnabled($0) }
                )
            )
            }
            .padding(14)

            Divider().background(BrandTokens.charcoal)

            HStack(spacing: 8) {
                statusChip(runtime.runState.rawValue.uppercased(), tint: timerStateTint(runtime.runState))
                statusChip(runtime.outputEnabled ? "OUTPUT ON" : "OUTPUT OFF", tint: runtime.outputEnabled ? BrandTokens.gold : BrandTokens.charcoal)
                if runtime.senderReady {
                    statusChip("READY", tint: BrandTokens.timerGreen)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Text(runtime.displayText)
                .font(BrandTokens.mono(size: 28))
                .foregroundStyle(BrandTokens.offWhite)
                .padding(.horizontal, 14)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Button("Save Settings") {
                    store.saveTimerState()
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandTokens.gold)

                Button("Start") {
                    store.startTimer()
                }
                .buttonStyle(.bordered)
                .disabled(runtime.runState == .running)

                Button(runtime.runState == .paused ? "Resume" : "Pause") {
                    if runtime.runState == .paused {
                        store.resumeTimer()
                    } else {
                        store.pauseTimer()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(runtime.runState == .stopped)

                Button("Stop") {
                    store.stopTimer()
                }
                .buttonStyle(.bordered)
                .disabled(runtime.runState == .stopped)

                Button("Restart") {
                    store.restartTimer()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if store.timerDraft.visibleSurfaces.isEmpty == false {
                chipRow(store.timerDraft.visibleSurfaces.map(\.rawValue).map { $0.uppercased() })
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .background(BrandTokens.surfaceDark)
    }

    private func timerStateTint(_ state: TimerRunState) -> Color {
        switch state {
        case .running:
            return BrandTokens.timerGreen
        case .paused:
            return BrandTokens.timerYellow
        case .stopped:
            return BrandTokens.charcoal
        }
    }

    private func statusChip(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(BrandTokens.mono(size: 9))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct PreviewGridPanel: View {
    let shellState: FeatureShellState
    @ObservedObject var store: RoomControlWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OUTPUTS")
                    .font(BrandTokens.display(size: 11, weight: .semibold))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .tracking(1.2)
                Spacer()
                Button {
                    store.addOutput()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Output")
                            .font(BrandTokens.display(size: 11, weight: .medium))
                    }
                    .foregroundStyle(BrandTokens.gold)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().background(BrandTokens.charcoal)

            ScrollView {
                if shellState.workspace.cards.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(BrandTokens.charcoal)
                        Text("No outputs configured")
                            .font(BrandTokens.display(size: 13, weight: .semibold))
                            .foregroundStyle(BrandTokens.offWhite)
                        Text("Add an output when you want to start routing sources again.")
                            .font(BrandTokens.display(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .padding(.horizontal, 16)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(shellState.workspace.cards) { card in
                            OutputPreviewTile(card: card, shellState: shellState, store: store)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(BrandTokens.dark)
    }
}

private struct OutputPreviewTile: View {
    let card: RoomControlOutputCardState
    let shellState: FeatureShellState
    @ObservedObject var store: RoomControlWorkspaceStore
    @State private var showRemoveOutputConfirmation = false
    @State private var showsDiagnostics = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            stackedLayout
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .background(BrandTokens.surfaceDark)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(BrandTokens.charcoal, lineWidth: 1)
        )
        .confirmationDialog(
            "Remove \(card.title)?",
            isPresented: $showRemoveOutputConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Output", role: .destructive) {
                store.removeOutput(card.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This tears down the sender, removes its slots, and can leave the workspace with zero outputs.")
        }
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            mediaColumn
                .frame(minWidth: 292, idealWidth: 344, maxWidth: 360, alignment: .topLeading)

            HStack(alignment: .top, spacing: 12) {
                OutputSlotBank(card: card, shellState: shellState, store: store)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                controlColumn
                    .frame(width: 108)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            mediaColumn
            OutputSlotBank(card: card, shellState: shellState, store: store)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            controlRow
        }
    }

    private var mediaColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(card.title)
                    .font(BrandTokens.display(size: 12, weight: .semibold))
                    .foregroundStyle(BrandTokens.offWhite)
                    .lineLimit(1)
                Spacer(minLength: 8)
                listenerBadge
                ForEach(card.statusPills, id: \.rawValue) { pill in
                    statusPill(pill.rawValue)
                }
            }

            LiveOutputSurfacePreview(
                renderFeed: store.programRenderFeed(for: card.id),
                previewState: card.liveTile.previewState,
                surfaceLabel: "LIVE",
                standbyLabel: programStandbyLabel,
                showsAudioMeters: true,
                audioMuted: card.isAudioMuted,
                leftLevel: card.liveTile.leftLevel,
                rightLevel: card.liveTile.rightLevel,
                inset: nil
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                sourceSummaryRow
                compactHealthSummary
                Text(card.rasterLabel)
                    .font(BrandTokens.mono(size: 9))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .lineLimit(1)
                diagnosticsDisclosure
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controlColumn: some View {
        VStack(spacing: 8) {
            controlButton(card.isAudioMuted ? "Unmute" : "Mute") {
                store.toggleOutputAudioMuted(card.id)
            }
            controlButton(card.isSoloedLocally ? "Unsolo" : "Solo") {
                store.toggleOutputSoloedLocally(card.id)
            }
            Menu {
                Button("Remove Output…", role: .destructive) {
                    showRemoveOutputConfirmation = true
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .font(BrandTokens.display(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .controlSize(.small)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            controlButton(card.isAudioMuted ? "Unmute" : "Mute") {
                store.toggleOutputAudioMuted(card.id)
            }
            controlButton(card.isSoloedLocally ? "Unsolo" : "Solo") {
                store.toggleOutputSoloedLocally(card.id)
            }
            Menu {
                Button("Remove Output…", role: .destructive) {
                    showRemoveOutputConfirmation = true
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .font(BrandTokens.display(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .controlSize(.small)
        }
    }

    private var programStandbyLabel: String {
        switch card.liveTile.previewState {
        case .live:
            return "LIVE"
        case .fault:
            return "FAULT / NO FRAME"
        case .unavailable:
            return card.confidencePreview?.mode == .pendingProgram ? "ARMING" : "NO PROGRAM"
        }
    }

    private var sourceSummaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            sourceChip(
                label: "LIVE",
                value: liveSourceName,
                tint: card.liveTile.previewState == .live ? BrandTokens.pgnGreen : BrandTokens.charcoal
            )
            Spacer(minLength: 8)
            if let confidencePreview = card.confidencePreview {
                sourceChip(
                    label: confidencePreview.isReady ? "PVW" : "ARM",
                    value: confidencePreview.sourceName ?? "None",
                    tint: confidencePreview.isReady ? BrandTokens.pvwRed : BrandTokens.gold
                )
            }
        }
    }

    private var liveSourceName: String {
        guard let liveSourceID = card.liveTile.sourceID else {
            return "None"
        }
        return shellState.workspace.sources.first(where: { $0.id == liveSourceID })?.name ?? liveSourceID
    }

    private func sourceChip(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(BrandTokens.mono(size: 8))
                .foregroundStyle(BrandTokens.warmGrey)
            Text(value)
                .font(BrandTokens.display(size: 10, weight: .medium))
                .foregroundStyle(BrandTokens.offWhite)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var compactHealthSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            healthSummaryRow(
                label: "INPUT",
                text: inputHealthSummaryText,
                tint: inputHealthSummaryTint
            )
            healthSummaryRow(
                label: "OUTPUT",
                text: outputHealthSummaryText,
                tint: outputHealthSummaryTint
            )
        }
    }

    private func healthSummaryRow(label: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            sectionBadge(label, tint: tint)
            Text(text)
                .font(BrandTokens.display(size: 10, weight: .medium))
                .foregroundStyle(BrandTokens.offWhite)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var telemetrySourceID: String? {
        if card.confidencePreview?.mode == .pendingProgram {
            return card.programSourceID
        }
        return card.liveTile.sourceID ?? card.programSourceID ?? card.previewSourceID
    }

    private var telemetrySourceName: String {
        if card.confidencePreview?.mode == .pendingProgram {
            return card.confidencePreview?.sourceName ?? card.programSourceName ?? "None"
        }
        return liveSourceName
    }

    private var inputHealthSummaryText: String {
        guard let sourceID = telemetrySourceID,
              let telemetry = store.hostValidation.receiverTelemetry(for: sourceID) else {
            return "\(telemetrySourceName) • \(sourceReadinessLabel(for: telemetrySourceID))"
        }

        let sync = inputSyncLabel(for: telemetry)
        let latency = inputLatencyLabel(for: telemetry)
        return "\(telemetry.sourceName) • \(sync) • \(latency)"
    }

    private var inputHealthSummaryTint: Color {
        guard let sourceID = telemetrySourceID,
              let telemetry = store.hostValidation.receiverTelemetry(for: sourceID) else {
            return sourceReadinessTint(for: telemetrySourceID)
        }
        return inputSyncTint(for: telemetry)
    }

    private var outputHealthSummaryText: String {
        guard let telemetry = store.hostValidation.outputTelemetry(for: card.id) else {
            return "Sender telemetry not reported yet."
        }

        let routeState: String
        if card.statusPills.contains(.fault) {
            routeState = "Fault / no frame"
        } else if card.statusPills.contains(.arming) {
            routeState = "Switch arming"
        } else if card.statusPills.contains(.live) {
            routeState = "Live"
        } else if card.statusPills.contains(.error) {
            routeState = "Needs attention"
        } else {
            routeState = "Idle"
        }

        let listenerLabel = telemetry.senderConnectionCount == 1
            ? "1 listener"
            : "\(telemetry.senderConnectionCount) listeners"
        let audioLabel: String
        switch card.liveTile.audioPresenceState {
        case .live:
            audioLabel = card.isAudioMuted ? "Muted" : "Audio live"
        case .muted:
            audioLabel = "Muted"
        case .silent:
            audioLabel = "Silent"
        }

        return "\(routeState) • \(listenerLabel) • \(audioLabel)"
    }

    private var outputHealthSummaryTint: Color {
        if card.statusPills.contains(.error) {
            return BrandTokens.red
        }
        if card.statusPills.contains(.arming) {
            return BrandTokens.gold
        }
        if card.statusPills.contains(.fault) {
            return BrandTokens.red
        }
        return BrandTokens.timerGreen
    }

    private var diagnosticsDisclosure: some View {
        DisclosureGroup(isExpanded: $showsDiagnostics) {
            ScrollView(.horizontal, showsIndicators: false) {
                telemetryStrip
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Text("Details")
                .font(BrandTokens.display(size: 10, weight: .semibold))
                .foregroundStyle(BrandTokens.warmGrey)
        }
    }

    private var listenerBadge: some View {
        let hasListeners = card.listenerCount > 0
        return HStack(spacing: 4) {
            Image(systemName: hasListeners ? "ear.fill" : "ear")
                .font(.system(size: 10, weight: .semibold))
            Text("\(card.listenerCount)")
                .font(BrandTokens.mono(size: 10))
        }
        .foregroundStyle(hasListeners ? BrandTokens.offWhite : BrandTokens.warmGrey)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(hasListeners ? 0.08 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func statusPill(_ label: String) -> some View {
        let tint: Color
        switch label {
        case "LIVE", "AUDIO":
            tint = BrandTokens.pgnGreen
        case "PVW":
            tint = BrandTokens.pvwRed
        case "MUTED":
            tint = BrandTokens.timerYellow
        case "SOLO":
            tint = Color(hex: 0x2962D9)
        case "FAULT", "NO PREVIEW", "DEGRADED", "ERROR":
            tint = BrandTokens.red
        case "ARMING":
            tint = BrandTokens.gold
        default:
            tint = BrandTokens.charcoal
        }

        return Text(label)
            .font(BrandTokens.mono(size: 10))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var telemetryStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            receiverTelemetryRow(
                sectionLabel: card.confidencePreview?.mode == .pendingProgram ? "IN NEXT" : "IN LIVE",
                sourceID: telemetrySourceID,
                fallbackSourceName: telemetrySourceName,
                tint: card.confidencePreview?.mode == .pendingProgram ? BrandTokens.gold : BrandTokens.pgnGreen
            )

            if card.confidencePreview?.mode == .armedPreview {
                receiverTelemetryRow(
                    sectionLabel: card.confidencePreview?.isReady == true ? "IN PVW" : "IN ARM",
                    sourceID: card.previewSourceID,
                    fallbackSourceName: card.previewSourceName ?? "None",
                    tint: card.confidencePreview?.isReady == true ? BrandTokens.pvwRed : BrandTokens.gold
                )
            }

            if let telemetry = store.hostValidation.outputTelemetry(for: card.id) {
                HStack(spacing: 6) {
                    sectionBadge("OUT", tint: telemetry.senderReady ? BrandTokens.timerGreen : BrandTokens.gold)
                    metricBadge("SND", "\(telemetry.senderConnectionCount)", tint: telemetry.senderConnectionCount > 0 ? BrandTokens.timerGreen : BrandTokens.charcoal)
                    metricBadge("Q", "\(telemetry.videoQueueDepth)", tint: telemetry.videoQueueDepth > 0 ? BrandTokens.gold : BrandTokens.charcoal)
                    metricBadge(
                        "AQ",
                        telemetry.audioQueueDepthMs.map { String(format: "%.0fms", $0) } ?? "n/a",
                        tint: telemetry.audioQueueDepthMs.map { $0 > 0 ? BrandTokens.gold : BrandTokens.red } ?? BrandTokens.charcoal
                    )
                    metricBadge("DRIFT", telemetry.audioDriftDebtSamples.map { String($0) } ?? "0", tint: telemetry.audioDriftDebtSamples.map { abs($0) > 240 ? BrandTokens.red : BrandTokens.timerYellow } ?? BrandTokens.charcoal)
                    let discontinuityCount = telemetry.videoTimestampDiscontinuityCount + telemetry.audioTimestampDiscontinuityCount
                    if discontinuityCount > 0 {
                        metricBadge("TS", "\(discontinuityCount)", tint: BrandTokens.red)
                    }
                    if card.liveTile.previewState == .fault {
                        metricBadge("FAULT", card.liveTile.playoutFaultStageID ?? "no_frame", tint: BrandTokens.red)
                    } else if telemetry.senderReady == false {
                        metricBadge("READY", "WAIT", tint: BrandTokens.gold)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func receiverTelemetryRow(
        sectionLabel: String,
        sourceID: String?,
        fallbackSourceName: String,
        tint: Color
    ) -> some View {
        if let telemetry = store.hostValidation.receiverTelemetry(for: sourceID) {
            let queueDepth = max(telemetry.videoQueueDepth, telemetry.audioQueueDepth)
            let totalDrops = telemetry.droppedVideoFrames + telemetry.droppedAudioFrames
            let warmAttemptDrops = telemetry.warmAttemptDroppedVideoFrames + telemetry.warmAttemptDroppedAudioFrames
            HStack(spacing: 6) {
                sectionBadge(sectionLabel, tint: tint)
                metricBadge("SRC", telemetry.sourceName, tint: BrandTokens.charcoal)
                metricBadge("STATE", sourceReadinessLabel(for: sourceID), tint: sourceReadinessTint(for: sourceID))
                metricBadge("SYNC", inputSyncLabel(for: telemetry), tint: inputSyncTint(for: telemetry))
                metricBadge("CONN", "\(telemetry.connectionCount)", tint: telemetry.connectionCount > 0 ? BrandTokens.timerGreen : BrandTokens.charcoal)
                metricBadge("Q", "\(queueDepth)", tint: queueDepth > 0 ? BrandTokens.gold : BrandTokens.charcoal)
                metricBadge("LAT", inputLatencyLabel(for: telemetry), tint: latencyTint(telemetry.estimatedVideoLatencyMs))
                metricBadge("DROP", "\(totalDrops)", tint: totalDrops > 0 ? BrandTokens.red : BrandTokens.charcoal)
                if warmAttemptDrops > 0 {
                    metricBadge("WDROP", "\(warmAttemptDrops)", tint: BrandTokens.red)
                }
                if let skew = telemetry.inputAVSkewMs {
                    metricBadge("SKEW", String(format: "%.0fms", skew), tint: skewTint(skew))
                }
                if telemetry.fanoutCount > 1 {
                    metricBadge("SHARED", "x\(telemetry.fanoutCount)", tint: BrandTokens.gold)
                }
            }
        } else {
            HStack(spacing: 6) {
                sectionBadge(sectionLabel, tint: tint)
                metricBadge("SRC", fallbackSourceName, tint: BrandTokens.charcoal)
                metricBadge("STATE", sourceReadinessLabel(for: sourceID), tint: sourceReadinessTint(for: sourceID))
            }
        }
    }

    private func inputLatencyLabel(for telemetry: NDIReceiverTelemetryRow) -> String {
        if let latency = telemetry.estimatedVideoLatencyMs {
            // Receiver telemetry does not currently carry source frame rate, so use a
            // documented 60 fps fallback when converting latency into frame buckets.
            let frameIntervalMs = 1000.0 / 60.0
            if latency < frameIntervalMs { return "<1f" }
            if latency < frameIntervalMs * 2.0 { return "1-2f" }
            if latency < frameIntervalMs * 3.0 { return "2-3f" }
            return ">3f"
        }
        return "n/a"
    }

    private func inputSyncLabel(for telemetry: NDIReceiverTelemetryRow) -> String {
        if telemetry.syncReady {
            return "OK"
        }
        if telemetry.gateReasons.contains("audio") {
            return telemetry.audioRequired ? "AUD?" : "VID"
        }
        if telemetry.gateReasons.contains("skew") {
            return "SKEW"
        }
        if telemetry.gateReasons.contains("queue") {
            return "QUEUE"
        }
        if telemetry.gateReasons.contains("drop") {
            return "DROP"
        }
        if telemetry.gateReasons.contains("video") {
            return "NO VID"
        }
        return "ARM"
    }

    private func inputSyncTint(for telemetry: NDIReceiverTelemetryRow) -> Color {
        if telemetry.syncReady {
            return BrandTokens.timerGreen
        }
        if telemetry.gateReasons.contains("skew") || telemetry.gateReasons.contains("drop") {
            return BrandTokens.red
        }
        return BrandTokens.gold
    }

    private func latencyTint(_ latencyMs: Double?) -> Color {
        guard let latencyMs else { return BrandTokens.charcoal }
        if latencyMs > 50 { return BrandTokens.red }
        if latencyMs > 16.7 { return BrandTokens.gold }
        return BrandTokens.timerGreen
    }

    private func skewTint(_ skewMs: Double) -> Color {
        if skewMs > 33.4 { return BrandTokens.red }
        if skewMs > 16.7 { return BrandTokens.gold }
        return BrandTokens.timerGreen
    }

    private func sectionBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(BrandTokens.mono(size: 8))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func metricBadge(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(BrandTokens.mono(size: 8))
                .foregroundStyle(BrandTokens.warmGrey)
            Text(value)
                .font(BrandTokens.mono(size: 8))
                .foregroundStyle(BrandTokens.offWhite)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(tint.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func sourceReadinessLabel(for sourceID: String?) -> String {
        guard let sourceID,
              let source = shellState.workspace.sources.first(where: { $0.id == sourceID }) else {
            return "COLD"
        }
        if source.isWarm {
            return "WARM"
        }
        if source.isWarming {
            return "ARM"
        }
        if source.isConnected {
            return "CONN"
        }
        return "DISC"
    }

    private func sourceReadinessTint(for sourceID: String?) -> Color {
        guard let sourceID,
              let source = shellState.workspace.sources.first(where: { $0.id == sourceID }) else {
            return BrandTokens.charcoal
        }
        if source.isWarm {
            return BrandTokens.timerGreen
        }
        if source.isWarming {
            return BrandTokens.gold
        }
        if source.isConnected {
            return BrandTokens.timerYellow
        }
        return BrandTokens.charcoal
    }

    private func controlButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(BrandTokens.display(size: 11, weight: .medium))
            .frame(maxWidth: .infinity)
    }
}

private struct OutputSlotBank: View {
    let card: RoomControlOutputCardState
    let shellState: FeatureShellState
    @ObservedObject var store: RoomControlWorkspaceStore

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 8)],
            spacing: 8
        ) {
            ForEach(card.slots) { slot in
                OutputSlotCell(card: card, slot: slot, shellState: shellState, store: store)
            }
        }
    }
}

private struct LiveOutputSurfacePreview: View {
    let renderFeed: OutputTileRenderFeed
    let previewState: OutputPreviewState
    let surfaceLabel: String
    let standbyLabel: String
    let showsAudioMeters: Bool
    let audioMuted: Bool
    let leftLevel: Double
    let rightLevel: Double
    let inset: AnyView?

    var body: some View {
        ZStack {
            OutputSurfaceMetalView(renderFeed: renderFeed)

            VStack {
                HStack {
                    Spacer()
                    Text(
                        previewState == .live
                            ? surfaceLabel
                            : (previewState == .fault ? "FAULT / NO FRAME" : standbyLabel)
                    )
                        .font(BrandTokens.mono(size: 8))
                        .foregroundStyle(BrandTokens.offWhite)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            (previewState == .fault ? BrandTokens.red : Color.black)
                                .opacity(0.78)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Spacer()
            }
            .padding(8)

            if showsAudioMeters {
                HStack(spacing: 4) {
                    OutputMeterBar(level: leftLevel, muted: audioMuted)
                    OutputMeterBar(level: rightLevel, muted: audioMuted)
                }
                .padding(.vertical, 10)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }

            if let inset {
                inset
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct OutputSlotCell: View {
    let card: RoomControlOutputCardState
    let slot: RoomControlOutputSlotState
    let shellState: FeatureShellState
    @ObservedObject var store: RoomControlWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(slot.id)
                    .font(BrandTokens.mono(size: 9))
                    .foregroundStyle(BrandTokens.warmGrey)
                Spacer()
                if isProgram {
                    miniBadge("PGM", tint: BrandTokens.pgnGreen)
                } else if isPreview {
                    miniBadge(
                        isPreviewSeamlessReady ? "PVW" : "ARM",
                        tint: isPreviewSeamlessReady ? BrandTokens.pvwRed : BrandTokens.gold
                    )
                } else if slot.sourceID == nil {
                    miniBadge("EMPTY", tint: BrandTokens.charcoal)
                } else if slot.isAvailable == false {
                    miniBadge("OFF", tint: Color(hex: 0x6B7280))
                }
            }

            Text(slot.sourceName ?? "Empty Slot")
                .font(BrandTokens.display(size: 11, weight: .medium))
                .foregroundStyle(slot.sourceID == nil ? BrandTokens.warmGrey : BrandTokens.offWhite.opacity(slot.isAvailable ? 1 : 0.7))
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)

            Text(slotAvailabilityLabel)
                .font(BrandTokens.mono(size: 8))
                .foregroundStyle(BrandTokens.warmGrey)
                .lineLimit(1)

            HStack(spacing: 6) {
                stateButton(
                    "PVW",
                    active: isPreview,
                    tint: isPreview
                        ? (isPreviewSeamlessReady ? BrandTokens.pvwRed : BrandTokens.gold)
                        : BrandTokens.pvwRed
                ) {
                    store.setPreviewSlot(card.id, slotID: isPreview ? nil : slot.id)
                }
                .disabled(slotCanPreview == false)

                stateButton("PGM", active: isProgram, tint: BrandTokens.pgnGreen) {
                    store.takeProgramSlot(card.id, slotID: slot.id)
                }
                .disabled(slotCanSwitch == false)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Color.white.opacity(isProgram || isPreview ? 0.06 : 0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: isProgram || isPreview ? 1.2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            ForEach(shellState.workspace.sources) { source in
                Button {
                    store.assignSource(source.id, to: card.id, slotID: slot.id)
                } label: {
                    if slot.sourceID == source.id {
                        Label(sourceMenuName(for: source), systemImage: "checkmark")
                    } else {
                        Text(sourceMenuName(for: source))
                    }
                }
            }

            Divider()

            Button("Clear Slot", role: .destructive) {
                store.clearOutputSlot(card.id, slotID: slot.id)
            }
            .disabled(slot.sourceID == nil)

            if isPreview {
                Button("Clear Preview") {
                    store.setPreviewSlot(card.id, slotID: nil)
                }
            } else {
                Button("Arm Preview") {
                    store.setPreviewSlot(card.id, slotID: slot.id)
                }
                .disabled(slotCanPreview == false)
            }

            Button("Take Program") {
                store.takeProgramSlot(card.id, slotID: slot.id)
            }
            .disabled(slotCanSwitch == false)
        }
    }

    private var isProgram: Bool {
        card.programSlotID == slot.id
    }

    private var isPreview: Bool {
        card.previewSlotID == slot.id
    }

    private var slotHasAssignedSource: Bool {
        slot.sourceID != nil
    }

    private var slotCanSwitch: Bool {
        slotHasAssignedSource
    }

    private var slotCanPreview: Bool {
        slotHasAssignedSource && isProgram == false
    }

    private var isPreviewSeamlessReady: Bool {
        guard isPreview, let sourceID = slot.sourceID else { return false }
        return shellState.workspace.sources.first(where: { $0.id == sourceID })?.isWarm == true
    }

    private var slotAvailabilityLabel: String {
        if slot.sourceID == nil {
            return "No source assigned"
        }
        if isPreview && isPreviewSeamlessReady == false {
            return "Warming for seamless take"
        }
        return slot.isAvailable ? "Source available" : "Source unavailable"
    }

    private var borderColor: Color {
        if isProgram {
            return BrandTokens.pgnGreen
        }
        if isPreview {
            return isPreviewSeamlessReady ? BrandTokens.pvwRed : BrandTokens.gold
        }
        return BrandTokens.charcoal
    }

    private func stateButton(_ title: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(active ? tint : BrandTokens.charcoal)
            .controlSize(.small)
            .font(BrandTokens.mono(size: 10))
            .frame(maxWidth: .infinity)
    }

    private func miniBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(BrandTokens.mono(size: 9))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func sourceMenuName(for source: RouterWorkspaceSourceState) -> String {
        if source.details.isEmpty {
            return source.name
        }
        return "\(source.name) • \(source.details)"
    }
}

private struct OutputMeterBar: View {
    let level: Double
    let muted: Bool

    var body: some View {
        GeometryReader { geometry in
            let clampedLevel = max(0, min(level, 1))
            let fillHeight = max(2, geometry.size.height * clampedLevel)
            let palette = muted
                ? [Color(hex: 0x4A5568), Color(hex: 0x718096), Color(hex: 0xDD8B20)]
                : [Color(hex: 0x1FC05E), Color(hex: 0xE0B238), Color(hex: 0xD84A3B)]

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: palette,
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: fillHeight)
                    .padding(.horizontal, 1)
                    .padding(.bottom, 1)
            }
        }
        .frame(width: 8)
    }
}

private struct CapacityStatusBar: View {
    let shellState: FeatureShellState
    let validation: NDIWizardValidationSnapshot

    var body: some View {
        HStack(spacing: 14) {
            statusCell("Sources", "\(shellState.workspace.sources.count)")
            statusCell("Finder", "\(validation.finderSourceVisibilityCount)")
            statusCell("Listener", "\(validation.listenerSenderVisibilityCount)")
            statusCell("Recv", "\(validation.totalReceiveConnectionCount)")
            statusCell("Drops", "\(validation.totalDroppedVideoFrames)")
            statusCell("Queue", "\(validation.worstCurrentQueueDepth)")
            statusCell("Latency", validation.latencyBucketLabel)
            statusCell("Outputs", "\(shellState.workspace.cards.count)")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(BrandTokens.toolbarDark)
    }

    private func statusCell(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(BrandTokens.display(size: 11, weight: .medium))
                .foregroundStyle(BrandTokens.warmGrey)
            Text(value)
                .font(BrandTokens.mono(size: 11))
                .foregroundStyle(BrandTokens.offWhite)
        }
    }
}

private func panelHeader(_ title: String) -> some View {
    Text(title)
        .font(BrandTokens.display(size: 11, weight: .semibold))
        .foregroundStyle(BrandTokens.warmGrey)
        .tracking(1.2)
}

private func chipRow(_ chips: [String]) -> some View {
    HStack(spacing: 6) {
        ForEach(chips, id: \.self) { chip in
            Text(chip)
                .font(BrandTokens.mono(size: 9))
                .foregroundStyle(BrandTokens.offWhite)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(BrandTokens.charcoal)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title)
            .font(BrandTokens.display(size: 14, weight: .semibold))
            .foregroundStyle(BrandTokens.gold)
        content()
    }
    .padding(16)
    .background(BrandTokens.panelDark)
    .clipShape(RoundedRectangle(cornerRadius: 16))
}
