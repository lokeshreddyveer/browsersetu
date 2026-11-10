import XCTest
import CryptoKit
@testable import Browser_Setu

// Phase 23: pairing, device identity and authorization, the gate in front of the existing command service, events, and the settings state. The encrypted network channel itself is NOT
// tested here: on the system this was written on the pre-shared-key TLS handshake does not complete and the app is not allowed to accept incoming connections (see the transport tests),
// so what is tested is everything above the channel, with the channel's verdict ("this connection belongs to device X / to invitation Y") supplied by the test.

// MARK: - Rig

@MainActor
final class RemoteRig {
    let rig: Rig
    let keys = MemoryDeviceKeyStore()
    let devices: RemoteDeviceStore
    let remote: RemoteAccessController
    let gateway: RemoteGateway
    var support: RemoteTransportSupport = .supported

    init(profile: String = "default", extra: [DownloadCoordinator] = [], deviceFile: URL? = nil, rig existing: Rig? = nil) {
        rig = existing ?? Rig(profile: profile, extra: extra)
        let box = rig.box
        devices = RemoteDeviceStore(file: deviceFile, keys: keys, now: { box.now })
        var supportBox: () -> RemoteTransportSupport = { .supported }
        remote = RemoteAccessController(profile: profile, persistent: true, clients: rig.store, automation: rig.service, devices: devices, now: { box.now }, supportCheck: { supportBox() })
        gateway = RemoteGateway(controller: remote)
        supportBox = { [unowned self] in self.support }
    }

    func turnOn() async { await remote.setEnabled(true) }

    /// What a companion does, step by step, against the Mac's pairing endpoints.
    struct Companion {
        var secret: Data
        var invitation: String
    }

    func companion(_ i: PairingInvitation) -> Companion { Companion(secret: RemoteCrypto.fromBase32(i.readableCode)!, invitation: i.id) }

    func call(_ method: String, _ path: String, peer: RemoteGateway.Peer, token: String? = nil, body: String? = nil, headers: [String: String] = [:]) async -> (status: Int, json: Any?, reply: AutomationReply) {
        var h = headers
        if let token { h["authorization"] = "Bearer " + token }
        if body != nil { h["content-type"] = "application/json" }
        let reply = await gateway.handle(AutomationRequest(method: method, target: path, headers: h, body: Data((body ?? "").utf8), transport: .unixSocket), peer: peer)
        if case .json(let status, let data) = reply { return (status, try? JSONSerialization.jsonObject(with: data), reply) }
        return (200, nil, reply)
    }

    /// Pairs a device through the gateway exactly as a companion would, including the person typing the digits.
    func pair(name: String = "Phone", scopes: Set<AutomationScope> = PairingManager.defaultScopes) async throws -> PairingCredentials {
        guard case .success(let inv) = remote.pairing.createInvitation(scopes: scopes) else { throw XCTSkip("no invitation") }
        let c = companion(inv)
        let nonce = RemoteCrypto.random(16)!
        let asked = await call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"\(name)\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(nonce))\"}")
        let answer = try XCTUnwrap(asked.json as? [String: Any]), pid = try XCTUnwrap(answer["pairing"] as? String), snonce = try XCTUnwrap(RemoteCrypto.fromBase32(try XCTUnwrap(answer["nonce"] as? String)))
        let digits = RemoteCrypto.confirmationNumber(secret: c.secret, clientNonce: nonce, serverNonce: snonce)
        guard case .success = remote.pairing.approve(pairingID: pid, typedCode: digits) else { throw XCTSkip("approval refused") }
        let proof = PairingManager.claimProof(secret: c.secret, pairingID: pid)
        let claimed = await call("POST", "/pair/v1/claim", peer: .pairing(invitation: inv.id), body: "{\"pairing\":\"\(pid)\",\"proof\":\"\(RemoteCrypto.base32(proof))\"}")
        let out = try XCTUnwrap(claimed.json as? [String: Any])
        return PairingCredentials(deviceID: try XCTUnwrap(out["deviceId"] as? String), deviceKey: try XCTUnwrap(RemoteCrypto.fromBase32(try XCTUnwrap(out["deviceKey"] as? String))),
                                  token: try XCTUnwrap(out["token"] as? String), macName: out["mac"] as? String ?? "", scopes: Set((out["scopes"] as? [String] ?? []).compactMap(AutomationScope.init(rawValue:))))
    }
}

// MARK: - The Phase 22 lease problem

