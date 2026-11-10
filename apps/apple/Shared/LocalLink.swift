import CryptoKit
import Security
import Foundation
import Network
import SwiftUI
import UniformTypeIdentifiers

/// The wire format between two Browser Setu devices on the same network: a 4-byte length, then JSON.
struct LinkMessage: Codable, Equatable {
    enum Kind: String, Codable {
        case text, link, file, sync
        // A file of any size, sent in pieces after the other device has agreed to it (see LinkTransfer.swift).
        case offer, accept, decline, chunk, finish, result, abort
        var isTransfer: Bool { switch self { case .offer, .accept, .decline, .chunk, .finish, .result, .abort: true; default: false } }
    }
    var kind: Kind
    var name: String?
    var text: String?
    var data: Data?
    /// For a transfer: which one, how large, its SHA-256, which piece this is, and (in a result) whether it arrived whole.
    var id: String?
    var size: Int?
    var sha256: String?
    var index: Int?
    var ok: Bool?
}

enum LinkWire {
    static let maxBytes = 25 * 1024 * 1024
    static let service = "_browsersetu._tcp"

    static func frame(_ message: LinkMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Takes complete messages off the front of the buffer. Anything larger than the limit is an error, so a stranger cannot make the app buffer without end.
    static func unframe(_ buffer: inout Data) throws -> [LinkMessage] {
        var out: [LinkMessage] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
            guard buffer.count >= 4 + length else { break }
            out.append(try JSONDecoder().decode(LinkMessage.self, from: buffer.subdata(in: 4..<(4 + length))))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return out
    }

    /// The pairing secret: 20 characters from a 32-letter alphabet, so 100 random bits. A code this size cannot be guessed offline from a captured handshake
    /// (six digits could be, in a moment). Letters that look alike are left out, and the code is shown in groups of five.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let codeLength = 20

    static func makeCode() -> String {
        var bytes = [UInt8](repeating: 0, count: codeLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return String((0..<codeLength).map { _ in alphabet.randomElement()! }) }
        return String(bytes.map { alphabet[Int($0) & 31] })
    }

    /// What a person types, brought to the plain form: capitals, no dashes or spaces, look-alike letters read as the digits they resemble. Nil if it is not a
    /// whole code.
    static func normalized(_ input: String) -> String? {
        let cleaned = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
            .map { character -> Character in
                switch character { case "O": return "0"; case "I", "L": return "1"; default: return character }
            }
        guard cleaned.count == codeLength, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return String(cleaned)
    }

    static func formatted(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 5).map { String(code.dropFirst($0).prefix(5)) }.joined(separator: "-")
    }

    /// The key both ends derive from the code. HKDF over 100 random bits; there is no weak secret to guess.
    static func key(forCode code: String) -> Data {
        let secret = SymmetricKey(data: Data((normalized(code) ?? code).utf8))
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: Data("browser-setu-link-v2".utf8), info: Data("tls-psk".utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    /// How long a code works, how many strangers' failed attempts end the session, and how much one session may take in.
    static let codeLifetime: TimeInterval = 300
    static let failedAttemptLimit = 5
    static let maxConnections = 4
    static let maxInboxItems = 50
    static let maxInboxBytes = 100 * 1024 * 1024

    static func safeFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces)
        return base.isEmpty || base.hasPrefix(".") ? "Received File" : String(base.prefix(120))
    }
}

/// Sends and receives text, links and files between your own devices over the local network, protected by a one-time code.
/// Nothing goes through a server, and nothing is kept after you close the sheet.
@MainActor
final class LocalLink: ObservableObject {
    struct Peer: Identifiable, Hashable { var id: String { name }; var name: String; var endpoint: NWEndpoint }
    @Published var code = ""
    @Published var receiving = false
    @Published var peers: [Peer] = []
    @Published var status = ""
    @Published var inbox: [LinkMessage] = []
    /// The file being sent or received now, if any.
    @Published var transfer: TransferProgress?
    /// Whether an incoming file waits for a yes. On unless the person turned it off.
    var askBeforeReceiving = true
    var receivedFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    var onFileReceived: ((URL) -> Void)?
    private var incoming: [ObjectIdentifier: IncomingFile] = [:]
    private var sendTask: Task<Void, Never>?

