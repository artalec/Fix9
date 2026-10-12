// DJPLAYER-BUILD: v4 (2026-10-12)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Список треков плейлиста: выделение, drag-n-drop файлов, перенос между плейлистами.
struct TrackList: View {

    @EnvironmentObject private var model: AppModel
    @State private var dropTarget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if let playlist = model.selectedPlaylist {
                if playlist.tracks.isEmpty {
                    emptyState
                } else {
                    trackListView(playlist)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Выберите плейлист слева")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Верхняя панель

    private var topBar: some View {
        HStack(spacing: 10) {
            if let playlist = model.selectedPlaylist {
                RoundedRectangle(cornerRadius: 3)
                    .fill(playlist.color.swiftUIColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.headline)
                    Text("Треков: \(playlist.tracks.count)  ·  Длительность: \(playlistDuration(playlist))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                addTracks()
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Добавить треки (⌘O)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Список

    private func trackListView(_ playlist: Playlist) -> some View {
        List {
            ForEach(playlist.tracks) { track in
                TrackRow(
                    track: track,
                    isCurrent: model.audioEngine.currentTrack?.id == track.id,
                    isSelected: model.selection.isSelected(track.id),
                    playlistColor: playlist.color,
                    isDropTarget: dropTarget == track.id,
                    onClick: { modifiers in
                        handleTrackClick(track.id, modifiers: modifiers, tracks: playlist.tracks)
                    }
                )
                .contextMenu {
                    trackContextMenu(track)
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .onDrag {
                    // Экспорт: если трек выделен, тащим всё выделение.
                    let ids = model.selection.isSelected(track.id) && model.selection.count > 1
                        ? Array(model.selection.selectedIDs)
                        : [track.id]
                    let joined = ids.map { $0.uuidString }.joined(separator: ",")
                    let item = NSItemProvider()
                    // Внутренний тип: ID треков для переупорядочивания и переноса
                    item.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                                    visibility: .all) { completion in
                        completion(Data(joined.utf8), nil)
                        return nil
                    }
                    // Файл для копирования в Finder (только для одиночного трека)
                    if ids.count == 1, let single = model.findTrack(ids[0]) {
                        item.registerFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                                        fileOptions: [],
                                                        visibility: .all) { completion in
                            completion(single.url, true, nil)
                            return nil
                        }
                    }
                    return item
                }
                .onDrop(of: [.utf8PlainText], delegate: TrackDropDelegate(
                    track: track,
                    tracks: playlist.tracks,
                    model: model,
                    dropTarget: $dropTarget
                ))
            }
            .onDelete { offsets in
                model.removeTracks(at: offsets)
            }
        }
        .listStyle(.inset)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Перетащите аудиофайлы сюда")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("или нажмите ⌘O")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
    }

    // MARK: - Клик по треку

    private func handleTrackClick(_ id: UUID, modifiers: EventModifiers, tracks: [Track]) {
        if modifiers.contains(.command) {
            model.selection.toggle(id)
        } else if modifiers.contains(.shift) {
            model.selection.selectRange(to: id, in: tracks.map(\.id))
        } else {
            model.selection.selectSingle(id)
        }
    }

    // MARK: - Контекстное меню

    @ViewBuilder
    private func trackContextMenu(_ track: Track) -> some View {
        Button("Показать в Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([track.url])
        }

        Divider()

        Menu("Установить цвет") {
            // Перечисляем по индексу: так компилятор точно не спутает
            // массив с Binding и не потребует вывода generic-параметра.
            ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { item in
                Button {
                    let color = item.element
                    if model.selection.isSelected(track.id) && model.selection.count > 1 {
                        model.setColorForSelected(color)
                    } else {
                        model.setTrackColor(color, for: track.id)
                    }
                } label: {
                    Image(nsImage: item.element.swatchImage())
                }
            }
            Divider()
            Button("Сбросить цвет") {
                if model.selection.isSelected(track.id) && model.selection.count > 1 {
                    model.setColorForSelected(nil)
                } else {
                    model.setTrackColor(nil, for: track.id)
                }
            }
        }

        Menu("Переместить в плейлист") {
            ForEach(model.playlistsSorted.filter { $0.id != model.selectedPlaylistID }) { playlist in
                Button(playlist.name) {
                    let ids = model.selection.isSelected(track.id) && model.selection.count > 1
                        ? Array(model.selection.selectedIDs)
                        : [track.id]
                    model.moveTracks(ids: ids, to: playlist.id)
                }
            }
        }
        .disabled(model.playlistsSorted.count < 2)

        Divider()

        Button(track.deleteAfterPlay ? "Не удалять после проигрывания" : "Удалять после проигрывания") {
            if model.selection.isSelected(track.id) && model.selection.count > 1 {
                model.toggleDeleteAfterPlayForSelected()
            } else {
                model.toggleDeleteAfterPlay(for: track.id)
            }
        }

        Button("Сбросить обрезку") {
            model.resetTrim(for: track.id)
        }

        Divider()

        Button("Переместить выше") {
            model.moveTrackUp(id: track.id)
        }
        Button("Переместить ниже") {
            model.moveTrackDown(id: track.id)
        }

        Divider()

        Button("Удалить трек", role: .destructive) {
            if model.selection.isSelected(track.id) && model.selection.count > 1 {
                model.removeSelectedTracks()
            } else {
                model.removeTrack(id: track.id)
            }
        }
    }

    // MARK: - Drag and drop файлов

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileType = UTType.fileURL.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(fileType) }
        guard !matching.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in matching {
                if let data = try? await provider.loadItem(forTypeIdentifier: fileType) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   Self.isAudioFile(url) {
                    urls.append(url)
                }
            }
            await MainActor.run {
                model.addTracks(urls: urls)
            }
        }
        return true
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "wav", "m4a", "aac", "flac", "aiff", "ogg"].contains(ext)
    }

    private func addTracks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK {
            model.addTracks(urls: panel.urls)
        }
    }

