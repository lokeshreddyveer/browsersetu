#if os(macOS)
import Foundation
import Network
import Security

// Remote control of downloads from a paired device.
//
// One command service, several ways to reach it. The same-Mac socket (Phase 13) is unchanged. This adds a gate in front of that very service for devices that are paired:
// the connection must be one the encrypted channel proved belongs to a paired, active device; the bearer token in the request must belong to the SAME device; the device's client must
// still be active; and the request then goes through `AutomationService.handle` like any other, so scopes, profile, the approval-only creation model, rate limits and the event stream
// are the ones that already exist. Nothing is duplicated, and no listener serves an unauthenticated request.

/// Whether this Mac can offer an encrypted, authenticated channel at all. Decided by looking, not by assuming.
enum RemoteTransportSupport: Equatable, Sendable {
    case supported
    case unsupported(String)

    /// The app is allowed to accept incoming connections only if its sandbox says so.
    static func canAcceptConnections() -> Bool {
        // Not sandboxed (the downloadable build, or a tool): nothing to ask. Sandboxed: the entitlement must be there.
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil else { return true }
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, "com.apple.security.network.server" as CFString, nil) as? Bool) == true
    }

    /// The honest answer for this system. A pre-shared-key TLS handshake is tried against itself over a private socket; only if a right key gets through and a wrong key does not
    /// is the channel offered. (On the system this was written on, Network.framework's pre-shared-key handshake did not complete, so this says unsupported there.)
    static func detect(accepting: () -> Bool = canAcceptConnections, handshake: () async -> Bool = { await RemoteChannelSelfTest.run() }) async -> RemoteTransportSupport {
        guard accepting() else { return .unsupported("This build of the app is not allowed to accept connections from other devices.") }
        guard await handshake() else { return .unsupported("This system could not set up the encrypted channel remote control needs.") }
        return .supported
    }
}

enum RemoteChannelSelfTest {
    /// Right key in, wrong key out, over a Unix socket in a private folder.
    static func run() async -> Bool {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString.prefix(6)).sock").path
        guard path.utf8.count < 100, let good = RemoteCrypto.random(32), let bad = RemoteCrypto.random(32) else { return false }
        defer { unlink(path) }
        let parameters = RemoteTLS.serverParameters(keys: [("selftest", good)])
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 8) { d, _, _, _ in c.send(content: d, completion: .contentProcessed { _ in c.cancel() }) }
        }
        let ready: Bool = await withCheckedContinuation { k in
            final class Once: @unchecked Sendable { let l = NSLock(); var d = false; func go(_ f: () -> Void) { l.lock(); defer { l.unlock() }; if !d { d = true; f() } } }
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state { case .ready: once.go { k.resume(returning: true) }; case .failed, .cancelled: once.go { k.resume(returning: false) }; default: break }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.go { k.resume(returning: false) } }
        }
        defer { listener.cancel() }
        guard ready else { return false }
        let right = await echo(path: path, key: good), wrong = await echo(path: path, key: bad)
        return right && !wrong
    }

    private static func echo(path: String, key: Data) async -> Bool {
        let c = NWConnection(to: NWEndpoint.unix(path: path), using: RemoteTLS.clientParameters(identity: "selftest", key: key))
        return await withCheckedContinuation { k in
            final class Once: @unchecked Sendable { let l = NSLock(); var d = false; func go(_ f: () -> Void) { l.lock(); defer { l.unlock() }; if !d { d = true; f() } } }
            let once = Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    c.send(content: Data("ok".utf8), completion: .contentProcessed { _ in })
                    c.receive(minimumIncompleteLength: 1, maximumLength: 8) { d, _, _, _ in once.go { k.resume(returning: d == Data("ok".utf8)); c.cancel() } }
                case .failed, .waiting, .cancelled: once.go { k.resume(returning: false); c.cancel() }
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.go { k.resume(returning: false); c.cancel() } }
        }
    }
}

