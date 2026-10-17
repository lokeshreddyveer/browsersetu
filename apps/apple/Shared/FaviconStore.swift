import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Small site icons for the suggestion list, the sidebar and the start page. An icon is found by reading the page's own icon links
/// (see WebKitEngine) and, if the page names none, the site's /favicon.ico. It is fetched once, shrunk, and kept on this device.
/// Only for sites opened in normal tabs, only when the user allows it in Settings, with no cookies, no cache and no identity.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    nonisolated static let maxBytes = 300_000
    nonisolated static let side: CGFloat = 64
    /// Icons kept decoded in memory; the rest are read back from disk when needed.
    static let memoryLimit = 150
    /// How long a saved icon is kept before the site is asked again.
    static let lifetime: TimeInterval = 14 * 24 * 3600

    /// Bumped when an icon arrives, so tiles showing a letter switch to the icon.
    @Published private(set) var version = 0
    var directory: URL
    private var memory: [String: PlatformImage] = [:]
    private var inFlight = Set<String>()

    init(directory: URL? = nil) {
        self.directory = directory ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("SiteIcons", isDirectory: true)
    }

    /// The key a site's icon is saved under: its host without a leading "www.".
    nonisolated static func key(forHost host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func image(forURL url: String) -> PlatformImage? {
        guard let key = Self.key(forHost: URL(string: url)?.host) else { return nil }
        if let cached = memory[key] { return cached }
        let file = directory.appendingPathComponent(key + ".png")
        guard let data = try? Data(contentsOf: file), let image = PlatformImage(data: data) else { return nil }
        remember(key, image)
        return image
    }

    /// The icon at an exact size in points: menus draw an image at its own size and ignore any resizing, so it is made that size here.
    func image(forURL url: String, points: CGFloat) -> PlatformImage? {
        guard let image = image(forURL: url) else { return nil }
        #if os(macOS)
        guard let copy = image.copy() as? NSImage else { return image }
        copy.size = NSSize(width: points, height: points)
        return copy
        #else
        return image
        #endif
    }

    private func isFresh(_ key: String) -> Bool {
        let file = directory.appendingPathComponent(key + ".png")
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return Date().timeIntervalSince(date) < Self.lifetime
    }

    /// Looks for the icon of `pageURL`'s site among `candidates` (the page's own icon links, best first), then /favicon.ico.
    func learn(pageURL: URL, candidates: [URL]) async {
        // While a proxy is on, the browser does not fetch anything on its own: that request would go out directly and show the real address.
        guard !ProxyState.active, let scheme = pageURL.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let key = Self.key(forHost: pageURL.host), !inFlight.contains(key), !isFresh(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        var list = candidates.filter { $0.scheme?.lowercased() == "https" }
        if let host = pageURL.host, let fallback = URL(string: "https://\(host)/favicon.ico") { list.append(fallback) }
        for url in list.prefix(4) {
            guard let data = await Self.download(url), let png = Self.shrunkPNG(from: data) else { continue }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
            if let icon = PlatformImage(data: png) { remember(key, icon) }
            announce()
            return
        }
    }

    private var announcePending = false

    /// Tells the tiles an icon has arrived, but at most a few times a second: icons come in bursts (a long history, a start page), and every announcement redraws every tile
    /// on screen, so each arrival announcing itself made the list stutter as it filled.
    private func announce() {
        guard !announcePending else { return }
        announcePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.announcePending = false
            self?.version += 1
        }
    }

    private func remember(_ key: String, _ image: PlatformImage) {
        if memory.count >= Self.memoryLimit, let drop = memory.keys.first { memory[drop] = nil }
        memory[key] = image
    }

    func trimMemory(limit: Int) {
        while memory.count > limit, let drop = memory.keys.first { memory[drop] = nil }
    }

    func clear() {
        memory = [:]
        try? FileManager.default.removeItem(at: directory)
        version += 1
    }

    // MARK: Fetching

    /// A bare request: no cookies, no cache, no credentials, a short wait, and a small size limit.
    nonisolated static func download(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxBytes, data.count > 60 else { return nil }
        return data
    }

    /// The icon as a small PNG, or nil if the data is not an image.
    nonisolated static func shrunkPNG(from data: Data) -> Data? {
        guard let image = PlatformImage(data: data) else { return nil }
        #if os(macOS)
        let size = NSSize(width: side, height: side)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let source = image.size
        let scale = min(side / max(source.width, 1), side / max(source.height, 1))
        let w = source.width * scale, h = source.height * scale
        image.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let source = image.size
        let scale = min(side / max(source.width, 1), side / max(source.height, 1))
        let w = source.width * scale, h = source.height * scale
        return renderer.pngData { _ in image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)) }
        #endif
    }
}

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}