    /// Set by the browser: given a snapshot that arrived, returns this device's snapshot to send back.
    var onSync: ((Data) async -> Data?)?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var buffers: [ObjectIdentifier: Data] = [:]
    /// Every accepted connection, so stopping can end them all, and a counter that makes callbacks from an earlier session do nothing.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var generation = 0
    private var failedAttempts = 0
    private var inboxBytes = 0

    private static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = LinkWire.key(forCode: code)
        let secondary = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("browser-setu".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secondary as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    func startReceiving(deviceName: String) {
        stop()
        code = LinkWire.makeCode()
        let session = generation
        failedAttempts = 0
        do {
            let listener = try NWListener(using: Self.parameters(code: code))
            listener.service = NWListener.Service(name: deviceName, type: LinkWire.service)
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: guard self?.generation == session else { return }; self?.receiving = true; self?.status = "Ready. Enter the code on your other device. It works for five minutes."
                    case .failed(let error): guard self?.generation == session else { return }; self?.status = "Could not start: \(error.localizedDescription)"; self?.receiving = false
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            // The code does not last: after five minutes nobody can use it any more.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(LinkWire.codeLifetime))
                guard let self, self.generation == session, self.receiving else { return }
                self.stop()
                self.status = "The code expired. Start receiving again for a new one."
            }
        } catch { status = "Could not start: \(error.localizedDescription)" }
    }

