// DJPLAYER-BUILD: v4 (2026-10-12)
import Foundation
import AVFoundation
import Combine

/// Аудиодвижок с поддержкой trim, seek, громкости, автоперехода на следующий трек.
///
/// Два независимых канала (A и B) для честного кроссфейда. У каждого канала своя
/// цепочка player → EQ → mainMixer. Защита от крашей: все обращения к AVAudioFile
/// и scheduleFile обёрнуты в do-catch с логом.
final class AudioEngine: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var waveform: [Float] = []

    var settings = AppSettings()
    var onTrackFinished: (() -> Void)?

    private let engine = AVAudioEngine()
    private let mainMixer = AVAudioMixerNode()

    private var channels: [Channel] = []
    private var activeIndex = 0

    private var activeFileOffset: TimeInterval = 0
    private var isTransitioning = false

    private var timeTimer: Timer?
    private var rampTimer: Timer?
    private var rampGeneration = 0

    private let rampStepsPerSecond: Double = 60
    private let lowPassOpenFrequency: Float = 20000
    private let lowPassClosedFrequency: Float = 500

    // MARK: - Структуры

    private class Channel {
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        var file: AVAudioFile?
        var generation = 0
    }

    // MARK: - Инициализация

    init() {
        do {
            engine.attach(mainMixer)
            engine.connect(mainMixer, to: engine.mainMixerNode, format: nil)

            for _ in 0..<2 {
                let ch = Channel()
                ch.eq.bypass = true
                if let band = ch.eq.bands.first {
                    band.filterType = .lowPass
                    band.frequency = lowPassOpenFrequency
                    band.bypass = true
                }
                engine.attach(ch.player)
                engine.attach(ch.eq)
                engine.connect(ch.player, to: ch.eq, format: nil)
                engine.connect(ch.eq, to: mainMixer, format: nil)
                channels.append(ch)
            }

            try engine.start()
        } catch {
            NSLog("DJPlayer: не удалось запустить аудиодвижок — \(error.localizedDescription)")
        }
    }

    // MARK: - Управление

    func play(track: Track) {
        let useTransition = isPlaying && !isTransitioning
        if useTransition && settings.crossfadeEnabled {
            transitionWithCrossfade(to: track)
        } else if useTransition && settings.highCutEnabled {
            transitionWithHighCut(to: track)
        } else {
            hardSwitch(to: track, autoplay: true)
        }

        Task {
            let result = await WaveformGenerator.load(for: track)
            await MainActor.run { [weak self] in
                if self?.currentTrack?.id == track.id {
                    self?.waveform = result.peaks
                }
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        channels[activeIndex].player.pause()
        stopTimeTimer()
        isPlaying = false
    }

    func resume() {
        guard !isPlaying, currentTrack != nil else { return }
        channels[activeIndex].player.play()
        startTimeTimer()
        isPlaying = true
    }

    func stop() {
        cancelRamp()
        for channel in channels {
            channel.generation += 1
            channel.player.stop()
            channel.player.volume = 1.0
            channel.file = nil
            resetLowPass(channel)
        }
        stopTimeTimer()
        isPlaying = false
        isTransitioning = false
        currentTrack = nil
        currentTime = 0
        activeFileOffset = 0
        waveform = []
    }

    func seek(to time: TimeInterval) {
        performSeek(to: time, autoplay: isPlaying)
    }

    /// Перемотка трека, который может ещё не играть.
    /// Если это другой трек — он загружается на паузе, затем ставится позиция.
    func seekOrLoad(track: Track, position: TimeInterval) {
        if currentTrack?.id != track.id {
            guard hardSwitch(to: track, autoplay: false) else { return }
        }
        performSeek(to: position, autoplay: false)
    }

    private func performSeek(to time: TimeInterval, autoplay: Bool) {
        guard let track = currentTrack else { return }

        // Останавливаем активный канал
        let channel = channels[activeIndex]
        channel.player.stop()
        stopTimeTimer()
        isPlaying = false

        // Перезапускаем с новой позиции
        let position = max(0, min(time, track.effectiveDuration))
        if startSegment(track: track, onChannel: activeIndex, position: position, autoplay: autoplay) {
            if autoplay {
                isPlaying = true
                startTimeTimer()
            }
        }
    }

    // MARK: - Синхронизация изменённого трека

    /// Обновляет данные трека (trim-точки, цвет) и перепланирует воспроизведение.
    func syncCurrentTrack(_ track: Track) {
        guard let old = currentTrack, old.id == track.id else { return }
        let wasPlaying = isPlaying
        let position = currentTime

        currentTrack = track

        // Границы сегмента изменились — надо перепланировать воспроизведение.
        if old.trimStart != track.trimStart || old.trimEnd != track.trimEnd {
            let clamped = max(0, min(position, track.effectiveDuration))
            // Сохраняем прежнее состояние: если трек стоял на паузе, он должен
            // остаться на паузе после перепланирования.
            if startSegment(track: track, onChannel: activeIndex, position: clamped, autoplay: wasPlaying) {
                if wasPlaying {
                    isPlaying = true
                    startTimeTimer()
                }
            }
        }
    }

    // MARK: - Громкость

    func applyVolume() {
        mainMixer.outputVolume = Float(settings.volume)
    }

    // MARK: - Внутренние методы

    @discardableResult
    private func hardSwitch(to track: Track, autoplay: Bool = true) -> Bool {
        cancelRamp()

        for channel in channels {
            channel.generation += 1
            channel.player.stop()
            channel.player.volume = 1.0
            resetLowPass(channel)
        }

        let index = 0
        activeIndex = index
        let started = startSegment(track: track, onChannel: index, position: 0, autoplay: autoplay)
        if started && autoplay {
            isPlaying = true
        }
        return started
    }

    private func transitionWithCrossfade(to track: Track) {
        let oldIndex = activeIndex
        let newIndex = 1 - oldIndex
        activeIndex = newIndex

        guard startSegment(track: track, onChannel: newIndex, startVolume: 0) else {
            return
        }

        isTransitioning = true

        let duration = max(0.5, settings.crossfadeDuration)
        let steps = max(2, Int(duration * rampStepsPerSecond))
        let interval = duration / Double(steps)
        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        let oldChannel = channels[oldIndex]
        let newChannel = channels[newIndex]

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)

            oldChannel.player.volume = 1 - progress
            newChannel.player.volume = progress

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil
                oldChannel.generation += 1
                oldChannel.player.stop()
                oldChannel.player.volume = 1.0
                oldChannel.file = nil
                self.isTransitioning = false
            }
        }
    }

    private func transitionWithHighCut(to track: Track) {
        cancelRamp()

        let oldIndex = activeIndex
        let oldChannel = channels[oldIndex]

        isTransitioning = true
        isPlaying = true

        let duration = max(0.2, settings.highCutDuration)
        let steps = max(2, Int(duration * rampStepsPerSecond))
        let interval = duration / Double(steps)
        rampGeneration += 1
        let generation = rampGeneration
        var step = 0

        if let band = oldChannel.eq.bands.first {
            band.bypass = false
            band.frequency = lowPassOpenFrequency
        }

        rampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            step += 1
            let progress = Float(min(step, steps)) / Float(steps)

            if let band = oldChannel.eq.bands.first {
                let curve = pow(progress, 1.5)
                band.frequency = self.lowPassOpenFrequency * pow(self.lowPassClosedFrequency / self.lowPassOpenFrequency, curve)
            }
            oldChannel.player.volume = max(0, 1 - progress * 0.6)

            if step >= steps {
                timer.invalidate()
                self.rampTimer = nil

                oldChannel.generation += 1
                oldChannel.player.stop()
                oldChannel.player.volume = 1.0
                oldChannel.file = nil
                self.resetLowPass(oldChannel)

                // Пауза после high-cut перед запуском следующего
                let pauseAfter = self.settings.highCutPauseAfter
                if pauseAfter > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pauseAfter) { [weak self] in
                        guard let self else { return }
                        let newIndex = 1 - oldIndex
                        self.activeIndex = newIndex
                        if self.startSegment(track: track, onChannel: newIndex, position: 0) {
                            self.isPlaying = true
                        }
                        self.isTransitioning = false
                    }
                } else {
                    let newIndex = 1 - oldIndex
                    self.activeIndex = newIndex
                    if self.startSegment(track: track, onChannel: newIndex, position: 0) {
                        self.isPlaying = true
                    }
                    self.isTransitioning = false
                }
            }
        }
    }

    /// Запускает сегмент трека с trimStart до trimEnd (или до конца файла).
    /// `position` — время относительно trimStart (0 = начало trimStart).
    /// Все обращения к AVAudioFile обёрнуты в do-catch — файл может быть битым или отсутствовать.
    @discardableResult
    private func startSegment(track: Track, onChannel index: Int, position: TimeInterval = 0, startVolume: Float = 1.0, autoplay: Bool = true) -> Bool {
        guard index >= 0, index < channels.count else { return false }
        let channel = channels[index]

        do {
            let file = try AVAudioFile(forReading: track.url)
            let format = file.processingFormat
            let rate = format.sampleRate
            let totalFrames = file.length
            
            guard rate > 0, totalFrames > 0 else {
                NSLog("DJPlayer: файл пуст или имеет нулевую частоту — \(track.path)")
                return false
            }

            // Позиция в файле = trimStart + position
            let startSec = track.trimStart + position
            let endSec = track.trimEnd ?? Double(totalFrames) / rate
            let startFrame = AVAudioFramePosition(startSec * rate)
            let endFrame = AVAudioFramePosition(min(endSec * rate, Double(totalFrames)))

            guard startFrame >= 0, startFrame < totalFrames, endFrame > startFrame else {
                NSLog("DJPlayer: некорректная позиция trim — \(track.path)")
                return false
            }

            let frameCount = AVAudioFrameCount(endFrame - startFrame)

            // Сначала меняем поколение: колбэк остановленного трека не должен
            // запускать переход. Потом останавливаем плеер.
            channel.generation += 1
            channel.player.stop()
            channel.file = file
            channel.player.volume = startVolume

            // Файл может иметь другую частоту/число каналов. Перед планированием
            // переподключаем узлы под его формат, иначе scheduleSegment падает.
            engine.disconnectNodeOutput(channel.player)
            engine.disconnectNodeOutput(channel.eq)
            engine.connect(channel.player, to: channel.eq, format: format)
            engine.connect(channel.eq, to: mainMixer, format: format)
            if !engine.isRunning {
                try engine.start()
            }

            channel.player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: frameCount,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self, generation = channel.generation, trackID = track.id] _ in
                DispatchQueue.main.async {
                    guard let self, generation == channel.generation,
                          self.currentTrack?.id == trackID else { return }
                    self.onTrackFinished?()
                }
            }

            // При autoplay = false трек загружается, но остаётся на паузе:
            // это нужно, чтобы можно было перематывать ещё не игравший трек.
            if autoplay {
                channel.player.play()
            }

            currentTrack = track
            currentTime = position
            activeFileOffset = startSec
            if autoplay {
                startTimeTimer()
            }

            return true

        } catch {
            NSLog("DJPlayer: не удалось прочитать файл — \(track.path): \(error.localizedDescription)")
            return false
        }
    }

    private func resetLowPass(_ channel: Channel) {
        guard let band = channel.eq.bands.first else { return }
        band.bypass = true
        band.frequency = lowPassOpenFrequency
    }

    private func cancelRamp() {
        rampGeneration += 1
        rampTimer?.invalidate()
        rampTimer = nil
    }

    // MARK: - Таймер времени

    private func startTimeTimer() {
        stopTimeTimer()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateTime()
        }
    }

    private func stopTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = nil
    }

    private func updateTime() {
        guard let track = currentTrack, isPlaying else { return }
        let player = channels[activeIndex].player

        if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
            currentTime = max(0, min(elapsed, track.effectiveDuration))
        }
    }
}
