#if os(macOS)
import Foundation
import CryptoKit

// Pairing a device.
//
//   1. The Mac makes an invitation: a random id and a random 128-bit secret, good for two minutes and for one device. The QR code (or the typed code) carries them. They are not an
//      access token: they open nothing by themselves and are of no use once the pairing has ended.
//   2. The companion reaches the Mac over the encrypted channel that the secret sets up, and asks to pair, saying what it is called and sending a random number.
//   3. The Mac answers with a random number of its own. Both sides work out the same six digits from the two numbers and the secret. The companion shows them; the PERSON types them into the
//      Mac. A stranger who only photographed the QR code cannot see the companion's screen, so cannot be approved by mistake, and three wrong tries end the pairing.
//   4. Only then does the Mac make the device's credentials (an automation client with its own scopes, and a channel key) and hand them over, once, to whoever can prove it holds the secret.
//
// The credentials are never in the QR code, never logged, never in a URL, and the Mac keeps only the hash of the token.

enum PairingError: Error, Equatable {
    case disabled, unsupported
    case invalidInvitation, expired, replayed, busy, notFound, rejected
    case tooManyAttempts
    case badRequest(String)
    case wrongCode(remaining: Int)
    case notApproved
    case tooManyDevices
    case storage(String)

    var message: String {
        switch self {
        case .disabled: "Remote control is switched off."
        case .unsupported: "This Mac cannot offer remote control."
        case .invalidInvitation: "That invitation is not valid."
        case .expired: "That invitation has expired."
        case .replayed: "That invitation has already been used."
        case .busy: "Another device is already waiting to be approved."
        case .notFound: "No such pairing."
        case .rejected: "The pairing was declined."
        case .tooManyAttempts: "Too many wrong attempts. Start again."
        case .badRequest(let why): why
        case .wrongCode(let remaining): "That is not the number the device shows. \(remaining) attempt\(remaining == 1 ? "" : "s") left."
        case .notApproved: "Waiting for approval on the Mac."
        case .tooManyDevices: "Too many devices are paired. Remove one first."
        case .storage(let why): why
        }
    }
}

struct PairingInvitation: Equatable {
    var id: String
    var expiresAt: Date
    var scopes: Set<AutomationScope>
    /// What the QR code holds.
    var qrPayload: String
    /// The same secret for typing: groups of four letters and digits.
    var readableCode: String
}

struct PairingPending: Equatable {
    var pairingID: String
    var deviceName: String
    var kind: RemoteDeviceKind
    var scopes: Set<AutomationScope>
    var expiresAt: Date
    var wrongAttempts: Int
}

/// What a device receives, once.
struct PairingCredentials: Equatable {
    var deviceID: String
    var deviceKey: Data
    var token: String
    var macName: String
    var scopes: Set<AutomationScope>
}

@MainActor
final class PairingManager: ObservableObject {
    static let invitationLifetime: TimeInterval = 120
    static let approvalLifetime: TimeInterval = 120
    static let maxWrongCodes = 3
    static let maxBadGuesses = 5
    static let guessWindow: TimeInterval = 60
    /// What a new device may do unless the person widens it. Never the file permission.
    static let defaultScopes: Set<AutomationScope> = [.downloadsRead, .downloadsControl, .downloadsCreate, .queuesRead]

    @Published private(set) var invitation: PairingInvitation?
    @Published private(set) var pending: PairingPending?

    private struct Secret { var id: String; var secret: Data; var consumed = false; var expiresAt: Date; var scopes: Set<AutomationScope> }
    private struct Waiting {
        var pairingID: String; var invitationID: String; var secret: Data; var name: String; var kind: RemoteDeviceKind
        var expectedCode: String; var wrong = 0; var expiresAt: Date; var scopes: Set<AutomationScope>
        var credentials: PairingCredentials?; var rejected = false
    }
    private var secret: Secret?
    private var waiting: Waiting?
    private var badGuesses: [Date] = []

    private let clients: AutomationClientStore
    private let devices: RemoteDeviceStore
    private let profile: String
    private let now: () -> Date
    private let random: (Int) -> Data?
    private let isAllowed: () -> PairingError?
    private let endpoint: () -> (host: String, port: Int)?
    private let macName: () -> String
    private let log: (String) -> Void
    /// Told when credentials were made for a device that never collected them, so the device is withdrawn rather than left paired with nobody holding its key.
    var abandoned: (String) -> Void = { _ in }
    private var expiryTask: Task<Void, Never>?
    private var claimFailures = 0

