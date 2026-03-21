// OutputSlotCell — individual slot cell with SMALL PVW/PGM buttons.
// v3 layout: VStack(spacing: 8), 10pt padding, minHeight 112pt.
// Row 1: Slot ID (mono 9pt) + mini badge (PGM/PVW/EMPTY/OFF)
// Row 2: Source name (11pt medium, 2 lines, 30pt min)
// Row 3: Availability (mono 8pt, warmGrey)
// Row 4: PVW + PGM buttons (borderProminent, small, mono 10pt, 6pt spacing)

import PresentationDomain
import RoutingDomain
import SwiftUI

struct OutputSlotCell: View {
    let card: OutputCardState
    let slot: OutputSlotState
    @ObservedObject var state: ShellViewState
    /// Emergency cold-cut confirmation: true after first tap on non-warm PGM.
    @State private var coldCutPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: Slot ID + state badge
            HStack {
                Text(slot.id)
                    .font(BrandTokens.mono(size: 9))
                    .foregroundStyle(BrandTokens.warmGrey)
                Spacer()
                if isProgram {
                    miniBadge("PGM", tint: BrandTokens.pgnGreen)
                } else if isPreview {
                    miniBadge("PVW", tint: BrandTokens.pvwRed)
                } else if slot.sourceID == nil {
                    miniBadge("EMPTY", tint: BrandTokens.charcoal)
                } else if !slot.isAvailable {
                    miniBadge("OFF", tint: Color(hex: 0x6B7280))
                }
            }

            // Row 2: Source name (11pt medium, 2 lines, 30pt min)
            HStack(spacing: 4) {
                if slot.sourceID != nil {
                    warmBadgeIndicator
                }
                Text(slot.displayName ?? "Empty Slot")
                    .font(BrandTokens.display(size: 11, weight: .medium))
                    .foregroundStyle(
                        slot.sourceID == nil
                            ? BrandTokens.warmGrey
                            : BrandTokens.offWhite.opacity(slot.isAvailable ? 1 : 0.7)
                    )
                    .lineLimit(2)
                    .frame(minHeight: 30, alignment: .topLeading)
            }

            // Row 3: Availability (mono 8pt, warmGrey)
            Text(availabilityLabel)
                .font(BrandTokens.mono(size: 8))
                .foregroundStyle(BrandTokens.warmGrey)