/// What the Remote Devices screen shows.
enum RemoteAccessState: Equatable {
    case disabled
    case unsupported(String)
    case ready
    case pairing
    case connected(Int)
    case disconnected
    case permissionRequired(String)
    case error(String)

    var title: String {
        switch self {
        case .disabled: "Off"
        case .unsupported: "Not available"
        case .ready: "Ready"
        case .pairing: "Pairing a device"
        case .connected(let n): n == 1 ? "1 device connected" : "\(n) devices connected"
        case .disconnected: "No device connected"
        case .permissionRequired: "Permission needed"
        case .error: "Problem"
        }
    }
}

/// One profile's remote control: whether it is on (never by default), what the system can do, the paired devices, pairing, the gate, and a short bounded log. A diagnostics line never
/// holds an address, a token, a key, an invitation secret or anything from a page.
@MainActor
final class RemoteAccessController: ObservableObject {
    static let maxLog = 100

    let profile: String
    let devices: RemoteDeviceStore
    private(set) var pairing: PairingManager!
    let automation: AutomationService
    @Published private(set) var enabled = false
    @Published private(set) var support: RemoteTransportSupport?
    @Published private(set) var log: [String] = []
    @Published private(set) var lastError: String?
    private var connected: Set<String> = []
    private let supportCheck: () async -> RemoteTransportSupport
    private let now: () -> Date
    private let persistent: Bool
    private var checking = false
    private var generation = 0
    /// A transport drops every open connection of a device when told (revoked, removed, rotated, switched off).
    var dropChannels: (String) -> Void = { _ in }

    init(profile: String, persistent: Bool, clients: AutomationClientStore, automation: AutomationService, devices: RemoteDeviceStore, now: @escaping () -> Date = Date.init,
         supportCheck: @escaping () async -> RemoteTransportSupport = { await RemoteTransportSupport.detect() },
         endpoint: @escaping () -> (host: String, port: Int)? = { nil }) {
        self.profile = profile; self.persistent = persistent; self.automation = automation; self.devices = devices; self.now = now; self.supportCheck = supportCheck
        pairing = PairingManager(clients: clients, devices: devices, profile: profile, now: now,
                                 isAllowed: { [weak self] in
                                     guard let self else { return .disabled }
                                     if !self.enabled { return .disabled }
                                     if case .unsupported? = self.support { return .unsupported }
                                     return nil
                                 }, endpoint: endpoint, log: { [weak self] in self?.note($0) })
        pairing.abandoned = { [weak self] id in self?.revoke(id) }
    }