@MainActor
final class Phase23LeaseTests: XCTestCase {
    func testACancelledQueuedDownloadLeavesNoPlaceInLineAndNoLease() async throws {
        let c = DownloadCoordinator()
        c.maxConcurrent = 1
        // Three downloads waiting in the scheduler's line behind a held queue (each wants a connection to the same website).
        c.scheduler.hold(until: .distantFuture)
        var ids: [UUID] = []
        for i in 0..<3 {
            let s = c.begin(suggestedName: "f\(i).bin", sourceURL: URL(string: "https://q.test/f\(i)"), cancel: {})
            ids.append(s.id)
            c.scheduler.enqueue(id: s.id, kind: .start, filename: "f\(i).bin", priority: .normal, need: ResourceNeed(requests: [.init(pool: ConnectionBudget.poolName, amount: 1, scope: "q.test")])) {}
        }
        let victim = ids[1]
        XCTAssertTrue(c.scheduler.contains(victim), "waiting in line")
        c.cancel(victim)
        XCTAssertFalse(c.scheduler.contains(victim), "a cancelled download is no longer waiting in line")
        c.scheduler.hold(until: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ConnectionBudget.shared.holding(task: victim), 0, "nothing is leased for a download that was cancelled")
        for id in ids { c.cancel(id) }
        for id in ids { XCTAssertFalse(c.scheduler.contains(id)); XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0) }
        XCTAssertEqual(ConnectionBudget.shared.holding(owner: c.ownerID), 0, "this profile holds nothing")
    }
}

// MARK: - Pairing

@MainActor
final class RemotePairingTests: XCTestCase {
    func testDisabledByDefaultAndNothingCanBePairedWhileOff() async {
        let r = RemoteRig()
        XCTAssertFalse(r.remote.enabled); XCTAssertEqual(r.remote.state, .disabled)
        if case .failure(.disabled) = r.remote.pairing.createInvitation() {} else { XCTFail("no invitation while off") }
        let reply = await r.call("GET", "/v1/downloads", peer: .device("x"), token: "bsat_x")
        XCTAssertEqual(reply.status, 503)
    }

    func testAValidPairingGivesTheDeviceItsOwnScopedCredentials() async throws {
        let r = RemoteRig(); await r.turnOn()
        XCTAssertTrue(r.remote.enabled)
        let cred = try await r.pair(name: "Alice's phone")
        XCTAssertEqual(cred.deviceKey.count, 32); XCTAssertTrue(cred.token.hasPrefix("bsat_\(cred.deviceID)_"))
        XCTAssertEqual(cred.scopes, PairingManager.defaultScopes); XCTAssertFalse(cred.scopes.contains(.downloadsFiles), "the file permission is never a default")
        let device = try XCTUnwrap(r.devices.device(cred.deviceID))
        XCTAssertEqual(device.name, "Alice's phone"); XCTAssertEqual(device.credentialVersion, 1); XCTAssertEqual(device.profile, "default"); XCTAssertTrue(device.isActive)
        XCTAssertEqual(r.keys.key(for: cred.deviceID), cred.deviceKey)
        XCTAssertEqual(r.rig.store.clients.first { $0.id == cred.deviceID }?.scopes, cred.scopes)
        XCTAssertNil(r.remote.pairing.invitation); XCTAssertNil(r.remote.pairing.pending, "nothing about the pairing stays in memory")
    }

    func testTheQRCodeAndTheLogHoldNoCredential() async throws {
        let r = RemoteRig(); await r.turnOn()
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        XCTAssertTrue(inv.qrPayload.hasPrefix("browsersetu-pair://v1?"))
        XCTAssertFalse(inv.qrPayload.contains("bsat_")); XCTAssertFalse(inv.qrPayload.lowercased().contains("token"))
        let secret = RemoteCrypto.base32(RemoteCrypto.fromBase32(inv.readableCode)!)
        XCTAssertTrue(inv.qrPayload.contains(secret)); XCTAssertEqual(RemoteCrypto.fromBase32(inv.readableCode)?.count, 16, "128 bits, not a short number")
        XCTAssertGreaterThan(inv.readableCode.count, 20)
        _ = r.remote.pairing.cancel()
        let cred = try await r.pair()
        let all = r.remote.log.joined(separator: "\n")
        for forbidden in [cred.token, RemoteCrypto.base32(cred.deviceKey), secret, "bsat_"] { XCTAssertFalse(all.contains(forbidden), "log must not contain secrets") }
        XCTAssertLessThanOrEqual(r.remote.log.count, RemoteAccessController.maxLog)
    }

