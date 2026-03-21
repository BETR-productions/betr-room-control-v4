// RoomControlShellView — three-column resizable operator shell.
// Left: sources/inputs. Center: outputs/routing. Right: tools/settings.

import SwiftUI

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

    private var centerColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                panelHeader("OUTPUTS")
                    .padding(16)
                ForEach(state.cards) { card in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(card.name)
                                .font(BrandTokens.display(size: 13, weight: .semibold))
                                .foregroundStyle(BrandTokens.offWhite)
                            Spacer()
                            // Audio meters for the program source on this card
                            if let pgmSlotID = card.programSlotID,
                               let pgmSlot = card.slots.first(where: { $0.id == pgmSlotID }) {
                                OutputCardAudioMeter(sourceID: pgmSlot.sourceID, state: state)
                            }
                        }
                        OutputSlotBank(card: card, state: state)
                    }
                    .padding(12)
                }
                if state.cards.isEmpty {
                    Text("No outputs configured")
                        .font(BrandTokens.display(size: 12))
                        .foregroundStyle(BrandTokens.warmGrey)
                        .padding(16)
                }
            }
        }
        .background(BrandTokens.dark)
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

    private func panelHeader(_ title: String) -> some View {
        Text(title)
            .font(BrandTokens.display(size: 11, weight: .semibold))
            .foregroundStyle(BrandTokens.warmGrey)
            .tracking(1.2)
    }
}