    func note(_ line: String) {
        log.append("\(Self.stamp(now())) \(line)")
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    private static func stamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    var state: RemoteAccessState {
        if let lastError { return .error(lastError) }
        if case .unsupported(let why)? = support { return .unsupported(why) }
        guard enabled else { return .disabled }
        if !automation.isEnabled { return .error("Download automation is switched off, so remote control is paused.") }
        if support == nil { return .error("Checking what this Mac can do…") }
        if pairing.invitation != nil || pairing.pending != nil { return .pairing }
        if !connected.isEmpty { return .connected(connected.count) }
        return devices.activeCount == 0 ? .ready : .disconnected
    }

    /// Off by default and never switched on by anything but the person. Turning it on checks what the system can do; if the encrypted channel is not possible the switch stays off.
    func setEnabled(_ on: Bool) async {
        lastError = nil
        guard on else { shutDown(); return }
        guard persistent else { lastError = "Remote control is not available in a temporary profile."; return }
        guard !enabled, !checking else { return }
        checking = true; defer { checking = false }
        let started = generation
        let result = await supportCheck()
        guard started == generation else { return }          // switched off while the check ran: it stays off
        support = result
        if case .unsupported(let why) = result { enabled = false; note("Remote control unavailable"); lastError = nil; _ = why; return }
        enabled = true
        automation.start()
        reconcile()
        note("Remote control switched on")
    }

    /// Everything stops at once: pairing is withdrawn, every device's event stream ends, and nothing is left listening because of this.
    func shutDown() {
        generation += 1
        pairing.cancel()
        for id in connected.union(devices.devices.map(\.id)) { automation.events.close(clientID: id); dropChannels(id) }          // only the devices' streams: the same-Mac socket is untouched
        connected.removeAll()
        if enabled { note("Remote control switched off") }
        enabled = false
    }

    /// A device whose automation client is gone, revoked or expired (changed in the Automation settings) is withdrawn here too, with its key.
    func reconcile() {
        for d in devices.devices where d.isActive {
            let client = automation.clients.clients.first { $0.id == d.id }
            if client == nil || client?.isActive(at: now()) != true { devices.revoke(d.id); dropChannels(d.id); note("A device was withdrawn because its access was removed elsewhere") }
        }
    }

    // MARK: Devices

    func revoke(_ id: String) {
        devices.revoke(id)
        let commit = automation.clients.revoke(id)          // ends the device's event streams through the client store, and survives a restart as every revocation does
        connected.remove(id)
        dropChannels(id)
        if case .restrictedButNotSaved = commit { lastError = "A device was revoked but the change could not be saved yet; it is retried."; note("A revocation could not be saved yet") }
        else { note("A device was revoked") }
    }

    func remove(_ id: String) {
        revoke(id)
        devices.remove(id)
        _ = automation.clients.remove(id)          // the revoked client goes too, so removed devices do not use up the limit
        note("A device was removed")
    }

    /// New channel key and a new token, shown to the device once. Nil when either could not be saved (then nothing changed).
    func rotateCredentials(_ id: String) -> PairingCredentials? {
        guard let device = devices.device(id), device.isActive, let newKey = RemoteCrypto.random(32), let oldKey = devices.keys.key(for: id) else { return nil }
        _ = device
        // Both halves or neither: the channel key first, then the token; if the token cannot be changed the key goes back, so the device is never left with a mismatched pair.
        guard devices.rotateKey(id, newKey: newKey) else { return nil }
        let result = automation.clients.rotate(id)
        guard let token = result.token else { devices.restoreKey(id, oldKey: oldKey); return nil }
        dropChannels(id)          // connections made with the old key end
        note("A device's credentials were rotated")
        return PairingCredentials(deviceID: id, deviceKey: newKey, token: token, macName: Host.current().localizedName ?? "This Mac", scopes: automation.clients.clients.first { $0.id == id }?.scopes ?? [])
    }

    func peerConnected(_ id: String) { connected.insert(id); devices.noteConnected(id); note("A device connected") }
    func peerDisconnected(_ id: String) { if connected.remove(id) != nil { note("A device disconnected") } }
}

/// The gate. A request arrives with the identity the encrypted channel proved (or none); this decides whether it may reach the command service.
@MainActor
final class RemoteGateway {
    enum Peer: Equatable {
        /// The channel was set up with a paired device's key.
        case device(String)
        /// The channel was set up with a pairing invitation's secret.
        case pairing(invitation: String)
        case none
    }

    static let maxBody = 16 * 1024
    private unowned let controller: RemoteAccessController
    /// Bad tokens from one device are counted like any other bad try (every attempt counts, successful or not, against a generous window).
    private var authFailures = AutomationRateLimiter(limit: 120, window: 60)

    init(controller: RemoteAccessController) { self.controller = controller }

    func handle(_ request: AutomationRequest, peer: Peer) async -> AutomationReply {
        guard controller.enabled else { return AutomationJSON.error(AutomationError(status: 503, code: "disabled", message: "Remote control is switched off.")) }
        guard request.body.count <= Self.maxBody else { return AutomationJSON.error(.tooLarge) }
        switch peer {
        case .none: return AutomationJSON.error(.unauthorized("No device identity."))
        case .pairing(let invitation): return pairingRoute(request, invitation: invitation)
        case .device(let id): return await deviceRoute(request, deviceID: id)
        }
    }