    init(clients: AutomationClientStore, devices: RemoteDeviceStore, profile: String, now: @escaping () -> Date = Date.init,
         random: @escaping (Int) -> Data? = RemoteCrypto.random, isAllowed: @escaping () -> PairingError? = { nil },
         endpoint: @escaping () -> (host: String, port: Int)? = { nil }, macName: @escaping () -> String = { Host.current().localizedName ?? "This Mac" },
         log: @escaping (String) -> Void = { _ in }) {
        self.clients = clients; self.devices = devices; self.profile = profile; self.now = now; self.random = random
        self.isAllowed = isAllowed; self.endpoint = endpoint; self.macName = macName; self.log = log
    }

    // MARK: Mac side

    /// A new invitation. Any earlier one that was not used is withdrawn: there is one at a time.
    func createInvitation(scopes: Set<AutomationScope> = PairingManager.defaultScopes, includeFiles: Bool = false) -> Result<PairingInvitation, PairingError> {
        if let why = isAllowed() { return .failure(why) }
        if awaitingCollection { return .failure(.busy) }
        var wanted = scopes
        if !includeFiles { wanted.remove(.downloadsFiles) }
        guard !wanted.isEmpty else { return .failure(.badRequest("Choose at least one permission.")) }
        guard devices.activeCount < RemoteDeviceStore.maxDevices else { return .failure(.tooManyDevices) }
        guard let id = random(6), let secretBytes = random(16), id.count == 6, secretBytes.count == 16 else { return .failure(.storage("A secure random number could not be made.")) }
        cancel(quiet: true)
        let invitationID = id.map { String(format: "%02x", $0) }.joined()
        let expires = now().addingTimeInterval(Self.invitationLifetime)
        secret = Secret(id: invitationID, secret: secretBytes, expiresAt: expires, scopes: wanted)
        let code = RemoteCrypto.base32(secretBytes)
        var link = URLComponents(); link.scheme = "browsersetu-pair"; link.host = "v1"
        var items = [URLQueryItem(name: "i", value: invitationID), URLQueryItem(name: "k", value: code)]
        if let e = endpoint() { items.append(URLQueryItem(name: "h", value: e.host)); items.append(URLQueryItem(name: "p", value: String(e.port))) }
        link.queryItems = items
        let made = PairingInvitation(id: invitationID, expiresAt: expires, scopes: wanted, qrPayload: link.string ?? "", readableCode: RemoteCrypto.grouped(code))
        invitation = made
        scheduleExpiry()
        log("Pairing invitation made")
        return .success(made)
    }

    func cancel() { cancel(quiet: false) }

    private func cancel(quiet: Bool) {
        let had = secret != nil || waiting != nil
        wipe()
        if had && !quiet { log("Pairing cancelled") }
    }

    private func wipe() {
        expiryTask?.cancel(); expiryTask = nil
        if let id = waiting?.credentials?.deviceID { abandoned(id) }          // approved but never collected
        secret = nil; waiting = nil
        invitation = nil; pending = nil; claimFailures = 0
    }

