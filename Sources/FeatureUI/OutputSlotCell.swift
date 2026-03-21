// OutputSlotCell — individual slot cell with PVW/PGM buttons.
// 108pt min width, 112pt min height, cardBlack background, 8pt corners.

import SwiftUI

struct OutputSlotCell: View {
    let card: OutputCardState
    let slot: OutputSlotState
    @ObservedObject var state: ShellViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: slot ID + state badge
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

            // Source name
            Text(slot.displayName ?? "Empty Slot")
                .font(BrandTokens.display(size: 11, weight: .medium))
                .foregroundStyle(
                    slot.sourceID == nil
                        ? BrandTokens.warmGrey
                        : BrandTokens.offWhite.opacity(slot.isAvailable ? 1 : 0.7)
                )
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)

            // Status
            Text(slot.sourceID == nil ? "No source assigned" : (slot.isAvailable ? "Source available" : "Source unavailable"))
                .font(BrandTokens.mono(size: 8))
                .foregroundStyle(BrandTokens.warmGrey)
                .lineLimit(1)

            // PVW / PGM buttons — always visible
            HStack(spacing: 6) {
                stateButton("PVW", active: isPreview, tint: BrandTokens.pvwRed) {
                    state.setPreviewSlot(card.id, slotID: isPreview ? nil : slot.id)
                }
                .disabled(!slotCanPreview)

                stateButton("PGM", active: isProgram, tint: BrandTokens.pgnGreen) {
                    state.takeProgramSlot(card.id, slotID: slot.id)
                }
                .disabled(!slotCanSwitch)
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
            ForEach(state.sources) { source in
                Button {
                    state.assignSource(source.id, to: card.id, slotID: slot.id)
                } label: {
                    if slot.sourceID == source.id {
                        Label(source.name, systemImage: "checkmark")
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
                .disabled(!slotCanPreview)
            }

            Button("Take Program") {
                state.takeProgramSlot(card.id, slotID: slot.id)
            }
            .disabled(!slotCanSwitch)
        }
    }

    // MARK: - State

    private var isProgram: Bool { card.programSlotID == slot.id }
    private var isPreview: Bool { card.previewSlotID == slot.id }
    private var slotCanSwitch: Bool { slot.sourceID != nil && slot.isAvailable }
    private var slotCanPreview: Bool { slotCanSwitch && !isProgram }

    private var borderColor: Color {
        if isProgram { return BrandTokens.pgnGreen }
        if isPreview { return BrandTokens.pvwRed }
        return BrandTokens.charcoal
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
