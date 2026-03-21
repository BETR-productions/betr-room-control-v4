// RoomControlShellView — three-column resizable operator shell.
// Left: sources/inputs. Center: outputs/routing. Right: tools/settings.

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

    public init(state: ShellViewState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
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
            // 1–6: select slot in focused output (Task 130)
            if let digit = Int(String(press.characters)), digit >= 1, digit <= 6 {
                handleSlotSelect(digit)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("BËTR Room Control")
                .font(BrandTokens.display(size: 16, weight: .bold))
                .foregroundStyle(BrandTokens.gold)

            modeBadge

            Spacer()

            headerStat("\(activeOutputCount) active", icon: "dot.radiowaves.left.and.right")
            headerStat("\(state.sources.count) sources", icon: "antenna.radiowaves.left.and.right")

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

    // MARK: - Columns

    private var leftColumn: some View {
        SourceBrowserView(state: state)
            .background(BrandTokens.dark)
    }

    /// Returns true if this source is a BËTR presentation slot.
    private func isPresentationSlot(_ source: SourceState) -> Bool {
        source.name == PresentationSlotNames.slideshow
            || source.name == PresentationSlotNames.presenterView
    }

    /// Source row with distinctive gold star icon for presentation slots (Task 97).
    private func sourceRow(_ source: SourceState) -> some View {
        HStack(spacing: 8) {
            if isPresentationSlot(source) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(BrandTokens.gold)
                    .frame(width: 8)
            } else {
                Circle()
                    .fill(source.isOnline ? .green : BrandTokens.warmGrey)
                    .frame(width: 8, height: 8)
            }
            Text(source.name)
                .font(BrandTokens.display(size: 12))
                .foregroundStyle(
                    isPresentationSlot(source)
                        ? BrandTokens.gold
                        : (source.isOnline ? BrandTokens.offWhite : BrandTokens.warmGrey)
                )
            if isPresentationSlot(source) {
                Spacer()
                warmBadgeDot(source.warmBadge)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// Task 98: Auto-warm indicator — pulses gold during .warming, solid green when .warm.
    private func warmBadgeDot(_ badge: WarmBadge) -> some View {
        WarmBadgeDotView(badge: badge)
    }

    private func warmBadgeColor(_ badge: WarmBadge) -> Color {
        switch badge {
        case .cold: return BrandTokens.warmGrey
        case .warming: return BrandTokens.gold
        case .warm: return BrandTokens.pgnGreen
        case .failed: return BrandTokens.red
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            // Header: title + capacity + add button (Task 122)
            centerColumnHeader

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
                        centerColumnEmptyState
                    }
                }
                .padding(12)
            }
        }
        .background(BrandTokens.dark)
    }

    // MARK: - Center Column Header (Task 122)

    private var centerColumnHeader: some View {
        HStack(spacing: 8) {
            panelHeader("OUTPUTS")

            // Capacity indicator (Task 129)
            Text("\(state.cards.count)/\(ShellViewState.maxOutputs)")
                .font(BrandTokens.mono(size: 10))
                .foregroundStyle(outputCapacityColor)

            Spacer()

            // Add output button (Task 122)
            Button {
                state.addOutput()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.cards.count >= ShellViewState.maxOutputs)
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

    private var centerColumnEmptyState: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(BrandTokens.warmGrey.opacity(0.5))
            Text("No outputs configured")
                .font(BrandTokens.display(size: 12, weight: .medium))
                .foregroundStyle(BrandTokens.warmGrey)
            Text("Click + to add an output")
                .font(BrandTokens.mono(size: 9))
                .foregroundStyle(BrandTokens.warmGrey.opacity(0.6))
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var rightColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                panelHeader("TOOLS")
                    .padding(16)
                Text("Settings and tools panel")
                    .font(BrandTokens.display(size: 12))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .padding(.horizontal, 16)
            }
        }
        .background(BrandTokens.dark)
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

    // MARK: - Helpers

    // MARK: - Keyboard Shortcuts (Task 130)

    /// Handle 1–6 key press: arm PVW on the corresponding slot in the focused output.
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

    private func panelHeader(_ title: String) -> some View {
        Text(title)
            .font(BrandTokens.display(size: 11, weight: .semibold))
            .foregroundStyle(BrandTokens.warmGrey)
            .tracking(1.2)
    }
}

// MARK: - Warm Badge Dot (Task 98)

/// Animated warm badge indicator: pulses gold during .warming, solid green when .warm.
private struct WarmBadgeDotView: View {
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