    private func deviceRoute(_ request: AutomationRequest, deviceID: String) async -> AutomationReply {
        let c = controller
        // The device must be known, active, and in this profile; its client must still be active (revocation lives there too); and the token must be that same device's.
        guard let device = c.devices.device(deviceID), device.isActive, device.profile == c.profile, c.devices.keys.key(for: deviceID) != nil else {
            c.note("A connection from an unknown or withdrawn device was refused")
            return AutomationJSON.error(.unauthorized("This device is not paired."))
        }
        guard authFailures.allow(deviceID, at: Date().timeIntervalSinceReferenceDate) else { return AutomationJSON.error(.tooMany) }
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer "), case .ok(let client) = c.automation.clients.authenticate(String(header.dropFirst(7))) else {
            return AutomationJSON.error(.unauthorized())
        }
        guard client.id == deviceID, client.profile == c.profile else {
            c.note("A token that belongs to another device was refused")
            return AutomationJSON.error(.forbidden("device_mismatch", "This credential belongs to another device."))
        }
        if request.path.hasPrefix("/pair") { return AutomationJSON.error(.notFound) }
        var routed = request
        routed.transport = .remote(device: deviceID)
        let reply = await c.automation.handle(routed)
        c.devices.noteConnected(deviceID)
        return reply
    }

    /// The only two things a pairing channel may do.
    private func pairingRoute(_ request: AutomationRequest, invitation: String) -> AutomationReply {
        let c = controller
        struct Ask: Codable { var invitation: String; var name: String; var kind: String; var nonce: String }
        struct Claim: Codable { var pairing: String; var proof: String }
        switch (request.method, request.path) {
        case ("POST", "/pair/v1/request"):
            guard let ask = try? AutomationJSON.decoder.decode(Ask.self, from: request.body), ask.invitation == invitation, let nonce = RemoteCrypto.fromBase32(ask.nonce) else {
                c.pairing.noteBadGuess()
                return AutomationJSON.error(.badRequest("bad_request", "The request is not valid."))
            }
            switch c.pairing.request(invitationID: ask.invitation, deviceName: ask.name, kind: RemoteDeviceKind(rawValue: ask.kind) ?? .other, clientNonce: nonce) {
            case .failure(let e): return AutomationJSON.error(Self.map(e))
            case .success(let r):
                struct Out: Codable { var pairing: String; var nonce: String }
                return AutomationJSON.reply(Out(pairing: r.pairingID, nonce: RemoteCrypto.base32(r.serverNonce)))
            }
        case ("POST", "/pair/v1/claim"):
            guard let claim = try? AutomationJSON.decoder.decode(Claim.self, from: request.body), let proof = RemoteCrypto.fromBase32(claim.proof) else {
                return AutomationJSON.error(.badRequest("bad_request", "The request is not valid."))
            }
            switch c.pairing.claim(pairingID: claim.pairing, proof: proof) {
            case .failure(.notApproved): return AutomationJSON.error(AutomationError(status: 202, code: "pending", message: "Waiting for approval on the Mac."))
            case .failure(let e): return AutomationJSON.error(Self.map(e))
            case .success(let cred):
                struct Out: Codable { var deviceId: String; var deviceKey: String; var token: String; var mac: String; var scopes: [String] }
                return AutomationJSON.reply(Out(deviceId: cred.deviceID, deviceKey: RemoteCrypto.base32(cred.deviceKey), token: cred.token, mac: cred.macName, scopes: cred.scopes.map(\.rawValue).sorted()))
            }
        default: return AutomationJSON.error(.notFound)
        }
    }

    private static func map(_ e: PairingError) -> AutomationError {
        switch e {
        case .disabled, .unsupported: AutomationError(status: 503, code: "disabled", message: e.message)
        case .tooManyAttempts: .tooMany
        case .notFound: .notFound
        case .busy, .replayed: .conflict("pairing_unavailable", e.message)
        default: AutomationError(status: 400, code: "pairing_refused", message: e.message)
        }
    }
}
#endif
