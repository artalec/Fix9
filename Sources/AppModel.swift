// DJPLAYER-BUILD: v4 (2026-10-12)
import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

/// Единая модель приложения: состояние (плейлисты, настройки), аудиодвижок и выделение.
final class AppModel: ObservableObject {

    static let shared = AppModel()

    @Published var state: AppState
    @Published var selectedPlaylistID: UUID?

    /// Пики waveform для трека, показанного на waveform (даже если он не играет).
    @Published private(set) var displayedWaveform: [Float] = []
    
    /// Цвет для waveform: запоминается при запуске трека и не меняется при смене плейлиста.
    @Published private(set) var displayedWaveformColor: RGBAColor = RGBAColor(red: 0.2, green: 0.55, blue: 1.0)

    private var waveformCache: [UUID: [Float]] = [:]

    /// Позиции, выбранные на waveform для треков, которые сейчас не играют.
    /// Применяются при запуске соответствующего трека.
    private var pendingSeek: [UUID: TimeInterval] = [:]
    private var waveformGeneration = 0

    let audioEngine = AudioEngine()
    let selection = SelectionManager()

    private let storage = StorageManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var autosaveWorkItem: DispatchWorkItem?

    private init() {
        let loaded = storage.load()
        self.state = loaded
        self.selectedPlaylistID = loaded.selectedPlaylistID ?? loaded.playlists.first?.id

        audioEngine.settings = loaded.settings

        audioEngine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        selection.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        $state
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutosave() }
            .store(in: &cancellables)

