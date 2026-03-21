// PresentationLauncherView — launcher panel for presentation files.
// NSOpenPanel with .pptx/.key filter, recent files list (last 10), clear button.
// Task 96: Presentation launcher panel.

import PresentationDomain
import SwiftUI

// MARK: - Recent Files Store

/// Manages the recent presentation files list (last 10), persisted via UserDefaults.
@MainActor
public final class PresentationLauncherStore: ObservableObject {
    private static let recentFilesKey = "com.betr.room-control.presentation.recentFiles"
    private static let maxRecent = 10

    @Published public var recentFiles: [RecentPresentationFile] = []
    @Published public var isOpening = false
    @Published public var currentFilePath: String?
    @Published public var currentMode: SlideshowMode = .closed

    /// Callback to open a file via PresentationController.
    public var onOpenFile: ((String) -> Void)?

    /// Callback to start slideshow.
    public var onStartSlideshow: (() -> Void)?

    /// Callback to stop slideshow.
    public var onStopSlideshow: (() -> Void)?

    /// Callback to close presentation.
    public var onClosePresentation: (() -> Void)?

    public init() {
        loadRecent()
    }

    // MARK: - Open Panel

    /// Show NSOpenPanel filtered to presentation files.
    public func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Presentation"
        panel.allowedContentTypes = [
            .init(filenameExtension: "pptx")!,
            .init(filenameExtension: "ppt")!,
            .init(filenameExtension: "pps")!,
            .init(filenameExtension: "pptm")!,
            .init(filenameExtension: "ppsm")!,
            .init(filenameExtension: "key")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url.path)
    }

    /// Open a file by path (from recent list or panel).
    public func openFile(_ path: String) {
        addToRecent(path)
        isOpening = true
        currentFilePath = path
        onOpenFile?(path)
    }

    // MARK: - Recent Files

    public func clearRecent() {
        recentFiles = []
        saveRecent()
    }

    func addToRecent(_ path: String) {
        recentFiles.removeAll { $0.path == path }
        let ext = (path as NSString).pathExtension.lowercased()
        let appKind: PresentationAppKind = ext == "key" ? .keynote : .powerPoint
        recentFiles.insert(
            RecentPresentationFile(
                path: path,
                name: (path as NSString).lastPathComponent,
                appKind: appKind,
                lastOpened: Date()
            ),
            at: 0
        )
        if recentFiles.count > Self.maxRecent {
            recentFiles = Array(recentFiles.prefix(Self.maxRecent))
        }
        saveRecent()
    }

    private func loadRecent() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentFilesKey),
              let decoded = try? JSONDecoder().decode([RecentPresentationFile].self, from: data)
        else { return }
        recentFiles = decoded
    }

    private func saveRecent() {
        guard let data = try? JSONEncoder().encode(recentFiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentFilesKey)
    }
}

/// A recent presentation file entry.
public struct RecentPresentationFile: Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let appKind: PresentationAppKind
    public let lastOpened: Date
}

// MARK: - Launcher View

public struct PresentationLauncherView: View {
    @ObservedObject var store: PresentationLauncherStore

    public init(store: PresentationLauncherStore) {
        self.store = store
    }

    public var body: some View {
        let mode = store.currentMode
        VStack(spacing: 0) {
            header
            Divider().background(BrandTokens.charcoal)
            if mode != .closed {
                activeSessionView(mode: mode)
                Divider().background(BrandTokens.charcoal)
            }
            recentFilesList
        }
        .background(BrandTokens.panelDark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Presentation")
                .font(BrandTokens.display(size: 13, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)
            Spacer()
            Button(action: store.showOpenPanel) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus")
                    Text("Open")
                        .font(BrandTokens.display(size: 11))
                }
                .foregroundStyle(BrandTokens.gold)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BrandTokens.toolbarDark)
    }

    // MARK: - Active Session

    @ViewBuilder
    private func activeSessionView(mode: SlideshowMode) -> some View {
        let label = Self.modeLabel(for: mode)
        let color = Self.modeColor(for: mode)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: appIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(BrandTokens.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentFileName)
                        .font(BrandTokens.display(size: 12, weight: .medium))
                        .foregroundStyle(BrandTokens.offWhite)
                        .lineLimit(1)
                    Text(label)
                        .font(BrandTokens.mono(size: 10))
                        .foregroundStyle(color)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if mode == .editing {
                    Button(action: { store.onStartSlideshow?() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Start Slideshow")
                                .font(BrandTokens.display(size: 11))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandTokens.gold)
                    .controlSize(.small)
                } else if mode == .slideshow {
                    Button(action: { store.onStopSlideshow?() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                                .font(BrandTokens.display(size: 11))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandTokens.red)
                    .controlSize(.small)
                }

                Button(action: { store.onClosePresentation?() }) {
                    Text("Close")
                        .font(BrandTokens.display(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(BrandTokens.surfaceDark)
    }

    private var currentFileName: String {
        guard let path = store.currentFilePath else { return "No file" }
        return (path as NSString).lastPathComponent
    }

    private var appIcon: String {
        guard let path = store.currentFilePath else { return "doc.richtext" }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "key" ? "rectangle.split.3x3" : "doc.richtext"
    }

    private static func modeLabel(for mode: SlideshowMode) -> String {
        switch mode {
        case .slideshow: return "Slideshow Active"
        case .editing: return "Editing"
        case .closed: return "Closed"
        }
    }

    private static func modeColor(for mode: SlideshowMode) -> Color {
        switch mode {
        case .slideshow: return BrandTokens.pgnGreen
        case .editing: return BrandTokens.gold
        case .closed: return BrandTokens.warmGrey
        }
    }

    // MARK: - Recent Files

    private var recentFilesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Files")
                    .font(BrandTokens.display(size: 11, weight: .semibold))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .tracking(0.8)
                Spacer()
                if !store.recentFiles.isEmpty {
                    Button("Clear") {
                        store.clearRecent()
                    }
                    .font(BrandTokens.display(size: 10))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if store.recentFiles.isEmpty {
                Text("No recent presentations")
                    .font(BrandTokens.display(size: 11))
                    .foregroundStyle(BrandTokens.charcoal)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ForEach(store.recentFiles) { file in
                    recentFileRow(file)
                }
            }
        }
    }

    private func recentFileRow(_ file: RecentPresentationFile) -> some View {
        Button {
            store.openFile(file.path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: file.appKind == .keynote
                    ? "rectangle.split.3x3" : "doc.richtext")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandTokens.gold)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(BrandTokens.display(size: 11, weight: .medium))
                        .foregroundStyle(BrandTokens.offWhite)
                        .lineLimit(1)
                    Text(file.path)
                        .font(BrandTokens.mono(size: 9))
                        .foregroundStyle(BrandTokens.charcoal)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(relativeDate(file.lastOpened))
                    .font(BrandTokens.mono(size: 9))
                    .foregroundStyle(BrandTokens.charcoal)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.001))
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
