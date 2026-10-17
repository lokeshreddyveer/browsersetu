import Foundation

/// Gets an extension from the Chrome Web Store when the user asks for one by its address or id. It is a single request, made only when the user
/// presses Add, with no cookies, no cache and no account: the package is downloaded to a temporary file, then goes through the same unpacking, permission
/// review and approval as any other extension. Browser Setu never contacts the store on its own, so installed extensions are not updated behind the
/// user's back; to update one, the user adds the newer version again.
enum ChromeWebStore {
    enum Failure: LocalizedError {
        case noID, notFound, tooLarge, offline, proxyOn

        var errorDescription: String? {
            switch self {
            case .noID: "That is not a Chrome Web Store address or extension id. Paste the page’s address, or the 32 letters of its id."
            case .notFound: "The Chrome Web Store has no extension with that id, or it is not offered for download."
            case .tooLarge: "That extension is larger than \(ExtensionPackage.maxUnpacked / 1_048_576) MB."
            case .offline: "The Chrome Web Store could not be reached."
            case .proxyOn: "Turn the proxy off to download an extension: the download does not go through it, and would show your real address."
            }
        }
    }

    /// The 32-letter id (a to p) from a store address such as chromewebstore.google.com/detail/name/<id>, or the id itself.
    static func extensionID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func isID(_ s: Substring) -> Bool { s.count == 32 && s.allSatisfy { $0 >= "a" && $0 <= "p" } }
        if isID(Substring(text)) { return text }
        guard let url = URL(string: text), let host = url.host,
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        return url.pathComponents.first(where: { isID(Substring($0)) })
    }

    static func downloadURL(id: String) -> URL? {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        let x = "id=\(id)&installsource=ondemand&uc"
        parts?.queryItems = [.init(name: "response", value: "redirect"), .init(name: "prodversion", value: "131.0.0.0"),
                             .init(name: "acceptformat", value: "crx3"), .init(name: "x", value: x)]
        return parts?.url
    }

    /// Downloads the package to a temporary `.crx` file and returns it.
    static func download(id: String) async throws -> URL {
        guard !ProxyState.active else { throw Failure.proxyOn }
        guard let url = downloadURL(id: id) else { throw Failure.noID }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (file, response): (URL, URLResponse)
        do { (file, response) = try await session.download(from: url) } catch { throw Failure.offline }
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else { throw Failure.offline }
        guard http.statusCode == 200 else { throw Failure.notFound }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ExtensionPackage.maxUnpacked else { throw Failure.tooLarge }
        let handle = try? FileHandle(forReadingFrom: file)
        defer { try? handle?.close() }
        guard size > 0, let head = try? handle?.read(upToCount: 4), head == Data([0x43, 0x72, 0x32, 0x34]) else { throw Failure.notFound }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).crx")
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }
}
