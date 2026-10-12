// DJPLAYER-BUILD: v4 (2026-10-12)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Левая колонка: список плейлистов с изменением порядка перетаскиванием.
struct PlaylistSidebar: View {

    @EnvironmentObject private var model: AppModel

    @State private var isAdding = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var coloring: Playlist?
    @State private var dropTarget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Шапка

    private var header: some View {
        HStack {
            Text("Плейлисты")
                .font(.headline)
            Spacer()
            Button {
                isAdding.toggle()
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Добавить плейлист")
            .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                addPlaylistPopover
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var addPlaylistPopover: some View {
        VStack(spacing: 10) {
            Text("Новый плейлист")
                .font(.headline)
            TextField("Название", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit {
                    submitNewPlaylist()
                }
            HStack {
                Button("Отмена") {
                    isAdding = false
                    newName = ""
                }
                Button("Создать") {
                    submitNewPlaylist()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func submitNewPlaylist() {
        model.addPlaylist(named: newName)
        newName = ""
        isAdding = false
    }

    // MARK: - Список

    private var list: some View {
        List {
            ForEach(model.playlistsSorted) { playlist in
                PlaylistRow(
                    playlist: playlist,
                    isSelected: model.selectedPlaylistID == playlist.id,
                    isPlayingHere: model.audioEngine.currentTrack != nil &&
                        playlist.tracks.contains { $0.id == model.audioEngine.currentTrack?.id },
                    isDropTarget: dropTarget == playlist.id,
                    onRename: { renaming = playlist; renameText = playlist.name },
                    onRecolor: { coloring = playlist },
                    onMoveUp: { model.movePlaylistUp(id: playlist.id) },
                    onMoveDown: { model.movePlaylistDown(id: playlist.id) },
                    onDelete: { model.deletePlaylist(id: playlist.id) }
                )
                .onTapGesture {
                    model.selectedPlaylistID = playlist.id
                    model.selection.clear()
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .onDrag {
                    let provider = NSItemProvider()
                    let payload = Data(playlist.id.uuidString.utf8)
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                                        visibility: .all) { completion in
                        completion(payload, nil)
                        return nil
                    }
                    return provider
                }
                .onDrop(of: [.utf8PlainText], delegate: PlaylistDropDelegate(
                    playlist: playlist,
                    playlists: model.playlistsSorted,
                    model: model,
                    dropTarget: $dropTarget
                ))
            }
        }
        .listStyle(.sidebar)
        .popover(item: $renaming) { playlist in
            renamePopover(playlist)
        }
        .popover(item: $coloring) { playlist in
            colorPopover(playlist)
        }
    }

    private func renamePopover(_ playlist: Playlist) -> some View {
        VStack(spacing: 10) {
            Text("Переименовать")
                .font(.headline)
            TextField("Название", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit {
                    model.renamePlaylist(id: playlist.id, to: renameText)
                    renaming = nil
                }
            HStack {
                Button("Отмена") {
                    renaming = nil
                }
                Button("Готово") {
                    model.renamePlaylist(id: playlist.id, to: renameText)
                    renaming = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func colorPopover(_ playlist: Playlist) -> some View {
        VStack(spacing: 12) {
            Text("Цвет плейлиста")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32))], spacing: 8) {
                ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { item in
                    Button {
                        model.setColor(item.element, for: playlist.id)
                        coloring = nil
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(item.element.swiftUIColor)
                            .frame(width: 32, height: 32)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 240)
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                exportSelectedPlaylistWithPanel()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Экспорт плейлиста")
            .disabled(model.selectedPlaylist == nil)

            Button {
                if let url = selectImportURL() {
                    model.importPlaylist(from: url)
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Импорт плейлиста")

            Spacer()

            if let playlist = model.selectedPlaylist {
                Text("\(playlist.tracks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Показывает диалог сохранения и пишет файл только если пользователь подтвердил.
    private func exportSelectedPlaylistWithPanel() {
        guard let playlist = model.selectedPlaylist else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = playlist.name + ".json"
        panel.title = "Экспорт плейлиста"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportSelectedPlaylist(to: url)
    }

    private func selectImportURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Строка плейлиста

private struct PlaylistRow: View {

    let playlist: Playlist
    let isSelected: Bool
    let isPlayingHere: Bool
    let isDropTarget: Bool
    let onRename: () -> Void
    let onRecolor: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(playlist.color.swiftUIColor)
                .frame(width: 4, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    if isPlayingHere {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(playlist.color.swiftUIColor)
                    }
                }

                HStack(spacing: 4) {
                    Text("\(playlist.tracks.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if playlist.loopEnabled {
                        Image(systemName: "repeat")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }

                    if playlist.autoplayEnabled {
                        Image(systemName: "arrow.forward.to.line")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isHovering {
                Menu {
                    Button("Переименовать", action: onRename)
                    Button("Изменить цвет", action: onRecolor)
                    Divider()
                    Button("Переместить выше", action: onMoveUp)
                    Button("Переместить ниже", action: onMoveDown)
                    Divider()
                    Button("Удалить", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground)
        .cornerRadius(5)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: some View {
        Group {
            if isDropTarget {
                Color.accentColor.opacity(0.25)
            } else if isSelected {
                Color.accentColor.opacity(0.25)
            } else if isHovering {
                Color.primary.opacity(0.06)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Drop delegate для переноса плейлистов

private struct PlaylistDropDelegate: DropDelegate {
    let playlist: Playlist
    let playlists: [Playlist]
    let model: AppModel
    @Binding var dropTarget: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        dropTarget = playlist.id
    }

    func dropExited(info: DropInfo) {
        if dropTarget == playlist.id {
            dropTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil

        guard let item = info.itemProviders(for: [.utf8PlainText]).first else { return false }

        item.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { return }

            // Может быть ID плейлиста или группа ID треков
            if let playlistID = UUID(uuidString: text) {
                // Перемещение плейлиста
                guard let targetIndex = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
                DispatchQueue.main.async {
                    var sorted = playlists
                    guard let sourceIndex = sorted.firstIndex(where: { $0.id == playlistID }) else { return }
                    let moving = sorted.remove(at: sourceIndex)
                    let insertAt = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
                    sorted.insert(moving, at: insertAt)
                    for (index, pl) in sorted.enumerated() {
                        if let i = model.state.playlists.firstIndex(where: { $0.id == pl.id }) {
                            model.state.playlists[i].order = index
                        }
                    }
                    model.save()
                }
            } else {
                // Перемещение треков в этот плейлист
                let ids = text.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                guard !ids.isEmpty else { return }
                DispatchQueue.main.async {
                    model.moveTracks(ids: ids, to: playlist.id)
                }
            }
        }
        return true
    }
}