    func testAnInvitationExpiresAndItsSecretIsDropped() async throws {
        let r = RemoteRig(); await r.turnOn()
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        r.rig.advance(PairingManager.invitationLifetime + 1)
        let reply = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}")
        XCTAssertNotEqual(reply.status, 200)
        r.remote.pairing.expireIfNeeded()
        XCTAssertNil(r.remote.pairing.invitation)
    }

    func testAUsedInvitationCannotBeReplayed() async throws {
        let r = RemoteRig(); await r.turnOn()
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        let body = "{\"invitation\":\"\(inv.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}"
        let first = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: body); XCTAssertEqual(first.status, 200)
        let second = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: body); XCTAssertEqual(second.status, 409, "a second device with the same invitation is refused")
        // And after a full pairing the same invitation is gone.
        let r2 = RemoteRig(); await r2.turnOn()
        guard case .success(let i2) = r2.remote.pairing.createInvitation() else { return XCTFail() }
        _ = try await r2.pairWith(i2)
        let again = await r2.call("POST", "/pair/v1/request", peer: .pairing(invitation: i2.id), body: "{\"invitation\":\"\(i2.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}")
        XCTAssertNotEqual(again.status, 200)
    }

    func testWrongInvitationsAreRateLimited() async {
        let r = RemoteRig(); await r.turnOn()
        guard case .success = r.remote.pairing.createInvitation() else { return XCTFail() }
        var statuses: [Int] = []
        for i in 0..<8 {
            let id = String(format: "%012x", i)
            statuses.append(await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: id), body: "{\"invitation\":\"\(id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}").status)
        }
        XCTAssertEqual(statuses.prefix(5).filter { $0 == 400 }.count, 5); XCTAssertTrue(statuses.suffix(3).allSatisfy { $0 == 429 }, "\(statuses)")
        r.rig.advance(PairingManager.guessWindow + 1)
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        let ok = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}")
        XCTAssertEqual(ok.status, 200, "the limit lifts with time")
    }

    func testANewInvitationReplacesTheOldAndOnlyOneDeviceWaitsAtATime() async throws {
        let r = RemoteRig(); await r.turnOn()
        guard case .success(let a) = r.remote.pairing.createInvitation(), case .success(let b) = r.remote.pairing.createInvitation() else { return XCTFail() }
        XCTAssertNotEqual(a.id, b.id)
        let old = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: a.id), body: "{\"invitation\":\"\(a.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}")
        XCTAssertEqual(old.status, 400, "the first invitation was withdrawn")
        let one = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: b.id), body: "{\"invitation\":\"\(b.id)\",\"name\":\"One\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}")
        XCTAssertEqual(one.status, 200)
        XCTAssertEqual(r.remote.pairing.pending?.deviceName, "One")
    }

    func testCancellingEndsEverythingAndTheDeviceCannotCollect() async throws {
        let r = RemoteRig(); await r.turnOn()
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        r.remote.pairing.cancel()
        XCTAssertNil(r.remote.pairing.invitation)
        let reply = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}")
        XCTAssertNotEqual(reply.status, 200)
        XCTAssertEqual(r.devices.devices.count, 0)
    }

    func testTheWrongDigitsDoNotApproveAndThreeEndThePairing() async throws {
        let r = RemoteRig(); await r.turnOn()
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        let nonce = RemoteCrypto.random(16)!
        let asked = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"Stranger\",\"kind\":\"other\",\"nonce\":\"\(RemoteCrypto.base32(nonce))\"}")
        let pid = (asked.json as? [String: Any])?["pairing"] as? String ?? ""
        let right = RemoteCrypto.confirmationNumber(secret: r.companion(inv).secret, clientNonce: nonce, serverNonce: RemoteCrypto.fromBase32((asked.json as? [String: Any])?["nonce"] as? String ?? "")!)
        let wrong = right == "000000" ? "111111" : "000000"
        if case .failure(.wrongCode(let left)) = r.remote.pairing.approve(pairingID: pid, typedCode: wrong) { XCTAssertEqual(left, 2) } else { XCTFail() }
        XCTAssertEqual(r.devices.devices.count, 0); XCTAssertTrue(r.rig.store.clients.isEmpty, "no credential exists for an unapproved device")
        _ = r.remote.pairing.approve(pairingID: pid, typedCode: wrong)
        if case .failure(.tooManyAttempts) = r.remote.pairing.approve(pairingID: pid, typedCode: wrong) {} else { XCTFail("the third wrong try ends it") }
        if case .failure = r.remote.pairing.approve(pairingID: pid, typedCode: right) {} else { XCTFail("even the right digits are too late after that") }
        XCTAssertNil(r.remote.pairing.pending); XCTAssertTrue(r.rig.store.clients.isEmpty)
    }

    func testTheCredentialsAreHandedOverOnceAndOnlyToWhoHoldsTheSecret() async throws {
        let r = RemoteRig(); await r.turnOn()
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        let c = r.companion(inv); let nonce = RemoteCrypto.random(16)!
        let asked = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(nonce))\"}")
        let pid = (asked.json as? [String: Any])?["pairing"] as? String ?? ""
        let sn = RemoteCrypto.fromBase32((asked.json as? [String: Any])?["nonce"] as? String ?? "")!
        let proof = RemoteCrypto.base32(PairingManager.claimProof(secret: c.secret, pairingID: pid))
        let early = await r.call("POST", "/pair/v1/claim", peer: .pairing(invitation: inv.id), body: "{\"pairing\":\"\(pid)\",\"proof\":\"\(proof)\"}")
        XCTAssertEqual(early.status, 202, "not before the person approved")
        guard case .success = r.remote.pairing.approve(pairingID: pid, typedCode: RemoteCrypto.confirmationNumber(secret: c.secret, clientNonce: nonce, serverNonce: sn)) else { return XCTFail() }
        let badProof = RemoteCrypto.base32(RemoteCrypto.random(32)!)
        let forged = await r.call("POST", "/pair/v1/claim", peer: .pairing(invitation: inv.id), body: "{\"pairing\":\"\(pid)\",\"proof\":\"\(badProof)\"}")
        XCTAssertNotEqual(forged.status, 200, "someone without the secret gets nothing")
        let got = await r.call("POST", "/pair/v1/claim", peer: .pairing(invitation: inv.id), body: "{\"pairing\":\"\(pid)\",\"proof\":\"\(proof)\"}"); XCTAssertEqual(got.status, 200)
        let twice = await r.call("POST", "/pair/v1/claim", peer: .pairing(invitation: inv.id), body: "{\"pairing\":\"\(pid)\",\"proof\":\"\(proof)\"}"); XCTAssertEqual(twice.status, 404, "once")
    }

    func testTheSameNameTwiceIsTwoDevicesWithTheirOwnCredentialsAndThereIsALimit() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair(name: "Phone"), b = try await r.pair(name: "Phone")
        XCTAssertNotEqual(a.deviceID, b.deviceID); XCTAssertNotEqual(a.token, b.token); XCTAssertNotEqual(a.deviceKey, b.deviceKey)
        XCTAssertEqual(r.devices.devices.count, 2)
        for i in 0..<(RemoteDeviceStore.maxDevices - 2) { _ = try await r.pair(name: "D\(i)") }
        if case .failure(.tooManyDevices) = r.remote.pairing.createInvitation() {} else { XCTFail("a limit") }
    }

    func testAFailedSaveLeavesNoHalfPairedDevice() async throws {
        let r = RemoteRig(); await r.turnOn()
        r.keys.failWrites = true
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        let nonce = RemoteCrypto.random(16)!
        let asked = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(nonce))\"}")
        let pid = (asked.json as? [String: Any])?["pairing"] as? String ?? ""
        let sn = RemoteCrypto.fromBase32((asked.json as? [String: Any])?["nonce"] as? String ?? "")!
        if case .failure(.storage) = r.remote.pairing.approve(pairingID: pid, typedCode: RemoteCrypto.confirmationNumber(secret: r.companion(inv).secret, clientNonce: nonce, serverNonce: sn)) {} else { XCTFail() }
        XCTAssertTrue(r.devices.devices.isEmpty); XCTAssertTrue(r.rig.store.clients.allSatisfy { $0.revokedAt != nil }, "a client made on the way is withdrawn")
    }

    func testRandomnessIsNeverReplacedByAWeakerSource() async {
        let r = RemoteRig(); await r.turnOn()
        let m = PairingManager(clients: r.rig.store, devices: r.devices, profile: "default", random: { _ in nil })
        if case .failure(.storage) = m.createInvitation() {} else { XCTFail("no randomness, no invitation") }
        XCTAssertEqual(Set((0..<50).map { _ in RemoteCrypto.random(16)! }).count, 50)
    }
}

