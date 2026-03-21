// RoomControlShellView — three-column resizable operator shell.
// V3 layout match (Task 131):
//   Left:   Source browser + Clip player + Timer
//   Center: Presentation controls + Presenter view (slide notes)
//   Right:  Output grid with add button + scrollable output tiles

import AppKit
import PresentationDomain
import RoutingDomain
import SwiftUI

/// Well-known static slot names for presentation sources.
private enum PresentationSlotNames {
    static let slideshow = SlideShowProducer.slotName
    static let presenterView = PresenterViewProducer.slotName
}

public struct RoomControlShellView: View {
    @ObservedObject var state: ShellViewState

    @State private var leadingColumnWidth: Double = 340
    @State private var centerColumnWidth: Double = 340
    @StateObject private var wizardState = NDIWizardState()
    @StateObject private var permissionCenter = PermissionCenter()

    public init(state: ShellViewState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            permissionBanners
            toolbar
            Divider().background(BrandTokens.charcoal)
            GeometryReader { geometry in
                let clamped = clampedWidths(totalWidth: geometry.size.width)
                HStack(spacing: 0) {
                    leftColumn
                        .frame(width: clamped.leading)
                    DividerHandle(.vertical) { delta in
                        leadingColumnWidth += delta
                    } onEnded: {
                        commitLayout(widths: clamped)
                    }
                    centerColumn
                        .frame(width: clamped.center)
                    DividerHandle(.vertical) { delta in
                        centerColumnWidth += delta
                    } onEnded: {
                        commitLayout(widths: clamped)
                    }
                    rightColumn
                        .frame(width: clamped.right)
                }
                .background(BrandTokens.dark)
            }
            Divider().background(BrandTokens.charcoal)
            CapacityStatusBar(state: state)
        }
        .background(BrandTokens.dark)
        .preferredColorScheme(.dark)
        .onAppear {
            syncLayoutFromState()
            state.ensureDefaultOutput()
            permissionCenter.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionCenter.refresh()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            // Shift+Tab: previous output (Task 130)
            if press.key == .tab, press.modifiers.contains(.shift) {
                state.focusPreviousCard()
                return .handled
            }
            // Tab: next output (Task 130)
            if press.key == .tab {
                state.focusNextCard()
                return .handled
            }
            // 1-6: select slot in focused output (Task 130)
            if let digit = Int(String(press.characters)), digit >= 1, digit <= 6 {
                handleSlotSelect(digit)
                return .handled
            }
            return .ignored
        }
        .sheet(isPresented: $state.showSettings) {
            settingsSheet
        }
    }

    // MARK: - Settings Sheet (Task 137)

    private var settingsSheet: some View {
        TabView {
            generalSettingsTab
                .tabItem { Label("General", systemImage: "gearshape") }
            NDIWizardSettingsView(wizard: wizardState)
                .tabItem { Label("NDI", systemImage: "network") }
            logsSettingsTab
                .tabItem { Label("Logs", systemImage: "doc.text") }
            updateSettingsTab
                .tabItem { Label("Update", systemImage: "arrow.down.circle") }
        }
        .frame(minWidth: 900, minHeight: 820)
        .background(BrandTokens.dark)
        .preferredColorScheme(.dark)
    }

    private var generalSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("General")
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        settingsRow("App", "BETR Room Control v4")
                        settingsRow("Bundle ID", Bundle.main.bundleIdentifier ?? "com.betr.room-control")
                        settingsRow("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                        settingsRow("Build", Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                        settingsRow("Outputs", "\(state.cards.count) / \(ShellViewState.maxOutputs)")
                        settingsRow("Sources", "\(state.sources.count) discovered")
                    }
                }
            }
            .padding(20)
        }
    }

    private var logsSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("Logs")
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("NDI runtime logs and diagnostics will appear here.")
                            .font(BrandTokens.display(size: 12))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }
                }
            }
            .padding(20)
        }
    }

    private var updateSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader("Update")
                settingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        settingsRow("Current Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                        settingsRow("Release Feed", "BETR-productions/betr-room-control-v4")
                        Text("Updates are checked automatically every 4 hours.")
                            .font(BrandTokens.display(size: 11))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }
                }
            }
            .padding(20)
        }
    }

    private func settingsHeader(_ title: String) -> some View {
        Text(title)
            .font(BrandTokens.display(size: 22, weight: .bold))
            .foregroundStyle(BrandTokens.offWhite)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandTokens.surfaceDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func settingsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(BrandTokens.display(size: 12, weight: .medium))
                .foregroundStyle(BrandTokens.warmGrey)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(BrandTokens.mono(size: 12))
                .foregroundStyle(BrandTokens.offWhite)
                .textSelection(.enabled)
        }
    }

    // MARK: - Permission Banners (Task 142)

    @ViewBuilder
    private var permissionBanners: some View {
        VStack(spacing: 0) {
            if !permissionCenter.screenRecordingGranted {
                permissionBannerRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording Permission Required",
                    message: "BETR Room Control needs Screen Recording access to capture presentation windows.",
                    actionTitle: "Grant Screen Recording",
                    action: { permissionCenter.requestScreenRecording() }
                )
            }
            if !permissionCenter.accessibilityGranted {
                permissionBannerRow(
                    icon: "accessibility",
                    title: "Accessibility Permission Required",
                    message: "BETR Room Control needs Accessibility access to control PowerPoint and Keynote.",
                    actionTitle: "Grant Accessibility",
                    action: { permissionCenter.requestAccessibility() }
                )
            }
        }
    }

    private func permissionBannerRow(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(BrandTokens.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrandTokens.display(size: 13, weight: .semibold))
                    .foregroundStyle(BrandTokens.white)
                Text(message)
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(BrandTokens.display(size: 11, weight: .medium))
                .foregroundStyle(BrandTokens.dark)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(BrandTokens.gold)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(BrandTokens.gold.opacity(0.12))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("BETR Room Control")
                .font(BrandTokens.display(size: 16, weight: .bold))
                .foregroundStyle(BrandTokens.gold)

            modeBadge

            // Task 138: Playback mode picker (v3 match)
            Picker(
                "Playback",
                selection: $state.playbackMode
            ) {
                Text("Manual").tag(PlaybackMode.manual)
                Text("Schedule").tag(PlaybackMode.schedule)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)

            // Task 138: Operation mode picker (v3 match)
            Picker(
                "Operation",
                selection: $state.operationMode
            ) {
                Text("Rehearsal").tag(OperationMode.rehearsal)
                Text("Live").tag(OperationMode.live)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)

            Spacer()

            headerStat("\(activeOutputCount) active", icon: "dot.radiowaves.left.and.right")

            // Task 138: XPC status dots (v3 match)
            xpcStatusDots

            headerStat("\(state.sources.count) sources", icon: "antenna.radiowaves.left.and.right")

            // Task 138: Discovery chip (v3 match)
            discoveryChip

            Button {
                state.showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(state.operationMode == .live ? BrandTokens.liveRed : BrandTokens.toolbarDark)
    }

    private var modeBadge: some View {
        Text(state.operationMode == .live ? "LIVE" : "REHEARSAL")
            .font(BrandTokens.mono(size: 10))
            .foregroundStyle(BrandTokens.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.operationMode == .live ? BrandTokens.red : BrandTokens.charcoal)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Task 138: XPC status dots — one per output card, colored by program state.
    private var xpcStatusDots: some View {
        HStack(spacing: 4) {
            ForEach(state.cards) { card in
                Circle()
                    .fill(xpcDotColor(for: card))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func xpcDotColor(for card: OutputCardState) -> Color {
        if card.programSlotID != nil {
            return .green
        }
        return BrandTokens.warmGrey
    }

    /// Task 138: Discovery chip — shows discovery server connection state.
    private var discoveryChip: some View {
        Text("mDNS")
            .font(BrandTokens.mono(size: 10))
            .foregroundStyle(BrandTokens.gold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(BrandTokens.gold.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func headerStat(_ label: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(BrandTokens.mono(size: 11))
        }
        .foregroundStyle(BrandTokens.warmGrey)
    }

    private var activeOutputCount: Int {
        state.cards.filter { $0.programSlotID != nil }.count
    }

    // MARK: - Left Column (v3: Sources + Clip Player + Timer)

    private var leftColumn: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Task 113/143: Source browser at top with warm badges
                SourceBrowserView(state: state)

                Divider().background(BrandTokens.charcoal)

                // Task 132: Clip player playlist panel
                if let clipStore = state.clipPlayerStore {
                    ClipPlayerPlaylistView(store: clipStore)
                    Divider().background(BrandTokens.charcoal)
                }

                // Task 133: Timer control panel
                if let timerStore = state.timerStore {
                    TimerControlView(store: timerStore)
                }
            }
        }
        .background(BrandTokens.dark)
    }

    // MARK: - Center Column (v3: Presentation + Presenter View)

    private var centerColumn: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Task 134: Presentation launcher panel
                PresentationLauncherView(store: state.presentationStore)

                Divider().background(BrandTokens.charcoal)

                // Task 135: Presenter view panel (slide notes)
                presenterViewPanel
            }
        }
        .background(BrandTokens.dark)
    }

    /// Presenter view panel — shows slide notes when available, placeholder otherwise.
    /// Matches v3 PresenterStatusPanel layout.
    private var presenterViewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader("PRESENTER VIEW")

            Text("Slide notes and presenter state will appear here once slideshow mode is verified.")
                .font(BrandTokens.display(size: 12))
                .foregroundStyle(BrandTokens.warmGrey)
        }
        .padding(16)
        .background(BrandTokens.surfaceDark)
    }

    // MARK: - Right Column (v3: Output Grid — moved from center)

    private var rightColumn: some View {
        VStack(spacing: 0) {
            // Header: title + capacity + add button (Task 122/136)
            outputColumnHeader

            Divider()
                .background(BrandTokens.charcoal)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(state.cards) { card in
                        OutputCardView(
                            card: card,
                            state: state,
                            isFocused: state.focusedCardID == card.id
                        )
                    }
                    if state.cards.isEmpty {
                        outputEmptyState
                    }
                }
                .padding(12)
            }
        }
        .background(BrandTokens.dark)
    }

    // MARK: - Output Column Header (Task 122, moved to right column Task 136)

    private var outputColumnHeader: some View {
        HStack(spacing: 8) {
            panelHeader("OUTPUTS")

            // Capacity indicator (Task 129)
            Text("\(state.cards.count)/\(ShellViewState.maxOutputs)")
                .font(BrandTokens.mono(size: 10))
                .foregroundStyle(outputCapacityColor)

            Spacer()

            // Add output button — gold accent (Task 136)
            Button {
                state.addOutput()
            } label: {
                Label("Add Output", systemImage: "plus")
                    .font(BrandTokens.display(size: 11, weight: .medium))
                    .foregroundStyle(BrandTokens.dark)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(BrandTokens.gold)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(state.cards.count >= ShellViewState.maxOutputs)
            .opacity(state.cards.count >= ShellViewState.maxOutputs ? 0.4 : 1.0)
            .help("Add output (\(ShellViewState.maxOutputs - state.cards.count) available)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var outputCapacityColor: Color {
        let count = state.cards.count
        let max = ShellViewState.maxOutputs
        if count >= max { return BrandTokens.red }
        if count >= Int(ceil(Double(max) * 0.8)) { return BrandTokens.gold }
        return BrandTokens.warmGrey
    }

    private var outputEmptyState: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(BrandTokens.warmGrey.opacity(0.5))
            Text("No outputs configured")
                .font(BrandTokens.display(size: 12, weight: .medium))
                .foregroundStyle(BrandTokens.warmGrey)
            Text("Click \"Add Output\" to create one")
                .font(BrandTokens.mono(size: 9))
                .foregroundStyle(BrandTokens.warmGrey.opacity(0.6))
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Layout

    private func clampedWidths(totalWidth: CGFloat) -> (leading: CGFloat, center: CGFloat, right: CGFloat) {
        let minimumLeading: CGFloat = 280
        let minimumCenter: CGFloat = 280
        let minimumRight: CGFloat = 360
        guard totalWidth > 0 else {
            return (CGFloat(leadingColumnWidth), CGFloat(centerColumnWidth), minimumRight)
        }
        let maxLeading = max(minimumLeading, totalWidth - minimumCenter - minimumRight - 12)
        let leading = min(max(CGFloat(leadingColumnWidth), minimumLeading), maxLeading)
        let maxCenter = max(minimumCenter, totalWidth - leading - minimumRight - 12)
        let center = min(max(CGFloat(centerColumnWidth), minimumCenter), maxCenter)
        let right = max(minimumRight, totalWidth - leading - center - 12)
        return (leading, center, right)
    }

    private func commitLayout(widths: (leading: CGFloat, center: CGFloat, right: CGFloat)) {
        state.commitLayout(leading: widths.leading, center: widths.center)
    }

    private func syncLayoutFromState() {
        leadingColumnWidth = state.leadingColumnWidth
        centerColumnWidth = state.centerColumnWidth
    }

    // MARK: - Keyboard Shortcuts (Task 130)

    /// Handle 1-6 key press: arm PVW on the corresponding slot in the focused output.
    private func handleSlotSelect(_ index: Int) {
        guard let cardID = state.focusedCardID,
              let card = state.cards.first(where: { $0.id == cardID }),
              index >= 1, index <= card.slots.count else { return }
        let slot = card.slots[index - 1]
        // Toggle preview on the selected slot
        if card.previewSlotID == slot.id {
            state.setPreviewSlot(cardID, slotID: nil)
        } else {
            state.setPreviewSlot(cardID, slotID: slot.id)
        }
    }

    // MARK: - Helpers

    private func panelHeader(_ title: String) -> some View {
        Text(title)
            .font(BrandTokens.display(size: 11, weight: .semibold))
            .foregroundStyle(BrandTokens.warmGrey)
            .tracking(1.2)
    }
}

// MARK: - Warm Badge Dot (Task 98)

/// Animated warm badge indicator: pulses gold during .warming, solid green when .warm.
struct WarmBadgeDotView: View {
    let badge: WarmBadge
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: 6, height: 6)
            .opacity(badge == .warming ? (isPulsing ? 1.0 : 0.3) : 1.0)
            .animation(
                badge == .warming
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if badge == .warming { isPulsing = true }
            }
            .onChange(of: badge) { _, newBadge in
                isPulsing = newBadge == .warming
            }
    }

    private var fillColor: Color {
        switch badge {
        case .cold: return BrandTokens.warmGrey
        case .warming: return BrandTokens.gold
        case .warm: return BrandTokens.pgnGreen
        case .failed: return BrandTokens.red
        }
    }
}
