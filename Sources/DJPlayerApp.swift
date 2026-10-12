// DJPLAYER-BUILD: v4 (2026-10-12)
import SwiftUI
import AppKit

// MARK: - Application entry point
// ВАЖНО: файл намеренно НЕ называется main.swift. Если положить @main
// в файл с именем main.swift, компилятор трактует модуль как содержащий
// top-level код и падает с ошибкой
// "'main' attribute cannot be used in a module that contains top-level code".

@main
struct DJPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("DJPlayer") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Добавить треки…") {
                    AppModel.shared.presentAddTracksPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Воспроизведение") {
                Button("Воспроизвести / пауза") {
                    AppModel.shared.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Остановить") {
                    AppModel.shared.audioEngine.stop()
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("Предыдущий трек") {
                    AppModel.shared.playPrevious()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("Следующий трек") {
                    AppModel.shared.playNext()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Divider()

                Button("Зациклить трек") {
                    AppModel.shared.updateSettings { $0.loopTrackEnabled.toggle() }
                }

                Button("Зациклить плейлист") {
                    let current = AppModel.shared.selectedPlaylist?.loopEnabled ?? false
                    AppModel.shared.setLoopPlaylist(!current)
                }

                Button("Автопереход к следующему") {
                    let current = AppModel.shared.selectedPlaylist?.autoplayEnabled ?? false
                    AppModel.shared.setAutoplay(!current)
                }
            }

            CommandMenu("Выделение") {
                Button("Выделить все треки") {
                    let ids = AppModel.shared.selectedPlaylist?.tracks.map(\.id) ?? []
                    AppModel.shared.selection.selectAll(ids)
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("Снять выделение") {
                    AppModel.shared.selection.clear()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Следующий трек (↓)") {
                    AppModel.shared.selectNextTrack()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Предыдущий трек (↑)") {
                    AppModel.shared.selectPreviousTrack()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Divider()

                Button("Удалить выделенные треки") {
                    AppModel.shared.removeSelectedTracks()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(AppModel.shared.selection.isEmpty)
            }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Перехват клавиш на уровне окна: работает и в macOS 13, где
        // SwiftUI .onKeyPress ещё недоступен.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Не перехватываем ввод в текстовых полях
            if event.window?.firstResponder is NSTextView { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let model = AppModel.shared

            switch event.keyCode {
            case 49: // Space — играть/пауза
                guard flags.isEmpty else { return event }
                model.togglePlayPause()
                return nil

            case 53: // Escape — стоп
                model.audioEngine.stop()
                return nil

            case 125: // Стрелка вниз
                if flags.contains(.option) {
                    // ⌥↓ — следующий плейлист
                    model.selectNextPlaylist()
                } else if flags.isEmpty {
                    // ↓ — следующий трек
                    model.selectNextTrack()
                } else {
                    return event
                }
                return nil

            case 126: // Стрелка вверх
                if flags.contains(.option) {
                    // ⌥↑ — предыдущий плейлист
                    model.selectPreviousPlaylist()
                } else if flags.isEmpty {
                    // ↑ — предыдущий трек
                    model.selectPreviousTrack()
                } else {
                    return event
                }
                return nil

            case 36, 76: // Return / Enter — играть выделенный
                guard flags.isEmpty else { return event }
                if let playlist = model.selectedPlaylist,
                   let first = model.selection.selectedTracks(from: playlist.tracks).first {
                    model.play(track: first)
                    return nil
                }
                return event

            default:
                return event
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.save()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