    private func accept(_ connection: NWConnection) {
        // One session takes in only so much: a few connections at a time, and a bounded inbox.
        guard connections.count < LinkWire.maxConnections, inbox.count < LinkWire.maxInboxItems, inboxBytes < LinkWire.maxInboxBytes else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        let session = generation
        buffers[id] = Data()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == session else { return }
                switch state {
                case .failed, .cancelled:
                    // A handshake that fails is a wrong code (or a stranger): too many of them end the session.
                    if case .failed = state { self.failedAttempts += 1 }
                    self.connections[id] = nil; self.buffers[id] = nil; self.discardIncoming(id)
                    if self.failedAttempts >= LinkWire.failedAttemptLimit { self.stop(); self.status = "Too many wrong attempts, so sharing was stopped. Start again for a new code." }
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, id: id, session: session)
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier, session: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.generation == session else { connection.cancel(); return }
                if let data { self.buffers[id, default: Data()].append(data) }
                do {
                    var buffer = self.buffers[id] ?? Data()
                    let messages = try LinkWire.unframe(&buffer)
                    self.buffers[id] = buffer
                    for message in messages {
                        if message.kind.isTransfer { self.handleTransfer(message, on: connection, id: id); continue }
                        if message.kind == .sync {
                            // A device is syncing with this one: take in its data and answer with this device's own, on the same connection.
                            // The other side is checked first (and asked about, the first time); only then is anything taken in.
                            if let data = message.data, let reply = await self.onSync?(data), self.generation == session, let framed = try? LinkWire.frame(LinkMessage(kind: .sync, data: reply)) {
                                connection.send(content: framed, completion: .contentProcessed { _ in })
                            }
                        } else if self.inbox.count < LinkWire.maxInboxItems, self.inboxBytes + (message.data?.count ?? 0) <= LinkWire.maxInboxBytes {
                            self.inboxBytes += message.data?.count ?? 0
                            self.inbox.append(message)
                        } else { connection.cancel(); self.connections[id] = nil; self.buffers[id] = nil; return }
                    }
                } catch { connection.cancel(); self.buffers[id] = nil; self.connections[id] = nil; self.discardIncoming(id); return }
                if done || error != nil { connection.cancel(); self.buffers[id] = nil; self.connections[id] = nil; self.discardIncoming(id) } else { self.receive(on: connection, id: id, session: session) }
            }
        }
    }

    func startBrowsing() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: LinkWire.service, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.peers = results.compactMap { result in
                    if case let .service(name, _, _, _) = result.endpoint { return Peer(name: name, endpoint: result.endpoint) }
                    return nil
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func send(_ message: LinkMessage, to peer: Peer, code: String) {
        let connection = NWConnection(to: peer.endpoint, using: Self.parameters(code: code))
        status = "Sending…"
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    guard let owner = self else { connection.cancel(); return }
                    guard let framed = try? LinkWire.frame(message) else { owner.status = "That is too large to send (limit 25 MB)."; connection.cancel(); return }
                    connection.send(content: framed, completion: .contentProcessed { error in
                        Task { @MainActor in owner.status = error == nil ? "Sent." : "Could not send."; connection.cancel() }
                    })
                case .failed, .waiting: self?.status = "Could not connect. Check the code and that both devices are on the same network."; connection.cancel()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// Syncs with a device that is showing its code: sends this device's snapshot and waits for the other's in return.
    func sync(snapshot: Data, to peer: Peer, code: String, completion: @escaping (Data?) -> Void) {
        let connection = NWConnection(to: peer.endpoint, using: Self.parameters(code: code))
        status = "Syncing…"
        var finished = false
        var buffer = Data()
        func finish(_ reply: Data?) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(reply)
        }
        func listen() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, error in
                Task { @MainActor in
                    if let data { buffer.append(data) }
                    if let messages = try? LinkWire.unframe(&buffer), let reply = messages.first(where: { $0.kind == .sync })?.data { finish(reply); return }
                    if done || error != nil { finish(nil) } else { listen() }
                }
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    guard let framed = try? LinkWire.frame(LinkMessage(kind: .sync, data: snapshot)) else { self?.status = "That is too large to sync."; finish(nil); return }
                    connection.send(content: framed, completion: .contentProcessed { error in
                        Task { @MainActor in if error != nil { finish(nil) } else { listen() } }
                    })
                case .failed, .waiting: self?.status = "Could not connect. Check the code and that both devices are on the same network."; finish(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        // Never wait for ever for an answer.
        Task { @MainActor in try? await Task.sleep(for: .seconds(20)); finish(nil) }
    }

    /// Ends everything: the listener, the search for devices, every connection that was accepted, and the code. Anything still in flight finds a new session
    /// number and does nothing. What was already received stays in the inbox until `clearInbox`.
    func stop() {
        generation += 1
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        for connection in connections.values { connection.cancel() }
        for file in incoming.values { file.discard() }
        incoming = [:]
        connections = [:]
        buffers = [:]
        code = ""
        failedAttempts = 0
        receiving = false
    }

    func clearInbox() { inbox = []; inboxBytes = 0 }

    // MARK: Files of any size

    private func discardIncoming(_ id: ObjectIdentifier) {
        if let file = incoming[id] {
            file.discard(); incoming[id] = nil
            if transfer?.isActive == true, transfer?.state == .receiving { transfer?.state = .failed("the connection ended") }
        }
    }

    private func reply(_ message: LinkMessage, on connection: NWConnection) {
        guard let framed = try? LinkWire.frame(message) else { return }
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    /// The receiving side: an offer is put to the person (unless they said not to ask), then the pieces are written and counted as they come, and the whole is checked.
    private func handleTransfer(_ message: LinkMessage, on connection: NWConnection, id: ObjectIdentifier) {
        switch message.kind {
        case .offer:
            guard let transferID = message.id, let name = message.name, let size = message.size, let sha = message.sha256, incoming[id] == nil, incoming.count < LinkTransferRules.maxIncoming,
                  size >= 0, size <= LinkTransferRules.maxFileBytes else { reply(LinkMessage(kind: .decline, id: message.id), on: connection); return }
            let folder = receivedFolder
            Task { @MainActor [weak self] in
                guard let self else { return }
                var yes = !self.askBeforeReceiving
                if !yes {
                    let readable = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    yes = await Dialogs.choose(title: "Receive “\(LinkWire.safeFileName(name))”?", message: "A device that has your code wants to send you this file (\(readable)). It goes straight between the two devices, and is checked when it arrives.", buttons: ["Receive", "Decline"]) == 0
                }
                guard yes, self.connections[id] != nil, self.incoming[id] == nil, let file = IncomingFile(id: transferID, name: name, size: size, sha256: sha, folder: folder) else {
                    self.reply(LinkMessage(kind: .decline, id: transferID), on: connection); return
                }
                self.incoming[id] = file
                self.transfer = TransferProgress(name: file.name, done: 0, total: size, state: .receiving)
                self.reply(LinkMessage(kind: .accept, id: transferID), on: connection)
                // A sender that goes quiet does not hold the file open for ever.
                Task { @MainActor [weak self] in
                    while let self, let file = self.incoming[id] {
                        try? await Task.sleep(for: .seconds(5))
                        if self.incoming[id] === file, Date().timeIntervalSince(file.lastActivity) > LinkTransferRules.idleTimeout {
                            file.discard(); self.incoming[id] = nil; self.transfer?.state = .failed("the other device stopped sending"); connection.cancel(); return
                        }
                    }
                }
            }
        case .chunk:
            guard let file = incoming[id], message.id == file.id, let data = message.data, let index = message.index, file.append(data, index: index) else {
                if let file = incoming[id] { file.discard(); incoming[id] = nil; transfer?.state = .failed("a piece was missing or out of order") }
                reply(LinkMessage(kind: .result, id: message.id, ok: false), on: connection); return
            }
            transfer?.done = file.received
        case .finish:
            guard let file = incoming[id], message.id == file.id else { reply(LinkMessage(kind: .result, id: message.id, ok: false), on: connection); return }
            transfer?.state = .verifying
            incoming[id] = nil
            if let url = file.finish() {
                transfer?.done = file.size; transfer?.state = .finished
                reply(LinkMessage(kind: .result, id: message.id, ok: true), on: connection)
                onFileReceived?(url)
            } else {
                transfer?.state = .failed("it did not match what was offered")
                reply(LinkMessage(kind: .result, id: message.id, ok: false), on: connection)
            }
        case .abort:
            if let file = incoming[id] { file.discard(); incoming[id] = nil; transfer?.state = .cancelled }
        default:
            break      // an answer meant for a sender, arriving at a receiver: ignored
        }
    }

    /// The sending side: hash the file, offer it, wait for a yes, then send it piece by piece (each piece waits for the last to be handed over) and wait for the other device's check.
    func sendFile(_ url: URL, to peer: Peer, code: String) {
        sendTask?.cancel()
        let name = LinkWire.safeFileName(url.lastPathComponent)
        transfer = TransferProgress(name: name, state: .waiting)
        let scoped = url.startAccessingSecurityScopedResource()
        sendTask = Task { @MainActor [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            #if os(iOS)
            var background: UIBackgroundTaskIdentifier = .invalid
            background = UIApplication.shared.beginBackgroundTask(withName: "Send a file") { [weak self] in Task { @MainActor in self?.sendTask?.cancel() }; UIApplication.shared.endBackgroundTask(background) }
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            #else
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Sending a file")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            #endif
            @MainActor func fail(_ reason: String) { self.transfer?.state = .failed(reason) }
            guard let sums = try? await Task.detached(priority: .userInitiated, operation: { try LinkTransferRules.checksum(of: url) }).value else { fail("the file could not be read"); return }
            guard sums.size <= LinkTransferRules.maxFileBytes else { fail("it is larger than 2 GB"); return }
            self.transfer?.total = sums.size
            let connection = NWConnection(to: peer.endpoint, using: Self.parameters(code: code))
            let reader = LinkReader(connection)
            defer { connection.cancel() }
            guard await reader.start() else { fail("could not connect. Check the code and that both devices are on the same network"); return }
            let transferID = UUID().uuidString
            guard await reader.send(LinkMessage(kind: .offer, name: name, id: transferID, size: sums.size, sha256: sums.sha256)) else { fail("could not send the offer"); return }
            guard let answer = await reader.next(timeout: LinkTransferRules.acceptTimeout), answer.id == transferID else { fail("no answer from the other device"); return }
            guard answer.kind == .accept else { self.transfer?.state = .declined; return }
            self.transfer?.state = .sending
            guard let handle = try? FileHandle(forReadingFrom: url) else { fail("the file could not be read"); return }
            defer { try? handle.close() }
            var index = 0
            while !Task.isCancelled {
                guard let piece = try? handle.read(upToCount: LinkTransferRules.chunkBytes), !piece.isEmpty else { break }
                guard await reader.send(LinkMessage(kind: .chunk, data: piece, id: transferID, index: index)) else { fail("the connection was lost"); return }
                index += 1
                self.transfer?.done += piece.count
            }
            if Task.isCancelled { _ = await reader.send(LinkMessage(kind: .abort, id: transferID)); self.transfer?.state = .cancelled; return }
            guard await reader.send(LinkMessage(kind: .finish, id: transferID)) else { fail("the connection was lost"); return }
            self.transfer?.state = .verifying
            if let result = await reader.next(timeout: 30), result.kind == .result, result.ok == true { self.transfer?.state = .finished } else { fail("the other device could not confirm it") }
        }
    }

    func cancelTransfer() { sendTask?.cancel() }
}

/// One connection read and written as awaited steps, for the sender: connect, send a message and wait until it is handed over, wait for the next message with a time limit.
@MainActor
final class LinkReader {
    private let connection: NWConnection
    private var buffer = Data()
    private var queue: [LinkMessage] = []

    init(_ connection: NWConnection) { self.connection = connection }

    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready: finished = true; continuation.resume(returning: true)
                case .failed, .waiting, .cancelled: finished = true; continuation.resume(returning: false)
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if !finished { finished = true; continuation.resume(returning: false) } }
        }
    }

    func send(_ message: LinkMessage) async -> Bool {
        guard let framed = try? LinkWire.frame(message) else { return false }
        return await withCheckedContinuation { continuation in
            connection.send(content: framed, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }

    func next(timeout: TimeInterval) async -> LinkMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while queue.isEmpty {
            if Date() >= deadline || Task.isCancelled { return nil }
            let got: Bool = await withCheckedContinuation { continuation in
                var finished = false
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
                    Task { @MainActor in
                        guard !finished else { return }
                        finished = true
                        if let data, let self { self.buffer.append(data); if let messages = try? LinkWire.unframe(&self.buffer) { self.queue += messages } }
                        continuation.resume(returning: error == nil && !done || !(data?.isEmpty ?? true))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, min(5, deadline.timeIntervalSinceNow))) { if !finished { finished = true; continuation.resume(returning: true) } }
            }
            if !got && queue.isEmpty { return nil }
        }
        return queue.removeFirst()
    }
}