            // Row 4: PVW + PGM buttons — SMALL, share width equally
            HStack(spacing: 6) {
                stateButton("PVW", active: isPreview, tint: BrandTokens.pvwRed) {
                    state.setPreviewSlot(card.id, slotID: isPreview ? nil : slot.id)
                }
                .disabled(!pvwEnabled)

                stateButton(pgmButtonLabel, active: isProgram, tint: pgmButtonTint) {
                    handlePGMTap()
                }
                .disabled(!pgmEnabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Color.white.opacity(isProgram || isPreview ? 0.06 : 0.03))
        .overlay(warmBadgeRing)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: isProgram || isPreview ? 1.2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: String.self) { items, _ in
            guard let sourceID = items.first else { return false }
            state.assignSource(sourceID, to: card.id, slotID: slot.id)
            return true
        }
        .contextMenu {
            ForEach(state.sources) { source in
                Button {
                    state.assignSource(source.id, to: card.id, slotID: slot.id)
                } label: {
                    let isPresentationSource =
                        source.name == SlideShowProducer.slotName
                        || source.name == PresenterViewProducer.slotName
                    if slot.sourceID == source.id {
                        Label(source.name, systemImage: "checkmark")
                    } else if isPresentationSource {
                        Label(source.name, systemImage: "star.fill")
                    } else {
                        Text(source.name)
                    }
                }
            }

            Divider()

            Button("Clear Slot", role: .destructive) {
                state.clearSlot(card.id, slotID: slot.id)
            }
            .disabled(slot.sourceID == nil)

            if isPreview {
                Button("Clear Preview") {
                    state.setPreviewSlot(card.id, slotID: nil)
                }
            } else {
                Button("Arm Preview") {
                    state.setPreviewSlot(card.id, slotID: slot.id)
                }
                .disabled(!pvwEnabled)
            }

            Button("Take Program") {
                state.takeProgramSlot(card.id, slotID: slot.id)
            }
            .disabled(!pgmEnabled)
        }
    }

    // MARK: - State

    private var isProgram: Bool { card.programSlotID == slot.id }
    private var isPreview: Bool { card.previewSlotID == slot.id }
    private var hasSource: Bool { slot.sourceID != nil && slot.isAvailable }
    private var isWarmOrWarming: Bool { slot.warmBadge == .warm || slot.warmBadge == .warming }

    /// PVW: requires source + available + not program + warm or warming.
    private var pvwEnabled: Bool { hasSource && !isProgram && isWarmOrWarming }

    /// PGM normal: requires warm source. Emergency cold cut: double-tap allowed.
    private var pgmEnabled: Bool { hasSource }
    private var pgmIsWarm: Bool { slot.warmBadge == .warm }

    private var pgmButtonLabel: String {
        if coldCutPending { return "CONFIRM" }
        return "PGM"
    }

    private var pgmButtonTint: Color {
        if coldCutPending { return BrandTokens.red }
        return BrandTokens.pgnGreen
    }

    private var availabilityLabel: String {
        if slot.sourceID == nil { return "No source" }
        if !slot.isAvailable { return "Offline" }
        switch slot.warmBadge {
        case .warm: return "Warm"
        case .warming: return "Warming..."
        case .failed: return "Failed"
        case .cold: return "Online"
        }
    }

    private func handlePGMTap() {
        if pgmIsWarm || isProgram {
            coldCutPending = false
            state.takeProgramSlot(card.id, slotID: slot.id)
        } else if coldCutPending {
            coldCutPending = false
            state.takeProgramSlot(card.id, slotID: slot.id)
        } else {
            coldCutPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                coldCutPending = false
            }
        }
    }

    private var borderColor: Color {
        if isProgram { return BrandTokens.pgnGreen }
        if isPreview { return BrandTokens.pvwRed }
        return BrandTokens.charcoal
    }

    // MARK: - Warm Badge Ring

    @ViewBuilder
    private var warmBadgeRing: some View {
        switch slot.warmBadge {
        case .warming:
            WarmPulsingRing(color: BrandTokens.gold)
        case .warm:
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(BrandTokens.pgnGreen, lineWidth: 2)
        case .failed:
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(BrandTokens.red, lineWidth: 2)
        case .cold:
            EmptyView()
        }
    }

    // MARK: - Subviews

    private func stateButton(_ title: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(active ? tint : BrandTokens.charcoal)
            .controlSize(.small)
            .font(BrandTokens.mono(size: 10))
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var warmBadgeIndicator: some View {
        Circle()
            .fill(warmBadgeColor)
            .frame(width: 6, height: 6)
    }

    private var warmBadgeColor: Color {
        switch slot.warmBadge {
        case .cold: return BrandTokens.warmGrey
        case .warming: return BrandTokens.gold
        case .warm: return BrandTokens.pgnGreen
        case .failed: return BrandTokens.red
        }
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
}

// MARK: - Warm Pulsing Ring (gold, animated)

private struct WarmPulsingRing: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(color, lineWidth: 2)
            .opacity(isPulsing ? 1.0 : 0.3)
            .animation(
                .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Slot Bank (grid layout)

struct OutputSlotBank: View {
    let card: OutputCardState
    @ObservedObject var state: ShellViewState

    private static let defaultColumnCount = 3

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(card.slots) { slot in
                    OutputSlotCell(card: card, slot: slot, state: state)
                        .frame(minWidth: 108, maxWidth: .infinity)
                }
            }

            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(row) { slot in
                            OutputSlotCell(card: card, slot: slot, state: state)
                                .frame(minWidth: 108, maxWidth: .infinity)
                        }
                        ForEach(row.count..<Self.defaultColumnCount, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var rows: [[OutputSlotState]] {
        guard !card.slots.isEmpty else { return [] }
        var result: [[OutputSlotState]] = []
        var i = 0
        while i < card.slots.count {
            let end = min(i + Self.defaultColumnCount, card.slots.count)
            result.append(Array(card.slots[i..<end]))
            i = end
        }
        return result
    }
}