        $selectedPlaylistID
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutosave() }
            .store(in: &cancellables)

        audioEngine.applyVolume()

        audioEngine.onTrackFinished = { [weak self] in
            self?.handleTrackFinished()
        }

        // Waveform должен показываться и для выделенного, но не играющего трека,
        // поэтому перезагружаем пики при смене выделения и плейлиста.
        selection.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshDisplayedWaveform() }
            }
            .store(in: &cancellables)

        $selectedPlaylistID
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshDisplayedWaveform() }
            }
            .store(in: &cancellables)

        // Смена играющего трека тоже меняет waveform (кэш + цвет).
        // Подписка на objectWillChange движка здесь не нужна: он срабатывает
        // на каждом тике таймера, что и давало лишние пересчёты и подтормаживание.
        audioEngine.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshDisplayedWaveform() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Waveform выбранного трека

    /// Загружает пики для текущего displayedTrack (из кэша или с диска).
    func refreshDisplayedWaveform() {
        guard let track = displayedTrack else {
            displayedWaveform = []
            return
        }

        // Цвет waveform: запоминается при старте трека, потом не меняется.
        if audioEngine.currentTrack?.id == track.id {
            let effectiveColor = track.color ?? selectedPlaylist?.color ?? RGBAColor(red: 0.2, green: 0.55, blue: 1.0)
            displayedWaveformColor = effectiveColor
        }

        if let cached = waveformCache[track.id] {
            displayedWaveform = cached
            return
        }

        waveformGeneration += 1
        let generation = waveformGeneration
        let id = track.id

        Task { @MainActor [weak self] in
            let result = await WaveformGenerator.load(for: track)
            guard let self, generation == self.waveformGeneration else { return }
            self.waveformCache[id] = result.peaks
            // Длительность тоже могла ещё не быть известна
            if result.duration > 0 {
                self.updateDuration(for: id, duration: result.duration)
            }
            if self.displayedTrack?.id == id {
                self.displayedWaveform = result.peaks
            }
        }
    }

    // MARK: - Текущий плейлист

    var playlistsSorted: [Playlist] {
        state.playlists.sorted { $0.order < $1.order }
    }

    var selectedPlaylist: Playlist? {
        guard let id = selectedPlaylistID else { return nil }
        return state.playlists.first { $0.id == id }
    }

    var selectedPlaylistIndex: Int? {
        guard let id = selectedPlaylistID else { return nil }
        return state.playlists.firstIndex { $0.id == id }
    }

    func findTrack(_ id: UUID) -> Track? {
        for playlist in state.playlists {
            if let track = playlist.tracks.first(where: { $0.id == id }) { return track }
        }
        return nil
    }

    private func playlistContaining(trackID: UUID) -> Int? {
        state.playlists.firstIndex { $0.tracks.contains { $0.id == trackID } }
    }

    // MARK: - Трек, отображаемый на waveform

    /// Первый выделенный трек; если ничего не выделено — играющий.
    var displayedTrack: Track? {
        if let playlist = selectedPlaylist, !selection.isEmpty {
            return selection.selectedTracks(from: playlist.tracks).first
        }
        if let id = audioEngine.currentTrack?.id, let playing = findTrack(id) {
            return playing
        }
        return nil
    }

    // MARK: - Плейлисты

    func addPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Плейлист \(state.playlists.count + 1)" : trimmed
        let nextOrder = (state.playlists.map(\.order).max() ?? -1) + 1
        let color = RGBAColor.palette[state.playlists.count % RGBAColor.palette.count]
        let playlist = Playlist(name: title, color: color, order: nextOrder)
        state.playlists.append(playlist)
        selectedPlaylistID = playlist.id
        selection.clear()
        save()
    }

    func renamePlaylist(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        state.playlists[index].name = trimmed
        save()
    }

    func setColor(_ color: RGBAColor, for id: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        state.playlists[index].color = color
        save()
    }

    func deletePlaylist(id: UUID) {
        audioEngine.stop()
        state.playlists.removeAll { $0.id == id }
        if state.playlists.isEmpty {
            state.playlists = [Playlist(name: "Плейлист 1", order: 0)]
        }
        reindexPlaylists()
        if selectedPlaylistID == id {
            selectedPlaylistID = playlistsSorted.first?.id
        }
        selection.clear()
        save()
    }

    func movePlaylists(from source: IndexSet, to destination: Int) {
        var sorted = playlistsSorted
        sorted.move(fromOffsets: source, toOffset: destination)
        for (index, playlist) in sorted.enumerated() {
            if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                state.playlists[i].order = index
            }
        }
        save()
    }

    /// Сдвиг плейлиста на позицию выше (гарантированный способ без drag-n-drop).
    func movePlaylistUp(id: UUID) {
        var sorted = playlistsSorted
        guard let i = sorted.firstIndex(where: { $0.id == id }), i > 0 else { return }
        sorted.swapAt(i, i - 1)
        applyPlaylistOrder(sorted)
    }

    /// Сдвиг плейлиста на позицию ниже.
    func movePlaylistDown(id: UUID) {
        var sorted = playlistsSorted
        guard let i = sorted.firstIndex(where: { $0.id == id }), i < sorted.count - 1 else { return }
        sorted.swapAt(i, i + 1)
        applyPlaylistOrder(sorted)
    }

    private func applyPlaylistOrder(_ sorted: [Playlist]) {
        for (index, playlist) in sorted.enumerated() {
            if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                state.playlists[i].order = index
            }
        }
        save()
    }

    private func reindexPlaylists() {
        let sorted = playlistsSorted
        for (index, playlist) in sorted.enumerated() {
            if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                state.playlists[i].order = index
            }
        }
    }

    // MARK: - Настройки плейлиста

    func setLoopPlaylist(_ enabled: Bool) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].loopEnabled = enabled
        save()
    }

    func setAutoplay(_ enabled: Bool) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].autoplayEnabled = enabled
        save()
    }

    // MARK: - Треки

    func addTracks(urls: [URL]) {
        guard let playlistID = selectedPlaylistID,
              let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }

        let existingPaths = Set(state.playlists[index].tracks.map(\.path))
        var added: [Track] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            guard !existingPaths.contains(standardized.path) else { continue }
            added.append(Track(url: standardized))
        }

        guard !added.isEmpty else { return }
        state.playlists[index].tracks.append(contentsOf: added)
        save()

        Task { @MainActor [weak self] in
            for track in added {
                let result = await WaveformGenerator.load(for: track)
                self?.updateDuration(for: track.id, duration: result.duration)
            }
        }
    }

    private func updateDuration(for trackID: UUID, duration: TimeInterval) {
        guard duration > 0 else { return }
        for pIndex in state.playlists.indices {
            if let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) {
                state.playlists[pIndex].tracks[tIndex].duration = duration
                scheduleAutosave()
                return
            }
        }
    }

    func removeTracks(at offsets: IndexSet) {
        guard let index = selectedPlaylistIndex else { return }
        let removing = offsets.map { state.playlists[index].tracks[$0] }
        removeTracks(ids: removing.map(\.id))
    }

    func removeTrack(id: UUID) {
        removeTracks(ids: [id])
    }

    func removeSelectedTracks() {
        removeTracks(ids: Array(selection.selectedIDs))
    }

    func removeTracks(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        
        if let current = audioEngine.currentTrack, idSet.contains(current.id) {
            audioEngine.stop()
        }
        
        for pIndex in state.playlists.indices {
            state.playlists[pIndex].tracks.removeAll { idSet.contains($0.id) }
        }
        
        selection.clear()
        save()
    }

    func moveTracks(from source: IndexSet, to destination: Int) {
        guard let index = selectedPlaylistIndex else { return }
        state.playlists[index].tracks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Сдвиг трека на одну позицию вверх.
    func moveTrackUp(id: UUID) {
        guard let pIndex = playlistContaining(trackID: id),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }),
              tIndex > 0 else { return }
        state.playlists[pIndex].tracks.swapAt(tIndex, tIndex - 1)
        save()
    }

    /// Сдвиг трека на одну позицию вниз.
    func moveTrackDown(id: UUID) {
        guard let pIndex = playlistContaining(trackID: id),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }),
              tIndex < state.playlists[pIndex].tracks.count - 1 else { return }
        state.playlists[pIndex].tracks.swapAt(tIndex, tIndex + 1)
        save()
    }

    /// Переупорядочивание треков в текущем плейлисте.
    /// Треки вставляются перед элементом с индексом `toIndex` текущего плейлиста.
    /// Если треки пришли из другого плейлиста, они переносятся сюда.
    func reorderTracks(ids: [UUID], toIndex: Int) {
        guard let index = selectedPlaylistIndex, !ids.isEmpty else { return }
        let moving = Set(ids)

        let current = state.playlists[index].tracks
        let clampedTarget = max(0, min(toIndex, current.count))

        // Порядок берём из текущего плейлиста, чужие треки добавляем в конец группы
        let orderedLocal = current.filter { moving.contains($0.id) }
        let localIDs = Set(orderedLocal.map(\.id))
        var foreign: [Track] = []
        for pIndex in state.playlists.indices where pIndex != index {
            foreign.append(contentsOf: state.playlists[pIndex].tracks.filter {
                moving.contains($0.id) && !localIDs.contains($0.id)
            })
        }
        let movingTracks = orderedLocal + foreign
        guard !movingTracks.isEmpty else { return }

        // Сколько перемещаемых треков стояло до точки вставки — смещаем индекс
        let removedBefore = current.prefix(clampedTarget).filter { moving.contains($0.id) }.count

        for pIndex in state.playlists.indices {
            state.playlists[pIndex].tracks.removeAll { moving.contains($0.id) }
        }

        let remainingCount = state.playlists[index].tracks.count
        let insertAt = max(0, min(clampedTarget - removedBefore, remainingCount))
        state.playlists[index].tracks.insert(contentsOf: movingTracks, at: insertAt)
        save()
    }

    /// Перенос треков в другой плейлист.
    func moveTracks(ids: [UUID], to targetPlaylistID: UUID) {
        guard targetPlaylistID != selectedPlaylistID, !ids.isEmpty else { return }
        let moving = Set(ids)

        var collected: [Track] = []
        for pIndex in state.playlists.indices {
            let taken = state.playlists[pIndex].tracks.filter { moving.contains($0.id) }
            collected.append(contentsOf: taken)
            state.playlists[pIndex].tracks.removeAll { moving.contains($0.id) }
        }

        guard let targetIndex = state.playlists.firstIndex(where: { $0.id == targetPlaylistID }) else { return }
        state.playlists[targetIndex].tracks.append(contentsOf: collected)
        
        selection.clear()
        save()
    }

    // MARK: - Атрибуты треков

    func setTrackColor(_ color: RGBAColor?, for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].color = color
        syncEngineTrack(trackID)
        save()
    }

    func setColorForSelected(_ color: RGBAColor?) {
        for id in selection.selectedIDs {
            guard let pIndex = playlistContaining(trackID: id),
                  let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }) else { continue }
            state.playlists[pIndex].tracks[tIndex].color = color
        }
        save()
    }

    func toggleDeleteAfterPlay(for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].deleteAfterPlay.toggle()
        syncEngineTrack(trackID)
        save()
    }

    func toggleDeleteAfterPlayForSelected() {
        let ids = selection.selectedIDs
        guard !ids.isEmpty else { return }
        // Если хотя бы у одного выключено — включаем у всех, иначе выключаем.
        let anyOff = ids.contains { id in
            findTrack(id)?.deleteAfterPlay == false
        }
        for id in ids {
            guard let pIndex = playlistContaining(trackID: id),
                  let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == id }) else { continue }
            state.playlists[pIndex].tracks[tIndex].deleteAfterPlay = anyOff
        }
        save()
    }

    // MARK: - Audio Trim

    /// Устанавливает точки обрезки. Значения в секундах от начала файла.
    func setTrim(for trackID: UUID, start: TimeInterval?, end: TimeInterval?) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        var track = state.playlists[pIndex].tracks[tIndex]
        let total = track.duration
        
        if let start {
            track.trimStart = max(0, min(start, total > 0 ? total - 0.1 : start))
        }
        if let end {
            let clamped = max(0, min(end, total > 0 ? total : end))
            // Если точка совпадает с концом файла — храним nil (значит "до конца")
            if total > 0 && abs(clamped - total) < 0.05 {
                track.trimEnd = nil
            } else {
                track.trimEnd = clamped
            }
        }
        
        // Не даём точкам пересечься
        if let end = track.trimEnd, track.trimStart >= end {
            track.trimStart = max(0, end - 0.1)
        }
        
        state.playlists[pIndex].tracks[tIndex] = track
        syncEngineTrack(trackID)
        scheduleAutosave()
    }

    func resetTrim(for trackID: UUID) {
        guard let pIndex = playlistContaining(trackID: trackID),
              let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        state.playlists[pIndex].tracks[tIndex].trimStart = 0
        state.playlists[pIndex].tracks[tIndex].trimEnd = nil
        syncEngineTrack(trackID)
        save()
    }

    private func syncEngineTrack(_ trackID: UUID) {
        guard audioEngine.currentTrack?.id == trackID, let track = findTrack(trackID) else { return }
        audioEngine.syncCurrentTrack(track)
    }

    // MARK: - Воспроизведение

    func play(track: Track) {
        audioEngine.play(track: track)

        // Если для трека заранее выбрана точка на waveform — стартуем с неё.
        if let position = pendingSeek.removeValue(forKey: track.id), position > 0 {
            audioEngine.seek(to: position)
        }

        // Запомним цвет трека при его запуске — не будет меняться при смене плейлиста.
        let effectiveColor = track.color ?? selectedPlaylist?.color ?? RGBAColor(red: 0.2, green: 0.55, blue: 1.0)
        displayedWaveformColor = effectiveColor
    }

    func playFirstTrackOfSelectedPlaylist() {
        guard let playlist = selectedPlaylist, let first = playlist.tracks.first else { return }
        play(track: first)
    }

    func togglePlayPause() {
        // Если играет именно выделенный трек — ставим на паузу
        if audioEngine.isPlaying,
           let currentID = audioEngine.currentTrack?.id,
           selection.isSelected(currentID) {
            audioEngine.pause()
            return
        }

        // Если выделен другой трек — запускаем его
        if let playlist = selectedPlaylist, !selection.isEmpty,
           let first = selection.selectedTracks(from: playlist.tracks).first {
            play(track: first)
            return
        }

        // Иначе: пауза / продолжить / первый трек плейлиста
        if audioEngine.isPlaying {
            audioEngine.pause()
        } else if audioEngine.currentTrack != nil {
            audioEngine.resume()
        } else {
            playFirstTrackOfSelectedPlaylist()
        }
    }

    /// Переход к следующему треку плейлиста (по кругу, если включено зацикливание).
    func playNext() {
        guard let playlist = selectedPlaylist, !playlist.tracks.isEmpty else { return }
        guard let currentID = audioEngine.currentTrack?.id,
              let currentIndex = playlist.tracks.firstIndex(where: { $0.id == currentID }) else {
            playFirstTrackOfSelectedPlaylist()
            return
        }
        let nextIndex = currentIndex + 1
        if nextIndex < playlist.tracks.count {
            play(track: playlist.tracks[nextIndex])
        } else if playlist.loopEnabled {
            play(track: playlist.tracks[0])
        } else {
            audioEngine.stop()
        }
    }

    /// Переход к предыдущему треку.
    func playPrevious() {
        guard let playlist = selectedPlaylist, !playlist.tracks.isEmpty else { return }
        guard let currentID = audioEngine.currentTrack?.id,
              let currentIndex = playlist.tracks.firstIndex(where: { $0.id == currentID }) else {
            playFirstTrackOfSelectedPlaylist()
            return
        }
        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            play(track: playlist.tracks[previousIndex])
        } else if playlist.loopEnabled {
            play(track: playlist.tracks[playlist.tracks.count - 1])
        } else {
            // На первом треке — начинаем его заново
            audioEngine.seek(to: 0)
        }
    }

    // MARK: - Завершение трека

    private func handleTrackFinished() {
        guard let finished = audioEngine.currentTrack else { return }
        let finishedID = finished.id
        
        // 1. Зацикливание трека — играем его же сначала.
        if state.settings.loopTrackEnabled {
            let resumed: Track
            if let pIndex = playlistContaining(trackID: finishedID),
               let tIndex = state.playlists[pIndex].tracks.firstIndex(where: { $0.id == finishedID }) {
                resumed = state.playlists[pIndex].tracks[tIndex]
            } else {
                resumed = finished
            }
            audioEngine.play(track: resumed)
            return
        }
        
        guard let playlist = selectedPlaylist,
              let index = playlist.tracks.firstIndex(where: { $0.id == finishedID }) else {
            audioEngine.stop()
            return
        }
        
        // 2. Удаление после полного проигрывания.
        if playlist.tracks[index].deleteAfterPlay {
            removeTracks(ids: [finishedID])
            // После удаления список сдвинулся: играем трек, который встал на это место
            if let nextPlaylist = selectedPlaylist, index < nextPlaylist.tracks.count {
                play(track: nextPlaylist.tracks[index])
            } else if let nextPlaylist = selectedPlaylist, nextPlaylist.loopEnabled,
                      let first = nextPlaylist.tracks.first {
                play(track: first)
            } else {
                audioEngine.stop()
            }
            return
        }
        
        // 3. Автопереход на следующий трек.
        guard playlist.autoplayEnabled else {
            audioEngine.stop()
            return
        }
        
        let nextIndex = index + 1
        if nextIndex < playlist.tracks.count {
            play(track: playlist.tracks[nextIndex])
        } else if playlist.loopEnabled, let first = playlist.tracks.first {
            play(track: first)
        } else {
            audioEngine.stop()
        }
    }

    // MARK: - Перемотка

    /// Перематывает трек, показанный на waveform. 
    /// ВАЖНО: не трогает играющий трек, если на waveform показан другой.
    func seekDisplayed(to time: TimeInterval, thenPlay: Bool) {
        guard let track = displayedTrack else { return }

        // Если на waveform показан играющий трек — перематываем его.
        if audioEngine.currentTrack?.id == track.id {
            audioEngine.seek(to: time)
            if thenPlay && !audioEngine.isPlaying {
                audioEngine.resume()
            }
        } else {
            // Играющий трек не трогаем совсем — он продолжает играть.
            // Для выбранного трека запоминаем точку: она применится при запуске.
            pendingSeek[track.id] = max(0, min(time, track.effectiveDuration))
        }
    }

    // MARK: - Навигация по спискам

    func selectNextTrack() {
        guard let playlist = selectedPlaylist, !playlist.tracks.isEmpty else { return }
        if selection.isEmpty {
            selection.selectSingle(playlist.tracks.first!.id)
        } else if let current = selection.selectedTracks(from: playlist.tracks).first,
                  let index = playlist.tracks.firstIndex(where: { $0.id == current.id }),
                  index + 1 < playlist.tracks.count {
            selection.selectSingle(playlist.tracks[index + 1].id)
        }
    }

    func selectPreviousTrack() {
        guard let playlist = selectedPlaylist, !playlist.tracks.isEmpty else { return }
        if selection.isEmpty {
            selection.selectSingle(playlist.tracks.last!.id)
        } else if let current = selection.selectedTracks(from: playlist.tracks).first,
                  let index = playlist.tracks.firstIndex(where: { $0.id == current.id }),
                  index > 0 {
            selection.selectSingle(playlist.tracks[index - 1].id)
        }
    }

    func selectNextPlaylist() {
        let sorted = playlistsSorted
        guard !sorted.isEmpty else { return }
        if let current = selectedPlaylist,
           let index = sorted.firstIndex(where: { $0.id == current.id }),
           index + 1 < sorted.count {
            selectedPlaylistID = sorted[index + 1].id
        } else {
            selectedPlaylistID = sorted.first?.id
        }
        selection.clear()
    }

    func selectPreviousPlaylist() {
        let sorted = playlistsSorted
        guard !sorted.isEmpty else { return }
        if let current = selectedPlaylist,
           let index = sorted.firstIndex(where: { $0.id == current.id }),
           index > 0 {
            selectedPlaylistID = sorted[index - 1].id
        } else {
            selectedPlaylistID = sorted.last?.id
        }
        selection.clear()
    }

    // MARK: - Настройки

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        transform(&state.settings)
        audioEngine.settings = state.settings
        audioEngine.applyVolume()
        scheduleAutosave()
    }

    func setVolume(_ value: Double) {
        updateSettings { $0.volume = max(0, min(value, 1)) }
    }

    // MARK: - UI helpers

    func presentAddTracksPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Только статические типы: failable-инициализатор UTType(...)
        // зависит от импорта и версии SDK, а .audio и так покрывает все
        // аудиоформаты при выборе файлов.
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK {
            addTracks(urls: panel.urls)
        }
    }

    // MARK: - Сохранение

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        autosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    func save() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        state.selectedPlaylistID = selectedPlaylistID
        storage.save(state)
    }

    // MARK: - Экспорт / импорт

    func exportSelectedPlaylist(to url: URL) {
        guard let playlist = selectedPlaylist else { return }
        do { try storage.export(playlist, to: url) }
        catch { NSLog("DJPlayer: экспорт не удался — \(error.localizedDescription)") }
    }

    func importPlaylist(from url: URL) {
        do {
            var playlist = try storage.`import`(from: url)
            playlist.order = (state.playlists.map(\.order).max() ?? -1) + 1
            state.playlists.append(playlist)
            selectedPlaylistID = playlist.id
            save()
        } catch {
            NSLog("DJPlayer: импорт не удался — \(error.localizedDescription)")
        }
    }
}
