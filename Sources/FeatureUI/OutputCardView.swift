// OutputCardView — multi-output card with live preview, 3x2 slot bank, audio meters, mute.
// Task 121: Port v3 OutputPreviewTile + OutputSlotBank into per-output card.
// Vertical layout for center column. Live IOSurface preview at top, 3x2 slot grid below.
// PVW/PGM buttons per slot (via OutputSlotCell). Output name editable inline. Mute button.

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
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            outputPreview
            OutputSlotBank(card: card, state: state)
            cardFooter
        }
        .padding(12)
        .background(BrandTokens.surfaceDark)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isFocused ? BrandTokens.gold : BrandTokens.charcoal,
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { state.focusedCardID = card.id }
        .contextMenu { cardContextMenu }
        .alert("Delete Output?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                state.removeOutput(card.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(card.name)\" and all slot assignments.")
        }
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 8) {
            if isEditingName {
                TextField("Output name", text: $editedName)
                    .font(BrandTokens.display(size: 13, weight: .semibold))
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelEditing() }
                    .frame(maxWidth: 160)
            } else {
                Text(card.name)
                    .font(BrandTokens.display(size: 13, weight: .semibold))
                    .foregroundStyle(BrandTokens.offWhite)
                    .onTapGesture(count: 2) { startEditing() }
            }

            if card.listenerCount > 0 {
                listenerBadge
            }

            Spacer()

            // Per-output audio meters from program source (Task 126)
            if let pgmSlotID = card.programSlotID,
               let pgmSlot = card.slots.first(where: { $0.id == pgmSlotID }) {
                OutputCardAudioMeter(sourceID: pgmSlot.sourceID, state: state)
                    .opacity(card.isAudioMuted ? 0.3 : 1.0)
            }

            muteButton
        }
    }

    // MARK: - Live Preview (Task 125)

    @ViewBuilder
    private var outputPreview: some View {
        // Per-output compositor preview when available (Task 125);
        // falls back to program source thumbnail until compositor XPC is wired.
        if let pgmSlotID = card.programSlotID,
           let pgmSlot = card.slots.first(where: { $0.id == pgmSlotID }),
           let sourceID = pgmSlot.sourceID,
           let feed = state.thumbnailFeeds[sourceID] {
            let _ = state.thumbnailSequence
            OutputSurfaceMetalView(renderFeed: feed)
                .frame(minHeight: 120)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(liveBadge, alignment: .topTrailing)
        } else {
            Rectangle()
                .fill(BrandTokens.cardBlack)
                .frame(minHeight: 120)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
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

    // MARK: - Footer

    private var cardFooter: some View {
        HStack(spacing: 8) {
            if !card.senderName.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 8))
                    Text(card.senderName)
                        .font(BrandTokens.mono(size: 9))
                }
                .foregroundStyle(BrandTokens.warmGrey)
            }
            Spacer()
            if card.listenerCount > 0 {
                Text("\(card.listenerCount) listener\(card.listenerCount == 1 ? "" : "s")")
                    .font(BrandTokens.mono(size: 9))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
        }
    }

    // MARK: - Subviews

    private var listenerBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.fill")
                .font(.system(size: 8))
            Text("\(card.listenerCount)")
                .font(BrandTokens.mono(size: 9))
        }
        .foregroundStyle(BrandTokens.warmGrey)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(BrandTokens.charcoal)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var muteButton: some View {
        Button {
            state.toggleMute(card.id)
        } label: {
            Image(systemName: card.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(card.isAudioMuted ? BrandTokens.red : BrandTokens.warmGrey)
        }
        .buttonStyle(.plain)
        .help(card.isAudioMuted ? "Unmute output" : "Mute output")
    }

    @ViewBuilder
    private var liveBadge: some View {
        if card.programSlotID != nil {
            Text("LIVE")
                .font(BrandTokens.mono(size: 8))
                .foregroundStyle(BrandTokens.offWhite)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(BrandTokens.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
    }

    // MARK: - Context Menu (Task 122)

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
