import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Browser_Setu

/// Builders for the bytes the favicon tests feed in: real PNGs, real ICO containers, solid pictures of any size.
enum FaviconFixtures {
    static func png(width: Int, height: Int, red: UInt8 = 20, green: UInt8 = 120, blue: UInt8 = 200, alpha: UInt8 = 255) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return buffer as Data
    }

    /// An ICO file whose frames are PNG pictures of the given sizes.
    static func ico(sizes: [Int]) -> Data {
        let pictures = sizes.map { png(width: $0, height: $0) }
        var out = Data([0, 0, 1, 0]) + le16(sizes.count)
        var offset = 6 + 16 * sizes.count
        for (size, picture) in zip(sizes, pictures) {
            out += Data([UInt8(size >= 256 ? 0 : size), UInt8(size >= 256 ? 0 : size), 0, 0]) + le16(1) + le16(32) + le32(picture.count) + le32(offset)
            offset += picture.count
        }
        for picture in pictures { out += picture }
        return out
    }

    static func le16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
    static func le32(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }

    static let safeSVG = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><rect width="32" height="32" rx="6" fill="#2a7"/><circle cx="16" cy="16" r="8" fill="#fff"/></svg>"##.utf8)

    static func pixelSize(of png: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func temporaryFolder(_ name: String = "favicons") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}

/// A fetcher that answers from a script and records what it was asked, so a test can see exactly what the service sent to the network.
actor StubFetcher: IconFetching {
    private(set) var requests: [IconFetchRequest] = []
    private(set) var concurrent = 0
    private(set) var peakConcurrent = 0
    var delay: Duration = .zero
    private var script: [String: IconFetchResult] = [:]
    var fallback: IconFetchResult = .failed(.badStatus)

    func set(_ url: String, _ result: IconFetchResult) { script[url] = result }
    func setDelay(_ d: Duration) { delay = d }
    func setFallback(_ r: IconFetchResult) { fallback = r }
    func requestedURLs() -> [String] { requests.map(\.url.absoluteString) }
    func lastRequest() -> IconFetchRequest? { requests.last }

    nonisolated func fetch(_ request: IconFetchRequest) async -> IconFetchResult { await run(request) }

    private func run(_ request: IconFetchRequest) async -> IconFetchResult {
        requests.append(request)
        concurrent += 1; peakConcurrent = max(peakConcurrent, concurrent)
        let wait = delay
        if wait != .zero { try? await Task.sleep(for: wait) }
        concurrent -= 1
        return script[request.url.absoluteString] ?? fallback
    }
}

/// A clock a test can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

extension IconFetchResult {
    static func image(_ data: Data = FaviconFixtures.png(width: 64, height: 64), etag: String? = nil, maxAge: TimeInterval? = nil) -> IconFetchResult {
        .fresh(.init(data: data, hints: IconCacheHints(etag: etag, lastModified: nil, maxAge: maxAge), mimeType: "image/png"))
    }
}
