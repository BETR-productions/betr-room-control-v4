// ClipPlayerPlaylistView — playlist panel for clip player.
// Drag-reorder list, per-item settings, playback order, transport controls.

import ClipPlayerDomain
import RoomControlXPCContracts
import SwiftUI

// MARK: - Playlist View

public struct ClipPlayerPlaylistView: View {
    @ObservedObject var store: ClipPlayerPlaylistStore

    public init(store: ClipPlayerPlaylistStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            playlistHeader
            Divider().background(BrandTokens.charcoal)
            if store.items.isEmpty {
                emptyState
            } else {
                itemList
            }
            Divider().background(BrandTokens.charcoal)
            transportBar
        }
        .background(BrandTokens.panelDark)
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

    // MARK: - Item List

    private var itemList: some View {
        List {
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                ClipPlayerItemRow(
                    item: item,
                    isSelected: store.selectedIndex == index,
                    isCurrent: store.currentItemIndex == index,
                    isPlaying: store.runState == .playing && store.currentItemIndex == index,
                    onSelect: { store.selectItem(at: index) },
                    onUpdateTransition: { kind in store.updateTransition(at: index, kind: kind) },
                    onUpdateDuration: { duration in store.updateDuration(at: index, duration: duration) },
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

    // MARK: - Transport Bar

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
    let onUpdateTransition: (TransitionKind) -> Void
    let onUpdateDuration: (TimeInterval?) -> Void
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

            // Name
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(BrandTokens.display(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? BrandTokens.gold : BrandTokens.offWhite)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    // Transition type
                    transitionPicker

                    // Duration override (stills only)
                    if item.type == .still {
                        durationField
                    }
                }
            }

            Spacer()

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

    private var transitionPicker: some View {
        Picker("", selection: Binding(
            get: { item.transitionKind },
            set: { onUpdateTransition($0) }
        )) {
            Text("Cut").tag(TransitionKind.cut)
            Text("Dissolve").tag(TransitionKind.dissolve)
        }
        .pickerStyle(.menu)
        .frame(width: 90)
        .font(BrandTokens.display(size: 10))
    }

    private var durationField: some View {
        HStack(spacing: 2) {
            Text("Hold:")
                .font(BrandTokens.display(size: 10))
                .foregroundStyle(BrandTokens.warmGrey)
            TextField(
                "",
                value: Binding(
                    get: { item.durationOverride ?? ClipPlayerConstants.defaultStillDuration },
                    set: { onUpdateDuration($0) }
                ),
                format: .number.precision(.fractionLength(1))
            )
            .textFieldStyle(.plain)
            .font(BrandTokens.mono(size: 10))
            .foregroundStyle(BrandTokens.offWhite)
            .frame(width: 36)
            Text("s")
                .font(BrandTokens.display(size: 10))
                .foregroundStyle(BrandTokens.warmGrey)
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
        // Track selectedIndex and currentItemIndex through the reorder
        let selectedID = selectedIndex.flatMap { items.indices.contains($0) ? items[$0].id : nil }
        let currentID = currentItemIndex.flatMap { items.indices.contains($0) ? items[$0].id : nil }

        items.move(fromOffsets: source, toOffset: destination)

        // Restore tracked indices by ID lookup after move
        selectedIndex = selectedID.flatMap { id in items.firstIndex { $0.id == id } }
        currentItemIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } }

        syncPlaylistToProducer()
    }

    public func selectItem(at index: Int) {
        selectedIndex = index
    }

    public func updateTransition(at index: Int, kind: TransitionKind) {
        guard items.indices.contains(index) else { return }
        let old = items[index]
        items[index] = ClipItem(
            id: old.id,
            url: old.url,
            type: old.type,
            transitionKind: kind,
            durationOverride: old.durationOverride
        )
        syncPlaylistToProducer()
    }

    public func updateDuration(at index: Int, duration: TimeInterval?) {
        guard items.indices.contains(index) else { return }
        let old = items[index]
        items[index] = ClipItem(
            id: old.id,
            url: old.url,
            type: old.type,
            transitionKind: old.transitionKind,
            durationOverride: duration
        )
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
