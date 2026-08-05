// Метаданные видеофайлов для списка выбора: миниатюра, длительность,
// разрешение. Загружаются в фоне по одному файлу за раз (8K HEVC-кадр
// декодируется заметное время), результат кэшируется на сессию.
//
// ResumeStore — запоминание позиции просмотра per-файл (UserDefaults).

import AVFoundation

final class VideoMetaCache {
    struct Meta {
        var thumb: CGImage?
        var durationS: Double?
        var dims: CGSize?
    }

    private var cache: [String: Meta] = [:]
    private var queued = Set<String>()
    private var queue: [URL] = []
    private var busy = false
    var onUpdate: (() -> Void)?

    func meta(for url: URL) -> Meta? { cache[url.path] }

    // Поставить файл в очередь загрузки (повторные вызовы игнорируются)
    func request(_ url: URL) {
        let key = url.path
        guard cache[key] == nil, !queued.contains(key) else { return }
        queued.insert(key)
        queue.append(url)
        pump()
    }

    // Сбросить очередь (список закрыт/сменилась папка): декодирование миниатюр
    // не должно конкурировать с воспроизведением. Видимые строки при следующей
    // отрисовке встанут в очередь заново
    func cancelPending() {
        for url in queue {
            queued.remove(url.path)
        }
        queue.removeAll()
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        busy = true

        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration))?.seconds
            var dims: CGSize?
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                dims = try? await track.load(.naturalSize)
            }

            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 256, height: 256)
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            let t = CMTime(seconds: min(20, (duration ?? 20) * 0.15), preferredTimescale: 600)
            var thumb = try? await gen.image(at: t).image

            // У SBS-видео (аспект ≥ 1.9) берём только левый глаз
            if let th = thumb, let d = dims, d.height > 0, d.width / d.height > 1.9 {
                thumb = th.cropping(
                    to: CGRect(x: 0, y: 0, width: th.width / 2, height: th.height)) ?? th
            }

            let meta = Meta(thumb: thumb, durationS: duration, dims: dims)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cache[url.path] = meta
                self.busy = false
                self.onUpdate?()
                self.pump()
            }
        }
    }
}

// MARK: - Память позиции просмотра

enum ResumeStore {
    private static let key = "resumePositions"

    // Кэш в памяти: position() зовётся из отрисовки списка на каждый кадр,
    // читать plist из UserDefaults каждый раз накладно
    private static var cache: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]

    static func position(for url: URL) -> Double? {
        cache[url.path]
    }

    // nil — удалить запись (файл досмотрен)
    static func set(_ pos: Double?, for url: URL) {
        cache[url.path] = pos
        UserDefaults.standard.set(cache, forKey: key)
    }
}
