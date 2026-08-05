// Video file metadata for the picker list: thumbnail, duration, resolution.
// Loaded in the background one file at a time (an 8K HEVC frame takes a
// noticeable time to decode); results are cached for the session.
//
// ResumeStore — per-file playback position memory (UserDefaults).

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

    // Queue a file for loading (repeated calls are ignored)
    func request(_ url: URL) {
        let key = url.path
        guard cache[key] == nil, !queued.contains(key) else { return }
        queued.insert(key)
        queue.append(url)
        pump()
    }

    // Drop the queue (list closed / folder changed): thumbnail decoding must
    // not compete with playback. Visible rows will be queued again on the
    // next redraw
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

            // For SBS video (aspect ≥ 1.9) take only the left eye
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

// MARK: - Playback position memory

enum ResumeStore {
    private static let key = "resumePositions"

    // In-memory cache: position() is called from list drawing every frame,
    // and reading the plist from UserDefaults each time is costly
    private static var cache: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]

    static func position(for url: URL) -> Double? {
        cache[url.path]
    }

    // nil — remove the entry (file watched to the end)
    static func set(_ pos: Double?, for url: URL) {
        cache[url.path] = pos
        UserDefaults.standard.set(cache, forKey: key)
    }
}
