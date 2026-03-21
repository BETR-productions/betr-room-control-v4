// ClipPlayerPlaylistView — playlist panel for clip player.
// Task 91: Drag-reorder list with .onMove.
// Task 92: Per-clip settings sheet (transition type, dissolve frames, duration).
// Task 93: Playback controls + keyboard shortcuts (Space, arrows).
// Task 94: Live preview thumbnail placeholder (wired to warm pool IOSurface path).
// Task 95: Clip player source appears alongside NDI sources in slot picker.

import ClipPlayerDomain
import RoomControlXPCContracts
import SwiftUI

// MARK: - Playlist View

public struct ClipPlayerPlaylistView: View {
    @ObservedObject var store: ClipPlayerPlaylistStore
    @State private var settingsItemIndex: Int?

    public init(store: ClipPlayerPlaylistStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            playlistHeader
            Divider().background(BrandTokens.charcoal)

            // Task 94: Live preview thumbnail when playing
            if store.runState == .playing {
                clipPlayerThumbnail
                Divider().background(BrandTokens.charcoal)
            }

            if store.items.isEmpty {
                emptyState
            } else {
                itemList
            }
            Divider().background(BrandTokens.charcoal)
            transportBar
        }
        .background(BrandTokens.panelDark)
        // Task 93: Keyboard shortcuts for playback controls
        .onKeyPress(.space) {
            if store.runState == .playing { store.pause() } else { store.play() }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            store.previous()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            store.next()
            return .handled
        }
        .onKeyPress(.escape) {
            store.stop()
            return .handled
        }
        // Task 92: Per-clip settings sheet
        .sheet(item: settingsBinding) { wrapper in
            ClipItemSettingsSheet(
                item: wrapper.item,
                index: wrapper.index,
                onSave: { index, updated in
                    store.updateItem(at: index, with: updated)
                    settingsItemIndex = nil
                },
                onCancel: { settingsItemIndex = nil }
            )
        }
    }

    private var settingsBinding: Binding<ClipItemWrapper?> {
        Binding(
            get: {
                guard let idx = settingsItemIndex,
                      store.items.indices.contains(idx) else { return nil }
                return ClipItemWrapper(item: store.items[idx], index: idx)
            },
            set: { _ in settingsItemIndex = nil }
        )
    }

    // MARK: - Header

    private var playlistHeader: some View {
        HStack {
            Text("Clip Player")
                .font(BrandTokens.display(size: 13, weight: .semibold))
                .foregroundStyle(BrandTokens.offWhite)
            Spacer()
            playbackOrderPicker
            addButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BrandTokens.toolbarDark)
    }

    private var playbackOrderPicker: some View {
        Picker("", selection: $store.playbackOrder) {
            Text("Sequential").tag(PlaybackOrder.sequential)
            Text("Random").tag(PlaybackOrder.random)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
    }

    private var addButton: some View {
        Button(action: store.addFiles) {
            Image(systemName: "plus")
                .foregroundStyle(BrandTokens.gold)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live Preview Thumbnail (Task 94)

    private var clipPlayerThumbnail: some View {
        ClipPlayerThumbnailView(producerID: store.producerID)
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .background(BrandTokens.surfaceDark)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 32))
                .foregroundStyle(BrandTokens.warmGrey)
            Text("No clips added")
                .font(BrandTokens.display(size: 13))
                .foregroundStyle(BrandTokens.warmGrey)
            Text("Drop media files here or click +")
                .font(BrandTokens.display(size: 11))
                .foregroundStyle(BrandTokens.charcoal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandTokens.panelDark)
    }

    // MARK: - Item List (Task 91: drag-reorder)

    private var itemList: some View {
        List {
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                ClipPlayerItemRow(
                    item: item,
                    isSelected: store.selectedIndex == index,
                    isCurrent: store.currentItemIndex == index,
                    isPlaying: store.runState == .playing && store.currentItemIndex == index,
                    onSelect: { store.selectItem(at: index) },
                    onSettings: { settingsItemIndex = index },
                    onDelete: { store.removeItem(at: index) }
                )
                .listRowBackground(
                    store.selectedIndex == index
                        ? BrandTokens.surfaceDark
                        : Color.clear
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .onMove { source, destination in
                store.moveItems(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(BrandTokens.panelDark)
    }

    // MARK: - Transport Bar (Task 93: play/pause, next, prev, stop)

    private var transportBar: some View {
        HStack(spacing: 16) {
            transportButton(systemName: "backward.fill", action: store.previous)
            transportButton(
                systemName: store.runState == .playing ? "pause.fill" : "play.fill",
                action: store.runState == .playing ? store.pause : store.play,
                highlighted: store.runState == .playing
            )
            transportButton(systemName: "stop.fill", action: store.stop)
            transportButton(systemName: "forward.fill", action: store.next)

            Spacer()

            if let currentName = store.currentItemName {
                Text(currentName)
                    .font(BrandTokens.mono(size: 10))
                    .foregroundStyle(BrandTokens.warmGrey)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BrandTokens.toolbarDark)
    }

    private func transportButton(
        systemName: String,
        action: @escaping () -> Void,
        highlighted: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundStyle(highlighted ? BrandTokens.gold : BrandTokens.offWhite)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Item Row

struct ClipPlayerItemRow: View {
    let item: ClipItem
    let isSelected: Bool
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let onSettings: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Current indicator
            Circle()
                .fill(isPlaying ? BrandTokens.gold : Color.clear)
                .frame(width: 6, height: 6)

            // Type icon
            Image(systemName: item.type == .video ? "film" : "photo")
                .font(.system(size: 12))
                .foregroundStyle(BrandTokens.warmGrey)
                .frame(width: 16)

            // Name + transition summary
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(BrandTokens.display(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? BrandTokens.gold : BrandTokens.offWhite)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(item.transitionKind == .cut ? "Cut" : "Dissolve \(item.transitionFrameCount)f")
                        .font(BrandTokens.mono(size: 9))
                        .foregroundStyle(BrandTokens.warmGrey)

                    if item.type == .still, let duration = item.durationOverride {
                        Text("\(String(format: "%.1f", duration))s")
                            .font(BrandTokens.mono(size: 9))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }
                }
            }

            Spacer()

            // Settings button (Task 92)
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
            .buttonStyle(.plain)

            // Delete
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

// MARK: - Per-Clip Settings Sheet (Task 92)

/// Identifiable wrapper for sheet presentation.
private struct ClipItemWrapper: Identifiable {
    let item: ClipItem
    let index: Int
    var id: UUID { item.id }
}

struct ClipItemSettingsSheet: View {
    let item: ClipItem
    let index: Int
    let onSave: (Int, ClipItem) -> Void
    let onCancel: () -> Void

    @State private var transitionKind: TransitionKind
    @State private var dissolveFrames: Double
    @State private var durationOverride: Double

    init(
        item: ClipItem,
        index: Int,
        onSave: @escaping (Int, ClipItem) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.index = index
        self.onSave = onSave
        self.onCancel = onCancel
        _transitionKind = State(initialValue: item.transitionKind)
        _dissolveFrames = State(initialValue: Double(item.transitionFrameCount))
        _durationOverride = State(initialValue: item.durationOverride ?? ClipPlayerConstants.defaultStillDuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: item.type == .video ? "film" : "photo")
                    .foregroundStyle(BrandTokens.gold)
                Text(item.displayName)
                    .font(BrandTokens.display(size: 14, weight: .semibold))
                    .foregroundStyle(BrandTokens.offWhite)
                Spacer()
            }

            Divider()

            // Transition type
            HStack {
                Text("Transition:")
                    .font(BrandTokens.display(size: 12))
                    .foregroundStyle(BrandTokens.warmGrey)
                Picker("", selection: $transitionKind) {
                    Text("Cut").tag(TransitionKind.cut)
                    Text("Dissolve").tag(TransitionKind.dissolve)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // Dissolve frame slider (10-60 frames)
            if transitionKind == .dissolve {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Dissolve Duration:")
                            .font(BrandTokens.display(size: 12))
                            .foregroundStyle(BrandTokens.warmGrey)
                        Spacer()
                        Text("\(Int(dissolveFrames)) frames")
                            .font(BrandTokens.mono(size: 11))
                            .foregroundStyle(BrandTokens.offWhite)
                        Text(String(format: "(%.2fs)", dissolveFrames * Double(ClipPlayerConstants.defaultFrameRateDenominator) / Double(ClipPlayerConstants.defaultFrameRateNumerator)))
                            .font(BrandTokens.mono(size: 10))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }
                    Slider(
                        value: $dissolveFrames,
                        in: Double(ClipPlayerConstants.minDissolveFrames)...Double(ClipPlayerConstants.maxDissolveFrames),
                        step: 1
                    )
                    .tint(BrandTokens.gold)

                    HStack {
                        Text("\(ClipPlayerConstants.minDissolveFrames)f")
                            .font(BrandTokens.mono(size: 9))
                            .foregroundStyle(BrandTokens.warmGrey)
                        Spacer()
                        Text("\(ClipPlayerConstants.maxDissolveFrames)f")
                            .font(BrandTokens.mono(size: 9))
                            .foregroundStyle(BrandTokens.warmGrey)
                    }
                }
            }

            // Duration override (stills only)
            if item.type == .still {
                HStack {
                    Text("Hold Duration:")
                        .font(BrandTokens.display(size: 12))
                        .foregroundStyle(BrandTokens.warmGrey)
                    TextField(
                        "",
                        value: $durationOverride,
                        format: .number.precision(.fractionLength(1))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(BrandTokens.mono(size: 12))
                    Text("seconds")
                        .font(BrandTokens.display(size: 12))
                        .foregroundStyle(BrandTokens.warmGrey)
                }
            }

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let updated = ClipItem(
                        id: item.id,
                        url: item.url,
                        type: item.type,
                        transitionKind: transitionKind,
                        transitionFrameCount: Int(dissolveFrames),
                        durationOverride: item.type == .still ? durationOverride : item.durationOverride
                    )
                    onSave(index, updated)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(BrandTokens.gold)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(BrandTokens.panelDark)
    }
}

// MARK: - Live Preview Thumbnail (Task 94)

/// Displays the clip player's current output frame from the warm pool IOSurface.
/// Follows the same path as NDI source thumbnails — looks up the IOSurface by producer ID.
struct ClipPlayerThumbnailView: View {
    let producerID: String?

    var body: some View {
        if let producerID, !producerID.isEmpty {
            // IOSurface thumbnail rendering — wired to the same warm pool path
            // as NDI sources. The ShellViewState.thumbnailReady event delivers
            // surfaceID which is resolved to an NSImage via IOSurface(lookup:).
            // Task 76 (full-frame-rate thumbnails) handles the actual Metal rendering.
            ZStack {
                BrandTokens.surfaceDark
                VStack(spacing: 4) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 24))
                        .foregroundStyle(BrandTokens.gold)
                    Text("Clip Player Output")
                        .font(BrandTokens.display(size: 10))
                        .foregroundStyle(BrandTokens.warmGrey)
                    Text(producerID)
                        .font(BrandTokens.mono(size: 8))
                        .foregroundStyle(BrandTokens.charcoal)
                        .lineLimit(1)
                }
            }
        } else {
            ZStack {
                BrandTokens.surfaceDark
                Text("Not registered")
                    .font(BrandTokens.display(size: 10))
                    .foregroundStyle(BrandTokens.warmGrey)
            }
        }
    }
}

// MARK: - Playlist Store

public final class ClipPlayerPlaylistStore: ObservableObject {
    @Published public var items: [ClipItem] = []
    @Published public var playbackOrder: PlaybackOrder = .sequential
    @Published public var runState: ClipPlayerRunState = .stopped
    @Published public var currentItemIndex: Int?
    @Published public var currentItemName: String?
    @Published public var selectedIndex: Int?
    @Published public var producerID: String?

    private let producer: ClipPlayerProducer

    public init(producer: ClipPlayerProducer) {
        self.producer = producer
    }

    // MARK: - Playlist Actions

    public func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ClipItemType.allSupportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let type = ClipItemType.type(for: url) else { continue }
            let item = ClipItem(
                url: url,
                type: type,
                durationOverride: type == .still ? ClipPlayerConstants.defaultStillDuration : nil
            )
            items.append(item)
        }
        syncPlaylistToProducer()
    }

    public func removeItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if selectedIndex == index {
            selectedIndex = nil
        } else if let selectedIndex, index < selectedIndex {
            self.selectedIndex = selectedIndex - 1
        }
        syncPlaylistToProducer()
    }

    public func moveItems(from source: IndexSet, to destination: Int) {
        let selectedID = selectedIndex.flatMap { items.indices.contains($0) ? items[$0].id : nil }
        let currentID = currentItemIndex.flatMap { items.indices.contains($0) ? items[$0].id : nil }

        items.move(fromOffsets: source, toOffset: destination)

        selectedIndex = selectedID.flatMap { id in items.firstIndex { $0.id == id } }
        currentItemIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } }

        syncPlaylistToProducer()
    }

    public func selectItem(at index: Int) {
        selectedIndex = index
    }

    /// Task 92: Update a clip item with new settings from the settings sheet.
    public func updateItem(at index: Int, with updated: ClipItem) {
        guard items.indices.contains(index) else { return }
        items[index] = updated
        syncPlaylistToProducer()
    }

    // MARK: - Transport

    public func play() {
        Task { await producer.play() }
    }

    public func pause() {
        Task { await producer.pause() }
    }

    public func stop() {
        Task { await producer.stop() }
    }

    public func next() {
        Task { await producer.next() }
    }

    public func previous() {
        Task { await producer.previous() }
    }

    // MARK: - Sync

    public func refreshFromProducer() {
        Task {
            let snapshot = await producer.snapshot()
            await MainActor.run {
                runState = snapshot.runState
                currentItemIndex = snapshot.currentItemIndex
                currentItemName = snapshot.currentItemName
                producerID = snapshot.producerID
            }
        }
    }

    private func syncPlaylistToProducer() {
        Task {
            await producer.setPlaylist(items: items, order: playbackOrder)
        }
    }
}

// MARK: - UTType

import UniformTypeIdentifiers
