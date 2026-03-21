// PresenterViewPanel — slide notes display for the active presentation.
// Task 135: Shows current slide notes from Scripting Bridge (via PresentationLauncherStore).
// Placeholder when no session active. Updates driven by 1Hz polling in PresentationLauncherStore.

import SwiftUI

/// Panel displaying slide notes for the current presentation slide.
/// Matches v3 PresenterStatusPanel pattern.
struct PresenterViewPanel: View {
    @ObservedObject var store: PresentationLauncherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader

            if store.currentMode == .slideshow, let notes = store.currentSlideNotes, !notes.isEmpty {
                notesContent(notes)
            } else {
                placeholder
            }
        }
        .padding(16)
        .background(BrandTokens.surfaceDark)
    }

    // MARK: - Header

    private var panelHeader: some View {
        Text("PRESENTER VIEW")
            .font(BrandTokens.display(size: 11, weight: .semibold))
            .foregroundStyle(BrandTokens.warmGrey)
            .tracking(1.2)
    }

    // MARK: - Notes Content

    private func notesContent(_ notes: String) -> some View {
        ScrollView {
            Text(notes)
                .font(BrandTokens.mono(size: 12))
                .foregroundStyle(BrandTokens.offWhite)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(BrandTokens.warmGrey.opacity(0.5))
            Text("No active presentation")
                .font(BrandTokens.display(size: 12))
                .foregroundStyle(BrandTokens.warmGrey)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
