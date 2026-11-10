import Foundation

// Phase 13: the automation contract. Nothing here owns transfer state: the ledger and coordinator stay the only authorities.

enum AutomationScope: String, Codable, CaseIterable, Sendable {
    case downloadsRead = "downloads.read"
    case downloadsCreate = "downloads.create"
    case downloadsControl = "downloads.control"
    /// Touches files on disk (moves a finished file to the Trash). Never implied by any other scope.
    case downloadsFiles = "downloads.files"
    case queuesRead = "queues.read"
    case queuesControl = "queues.control"
    case settingsRead = "settings.read"
}

/// Every refusal has a stable code. Messages never include a token, a full address or a path.
struct AutomationError: Error, Equatable {
    var status: Int
    var code: String
    var message: String

    static func unauthorized(_ why: String = "Missing or invalid credentials.") -> AutomationError { .init(status: 401, code: "unauthorized", message: why) }
    static func forbidden(_ code: String, _ why: String) -> AutomationError { .init(status: 403, code: code, message: why) }
    static func missingScope(_ scope: AutomationScope) -> AutomationError { .init(status: 403, code: "missing_scope", message: "This client lacks the \(scope.rawValue) permission.") }
    static let notFound = AutomationError(status: 404, code: "not_found", message: "No such item.")
    static func badRequest(_ code: String, _ why: String) -> AutomationError { .init(status: 400, code: code, message: why) }
    static func conflict(_ code: String, _ why: String) -> AutomationError { .init(status: 409, code: code, message: why) }
    static let tooLarge = AutomationError(status: 413, code: "payload_too_large", message: "The request is too large.")
    static let tooMany = AutomationError(status: 429, code: "rate_limited", message: "Too many requests. Slow down.")
    static let busy = AutomationError(status: 503, code: "busy", message: "The service is busy. Try again shortly.")
    static let disabled = AutomationError(status: 503, code: "disabled", message: "Local automation is switched off.")
}

struct AutomationClient: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    /// The one profile this client belongs to. Fixed at enrolment; a request cannot name another.
    var profile: String
    var scopes: Set<AutomationScope>
    var createdAt: Date
    var expiresAt: Date?
    var revokedAt: Date?
    var lastUsedAt: Date?
    /// SHA-256 of the secret. The secret itself is shown once, at enrolment or rotation, and kept nowhere.
    var tokenHash: String

    func isActive(at now: Date) -> Bool { revokedAt == nil && (expiresAt.map { $0 > now } ?? true) }
}

// MARK: - What leaves the app

/// A download as an automation client sees it. No cookie, header, proxy detail, query string, user name or folder path.
struct DownloadDTO: Codable, Equatable, Sendable {
    var id: String
    var state: String
    var filename: String
    var source: String?
    var sourceHost: String?
    var engine: String
    var priority: String
    var bytesReceived: Int64
    var totalBytes: Int64?
    var fraction: Double?
    var createdAt: Date
    var scheduledAt: Date?
    var canPause: Bool
    var canResume: Bool
    var failureReason: String?
}

enum AutomationSanitize {
    /// The address with no user name, password, query or fragment (signed links keep their secret in the query).
    static func address(_ raw: String?) -> String? {
        guard let raw, var parts = URLComponents(string: raw) else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return parts.url?.absoluteString
    }

    static func priority(_ p: DownloadPriority) -> String { p.title.lowercased() }
    static func priority(named name: String) -> DownloadPriority? { DownloadPriority.allCases.first { $0.title.lowercased() == name.lowercased() } }
}

struct ProposalDTO: Codable, Equatable, Sendable {
    var id: String
    var state: String
    var source: String
    var sourceHost: String
    var filename: String?
    var priority: String
    var startAt: Date?
    var createdAt: Date
    var clientName: String
    var taskID: String?
}

struct QueueDTO: Codable, Equatable, Sendable {
    var id: String
    var running: Int
    var waiting: Int
    var scheduled: Int
    var held: Bool
    var heldUntil: Date?
    var maxConcurrent: Int
}

struct StatsDTO: Codable, Equatable, Sendable {
    var total: Int
    var byState: [String: Int]
    var bytesReceived: Int64
    var active: Int
    var queueHeld: Bool
}

struct EngineCapabilityDTO: Codable, Equatable, Sendable {
    var engine: String
    var canPause: Bool
    var canResume: Bool
    var createdThroughAPI: Bool
    var note: String
}

// MARK: - Request / reply

struct AutomationRequest: Sendable {
    enum Transport: Equatable, Sendable { case unixSocket, loopback(port: UInt16), remote(device: String) }
    var method: String
    var target: String                 // path and query
    var headers: [String: String]      // lower-cased names
    var body: Data
    var transport: Transport = .unixSocket

    var path: String { target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target }
    var query: [String: String] {
        guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if let k = kv.first { out[k.removingPercentEncoding ?? k] = (kv.count > 1 ? kv[1] : "").removingPercentEncoding ?? "" }
        }
        return out
    }
}

enum AutomationReply {
    case json(status: Int, body: Data)
    case stream(AutomationSubscription)

    var status: Int { if case .json(let s, _) = self { return s }; return 200 }
}

enum AutomationJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func reply<T: Encodable>(_ value: T, status: Int = 200) -> AutomationReply {
        .json(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ e: AutomationError) -> AutomationReply {
        struct Body: Encodable { var error: Inner; struct Inner: Encodable { var code: String; var message: String } }
        return reply(Body(error: .init(code: e.code, message: e.message)), status: e.status)
    }
}