    /// Суммарная длительность плейлиста с учётом trim-точек.
    private func playlistDuration(_ playlist: Playlist) -> String {
        let total = playlist.tracks.reduce(0.0) { $0 + $1.effectiveDuration }
        return total.timecode
    }
}

// MARK: - Строка трека

private struct TrackRow: View {

    let track: Track
    let isCurrent: Bool
    let isSelected: Bool
    let playlistColor: RGBAColor
    let isDropTarget: Bool
    let onClick: (EventModifiers) -> Void

    @EnvironmentObject private var model: AppModel
    @State private var isHovering = false

    private var effectiveColor: RGBAColor {
        track.color ?? playlistColor
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(isCurrent ? effectiveColor.swiftUIColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if track.deleteAfterPlay {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .help("Удалится после проигрывания")
            }

            Text(track.effectiveDuration.timecode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(rowBackground)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.play(track: track)
        }
        .onTapGesture(count: 1) {
            onClick(currentModifiers())
        }
        .onHover { isHovering = $0 }
    }

    private var rowBackground: some View {
        Group {
            if isDropTarget {
                Color.accentColor.opacity(0.25)
            } else if isSelected {
                effectiveColor.swiftUIColor.opacity(0.28)
            } else if isHovering {
                Color.primary.opacity(0.06)
            } else {
                Color.clear
            }
        }
    }

    private var detail: String {
        track.exists ? track.url.deletingLastPathComponent().lastPathComponent : "файл не найден"
    }

    private func currentModifiers() -> EventModifiers {
        let flags = NSEvent.modifierFlags
        var result: EventModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

// MARK: - Drop delegate для переноса между треками

private struct TrackDropDelegate: DropDelegate {
    let track: Track
    let tracks: [Track]
    let model: AppModel
    @Binding var dropTarget: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        dropTarget = track.id
    }

    func dropExited(info: DropInfo) {
        if dropTarget == track.id {
            dropTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil

        guard let item = info.itemProviders(for: [.utf8PlainText]).first else { return false }

        item.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
            guard let data, let joined = String(data: data, encoding: .utf8) else { return }

            let ids = joined.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty, let targetIndex = tracks.firstIndex(where: { $0.id == track.id }) else { return }

            DispatchQueue.main.async {
                model.reorderTracks(ids: ids, toIndex: targetIndex)
            }
        }
        return true
    }
}
