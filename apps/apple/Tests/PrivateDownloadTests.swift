import XCTest
import WebKit
@testable import Browser_Setu

// A private download belongs to the private session it came from: only that session's window lists it, it is never written down, and it stops with its window.

final class PrivateDownloadVisibilityTests: XCTestCase {
    func testWhoMaySeeATask() {
        let windowA = UUID(), windowB = UUID(), owners: Set<UUID> = [windowA, windowB]
        let shared = DownloadStoreKey.sharedPrivateSession
        func v(_ priv: Bool, _ session: UUID?, viewer: UUID?) -> Bool { PrivateDownloadVisibility.isVisible(isPrivate: priv, session: session, viewer: viewer, privateWindowSessions: owners) }
        XCTAssertTrue(v(false, nil, viewer: nil)); XCTAssertTrue(v(false, nil, viewer: windowA), "an ordinary download is listed everywhere")
        XCTAssertTrue(v(true, windowA, viewer: windowA), "a private window lists its own")
        XCTAssertFalse(v(true, windowA, viewer: windowB), "another private window does not")
        XCTAssertFalse(v(true, windowA, viewer: nil), "an ordinary window does not")
        XCTAssertTrue(v(true, shared, viewer: nil), "private tabs of ordinary windows are listed in ordinary windows")
        XCTAssertFalse(v(true, shared, viewer: windowA), "…and not in a private window")
        XCTAssertFalse(v(true, windowA, viewer: nil), "still hidden after window A closed: the id stays known for the run")
    }
}

@MainActor
final class PrivateDownloadOwnershipTests: XCTestCase {
    private func coordinator() -> DownloadCoordinator {
        let c = DownloadCoordinator(); c.profileName = "default"; c.hasHost = { false }
        return c
    }

    func testAStoreOfAPrivateWindowCarriesThatWindowsSessionAndTheSharedStoreItsOwn() {
        let engine = WebKitEngine()
        let window = UUID()
        let own = WKWebView(frame: .zero, configuration: engine.makeConfiguration(isPrivate: true, profile: "default", privateSession: window))
        let shared = WKWebView(frame: .zero, configuration: engine.makeConfiguration(isPrivate: true, profile: "default"))
        let normal = WKWebView(frame: .zero, configuration: engine.makeConfiguration(isPrivate: false, profile: "default"))
        let ownKey = WebKitDownloads.storeKey(of: own), sharedKey = WebKitDownloads.storeKey(of: shared), normalKey = WebKitDownloads.storeKey(of: normal)
        XCTAssertEqual(ownKey.session, window, "the window's own id is its session"); XCTAssertFalse(ownKey.isPersistent)
        XCTAssertEqual(sharedKey.session, DownloadStoreKey.sharedPrivateSession)
        XCTAssertTrue(normalKey.isPersistent); XCTAssertNil(normalKey.persistedValue == nil ? normalKey.session : nil)
        XCTAssertNil(ownKey.persistedValue, "nothing about a private session is kept with a task")
    }

    func testTheOwnerIsStampedOnThePrivateRecordAndKeptOutOfPersistence() {
        let c = coordinator()
        let id = c.ledger.create(protocolID: .webKit, source: URL(string: "https://example.test/f.bin"), filename: "f.bin", isPrivate: true).id
        let window = UUID()
        WebKitDownloads(coordinator: c).remember(id, DownloadStoreKey(identifier: nil, isPersistent: false, session: window))
        XCTAssertEqual(c.ledger.record(id)?.privateSession, window)
        XCTAssertNil(c.ledger.record(id)?.engineMetadata[DownloadStoreKey.metadataKey], "no session name is kept in the task's saved details")
    }

    func testListsAreFilteredWhereTheyAreMadeAndAClosedWindowsDownloadsStop() {
        let c = coordinator()
        let a = UUID(), b = UUID()
        func make(_ name: String, private priv: Bool, session: UUID?) -> UUID {
            let id = c.ledger.create(protocolID: .webKit, source: URL(string: "https://example.test/\(name)"), filename: name, isPrivate: priv).id
            c.ledger.update(id) { $0.privateSession = session }
            for e in [DownloadEvent.queued, .started, .running] { _ = c.ledger.apply(e, to: id) }
            return id
        }
        let ordinary = make("ordinary.bin", private: false, session: nil), inA = make("a.bin", private: true, session: a), inB = make("b.bin", private: true, session: b)
        let shared = make("shared.bin", private: true, session: DownloadStoreKey.sharedPrivateSession)
        PrivateWindowSessions.known.formUnion([a, b])
        defer { PrivateWindowSessions.known.subtract([a, b]) }
        func listed(viewer: UUID?) -> Set<String> {
            let vm = DownloadsViewModel(coordinator: c, defaults: nil)
            vm.viewerPrivateSession = { viewer }
            vm.refreshNow()
            return Set(vm.rows.map(\.filename))
        }
        XCTAssertEqual(listed(viewer: a), ["ordinary.bin", "a.bin"])
        XCTAssertEqual(listed(viewer: b), ["ordinary.bin", "b.bin"])
        XCTAssertEqual(listed(viewer: nil), ["ordinary.bin", "shared.bin"])

        c.cancelPrivateSession(a)
        XCTAssertEqual(c.ledger.record(inA)?.state, .cancelled, "window A's download stopped with its window")
        XCTAssertEqual(c.ledger.record(inB)?.state, .running); XCTAssertEqual(c.ledger.record(ordinary)?.state, .running); XCTAssertEqual(c.ledger.record(shared)?.state, .running)
        for id in [inB, ordinary, shared] { c.cancel(id) }
    }
}
