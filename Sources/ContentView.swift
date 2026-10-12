// DJPLAYER-BUILD: v4 (2026-10-12)
import SwiftUI
import AppKit

/// Главное окно.
///
/// Раскладка:
///   слева  — список плейлистов
///   справа — waveform с маркерами обрезки, панель управления, список треков
struct ContentView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            PlaylistSidebar()
                .frame(minWidth: 210, idealWidth: 250, maxWidth: 340)

            mainContent
                .frame(minWidth: 600)
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            waveformAndControls
            Divider()
            TrackList()
        }
    }

    // MARK: - Waveform и элементы управления

    private var waveformAndControls: some View {
        VStack(spacing: 12) {
            waveformSection
                .padding(.horizontal, 16)
                .padding(.top, 16)

            transportBar
                .padding(.horizontal, 16)

            settingsBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var waveformSection: some View {
        let progressTime: TimeInterval
        let displayedDuration: TimeInterval
        let displayedTrimStart: TimeInterval
        let displayedTrimEnd: TimeInterval?

        if let displayed = model.displayedTrack {
            if model.audioEngine.currentTrack?.id == displayed.id {
                progressTime = model.audioEngine.currentTime
            } else {
                progressTime = 0
            }
            displayedDuration = displayed.duration
            displayedTrimStart = displayed.trimStart
            displayedTrimEnd = displayed.trimEnd
        } else {
            progressTime = 0
            displayedDuration = 0
            displayedTrimStart = 0
            displayedTrimEnd = nil
        }

        return VStack(spacing: 8) {
            WaveformView(
                peaks: model.displayedWaveform,
                currentTime: progressTime,
                duration: displayedDuration,
                accent: model.displayedWaveformColor,
                trimStart: displayedTrimStart,
                trimEnd: displayedTrimEnd,
                onSeek: { time, shouldPlay in
                    model.seekDisplayed(to: time, thenPlay: shouldPlay)
                },
                onTrimChanged: { start, end in
                    if let track = model.displayedTrack {
                        model.setTrim(for: track.id, start: start, end: end)
                    }
                }
            )
            .frame(height: 180)

            HStack(spacing: 6) {
                Text(progressTime.timecode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)

                Spacer()

                if let track = model.displayedTrack {
                    Text(track.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }

                Spacer()

                Text(displayedDuration.timecode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }

    // MARK: Панель управления и громкость

    private var transportBar: some View {
        HStack(spacing: 14) {
            // Предыдущий / Play / Pause / Следующий / Стоп
            HStack(spacing: 8) {
                Button {
                    model.playPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                        .frame(width: 22)
                }
                .help("Предыдущий трек")

                Button {
                    playSelectedOrResume()
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 26)
                }
                .help("Воспроизвести выделенный или возобновить (Пробел)")

                Button {
                    model.audioEngine.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 26)
                }
                .help("Пауза")
                .disabled(!model.audioEngine.isPlaying)

                Button {
                    model.playNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 22)
                }
                .help("Следующий трек")

                Button {
                    model.audioEngine.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 22)
                }
                .help("Стоп (Esc)")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 22)

            // Зацикливание трека и плейлиста
            Toggle(isOn: Binding(
                get: { model.state.settings.loopTrackEnabled },
                set: { value in model.updateSettings { $0.loopTrackEnabled = value } }
            )) {
                Image(systemName: "repeat.1")
            }
            .toggleStyle(.button)
            .help("Зациклить текущий трек")

            Toggle(isOn: Binding(
                get: { model.selectedPlaylist?.loopEnabled ?? false },
                set: { model.setLoopPlaylist($0) }
            )) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Зациклить плейлист")

            Toggle(isOn: Binding(
                get: { model.selectedPlaylist?.autoplayEnabled ?? false },
                set: { model.setAutoplay($0) }
            )) {
                Image(systemName: "arrow.forward.to.line")
            }
            .toggleStyle(.button)
            .help("Автоматически переходить к следующему треку")

            Divider().frame(height: 22)

            // Громкость
            HStack(spacing: 6) {
                Image(systemName: volumeIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Slider(value: Binding(
                    get: { model.state.settings.volume },
                    set: { model.setVolume($0) }
                ), in: 0...1)
                .frame(width: 110)
                .controlSize(.small)

                Text("\(Int(model.state.settings.volume * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }

            Spacer()
        }
    }

    /// Запускает выделенный трек, иначе возобновляет текущий или запускает первый.
    private func playSelectedOrResume() {
        if let playlist = model.selectedPlaylist, !model.selection.isEmpty,
           let first = model.selection.selectedTracks(from: playlist.tracks).first {
            model.play(track: first)
            return
        }
        if model.audioEngine.currentTrack != nil {
            model.audioEngine.resume()
        } else {
            model.playFirstTrackOfSelectedPlaylist()
        }
    }

    private var volumeIcon: String {
        let v = model.state.settings.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.4 { return "speaker.fill" }
        if v < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: Настройки переходов

    private var settingsBar: some View {
        HStack(spacing: 16) {
            settingsToggle(
                title: "Crossfade",
                enabled: Binding(
                    get: { model.state.settings.crossfadeEnabled },
                    set: { v in model.updateSettings { $0.crossfadeEnabled = v } }
                ),
                value: Binding(
                    get: { model.state.settings.crossfadeDuration },
                    set: { v in model.updateSettings { $0.crossfadeDuration = v } }
                ),
                range: 0.5...10,
                unit: "с"
            )

            settingsToggle(
                title: "High-cut",
                enabled: Binding(
                    get: { model.state.settings.highCutEnabled },
                    set: { v in model.updateSettings { $0.highCutEnabled = v } }
                ),
                value: Binding(
                    get: { model.state.settings.highCutDuration },
                    set: { v in model.updateSettings { $0.highCutDuration = v } }
                ),
                range: 0.2...5,
                unit: "с"
            )

            settingsSlider(
                title: "Пауза",
                enabled: true,
                value: Binding(
                    get: { model.state.settings.highCutPauseAfter },
                    set: { v in model.updateSettings { $0.highCutPauseAfter = v } }
                ),
                range: 0...10,
                unit: "с"
            )

            Spacer()
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private func settingsToggle(title: String, enabled: Binding<Bool>, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: enabled) {
                Text(title)
                    .foregroundStyle(enabled.wrappedValue ? Color.primary : Color.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)

            Slider(value: value, in: range)
                .frame(width: 80)
                .controlSize(.mini)
                .disabled(!enabled.wrappedValue)

            Text(String(format: "%.1f", value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(enabled.wrappedValue ? Color.primary : Color.secondary)
                .frame(width: 28, alignment: .leading)
        }
    }

    @ViewBuilder
    private func settingsSlider(title: String, enabled: Bool, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)

            Slider(value: value, in: range)
                .frame(width: 80)
                .controlSize(.mini)
                .disabled(!enabled)

            Text(String(format: "%.1f", value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 28, alignment: .leading)
        }
    }
}