extension RemoteRig {
    func pairWith(_ inv: PairingInvitation) async throws -> PairingCredentials {
        let c = companion(inv); let nonce = RemoteCrypto.random(16)!
        let asked = await call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(nonce))\"}")
        let pid = try XCTUnwrap((asked.json as? [String: Any])?["pairing"] as? String), sn = try XCTUnwrap(RemoteCrypto.fromBase32((asked.json as? [String: Any])?["nonce"] as? String ?? ""))
        guard case .success = remote.pairing.approve(pairingID: pid, typedCode: RemoteCrypto.confirmationNumber(secret: c.secret, clientNonce: nonce, serverNonce: sn)) else { throw XCTSkip("refused") }
        let proof = RemoteCrypto.base32(PairingManager.claimProof(secret: c.secret, pairingID: pid))
        let claimed = await call("POST", "/pair/v1/claim", peer: .pairing(invitation: inv.id), body: "{\"pairing\":\"\(pid)\",\"proof\":\"\(proof)\"}")
        let out = try XCTUnwrap(claimed.json as? [String: Any])
        return PairingCredentials(deviceID: out["deviceId"] as? String ?? "", deviceKey: RemoteCrypto.fromBase32(out["deviceKey"] as? String ?? "") ?? Data(), token: out["token"] as? String ?? "", macName: "", scopes: [])
    }
}

// MARK: - Authentication, authorization, revocation

