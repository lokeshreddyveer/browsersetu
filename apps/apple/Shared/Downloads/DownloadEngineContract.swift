import Foundation

// The seam between the coordinator and a transfer engine. The coordinator owns a task's STATE and the scheduling decisions (who runs, when, in what order); an engine owns the
// TRANSFER (sockets, files, resume data) and nothing else. There is one state machine (`DownloadStateMachine`), and an engine never has a second one: it reports what happened,
// and the coordinator turns that into an event.
//
// Not every protocol can do everything. An engine declares what it can; the coordinator asks only for that, and the Downloads list shows a control only when it will work.

struct DownloadEngineCapabilities: OptionSet, Sendable {
    let rawValue: Int
    /// Can stop and keep its place (`pause`).
    static let pause = DownloadEngineCapabilities(rawValue: 1 << 0)
    /// Can carry on from kept data (`resume`), including after the app was closed.
    static let resume = DownloadEngineCapabilities(rawValue: 1 << 1)
    /// Can find out name, size and resumability before fetching (`resolve`).
    static let resolveMetadata = DownloadEngineCapabilities(rawValue: 1 << 2)
    /// Can check what it fetched (`verify`).
    static let verify = DownloadEngineCapabilities(rawValue: 1 << 3)
    /// Reports a total size while it runs.
    static let reportsTotalBytes = DownloadEngineCapabilities(rawValue: 1 << 4)
    /// One task is several independent pieces (HTTP ranges, torrent pieces); the engine reports them in `engineMetadata`, never as extra tasks.
    static let pieces = DownloadEngineCapabilities(rawValue: 1 << 5)
    /// One task is a folder of several files, of which the person may choose some.
    static let multiFile = DownloadEngineCapabilities(rawValue: 1 << 6)
    /// Sends data to other peers while it runs (and so exposes the user's network address to them).
    static let upload = DownloadEngineCapabilities(rawValue: 1 << 7)
    /// Holds a speed limit at the point where bytes are read from, and sent to, the network.
    static let enforcesSpeedLimit = DownloadEngineCapabilities(rawValue: 1 << 8)
}

/// What an engine tells the coordinator. Every report carries the `attempt` the engine was started with; one from an earlier attempt is ignored.
enum DownloadEngineReport: Sendable {
    case running
    case progress(completed: Int64, total: Int64?)
    case metadata([String: String])
    case paused(resumeData: Data?)
    case finishedTransfer                      // all bytes are in place; verification (if any) is next
    case failed(DownloadFailureInfo, resumeData: Data?, retryAfter: TimeInterval?)
}

/// Where an engine sends its reports.
protocol DownloadReportSink: AnyObject, Sendable {
    func report(_ report: DownloadEngineReport, task: DownloadTaskID, attempt: Int)
}

struct DownloadSourceRequest: Sendable {
    var url: URL
    var profile: String
    var isPrivate: Bool
    /// Who asked, so resolving a link is held to the same rules as fetching it.
    var origin: DownloadRequestOrigin = .user
}

struct DownloadResolvedSource: Sendable {
    var suggestedFilename: String?
    var totalBytes: Int64?
    var acceptsRanges: Bool
    var metadata: [String: String]
}

enum DownloadEngineError: Error, Equatable, Sendable {
    /// The engine does not have this capability; the coordinator should not have asked.
    case unsupported(String)
}

/// What an engine must do to take part. Operations a protocol cannot do keep their default, which refuses, so a missing capability is an error and never silence.
protocol DownloadTransferEngine: AnyObject, Sendable {
    var protocolID: DownloadProtocolID { get }
    var capabilities: DownloadEngineCapabilities { get }

    /// Starts (or, with `resumeData`, carries on) fetching. Reports go to `sink` with `attempt`.
    func start(_ task: DownloadTaskRecord, attempt: Int, resumeData: Data?, sink: DownloadReportSink) async throws
    /// Stops and keeps its place; the answer arrives as `.paused`.
    func pause(task: DownloadTaskID, attempt: Int) async throws
    /// Abandons the transfer and releases everything it holds. Always supported.
    func cancel(task: DownloadTaskID, attempt: Int) async
    func resolve(_ request: DownloadSourceRequest) async throws -> DownloadResolvedSource
    func verify(_ task: DownloadTaskRecord) async throws -> DownloadIntegrity
    /// For a task found live after the app was closed: whether this engine can carry on from what was kept.
    func canRecover(_ task: DownloadTaskRecord, hasResumeData: Bool) -> Bool
}

extension DownloadTransferEngine {
    func pause(task: DownloadTaskID, attempt: Int) async throws { throw DownloadEngineError.unsupported("pause") }
    func resolve(_ request: DownloadSourceRequest) async throws -> DownloadResolvedSource { throw DownloadEngineError.unsupported("resolve") }
    func verify(_ task: DownloadTaskRecord) async throws -> DownloadIntegrity { .unknown }
    func canRecover(_ task: DownloadTaskRecord, hasResumeData: Bool) -> Bool { capabilities.contains(.resume) && hasResumeData }
}

/// The engines that exist, by protocol. A task whose engine is not registered cannot be controlled (it can still be listed and removed).
@MainActor
final class DownloadEngineRegistry {
    private(set) var capabilitiesByProtocol: [DownloadProtocolID: DownloadEngineCapabilities] = [:]

    /// The two engines that exist today push events into the coordinator (WebKit makes the download; the piece fetcher runs inside the app), so they are described by what
    /// they can do rather than driven through `start`. A future engine conforms to `DownloadTransferEngine` and is registered with `register(_:)`.
    init() {
        capabilitiesByProtocol[.webKit] = [.pause, .resume, .reportsTotalBytes]
        capabilitiesByProtocol[.httpPieces] = [.pieces, .reportsTotalBytes]
        capabilitiesByProtocol[.http] = [.pause, .resume, .resolveMetadata, .verify, .reportsTotalBytes, .pieces]
        capabilitiesByProtocol[.bittorrent] = BitTorrentTransferEngine.capabilities
        capabilitiesByProtocol[.ed2k] = ED2KTransferEngine.capabilities
        capabilitiesByProtocol[.media] = MediaTransferEngine.capabilities
        capabilitiesByProtocol[.remoteZip] = [.pause, .resume, .verify, .reportsTotalBytes]
        capabilitiesByProtocol[.remoteFile] = [.pause, .resume, .verify, .reportsTotalBytes]
    }

    func register(_ engine: DownloadTransferEngine) { capabilitiesByProtocol[engine.protocolID] = engine.capabilities }

    func capabilities(of id: DownloadProtocolID) -> DownloadEngineCapabilities { capabilitiesByProtocol[id] ?? [] }
    func can(_ capability: DownloadEngineCapabilities, _ id: DownloadProtocolID) -> Bool { capabilities(of: id).contains(capability) }
}
