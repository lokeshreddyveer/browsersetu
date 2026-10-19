import Foundation

/// Fetches one large file as several pieces at once, each over its own connection, and joins them. A site that limits the speed of a single
/// connection (many do) gives the pieces together several times the speed. It is used only for plain public files that a server says it can
/// send in pieces; everything else, and anything that goes wrong in the check, is left to WebKit's own download.
enum SegmentPlan {
    static let minimumSize: Int64 = 8_000_000
    static let connections = 6

    /// The pieces of a file: roughly equal, none smaller than `minimum` (a small file gets fewer pieces).
    static func ranges(total: Int64, connections: Int = SegmentPlan.connections, minimum: Int64 = 2_000_000) -> [ClosedRange<Int64>] {
        guard total > 0 else { return [] }
        let count = Int(max(1, min(Int64(connections), total / max(minimum, 1))))
        let size = (total + Int64(count) - 1) / Int64(count)
        return (0..<count).compactMap { i in
            let start = Int64(i) * size
            let end = min(total - 1, start + size - 1)
            return start <= end ? start...end : nil
        }
    }

    /// Whether a download WebKit is about to start is one this can take over: a plain GET of a large https file, sent as-is and in pieces.
    static func eligible(response: HTTPURLResponse, request: URLRequest?) -> Bool {
        guard response.statusCode == 200, let url = response.url, url.scheme?.lowercased() == "https" else { return false }
        if let method = request?.httpMethod, method.uppercased() != "GET" { return false }
        if request?.httpBody != nil || request?.httpBodyStream != nil { return false }
        let accepts = (response.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
        guard accepts.contains("bytes") else { return false }
        // A compressed body cannot be fetched by byte positions in the file.
        let encoding = (response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased()
        guard encoding == "identity" || encoding.isEmpty else { return false }
        let size = response.expectedContentLength
        return size >= minimumSize && size <= 64_000_000_000
    }

    /// The total size named by a "Content-Range: bytes 0-0/12345" header.
    static func total(fromContentRange header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}

enum SegmentedDownloadError: Error { case refused, wrongSize, failed(String) }

final class SegmentedDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let userAgent: String?
    private let pieces: Int
    private let lock = NSLock()
    private var session: URLSession!
    private var ranges: [ClosedRange<Int64>] = []
    private var written: [Int: Int64] = [:]
    private var done = Set<Int>()
    private var attempts: [Int: Int] = [:]
    private var tasks: [Int: URLSessionDownloadTask] = [:]
    private var segmentFiles: [Int: URL] = [:]
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (Int64) -> Void)?
    private var finished = false
    private var folder: URL?

    init(url: URL, userAgent: String? = nil, pieces: Int = SegmentPlan.connections) {
        self.url = url
        self.pieces = pieces
        self.userAgent = userAgent
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = max(pieces, 1) + 2
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func request(_ range: ClosedRange<Int64>) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let userAgent { r.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        return r
    }

    /// Asks for the first byte only, without cookies. A server that answers 206 with the expected total can be fetched in pieces by this
    /// downloader; any other answer means WebKit's own download is the better choice.
    func probe(expectedTotal: Int64) async -> Bool {
        guard let (_, response) = try? await session.data(for: request(0...0)), let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 206 && SegmentPlan.total(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")) == expectedTotal
    }

    /// Downloads the whole file to `destination`. `progress` gets the bytes received so far. Throws on failure, or CancellationError after `cancel()`.
    func run(total: Int64, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let parts = SegmentPlan.ranges(total: total, connections: pieces)
        guard !parts.isEmpty else { throw SegmentedDownloadError.failed("empty") }
        let work = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).parts", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        prepare(parts: parts, progress: progress, folder: work)
        defer { try? FileManager.default.removeItem(at: work) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                start(parts: parts, continuation: c)
            }
        } onCancel: { self.cancel() }
        try assemble(parts: parts, total: total, to: destination)
    }

    private func prepare(parts: [ClosedRange<Int64>], progress: @escaping @Sendable (Int64) -> Void, folder: URL) {
        lock.lock(); ranges = parts; self.progress = progress; self.folder = folder; lock.unlock()
    }

    private func start(parts: [ClosedRange<Int64>], continuation c: CheckedContinuation<Void, Error>) {
        lock.lock(); continuation = c
        for (i, r) in parts.enumerated() { let t = session.downloadTask(with: request(r)); tasks[i] = t; t.resume() }
        lock.unlock()
    }

    private func segmentFile(_ i: Int) -> URL? { lock.lock(); defer { lock.unlock() }; return segmentFiles[i] }

    func cancel() {
        lock.lock()
        let wasFinished = finished
        finished = true
        let c = continuation; continuation = nil
        lock.unlock()
        session.invalidateAndCancel()
        if !wasFinished { c?.resume(throwing: CancellationError()) }
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation; continuation = nil
        lock.unlock()
        session.invalidateAndCancel()
        c?.resume(throwing: error)
    }

    private func assemble(parts: [ClosedRange<Int64>], total: Int64, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        for i in parts.indices {
            guard let file = segmentFile(i) else { throw SegmentedDownloadError.failed("missing piece") }
            let input = try FileHandle(forReadingFrom: file)
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            try input.close()
            try? fm.removeItem(at: file)
        }
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        guard size == total else { try? fm.removeItem(at: destination); throw SegmentedDownloadError.wrongSize }
    }

    // MARK: URLSessionDownloadDelegate

    private func index(of task: URLSessionTask) -> Int? { tasks.first { $0.value.taskIdentifier == task.taskIdentifier }?.key }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        if let i = index(of: downloadTask) { written[i] = totalBytesWritten }
        let sum = written.values.reduce(0, +)
        let callback = progress
        lock.unlock()
        callback?(sum)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let i = index(of: downloadTask)
        let folder = self.folder
        let expected = i.map { ranges[$0] }
        lock.unlock()
        guard let i, let folder, let expected, let http = downloadTask.response as? HTTPURLResponse else { return }
        let length = expected.upperBound - expected.lowerBound + 1
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        guard http.statusCode == 206, size == length else { fail(SegmentedDownloadError.refused); return }
        let target = folder.appendingPathComponent("part\(i)")
        try? FileManager.default.removeItem(at: target)
        do { try FileManager.default.moveItem(at: location, to: target) } catch { fail(error); return }
        lock.lock()
        segmentFiles[i] = target
        done.insert(i)
        let all = done.count == ranges.count
        var c: CheckedContinuation<Void, Error>?
        if all, !finished { finished = true; c = continuation; continuation = nil }
        lock.unlock()
        if all { session.finishTasksAndInvalidate(); c?.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        lock.lock()
        guard let i = index(of: task), !done.contains(i), !finished else { lock.unlock(); return }
        let tries = (attempts[i] ?? 0) + 1
        attempts[i] = tries
        if tries <= 3 {
            // One piece failing (the connection dropped) starts that piece again, a few times.
            written[i] = 0
            let t = self.session.downloadTask(with: request(ranges[i]))
            tasks[i] = t
            lock.unlock()
            t.resume()
        } else {
            lock.unlock()
            fail(error)
        }
    }
}
