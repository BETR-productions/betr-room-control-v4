// OutputCardView — v3 HORIZONTAL OutputPreviewTile layout.
// Left: 312pt preview section (header, live 312×176, source info).
// Middle: flexible OutputSlotBank (3-col ViewThatFits, minWidth 108pt).
// Right: 108pt control column (Mute, Solo, Actions).

import RoutingDomain
import SwiftUI

struct OutputCardView: View {
    let card: OutputCardState
    @ObservedObject var state: ShellViewState
    let isFocused: Bool

    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showDeleteConfirmation = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left section: 312pt fixed — preview hero
            leftPreviewSection
                .frame(width: 312)

            // Middle section: flexible — slot bank
            OutputSlotBank(card: card, state: state)

            // Right section: 108pt fixed — control buttons
            rightControlSection
                .frame(width: 108)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 252, alignment: .topLeading)
        .background(BrandTokens.surfaceDark)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isFocused ? BrandTokens.gold : BrandTokens.charcoal,
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { state.focusedCardID = card.id }
        .contextMenu { cardContextMenu }
        .confirmationDialog(
            "Remove \(card.name)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Output", role: .destructive) {
                state.removeOutput(card.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This tears down the sender, removes its slots, and can leave the workspace with zero outputs.")
        }
    }

    // MARK: - Left Preview Section (312pt)

    private var leftPreviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: card name + listener badge + status pills
            HStack(spacing: 6) {
                if isEditingName {
                    TextField("Output name", text: $editedName)
                        .font(BrandTokens.display(size: 12, weight: .semibold))
                        .textFieldStyle(.plain)
                        .focused($nameFieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelEditing() }
                        .frame(maxWidth: 160)
                } else {
                    Text(card.name)
                        .font(BrandTokens.display(size: 12, weight: .semibold))
                        .foregroundStyle(BrandTokens.offWhite)
                        .onTapGesture(count: 2) { startEditing() }
                }

                Spacer(minLength: 8)
                listenerBadge

                statusPills
            }

            // Live preview: 312×176pt
            outputPreview
                .frame(width: 312, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(liveOutBadge, alignment: .topTrailing)
                .overlay(audioMetersOverlay, alignment: .bottomTrailing)

            // Source info: name + raster
            sourceInfoRow
        }
    }

    // MARK: - Status Pills (inline with header)

    @ViewBuilder
    private var statusPills: some View {
        let labels = buildStatusLabels()
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels, id: \.self) { label in
                    statusPill(label)
                }
            }
        }
    }

    private func buildStatusLabels() -> [String] {
        var labels: [String] = []
        if card.previewSlotID != nil { labels.append("PVW") }
        if card.programSlotID != nil { labels.append("PGM") }
        if card.isAudioMuted { labels.append("MUTED") }
        if card.isSoloed { labels.append("SOLO") }
        return labels
    }

    private func statusPill(_ label: String) -> some View {
        let tint: Color = switch label {
        case "PVW": Color(hex: 0xC73B33)
        case "PGM": Color(hex: 0x1F9D55)
        case "MUTED": Color(hex: 0xC97A16)
        case "SOLO": Color(hex: 0x2962D9)
        default: BrandTokens.charcoal
        }
        return Text(label)
            .font(BrandTokens.mono(size: 10))
            .foregroundStyle(BrandTokens.offWhite)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Live Preview (312×176)

    @ViewBuilder
    private var outputPreview: some View {
        if let pgmSlotID = card.programSlotID,
           let pgmSlot = card.slots.first(where: { $0.id == pgmSlotID }),
           let sourceID = pgmSlot.sourceID,
           let feed = state.thumbnailFeeds[sourceID] {
            let _ = state.thumbnailSequence
            OutputSurfaceMetalView(renderFeed: feed)
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
        } else {
            Rectangle()
                .fill(BrandTokens.cardBlack)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(BrandTokens.warmGrey.opacity(0.4))
                        Text("No program")
                            .font(BrandTokens.mono(size: 9))
                            .foregroundStyle(BrandTokens.warmGrey.opacity(0.5))
                    }
                )
        }
    }

    @ViewBuilder
    private var liveOutBadge: some View {
        if card.programSlotID != nil {
            Text("LIVE OUT")
                .font(BrandTokens.mono(size: 8))
                .foregroundStyle(BrandTokens.offWhite)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(8)
        }
    }

    @ViewBuilder
    private var audioMetersOverlay: some View {
        if let pgmSlotID = card.programSlotID,
           let pgmSlot = card.slots.first(where: { $0.id == pgmSlotID }) {
            OutputCardAudioMeter(sourceID: pgmSlot.sourceID, state: state)
                .opacity(card.isAudioMuted ? 0.3 : 1.0)
                .padding(6)
        }
    }

    // MARK: - Source Info Row

    private var sourceInfoRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(primarySourceLabel)
                .font(BrandTokens.display(size: 12, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)
                .lineLimit(2)
                .frame(height: 32, alignment: .topLeading)

            if !card.senderName.isEmpty {
                Text(card.senderName)
                    .font(BrandTokens.mono(size: 9))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .lineLimit(1)
            }
        }
        .frame(width: 312, alignment: .leading)
    }

    private var primarySourceLabel: String {
        if let pgmSlotID = card.programSlotID,
           let pgmSlot = card.slots.first(where: { $0.id == pgmSlotID }),
           let name = pgmSlot.displayName {
            return name
        }
        return "Fallback Slate"
    }

    // MARK: - Right Control Section (108pt)

    private var rightControlSection: some View {
        VStack(spacing: 8) {
            Spacer()

            // Mute button
            Button {
                state.toggleMute(card.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: card.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                    Text(card.isAudioMuted ? "Unmute" : "Mute")
                        .font(BrandTokens.display(size: 11, weight: .medium))
                }
                .foregroundStyle(card.isAudioMuted ? BrandTokens.red : BrandTokens.warmGrey)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Solo button
            Button {
                state.toggleSolo(card.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "headphones")
                        .font(.system(size: 11))
                    Text("Solo")
                        .font(BrandTokens.display(size: 11, weight: .medium))
                }
                .foregroundStyle(card.isSoloed ? BrandTokens.dark : BrandTokens.warmGrey)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(card.isSoloed ? .blue : nil)
            .controlSize(.small)

            // Actions menu
            Menu {
                Button("Clear To Fallback") {
                    // Clear all slots to return output to fallback state
                    for slot in card.slots where slot.sourceID != nil {
                        state.clearSlot(card.id, slotID: slot.id)
                    }
                }
                Divider()
                Button("Remove Output…", role: .destructive) {
                    showDeleteConfirmation = true
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .font(BrandTokens.display(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .controlSize(.small)

            Spacer()
        }
    }

    // MARK: - Subviews

    private var listenerBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: card.listenerCount > 0 ? "ear.fill" : "ear")
                .font(.system(size: 10, weight: .semibold))
            Text("\(card.listenerCount)")
                .font(BrandTokens.mono(size: 10))
        }
        .foregroundStyle(card.listenerCount > 0 ? BrandTokens.offWhite : BrandTokens.warmGrey)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(card.listenerCount > 0 ? 0.08 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var cardContextMenu: some View {
        Button("Rename Output...") { startEditing() }
        Divider()
        Button("Delete Output", role: .destructive) {
            showDeleteConfirmation = true
        }
    }

    // MARK: - Name Editing

    private func startEditing() {
        editedName = card.name
        isEditingName = true
        nameFieldFocused = true
    }

    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            state.renameOutput(card.id, name: trimmed)
        }
        isEditingName = false
    }

    private func cancelEditing() {
        isEditingName = false
    }
}