struct DevicesView: View {
    @EnvironmentObject var model: BrowserModel
    @StateObject private var link = LocalLink()
    @State private var enteredCode = ""
    @State private var picking = false
    @State private var chosen: LocalLink.Peer?

    var body: some View {
        Form {
            Section {
                #if os(macOS)
                Text("The Mac does not accept incoming connections, which keeps its sandbox as narrow as possible. Receive on your iPhone, or use AirDrop.")
                    .font(.callout).foregroundStyle(.secondary)
                #else
                if link.receiving {
                    Text(LinkWire.formatted(link.code)).font(.system(size: 21, weight: .semibold, design: .monospaced)).minimumScaleFactor(0.6).lineLimit(1).frame(maxWidth: .infinity)
                    Button("Stop Receiving") { link.stop() }
                } else {
                    Button("Receive from Another Device") { link.startReceiving(deviceName: ProcessInfo.processInfo.hostName) }
                }
                Toggle("Ask before receiving a file", isOn: $model.linkAskBeforeReceiving)
                    .onChange(of: model.linkAskBeforeReceiving) { _, on in link.askBeforeReceiving = on }
                #endif
                ForEach(Array(link.inbox.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(label(item)).lineLimit(2)
                        Spacer()
                        Button(item.kind == .file ? "Save" : "Open") { handle(item) }.controlSize(.small)
                    }
                }
            } header: { Text("Receive") } footer: { Text("Shows a long one-time code that works for five minutes. Anything sent must use it, and goes straight between the two devices.") }
            Section {
                ForEach(link.peers) { peer in
                    Button { chosen = peer } label: { Label(peer.name, systemImage: chosen == peer ? "checkmark.circle.fill" : "laptopcomputer.and.iphone") }.buttonStyle(.plain)
                }
                if link.peers.isEmpty { Text("Looking for devices that are receiving…").foregroundStyle(.secondary) }
                TextField("Code shown on the other device (20 characters)", text: $enteredCode).autocorrectionDisabled()
                Button("Send This Page’s Link") { send(LinkMessage(kind: .link, name: model.active?.title, text: model.active?.url?.absoluteString)) }.disabled(!ready || model.active?.url == nil)
                Button("Send Copied Text") { if let text = pasteboardText() { send(LinkMessage(kind: .text, text: text)) } }.disabled(!ready)
                Button("Send a File…") { picking = true }.disabled(!ready || link.transfer?.isActive == true)
                if let file = model.transferFile {
                    Button("Send “\(file.lastPathComponent)”") {
                        if let chosen, let code = LinkWire.normalized(enteredCode) { link.sendFile(file, to: chosen, code: code); model.transferFile = nil }
                    }.disabled(!ready || link.transfer?.isActive == true)
                }
                Button("Sync Bookmarks and Tabs with This Device") { syncNow() }.disabled(!ready).accessibilityIdentifier("wifi-sync")
            } header: { Text("Send") }
            if let transfer = link.transfer {
                Section {
                    if transfer.isActive { ProgressView(value: transfer.fraction) }
                    Text(transfer.summary).font(.callout)
                    if transfer.total > 0 { Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.done), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(transfer.total), countStyle: .file))").font(.caption).foregroundStyle(.secondary) }
                    if transfer.isActive { Button("Cancel", role: .destructive) { link.cancelTransfer() } }
                } header: { Text("File") }
            }
            if !link.status.isEmpty { Section { Text(link.status).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .onAppear {
            link.startBrowsing()
            link.onSync = { data in await model.acceptWiFiSnapshot(data) }
            link.askBeforeReceiving = model.linkAskBeforeReceiving
            link.onFileReceived = { url in model.notice = "Received “\(url.lastPathComponent)” and checked it." }
        }
        .onDisappear { link.stop(); link.clearInbox() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Any size, in pieces: nothing is read into memory whole, the other device is asked first, and the file is checked when it arrives.
            if let chosen, let code = LinkWire.normalized(enteredCode) { link.sendFile(url, to: chosen, code: code) }
        }
        .accessibilityIdentifier("devices")
    }

    private var ready: Bool { chosen != nil && LinkWire.normalized(enteredCode) != nil }

    private func syncNow() {
        guard let chosen, let snapshot = model.signedWiFiSnapshot() else { return }
        guard let code = LinkWire.normalized(enteredCode) else { return }
        link.sync(snapshot: snapshot, to: chosen, code: code) { reply in
            Task { @MainActor in
                await model.acceptWiFiReply(reply, deviceName: chosen.name)
                link.status = model.syncStatus
            }
        }
    }

    private func send(_ message: LinkMessage) { if let chosen, let code = LinkWire.normalized(enteredCode) { link.send(message, to: chosen, code: code) } }

    private func label(_ item: LinkMessage) -> String {
        switch item.kind { case .file: "File: \(item.name ?? "")"; case .link: "Link: \(item.text ?? "")"; case .text: "Text: \(item.text ?? "")"; default: "Transfer" }
    }

    private func handle(_ item: LinkMessage) {
        switch item.kind {
        case .link: if let text = item.text { model.open(urlString: text, newTab: true) }
        case .text: if let text = item.text { copyToPasteboard(text); model.notice = "Copied." }
        case .file:
            guard let data = item.data else { return }
            let name = LinkWire.safeFileName(item.name ?? "")
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            let target = folder.appendingPathComponent(name)
            model.notice = (try? data.write(to: target, options: .withoutOverwriting)) != nil ? "Saved \(name) to Downloads." : "Could not save \(name)."
        default: break
        }
    }

    private func pasteboardText() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}