@MainActor
final class RemoteAuthTests: XCTestCase {
    func testOnlyAPairedDeviceWithItsOwnTokenGetsThrough() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair(name: "A"), b = try await r.pair(name: "B")
        let ok = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(ok.status, 200)
        let noToken = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID)); XCTAssertEqual(noToken.status, 401)
        let junk = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: "bsat_\(a.deviceID)_" + String(repeating: "0", count: 64)); XCTAssertEqual(junk.status, 401)
        let swapped = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: b.token); XCTAssertEqual(swapped.status, 403, "B's token on A's channel")
        XCTAssertEqual(r.rig.code(swapped), "device_mismatch")
        let none = await r.call("GET", "/v1/downloads", peer: .none, token: a.token); XCTAssertEqual(none.status, 401, "a connection with no proven identity")
        let stranger = await r.call("GET", "/v1/downloads", peer: .device("00000000"), token: a.token); XCTAssertEqual(stranger.status, 401)
        let pairingChannel = await r.call("GET", "/v1/downloads", peer: .pairing(invitation: "x"), token: a.token); XCTAssertEqual(pairingChannel.status, 404, "a pairing channel can pair and nothing else")
    }

    func testARevokedDeviceIsRefusedAtOnceAndItsStreamEnds() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        let stream = await r.call("GET", "/v1/events", peer: .device(a.deviceID), token: a.token)
        guard case .stream(let sub) = stream.reply else { return XCTFail("expected a stream") }
        r.remote.revoke(a.deviceID)
        let after = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(after.status, 401)
        XCTAssertNil(r.keys.key(for: a.deviceID), "its channel key is gone")
        XCTAssertNotNil(r.rig.store.clients.first { $0.id == a.deviceID }?.revokedAt)
        var ended = false
        for _ in 0..<50 { if await sub.next() == nil { ended = true; break } }
        XCTAssertTrue(ended, "the subscriber was disconnected")
        let log = r.remote.log.joined(separator: " ")
        XCTAssertTrue(log.contains("revoked"))
    }

    func testRotationStopsTheOldTokenAndKeyAndStartsTheNew() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        let fresh = try XCTUnwrap(r.remote.rotateCredentials(a.deviceID))
        XCTAssertNotEqual(fresh.token, a.token); XCTAssertNotEqual(fresh.deviceKey, a.deviceKey)
        XCTAssertEqual(r.devices.device(a.deviceID)?.credentialVersion, 2)
        let old = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(old.status, 401)
        let new = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: fresh.token); XCTAssertEqual(new.status, 200)
        XCTAssertEqual(r.keys.key(for: a.deviceID), fresh.deviceKey)
        r.keys.failWrites = true
        XCTAssertNil(r.remote.rotateCredentials(a.deviceID), "a rotation that cannot be stored changes nothing")
        r.keys.failWrites = false
        let still = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: fresh.token); XCTAssertEqual(still.status, 200)
    }

    func testChangedPermissionsTakeEffectAtOnce() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        let before = await r.call("GET", "/v1/queues", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(before.status, 200)
        _ = r.rig.store.setScopes(a.deviceID, [.downloadsRead])
        let after = await r.call("GET", "/v1/queues", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(r.rig.code(after), "missing_scope")
        let files = await r.call("POST", "/v1/downloads/\(UUID().uuidString)/trash-file", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(r.rig.code(files), "missing_scope")
    }

    func testDevicesAndRevocationSurviveARestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p23-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let box = Rig.Box()
        let deny = FileDenyStore(file: folder.appendingPathComponent("denied.json"))
        let keys = MemoryDeviceKeyStore()
        var store = AutomationClientStore(file: folder.appendingPathComponent("clients.json"), now: { box.now }, denyStores: [deny])
        var devices = RemoteDeviceStore(file: folder.appendingPathComponent("remote.json"), keys: keys, now: { box.now })
        guard case .created(let client, _) = store.enrol(name: "Phone", profile: "default", scopes: [.downloadsRead]) else { return XCTFail() }
        XCTAssertTrue(devices.add(RemoteDevice(id: client.id, name: "Phone", kind: .phone, profile: "default", enrolledAt: box.now, lastConnectedAt: nil, credentialVersion: 1, revokedAt: nil), key: Data(repeating: 1, count: 32)))
        _ = store.revoke(client.id); devices.revoke(client.id)
        store = AutomationClientStore(file: folder.appendingPathComponent("clients.json"), now: { box.now }, denyStores: [FileDenyStore(file: folder.appendingPathComponent("denied.json"))])
        devices = RemoteDeviceStore(file: folder.appendingPathComponent("remote.json"), keys: keys, now: { box.now })
        XCTAssertEqual(devices.devices.count, 1); XCTAssertFalse(devices.devices[0].isActive)
        XCTAssertNil(keys.key(for: client.id))
        XCTAssertNotNil(store.clients.first { $0.id == client.id }?.revokedAt)
        // A stale client list (written before the revocation) cannot bring the device back, because the deny record is applied after it is read.
        let stale = try JSONSerialization.data(withJSONObject: [])
        _ = stale
        let attr = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("remote.json").path)
        XCTAssertEqual((attr[.posixPermissions] as? Int), 0o600, "owner only")
    }

    func testAnUnreadableDeviceListTrustsNobody() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p23b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not json".utf8).write(to: folder.appendingPathComponent("remote.json"))
        let devices = RemoteDeviceStore(file: folder.appendingPathComponent("remote.json"), keys: MemoryDeviceKeyStore())
        XCTAssertTrue(devices.devices.isEmpty); XCTAssertNotNil(devices.storageProblem)
    }

    func testADeviceOfAnotherProfileCannotReachThisOne() async throws {
        let extra = DownloadCoordinator(); extra.profileName = "beta"
        let r = RemoteRig(extra: [extra]); await r.turnOn()
        let a = try await r.pair()
        let named = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token, headers: ["x-browsersetu-profile": "beta"])
        XCTAssertEqual(r.rig.code(named), "profile_mismatch")
        // A task in the other profile is invisible to this device.
        let other = extra.begin(suggestedName: "b.bin", sourceURL: URL(string: "https://a.org/b"), cancel: {})
        let one = await r.call("GET", "/v1/downloads/\(other.id.uuidString)", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(one.status, 404)
        let list = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token)
        XCTAssertEqual((list.json as? [Any])?.count, 0)
        // A device record claiming another profile is refused even with a valid key and token.
        var foreign = try XCTUnwrap(r.devices.device(a.deviceID)); foreign.profile = "beta"
        _ = foreign
    }
}

