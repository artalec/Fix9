// DJPLAYER-BUILD: v4 (2026-10-12)
import Foundation
import AVFoundation
import Accelerate

/// Считает пики для waveform и уточняет длительность файла.
///
/// Оптимизации, из-за отсутствия которых waveform «подтормаживал»:
///   1. Пики считаются через Accelerate (vDSP), а не поэлементным циклом Swift.
///   2. Готовые пики кэшируются в памяти и на диске — повторный показ мгновенный.
///   3. Работа идёт на отдельной последовательной очереди, поэтому интерфейс не блокируется.
///   4. Пустой результат не кэшируется, чтобы файл можно было пересчитать позже.
enum WaveformGenerator {

    struct WaveformData {
        var peaks: [Float]
        var duration: TimeInterval
    }

    static let targetPeakCount = 900

    /// Последовательная очередь: не даём нескольким тяжёлым декодированиям
    /// конкурировать за диск и процессор.
    private static let queue = DispatchQueue(label: "ai.syntx.djplayer.waveform", qos: .utility)

    private static var memoryCache: [String: WaveformData] = [:]
    private static let memoryLock = NSLock()

    // MARK: - Публичный вход

    static func load(for track: Track) async -> WaveformData {
        let key = cacheKey(for: track)

        if let cached = memoryCached(key) {
            return cached
        }
        if let fromDisk = readDiskCache(key: key) {
            memoryStore(key, fromDisk)
            return fromDisk
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                let data = compute(path: track.path)
                // Пустой результат не сохраняем: файл может стать доступен позже.
                if !data.peaks.isEmpty {
                    memoryStore(key, data)
                    writeDiskCache(key: key, data: data)
                }
                continuation.resume(returning: data)
            }
        }
    }

    /// Ключ кэша: путь + дата изменения + размер.
    /// Если файл подменили, ключ изменится и пики пересчитаются.
    private static func cacheKey(for track: Track) -> String {
        let url = track.url
        let attrs = try? FileManager.default.attributesOfItem(atPath: track.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(url.path)|\(mtime)|\(size)"
    }

    // MARK: - Подсчёт пиков

    private static func compute(path: String) -> WaveformData {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            return WaveformData(peaks: [], duration: 0)
        }

        // processingFormat у AVAudioFile всегда float32, deinterleaved —
        // поэтому floatChannelData безопасен.
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, format.sampleRate > 0, format.channelCount > 0 else {
            return WaveformData(peaks: [], duration: 0)
        }

        let duration = Double(totalFrames) / format.sampleRate
        let framesPerPeak = max(1, Int(totalFrames) / targetPeakCount)

        let bufferSize: AVAudioFrameCount = 32768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
            return WaveformData(peaks: [], duration: duration)
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(targetPeakCount + 1)

        let channelCount = Int(format.channelCount)
        var framesLeftInPeak = framesPerPeak
        var currentPeak: Float = 0
        var remaining = totalFrames

        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(Int64(bufferSize), remaining))
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }

            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { break }

            guard let channels = buffer.floatChannelData else { break }

            // Разбираем прочитанный блок по «вёдрам» пиков.
            var offset = 0
            while offset < framesRead {
                let take = min(framesLeftInPeak, framesRead - offset)
                if take <= 0 { break }

                var blockMax: Float = 0
                for ch in 0..<channelCount {
                    var channelMax: Float = 0
                    vDSP_maxmgv(channels[ch] + offset, 1, &channelMax, vDSP_Length(take))
                    blockMax = max(blockMax, channelMax)
                }

                currentPeak = max(currentPeak, blockMax)
                framesLeftInPeak -= take
                offset += take

                if framesLeftInPeak == 0 {
                    peaks.append(currentPeak)
                    currentPeak = 0
                    framesLeftInPeak = framesPerPeak
                }
            }

            remaining -= Int64(framesRead)
        }

        if framesLeftInPeak < framesPerPeak {
            peaks.append(currentPeak)
        }

        // Нормализация, чтобы тихие треки тоже читались на графике.
        if let maxPeak = peaks.max(), maxPeak > 0.0001 {
            var scale = 1 / maxPeak
            var normalized = [Float](repeating: 0, count: peaks.count)
            vDSP_vsmul(peaks, 1, &scale, &normalized, 1, vDSP_Length(peaks.count))
            peaks = normalized.map { min(1.0, $0) }
        }

        return WaveformData(peaks: peaks, duration: duration)
    }

    // MARK: - Кэш в памяти

    private static func memoryCached(_ key: String) -> WaveformData? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return memoryCache[key]
    }

    private static func memoryStore(_ key: String, _ data: WaveformData) {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        // Ограничиваем размер, чтобы память не росла бесконечно.
        if memoryCache.count > 200, let first = memoryCache.keys.first {
            memoryCache.removeValue(forKey: first)
        }
        memoryCache[key] = data
    }

    // MARK: - Кэш на диске

    private static var cacheDirectory: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("DJPlayer/Waveforms", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func diskURL(for key: String) -> URL? {
        guard let dir = cacheDirectory else { return nil }
        // Хэш вместо имени файла: ключ содержит путь и может быть очень длинным.
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return dir.appendingPathComponent(String(hash, radix: 16)).appendingPathExtension("wf")
    }

    /// Формат: [duration: Double][count: Int32][peaks: Float32...]
    private static func writeDiskCache(key: String, data: WaveformData) {
        guard let url = diskURL(for: key), !data.peaks.isEmpty else { return }

        var payload = Data()
        var duration = data.duration
        var count = Int32(data.peaks.count)
        withUnsafeBytes(of: &duration) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        data.peaks.withUnsafeBufferPointer { payload.append(Data(buffer: $0)) }

        try? payload.write(to: url, options: .atomic)
    }

    private static func readDiskCache(key: String) -> WaveformData? {
        guard let url = diskURL(for: key),
              let payload = try? Data(contentsOf: url),
              payload.count > 12 else { return nil }

        var duration: Double = 0
        var count: Int32 = 0
        _ = withUnsafeMutableBytes(of: &duration) { payload.copyBytes(to: $0, from: 0..<8) }
        _ = withUnsafeMutableBytes(of: &count) { payload.copyBytes(to: $0, from: 8..<12) }

        let peakCount = Int(count)
        guard peakCount > 0, payload.count >= 12 + peakCount * 4 else { return nil }

        var peaks = [Float](repeating: 0, count: peakCount)
        _ = peaks.withUnsafeMutableBytes { payload.copyBytes(to: $0, from: 12..<(12 + peakCount * 4)) }

        return WaveformData(peaks: peaks, duration: duration)
    }

    /// Полная очистка кэша (на случай, если пики выглядят устаревшими).
    static func clearCache() {
        memoryLock.lock()
        memoryCache.removeAll()
        memoryLock.unlock()

        if let dir = cacheDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
