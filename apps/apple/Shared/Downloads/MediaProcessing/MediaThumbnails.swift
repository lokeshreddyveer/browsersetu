import Foundation
import AVFoundation
import CoreGraphics

// Picture thumbnails of local video files.
//
// One frame is asked for (never the whole file decoded), turned upright from the track's own transform, and scaled down inside a bounded square. They are kept only in memory
// (a bounded cache keyed by the file's identity: path, size and modification time, so an edited file asks again), and never at all for a private download. Failure of a damaged
// or unsupported file is an ordinary thrown error.

enum MediaThumbnailError: Error, Equatable, LocalizedError {
    case unsupported, noVideo, failed(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: return "This file cannot be previewed as a picture."
        case .noVideo: return "There is no video in this file."
        case .failed(let why): return "A thumbnail could not be made (\(why))."
        }
    }
}

final class MediaThumbnailer: @unchecked Sendable {
    static let shared = MediaThumbnailer()
    static let maxDimension = 1024
    static let defaultDimension = 256
    static let maxConcurrent = 2

    private let cache = NSCache<NSString, CGImage>()
    private let slots = Slots(limit: maxConcurrent)

    init(entries: Int = 64) { cache.countLimit = entries; cache.totalCostLimit = 48 * 1024 * 1024 }

    /// An identity that changes whenever the file does.
    static func identity(of url: URL, time: Double, dimension: Int) -> String {
        // Read afresh (a URL object caches the values it was first asked for, which would hide an edit).
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)|\(Int(time * 1000))|\(dimension)"
    }

    func cached(_ url: URL, time: Double = -1, dimension: Int = defaultDimension, tolerance: Double = 2) -> CGImage? {
        cache.object(forKey: (Self.identity(of: url, time: time, dimension: min(dimension, Self.maxDimension)) + "|\(tolerance)") as NSString)
    }

    func purge() { cache.removeAllObjects() }

    /// `time` is a number of seconds, or negative for a representative moment (a tenth of the way in, never past the first minute).
    func thumbnail(for url: URL, at time: Double = -1, dimension: Int = defaultDimension, isPrivate: Bool = false, tolerance: Double = 2) async throws -> CGImage {
        let dimension = max(16, min(dimension, Self.maxDimension))
        let key = (Self.identity(of: url, time: time, dimension: dimension) + "|\(tolerance)") as NSString
        if !isPrivate, let hit = cache.object(forKey: key) { return hit }
        await slots.acquire()
        defer { Task { await slots.release() } }
        try Task.checkCancellation()
        if !isPrivate, let hit = cache.object(forKey: key) { return hit }
        let asset = AVURLAsset(url: MediaAlias.url(for: url))
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .video) } catch { throw MediaThumbnailError.unsupported }
        guard !tracks.isEmpty else { throw MediaThumbnailError.noVideo }
        let duration = (try? await asset.load(.duration)).flatMap { $0.isNumeric && $0.seconds.isFinite ? $0.seconds : nil } ?? 0
        let moment: Double = time >= 0 ? min(time, max(0, duration)) : min(duration * 0.1, 60)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: dimension, height: dimension)       // fits inside the square, keeping the aspect ratio
        generator.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: tolerance, preferredTimescale: 600)
        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: moment, preferredTimescale: 600))
            try Task.checkCancellation()
            if !isPrivate { cache.setObject(image, forKey: key, cost: image.width * image.height * 4) }
            return image
        } catch is CancellationError { throw CancellationError() }
        catch { throw MediaThumbnailError.failed(error.localizedDescription) }
    }

    /// A counting gate, so a page of many videos does not decode a dozen at once.
    actor Slots {
        private var free: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(limit: Int) { free = limit }
        func acquire() async {
            if free > 0 { free -= 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
        }
    }
}