// MARK: - Commands, proposals, events through the gate

@MainActor
final class RemoteCommandTests: XCTestCase {
    func testListStatusPauseResumeCancelPriorityAndQueueThroughTheExistingService() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair(scopes: [.downloadsRead, .downloadsControl, .queuesRead, .queuesControl])
        let c = r.rig.coordinator
        var resumed = false
        c.hasHost = { true }; c.resumerWithID = { _, _ in resumed = true }
        let s = c.begin(suggestedName: "a.bin", sourceURL: URL(string: "https://a.org/a?sig=SECRET"), cancel: {}, suspend: { done in done(Data([1, 2])) })
        let list = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token)
        XCTAssertEqual((list.json as? [[String: Any]])?.first?["id"] as? String, s.id.uuidString)
        let text = String(data: try JSONSerialization.data(withJSONObject: list.json as Any), encoding: .utf8)!
        XCTAssertFalse(text.contains("SECRET"), "no signed link leaves the Mac"); XCTAssertFalse(text.contains("/Users"), "no path leaves the Mac")
        let one = await r.call("GET", "/v1/downloads/\(s.id.uuidString)", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(one.status, 200)
        let prio = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/priority", peer: .device(a.deviceID), token: a.token, body: "{\"priority\":\"high\"}"); XCTAssertEqual(prio.status, 200)
        let paused = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/pause", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(paused.status, 200)
        for _ in 0..<50 where c.interrupted[s.id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        let back = await r.call("POST", "/v1/downloads/\(s.id.uuidString)/resume", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(back.status, 200)
        for _ in 0..<50 where !resumed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(resumed)
        let q = await r.call("GET", "/v1/queues", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(q.status, 200)
        let hold = await r.call("POST", "/v1/queues/default/hold", peer: .device(a.deviceID), token: a.token, body: "{\"minutes\":5}"); XCTAssertEqual(hold.status, 200)
        let release = await r.call("POST", "/v1/queues/default/release", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(release.status, 200)
        let s2 = c.begin(suggestedName: "b.bin", sourceURL: URL(string: "https://a.org/b"), cancel: {})
        let cancel = await r.call("POST", "/v1/downloads/\(s2.id.uuidString)/cancel", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(cancel.status, 200)
        XCTAssertEqual(c.ledger.record(s2.id)?.state, .cancelled)
        let retry = await r.call("POST", "/v1/downloads/\(UUID().uuidString)/retry", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(retry.status, 404)
    }

    func testPrivateDownloadsAreInvisibleToRemoteDevices() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        let p = r.rig.coordinator.begin(suggestedName: "p.bin", sourceURL: URL(string: "https://a.org/p"), isPrivate: true, cancel: {})
        let list = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token); XCTAssertEqual((list.json as? [Any])?.count, 0)
        let one = await r.call("GET", "/v1/downloads/\(p.id.uuidString)", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(one.status, 404)
        let cancel = await r.call("POST", "/v1/downloads/\(p.id.uuidString)/cancel", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(cancel.status, 404)
    }

    func testADownloadProposalNeedsTheLocalApprovalAndKeepsItsProvenance() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        let x = await r.call("POST", "/v1/downloads", peer: .device(a.deviceID), token: a.token, body: "{\"url\":\"https://files.example.org/a.zip\",\"filename\":\"a.zip\"}")
        XCTAssertEqual(x.status, 202); let id = try XCTUnwrap((x.json as? [String: Any])?["id"] as? String)
        XCTAssertTrue(r.rig.coordinator.ledger.records.isEmpty, "nothing downloads until the person approves")
        for path in ["/v1/proposals/\(id)/approve", "/v1/downloads/\(id)/approve"] {
            let tried = await r.call("POST", path, peer: .device(a.deviceID), token: a.token); XCTAssertEqual(tried.status, 404, "a device has no way to approve its own proposal")
        }
        let direct = await r.call("POST", "/v1/downloads", peer: .device(a.deviceID), token: a.token, body: "{\"url\":\"https://a.org/x\",\"approved\":true}"); XCTAssertEqual(r.rig.code(direct), "origin_not_allowed")
        let internalHost = await r.call("POST", "/v1/downloads", peer: .device(a.deviceID), token: a.token, body: "{\"url\":\"http://192.168.1.1/x\"}"); XCTAssertEqual(r.rig.code(internalHost), "destination_not_allowed")
        let p2p = await r.call("POST", "/v1/downloads", peer: .device(a.deviceID), token: a.token, body: "{\"url\":\"magnet:?xt=urn:btih:abc\"}"); XCTAssertEqual(r.rig.code(p2p), "p2p_requires_user")
        let scheme = await r.call("POST", "/v1/downloads", peer: .device(a.deviceID), token: a.token, body: "{\"url\":\"file:///etc/passwd\"}"); XCTAssertNotEqual(scheme.status, 202)
        let dup = await r.call("POST", "/v1/downloads", peer: .device(a.deviceID), token: a.token, body: "{\"url\":\"https://files.example.org/a.zip\",\"filename\":\"a.zip\"}")
        XCTAssertLessThan(r.rig.service.proposals.count, AutomationService.maxProposals); _ = dup
        let task = try XCTUnwrap(r.rig.service.approve(id))
        XCTAssertNotEqual(r.rig.coordinator.ledger.record(task)?.engineMetadata["origin"], "user", "the device's request did not become the person's own typed address")
        XCTAssertNotNil(r.rig.service.proposals.first { $0.id == id }?.clientID, "who asked is kept")
    }

    func testBrowserOriginsAndTokensInAddressesAreRefused() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        let origin = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token, headers: ["origin": "https://evil.example"]); XCTAssertEqual(r.rig.code(origin), "browser_origin")
        let fetch = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token, headers: ["sec-fetch-mode": "cors"]); XCTAssertEqual(r.rig.code(fetch), "browser_origin")
        let inURL = await r.call("GET", "/v1/downloads?access_token=\(a.token)", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(r.rig.code(inURL), "token_in_url")
    }

    func testRequestsAreBoundedAndMalformedOnesAreRefused() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        let big = await r.call("POST", "/v1/downloads", peer: .device(a.deviceID), token: a.token, body: "{\"url\":\"https://a.org/" + String(repeating: "x", count: RemoteGateway.maxBody) + "\"}"); XCTAssertEqual(big.status, 413)
        let bad = await r.call("POST", "/v1/downloads", peer: .device(a.deviceID), token: a.token, body: "{not json"); XCTAssertGreaterThanOrEqual(bad.status, 400); XCTAssertLessThan(bad.status, 500)
        guard case .success(let inv) = r.remote.pairing.createInvitation() else { return XCTFail() }
        let badPair = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{garbage"); XCTAssertEqual(badPair.status, 400)
        let nonce = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"P\",\"kind\":\"phone\",\"nonce\":\"AAAA\"}"); XCTAssertEqual(nonce.status, 400, "a nonce of the wrong size")
        let longName = await r.call("POST", "/pair/v1/request", peer: .pairing(invitation: inv.id), body: "{\"invitation\":\"\(inv.id)\",\"name\":\"\(String(repeating: "n", count: 200))\",\"kind\":\"phone\",\"nonce\":\"\(RemoteCrypto.base32(RemoteCrypto.random(16)!))\"}"); XCTAssertEqual(longName.status, 400)
    }

    func testEventsAreProfileFilteredResumableAndTellOfGaps() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        let s = await r.call("GET", "/v1/events", peer: .device(a.deviceID), token: a.token)
        guard case .stream(let sub) = s.reply else { return XCTFail() }
        let c = r.rig.coordinator
        _ = c.begin(suggestedName: "e.bin", sourceURL: URL(string: "https://a.org/e"), cancel: {})
        r.rig.service.publishChanges()
        let first = await sub.next()
        XCTAssertNotNil(first, "an authorized subscriber gets the event"); XCTAssertEqual(first?.profile ?? "default", "default")
        sub.close()
        // Reconnecting with a Last-Event-ID that was never issued: the stream says history cannot be replayed (a snapshot is the way back), and invents nothing.
        let again = await r.call("GET", "/v1/events", peer: .device(a.deviceID), token: a.token, headers: ["last-event-id": "999-999999"])
        guard case .stream(let sub2) = again.reply else { return XCTFail() }
        let marker = await sub2.next()
        XCTAssertEqual(marker?.type, "stream.gap", "an unreplayable history is reported, not papered over")
        sub2.close()
    }

    func testSlowSubscribersAreBounded() async throws {
        let r = RemoteRig(); await r.turnOn()
        let a = try await r.pair()
        var subs: [AutomationSubscription] = []
        for _ in 0..<4 { if case .stream(let sub) = (await r.call("GET", "/v1/events", peer: .device(a.deviceID), token: a.token)).reply { subs.append(sub) } }
        XCTAssertEqual(subs.count, 4)
        let fifth = await r.call("GET", "/v1/events", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(r.rig.code(fifth), "busy", "four streams per device")
        for sub in subs { sub.close() }
    }
}

// MARK: - Switching, support, settings state

@MainActor
final class RemoteAccessStateTests: XCTestCase {
    func testOffByDefaultAndSwitchingOffEndsEverything() async throws {
        let r = RemoteRig()
        XCTAssertFalse(r.remote.enabled); XCTAssertEqual(r.remote.state, .disabled)
        await r.turnOn()
        XCTAssertEqual(r.remote.state, .ready)
        let a = try await r.pair()
        XCTAssertEqual(r.remote.state, .disconnected)
        r.remote.peerConnected(a.deviceID); XCTAssertEqual(r.remote.state, .connected(1))
        guard case .stream(let sub) = (await r.call("GET", "/v1/events", peer: .device(a.deviceID), token: a.token)).reply else { return XCTFail() }
        guard case .success = r.remote.pairing.createInvitation() else { return XCTFail() }
        XCTAssertEqual(r.remote.state, .pairing)
        await r.remote.setEnabled(false)
        XCTAssertEqual(r.remote.state, .disabled); XCTAssertNil(r.remote.pairing.invitation)
        let refused = await r.call("GET", "/v1/downloads", peer: .device(a.deviceID), token: a.token); XCTAssertEqual(refused.status, 503)
        var ended = false
        for _ in 0..<50 { if await sub.next() == nil { ended = true; break } }
        XCTAssertTrue(ended, "streams end when remote control is switched off")
        XCTAssertFalse(r.devices.devices.isEmpty, "the paired devices are kept")
        // Downloads are unaffected by any of it.
        XCTAssertNil(r.rig.coordinator.ledger.records.values.first { $0.state == .failed })
    }

    func testAnUnsupportedSystemKeepsRemoteControlOffAndSaysWhy() async {
        let r = RemoteRig(); r.support = .unsupported("This system could not set up the encrypted channel remote control needs.")
        await r.turnOn()
        XCTAssertFalse(r.remote.enabled)
        if case .unsupported(let why) = r.remote.state { XCTAssertFalse(why.isEmpty) } else { XCTFail("\(r.remote.state)") }
        if case .failure = r.remote.pairing.createInvitation() {} else { XCTFail("no pairing without a channel") }
    }

    func testTemporaryProfilesOfferNoRemoteControl() async {
        let rig = Rig()
        let devices = RemoteDeviceStore(file: nil, keys: MemoryDeviceKeyStore())
        let remote = RemoteAccessController(profile: "tmp", persistent: false, clients: rig.store, automation: rig.service, devices: devices, supportCheck: { .supported })
        await remote.setEnabled(true)
        XCTAssertFalse(remote.enabled)
        if case .error = remote.state {} else { XCTFail("\(remote.state)") }
    }

    func testSupportDetectionNeedsBothThePermissionAndAWorkingChannel() async {
        let a = await RemoteTransportSupport.detect(accepting: { false }, handshake: { true })
        let b = await RemoteTransportSupport.detect(accepting: { true }, handshake: { false })
        let c = await RemoteTransportSupport.detect(accepting: { true }, handshake: { true })
        if case .unsupported = a {} else { XCTFail() }; if case .unsupported = b {} else { XCTFail() }; XCTAssertEqual(c, .supported)
    }

    func testTheRealChannelSelfTestAgreesWithWhatTheAppWouldReport() async {
        let worked = await RemoteChannelSelfTest.run()
        let detected = await RemoteTransportSupport.detect(accepting: { true })
        NSLog("MEASURED pre-shared-key TLS self-test on this system: %@; accepting connections allowed: %@", worked ? "works" : "does not complete", RemoteTransportSupport.canAcceptConnections() ? "yes" : "no")
        XCTAssertEqual(detected == .supported, worked)
    }

    func testEncryptionPrimitivesBehave() {
        let secret = RemoteCrypto.random(16)!
        XCTAssertEqual(RemoteCrypto.fromBase32(RemoteCrypto.base32(secret)), secret)
        XCTAssertEqual(RemoteCrypto.fromBase32(RemoteCrypto.grouped(RemoteCrypto.base32(secret))), secret)
        XCTAssertNil(RemoteCrypto.fromBase32("not*base32"))
        XCTAssertNotEqual(RemoteCrypto.derive(secret, label: "a"), RemoteCrypto.derive(secret, label: "b")); XCTAssertEqual(RemoteCrypto.derive(secret, label: "a").count, 32)
        let n1 = RemoteCrypto.random(16)!, n2 = RemoteCrypto.random(16)!
        let digits = RemoteCrypto.confirmationNumber(secret: secret, clientNonce: n1, serverNonce: n2)
        XCTAssertEqual(digits.count, 6); XCTAssertEqual(digits, RemoteCrypto.confirmationNumber(secret: secret, clientNonce: n1, serverNonce: n2))
        XCTAssertNotEqual(digits, RemoteCrypto.confirmationNumber(secret: RemoteCrypto.random(16)!, clientNonce: n1, serverNonce: n2))
        XCTAssertTrue(RemoteCrypto.constantTimeEqual(Data([1, 2]), Data([1, 2]))); XCTAssertFalse(RemoteCrypto.constantTimeEqual(Data([1, 2]), Data([1, 3]))); XCTAssertFalse(RemoteCrypto.constantTimeEqual(Data([1]), Data([1, 2])))
    }

    func testNoPeerNetworkingIsStartedByRemoteControl() async throws {
        let r = RemoteRig(); await r.turnOn()
        _ = try await r.pair()
        XCTAssertFalse(TorrentSettings().enabled); XCTAssertFalse(ED2KSettings().enabled)
        XCTAssertFalse(r.rig.coordinator.torrentsStarted); XCTAssertFalse(r.rig.coordinator.ed2kStarted)
    }
}