    /// Runs the clock out on its own: an invitation or an approved-but-uncollected pairing is dropped (with its secret and credentials) at its time, whether or not any screen is open.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        let due = [secret?.expiresAt, waiting?.expiresAt].compactMap { $0 }.min()
        guard let due else { return }
        let delay = max(0.05, due.timeIntervalSince(now()) + 0.05)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.expireIfNeeded()
            self?.scheduleExpiry()
        }
    }

    /// True while credentials have been made and the device has not yet collected them.
    var awaitingCollection: Bool { waiting?.credentials != nil }

    /// A wrong invitation seen anywhere (including by the gateway) counts toward the lockout.
    func noteBadGuess() { badGuesses.append(now()) }

    /// Moves time on: an invitation or a waiting device that has run out is dropped, with its secret.
    func expireIfNeeded() {
        if let s = secret, s.expiresAt <= now(), waiting == nil { wipe(); log("Pairing invitation expired") }
        if let w = waiting, w.expiresAt <= now() { wipe(); log("Pairing request expired") }
    }

    /// The person approves the device by typing the six digits the device shows.
    func approve(pairingID: String, typedCode: String) -> Result<String, PairingError> {
        expireIfNeeded()
        if let why = isAllowed() { return .failure(why) }
        guard var w = waiting, w.pairingID == pairingID, w.credentials == nil, !w.rejected else { return .failure(.notFound) }
        let typed = typedCode.filter(\.isNumber)
        guard RemoteCrypto.constantTimeEqual(Data(typed.utf8), Data(w.expectedCode.utf8)) else {
            w.wrong += 1
            if w.wrong >= Self.maxWrongCodes { wipe(); log("Pairing attempt ended: wrong confirmation"); return .failure(.tooManyAttempts) }
            waiting = w; pending?.wrongAttempts = w.wrong
            log("Pairing confirmation did not match")
            return .failure(.wrongCode(remaining: Self.maxWrongCodes - w.wrong))
        }
        guard devices.activeCount < RemoteDeviceStore.maxDevices else { return .failure(.tooManyDevices) }
        guard let key = random(32), key.count == 32 else { return .failure(.storage("A secure random number could not be made.")) }
        switch clients.enrol(name: w.name, profile: profile, scopes: w.scopes) {
        case .refused(let why): return .failure(.storage(why))
        case .created(let client, let token):
            let device = RemoteDevice(id: client.id, name: w.name, kind: w.kind, profile: profile, enrolledAt: now(), lastConnectedAt: nil, credentialVersion: 1, revokedAt: nil)
            guard devices.add(device, key: key) else {
                clients.revoke(client.id)          // never leave a client that has no device record
                return .failure(.storage("The device could not be saved, so it was not paired."))
            }
            w.credentials = PairingCredentials(deviceID: client.id, deviceKey: key, token: token, macName: macName(), scopes: w.scopes)
            w.expiresAt = now().addingTimeInterval(Self.approvalLifetime)          // a fresh window to collect them
            waiting = w; pending = nil; invitation = nil
            scheduleExpiry()
            log("Pairing approved")
            return .success(client.id)
        }
    }

    func reject(pairingID: String) {
        guard var w = waiting, w.pairingID == pairingID else { return }
        w.rejected = true; waiting = w; pending = nil; invitation = nil          // the device is told on its next look, then everything is dropped
        log("Pairing declined")
    }

    // MARK: Device side (reached over the encrypted channel)

    /// The device asks to pair. One request per invitation; a second use of the same invitation is a replay.
    func request(invitationID: String, deviceName: String, kind: RemoteDeviceKind, clientNonce: Data) -> Result<(pairingID: String, serverNonce: Data), PairingError> {
        expireIfNeeded()
        if let why = isAllowed() { return .failure(why) }
        let t = now()
        badGuesses.removeAll { t.timeIntervalSince($0) > Self.guessWindow }
        guard badGuesses.count < Self.maxBadGuesses else { return .failure(.tooManyAttempts) }
        guard var s = secret, AgentHTTP.constantTimeEqual(s.id, invitationID) else {
            badGuesses.append(t); log("Pairing attempted with an unknown invitation"); return .failure(.invalidInvitation)
        }
        guard s.expiresAt > t else { wipe(); return .failure(.expired) }
        guard !s.consumed else { log("A used pairing invitation was presented again"); return .failure(.replayed) }
        let name = deviceName.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned]
        guard !name.isEmpty, name.count <= 60, !name.unicodeScalars.contains(where: { forbidden.contains($0.properties.generalCategory) }) else { return .failure(.badRequest("The device needs a short plain name.")) }
        guard clientNonce.count == 16 else { return .failure(.badRequest("The request is not valid.")) }
        guard waiting == nil else { return .failure(.busy) }
        guard let serverNonce = random(16), let pid = random(6), serverNonce.count == 16, pid.count == 6 else { return .failure(.storage("A secure random number could not be made.")) }
        s.consumed = true; secret = s
        let pairingID = pid.map { String(format: "%02x", $0) }.joined()
        let expected = RemoteCrypto.confirmationNumber(secret: s.secret, clientNonce: clientNonce, serverNonce: serverNonce)
        let expires = t.addingTimeInterval(Self.approvalLifetime)
        waiting = Waiting(pairingID: pairingID, invitationID: s.id, secret: s.secret, name: name, kind: kind, expectedCode: expected, expiresAt: expires, scopes: s.scopes)
        pending = PairingPending(pairingID: pairingID, deviceName: name, kind: kind, scopes: s.scopes, expiresAt: expires, wrongAttempts: 0)
        scheduleExpiry()
        log("Pairing requested")
        return .success((pairingID, serverNonce))
    }

    /// The proof that the device holds the invitation secret: an HMAC over the pairing id.
    static func claimProof(secret: Data, pairingID: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(pairingID.utf8), using: SymmetricKey(data: RemoteCrypto.derive(secret, label: "claim"))))
    }

    /// The device collects its credentials, once, after the person approved.
    func claim(pairingID: String, proof: Data) -> Result<PairingCredentials, PairingError> {
        expireIfNeeded()
        guard let w = waiting, w.pairingID == pairingID else { return .failure(.notFound) }
        guard RemoteCrypto.constantTimeEqual(proof, Self.claimProof(secret: w.secret, pairingID: pairingID)) else {
            claimFailures += 1
            if claimFailures >= 5 { wipe(); log("Pairing ended: too many wrong claims"); return .failure(.tooManyAttempts) }
            return .failure(.invalidInvitation)
        }
        if w.rejected { wipe(); return .failure(.rejected) }
        guard let credentials = w.credentials else { return .failure(.notApproved) }
        waiting?.credentials = nil          // handed over: not abandoned
        wipe()                                   // handed over once; nothing about it stays in memory
        log("Pairing completed")
        return .success(credentials)
    }
}
#endif
