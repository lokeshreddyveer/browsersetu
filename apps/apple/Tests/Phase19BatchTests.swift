import XCTest
@testable import Browser_Setu

// Phase 19: provenance correction, packages, batch creation, and the Website Explorer. Pages and files are original, served by the local fixture server (port 18766).

// MARK: - The Phase 18 provenance correction

@MainActor
final class ProvenanceTests: MediaCase {
    func testAnAddressFromAPageNeverGainsTheReachOfOneThePersonTyped() {
        let policyUser = HTTPRequestPolicy(origin: .user), policyPage = HTTPRequestPolicy(origin: .page)
        XCTAssertTrue(policyUser.allowsInternalHosts); XCTAssertFalse(policyPage.allowsInternalHosts)
        XCTAssertNoThrow(try policyUser.check(URL(string: "http://192.168.1.2/a.zip")!))
        XCTAssertThrowsError(try policyPage.check(URL(string: "http://192.168.1.2/a.zip")!))
        XCTAssertThrowsError(try policyPage.check(URL(string: "http://localhost/a.zip")!))
        XCTAssertNoThrow(try policyPage.requireAllowedOrigin(), "approved by the person, so it may start")
        XCTAssertEqual(policyPage.decideRedirect(from: URL(string: "https://cdn.example.com/a")!, to: URL(string: "http://127.0.0.1/x")!, chain: []), .refuse(.insecureRedirect))
        XCTAssertEqual(policyPage.decideRedirect(from: URL(string: "http://127.0.0.1/a")!, to: URL(string: "http://127.0.0.2/b")!, chain: [URL(string: "http://127.0.0.1/a")!]), .refuse(.redirectIntoInternalNetwork("127.0.0.2")), "even from inside")
    }

    func testTheOriginIsRecordedWithTheTaskAndCannotBeForgedUpward() throws {
        let page = try XCTUnwrap(c.scheduleDownload(url: URL(string: "https://cdn.example.com/a.zip")!, at: Date().addingTimeInterval(3600), origin: .page))
        let typed = try XCTUnwrap(c.scheduleDownload(url: URL(string: "https://cdn.example.com/b.zip")!, at: Date().addingTimeInterval(3600)))
        let forged = try XCTUnwrap(c.scheduleDownload(url: URL(string: "https://cdn.example.com/c.zip")!, at: Date().addingTimeInterval(3600), origin: .automation))
        XCTAssertEqual(c.ledger.record(page)?.engineMetadata["origin"], "page")
        XCTAssertEqual(c.ledger.record(typed)?.engineMetadata["origin"], "user")
        XCTAssertEqual(c.ledger.record(forged)?.engineMetadata["origin"], "page", "anything that is not the person's own typing is held to the page rules")
    }

    func testAPageDerivedDownloadOfTheLocalNetworkIsRefusedThroughEveryEntryPoint() async throws {
        // A typed address on this Mac works (that is the person's own act).
        try await put("prov/file.bin", Data(repeating: 1, count: 100))
        let address = url("/media/prov/file.bin")
        // The same address, page-derived, through the scheduled path:
        let id = try XCTUnwrap(c.scheduleDownload(url: address, at: Date(), origin: .page))
        let record = await wait(id, for: [.failed, .completed, .cancelled], seconds: 20)
        XCTAssertEqual(record?.state, .failed, "refused: a page cannot point a download at this Mac")
        let _h = await hits()
        XCTAssertNil(_h["prov/file.bin"], "and nothing was requested")
        // Through the engine's own start:
        var options = HTTPDownloadRunner.Options(); options.origin = .page
        do { _ = try await c.http.start(url: address, options: options); XCTFail("started") } catch {}
        // Through the media inspection and fetcher:
        do { _ = try await c.media.inspect(address, origin: .page); XCTFail("read") } catch {}
        // Through the LinkGrabber: refused by routing before it gets that far.
        let links = LinkGrabberStore(profile: "default", isPrivate: false)
        links.add(candidates: [address.absoluteString], provenance: .page)
        if case .refused = LinkRouter.route(links.items[0]) {} else { XCTFail("routed") }
    }

    func testATypedAddressStillWorksAndChangingAPrefilledOneMakesItTheirOwn() async throws {
        try await put("prov/typed.bin", Data(repeating: 2, count: 100))
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/prov/typed.bin"), at: Date()))
        let record = await wait(id, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
    }

    func testTheRestartKeepsThePageOrigin() throws {
        let id = try XCTUnwrap(c.scheduleDownload(url: URL(string: "https://cdn.example.com/a.zip")!, at: Date().addingTimeInterval(3600), origin: .page))
        let restored = DownloadRequestOrigin(rawValue: c.ledger.record(id)?.engineMetadata["origin"] ?? "")
        XCTAssertEqual(restored, .page, "a restart reads it back as it was and does not promote it")
        XCTAssertEqual(DownloadRequestOrigin(rawValue: ""), nil)
    }

    func testMediaPreviewedFromADiscoveryUsesThePageOriginForEveryFetch() async throws {
        let master = try await publishHLS("provm")
        let model = MediaAddModel(coordinator: c, url: master, name: "x", origin: .page)
        model.load()
        for _ in 0..<100 where model.phase == .loading { try await Task.sleep(for: .milliseconds(20)) }
        if case .failed = model.phase {} else { XCTFail("the local playlist was read for a page-derived preview: \(model.phase)") }
        let _h = await hits()
        XCTAssertNil(_h["provm/master.m3u8"])
    }
}

// MARK: - Packages

@MainActor
final class PackageTests: MediaCase {
    private func task(_ n: Int, state: DownloadState? = nil, total: Int64? = nil, done: Int64 = 0) -> UUID {
        let r = c.ledger.create(protocolID: .http, source: URL(string: "https://cdn.example.com/f\(n).bin"), filename: "f\(n).bin", isPrivate: false)
        c.ledger.apply(.queued, to: r.id)
        if let total { c.ledger.update(r.id) { $0.transfer.totalBytes = total; $0.transfer.completedBytes = done } }
        if let state, state != .queued {
            switch state {
            case .running: c.ledger.apply(.started, to: r.id); c.ledger.apply(.running, to: r.id)
            case .completed: c.ledger.apply(.started, to: r.id); c.ledger.apply(.running, to: r.id); c.ledger.apply(.verifying, to: r.id); c.ledger.apply(.completed(.verified), to: r.id)
            case .failed: c.ledger.apply(.started, to: r.id); c.ledger.apply(.running, to: r.id); c.ledger.apply(.failed(DownloadFailureInfo(code: "x", reason: "no", retryable: true)), to: r.id)
            case .cancelled: c.ledger.apply(.cancelled, to: r.id)
            default: break
            }
        }
        return r.id
    }

    func testCreateRenameMembershipAndTheGroupingIsNotTheDownloads() throws {
        let a = task(1), b = task(2), d = task(3)
        let (p, report) = try XCTUnwrap(c.packages.create(name: "  My  \u{7}Set ", members: [a, b]))
        XCTAssertEqual(p.name, "My  Set"); XCTAssertEqual(report.added, 2)
        c.packages.rename(p.id, to: String(repeating: "x", count: 300)); XCTAssertEqual(c.packages.package(p.id)?.name.count, PackageStore.maxNameLength)
        c.packages.add([b, d], to: p.id)
        XCTAssertEqual(c.packages.package(p.id)?.members, [a, b, d], "order is the order added; no duplicate")
        c.packages.remove([b], from: p.id)
        XCTAssertNotNil(c.ledger.record(b), "removing from the grouping does not touch the download")
        c.packages.deletePackage(p.id)
        XCTAssertTrue(c.packages.packages.isEmpty); XCTAssertNotNil(c.ledger.record(a)); XCTAssertEqual(c.ledger.record(a)?.state, .queued)
    }

    func testATaskIsInOnePackageMergeAndSplit() throws {
        let ids = (1...4).map { task($0) }
        let p1 = try XCTUnwrap(c.packages.create(name: "One", members: Array(ids[0...1]))?.package)
        let p2 = try XCTUnwrap(c.packages.create(name: "Two", members: Array(ids[2...3]))?.package)
        c.packages.move([ids[0]], to: p2.id)
        XCTAssertEqual(c.packages.package(p1.id)?.members, [ids[1]]); XCTAssertEqual(c.packages.package(p2.id)?.members, [ids[2], ids[3], ids[0]])
        c.packages.merge(p1.id, into: p2.id)
        XCTAssertNil(c.packages.package(p1.id)); XCTAssertEqual(c.packages.package(p2.id)?.members.count, 4)
        let split = try XCTUnwrap(c.packages.split([ids[0], ids[1]], from: p2.id, name: "Half"))
        XCTAssertEqual(Set(split.members), [ids[0], ids[1]]); XCTAssertEqual(c.packages.package(p2.id)?.members.count, 2)
        for t in ids { XCTAssertEqual(c.packages.packages.filter { $0.members.contains(t) }.count, 1) }
    }

    func testOnlyThisProfilesOrdinaryTasksCanBeHeld() throws {
        let mine = task(1)
        let priv = c.ledger.create(protocolID: .http, source: URL(string: "https://x.example.com/p.bin"), filename: "p.bin", isPrivate: true).id
        let other = c.ledger.create(protocolID: .http, source: URL(string: "https://x.example.com/o.bin"), filename: "o.bin", isPrivate: false).id
        c.ledger.update(other) { $0.profile = "someone-else" }
        let (p, r) = try XCTUnwrap(c.packages.create(name: "P", members: [mine, priv, other, UUID()]))
        XCTAssertEqual(r.added, 1); XCTAssertEqual(r.rejected, 3)
        XCTAssertEqual(c.packages.package(p.id)?.members, [mine])
    }

    func testProgressIsDerivedAndHonestAboutUnknownSizes() throws {
        let done = task(1, state: .completed, total: 100, done: 100)
        let half = task(2, state: .running, total: 100, done: 50)
        let p = try XCTUnwrap(c.packages.create(name: "P", members: [done, half])?.package)
        var r = c.packages.progress(p)
        XCTAssertEqual(r.total, 2); XCTAssertEqual(r.completed, 1); XCTAssertEqual(r.active, 1); XCTAssertEqual(r.status, .active)
        XCTAssertEqual(r.fraction ?? 0, 0.75, accuracy: 0.001)
        let unknown = task(3, state: .running)
        c.packages.add([unknown], to: p.id)
        r = c.packages.progress(try XCTUnwrap(c.packages.package(p.id)))
        XCTAssertNil(r.fraction, "a member of unknown size means no percentage")
        XCTAssertEqual(r.total, 3)
    }

    func testStatusNeverSaysCompletedForPausedCancelledOrFailedMembers() throws {
        func status(_ states: [DownloadState]) -> PackageStatus {
            let ids = states.enumerated().map { task($0.offset + 100, state: $0.element) }
            let p = c.packages.create(name: "S", members: ids)!.package
            defer { c.packages.deletePackage(p.id) }
            return c.packages.progress(c.packages.package(p.id)!).status
        }
        XCTAssertEqual(status([.completed, .completed]), .completed)
        XCTAssertEqual(status([.completed, .cancelled]), .incomplete)
        XCTAssertEqual(status([.completed, .failed]), .needsAttention)
        XCTAssertEqual(status([.completed, .queued]), .waiting)
        XCTAssertEqual(status([.completed, .running]), .active)
        XCTAssertEqual(c.packages.create(name: "E", members: [])!.package.members.count, 0)
        XCTAssertEqual(PackageStore.status(of: PackageProgress()), .empty)
    }

    func testCompletionIsAnnouncedOnceAndOnlyWhenEverythingFinished() async throws {
        var events: [String] = []
        c.packages.onEvent = { type, _, _ in events.append(type) }
        let a = task(1, state: .running), b = task(2, state: .running)
        let p = try XCTUnwrap(c.packages.create(name: "Ev", members: [a, b])?.package)
        c.ledger.apply(.verifying, to: a); c.ledger.apply(.completed(.verified), to: a)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(events.isEmpty, "one finished, one still going")
        c.ledger.apply(.cancelled, to: b)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(events.isEmpty, "a cancelled member is not a finished package")
        c.packages.remove([b], from: p.id)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(events, ["package.completed"])
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(events, ["package.completed"], "once")
    }

    func testPackageEventsGoThroughTheSameFeedAsTaskEvents() throws {
        let feed = DownloadEventFeed(coordinators: { [c] in [c!] })
        var seen: [AutomationEvent] = []
        feed.observe { e, _ in seen.append(e) }
        let id = UUID()
        feed.publishPackage(type: "package.completed", packageID: id, profile: "default", fraction: 1)
        XCTAssertEqual(seen.first?.type, "package.completed"); XCTAssertEqual(seen.first?.taskID, id.uuidString)
        XCTAssertFalse((seen.first?.epoch ?? "").isEmpty)
    }

    func testRelaunchRestoresPackagesAndDropsMissingTasks() throws {
        let a = task(1), b = task(2)
        let p = try XCTUnwrap(c.packages.create(name: "Keep", members: [a, b], folder: "Set/One")?.package)
        c.ledger.remove(b)
        c.ledger.flush(); DownloadTaskStore.close(folder: folder)
        c = makeCoordinator()
        let again = try XCTUnwrap(c.packages.package(p.id))
        XCTAssertEqual(again.name, "Keep"); XCTAssertEqual(again.folder, "Set/One")
        XCTAssertEqual(again.members, [a], "the removed task is no longer a member")
    }

    func testActionsReportPartialSuccessAndUseTheCoordinatorsOwnRules() throws {
        let running = task(1, state: .running), waiting = task(2), failed = task(3, state: .failed), done = task(4, state: .completed)
        let p = try XCTUnwrap(c.packages.create(name: "Act", members: [running, waiting, failed, done])?.package)
        let pause = c.packages.pause(p.id)
        XCTAssertEqual(pause.succeeded.count + pause.skipped.count, 4, "every member is accounted for")
        XCTAssertTrue(pause.skipped.contains { $0.id == done }, "a finished download is left as it was")
        let cancel = c.packages.cancel([done, waiting], in: p.id)
        XCTAssertEqual(cancel.succeeded, [waiting]); XCTAssertEqual(cancel.skipped.map(\.id), [done])
        XCTAssertEqual(c.ledger.record(done)?.state, .completed)
        XCTAssertEqual(c.packages.clearCompleted(p.id), 1)
        XCTAssertNotNil(c.ledger.record(done), "clearing removes it from the package only")
        XCTAssertFalse(c.packages.package(p.id)!.members.contains(done))
    }

    func testPackagesAreBounded() {
        for i in 0..<PackageStore.maxPackages { XCTAssertNotNil(c.packages.create(name: "P\(i)")) }
        XCTAssertNil(c.packages.create(name: "one too many"))
    }
}

// MARK: - Batch creation

@MainActor
final class BatchTests: MediaCase {
    private func links(_ texts: [String], provenance: LinkProvenance = .pasted) -> LinkGrabberStore {
        let s = LinkGrabberStore(profile: "default", isPrivate: false)
        s.add(candidates: texts, provenance: provenance)
        s.selection = Set(s.items.map(\.id))
        return s
    }

    func testABatchMakesOrdinaryScheduledTasksInOnePackageWithTheirFolders() async throws {
        let s = links(["https://cdn.example.com/a/one.zip", "https://cdn.example.com/b/two.pdf", "https://other.example.org/c/three.mp4"], provenance: .page)
        var request = BatchRequest(name: "Set"); request.folderTemplate = "{package}/{host}"
        let r = await BatchSubmitter.submit(request, links: s.selectedItems, isPrivate: false, coordinator: c)
        XCTAssertEqual(r.started, 3)
        let p = try XCTUnwrap(c.packages.package(r.packages[0]))
        XCTAssertEqual(p.members.count, 3)
        let folders = p.members.compactMap { c.ledger.record($0)?.engineMetadata["packageFolder"] }
        XCTAssertEqual(Set(folders), ["Set/cdn.example.com", "Set/other.example.org"])
        for m in p.members {
            XCTAssertEqual(c.ledger.record(m)?.engineMetadata["origin"], "page", "page-derived links keep their provenance")
            XCTAssertEqual(c.ledger.record(m)?.protocolID, .http); XCTAssertEqual(c.ledger.record(m)?.engineMetadata["package"], p.id.uuidString)
        }
    }

    func testAskingAgainWithTheSameBatchMakesNothingNew() async throws {
        let s = links(["https://cdn.example.com/a.zip", "https://cdn.example.com/b.zip"])
        let request = BatchRequest(name: "Twice")
        let first = await BatchSubmitter.submit(request, links: s.selectedItems, isPrivate: false, coordinator: c)
        let count = c.ledger.records.count
        let second = await BatchSubmitter.submit(request, links: s.selectedItems, isPrivate: false, coordinator: c)
        XCTAssertEqual(c.ledger.records.count, count); XCTAssertTrue(second.replayed); XCTAssertEqual(second.packages, first.packages)
        let other = await BatchSubmitter.submit(BatchRequest(name: "New id"), links: s.selectedItems, isPrivate: false, coordinator: c)
        XCTAssertEqual(other.started, 0); XCTAssertEqual(other.alreadyDownloading, 2, "already downloading: not made again, whoever asks")
    }

    func testGroupingAndWhatIsNeverMadeHere() async throws {
        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)
        let s = links(["https://a.example.com/x.zip", "https://b.example.com/y.zip", "https://a.example.com/z.zip", "https://a.example.com/i.m3u8", magnet, "https://a.example.com/page", "ftp://a.example.com/f.zip", "http://192.168.1.2/lan.zip", "https://a.example.com/x.zip#again"])
        var request = BatchRequest(name: "Mix"); request.grouping = .host
        let r = await BatchSubmitter.submit(request, links: s.selectedItems, isPrivate: false, coordinator: c)
        XCTAssertEqual(r.started, 3); XCTAssertEqual(r.packages.count, 2)
        XCTAssertEqual(Set(r.packages.compactMap { c.packages.package($0)?.name }), ["Mix – a.example.com", "Mix – b.example.com"])
        XCTAssertEqual(Set(r.needsOwnApproval), ["i.m3u8", s.items.first { $0.kind == .magnet }!.name], "streams and magnets are never made into tasks here")
        XCTAssertTrue(c.ledger.records.values.allSatisfy { $0.protocolID == .http }, "no torrent or eD2k task was created")
        XCTAssertTrue(r.refused.contains { $0.contains("page") }); XCTAssertTrue(r.refused.contains { $0.contains("own network") })
    }

    func testAPrivateCollectionMakesNothing() async {
        let s = LinkGrabberStore(profile: "default", isPrivate: true)
        s.add(candidates: ["https://a.example.com/x.zip"], provenance: .pasted); s.selection = Set(s.items.map(\.id))
        let r = await BatchSubmitter.submit(BatchRequest(name: "P"), links: s.selectedItems, isPrivate: true, coordinator: c)
        XCTAssertEqual(r.started, 0); XCTAssertTrue(c.ledger.records.isEmpty); XCTAssertTrue(c.packages.packages.isEmpty)
    }

    func testTheBatchIsBoundedAndSharesTheQueueWithEveryoneElse() async throws {
        let many = (0..<(LinkGrabberStore.maxBatchAdd + 30)).map { "https://cdn.example.com/f\($0).zip" }
        let s = links(many)
        c.maxConcurrent = 2
        let r = await BatchSubmitter.submit(BatchRequest(name: "Big"), links: s.selectedItems, isPrivate: false, coordinator: c)
        XCTAssertEqual(r.started, LinkGrabberStore.maxBatchAdd); XCTAssertTrue(r.tooMany)
        let holding = c.ledger.records.values.filter { [.starting, .running, .resolving, .verifying].contains($0.state) }.count
        XCTAssertLessThanOrEqual(holding, 2, "creating tasks did not start more than the limit (a task waiting out a retry gives its place back)")
        XCTAssertTrue(c.ledger.records.values.allSatisfy { [.scheduled, .queued, .starting, .running, .resolving, .failed, .created, .retrying].contains($0.state) })
    }

    func testACancelledBatchLeavesAConsistentPartialPackage() async throws {
        let s = links((0..<60).map { "https://cdn.example.com/c\($0).zip" })
        let task = Task { await BatchSubmitter.submit(BatchRequest(name: "Cut"), links: s.selectedItems, isPrivate: false, coordinator: c) }
        task.cancel()
        let r = await task.value
        XCTAssertTrue(r.cancelled || r.started == 60)
        if let id = r.packages.first, let p = c.packages.package(id) { XCTAssertEqual(p.members.count, r.started, "membership matches what was made") }
        XCTAssertEqual(c.ledger.records.count, r.started)
    }

    func testPackageFolderTemplatesCannotEscapeOrNameHiddenFolders() {
        let parts = PackageFolderTemplate.components("../{package}/{host}/.hidden/{directory}\\x/a:b/{date}/five/six", package: "../../etc", host: "evil/../host", directory: "..", date: Date(timeIntervalSince1970: 0))
        XCTAssertLessThanOrEqual(parts.count, PackageFolderTemplate.maxParts)
        for p in parts { XCTAssertFalse(p.contains("/")); XCTAssertFalse(p.hasPrefix(".")); XCTAssertNotEqual(p, ".."); XCTAssertFalse(p.contains("\\")); XCTAssertFalse(p.contains(":")) }
        XCTAssertEqual(PackageFolderTemplate.components("{package}", package: "My Set", host: nil, directory: nil), ["My Set"])
        XCTAssertEqual(PackageFolderTemplate.components("{package}/{host}", package: "A", host: nil, directory: nil), ["A"], "an empty value leaves no empty folder")
        XCTAssertNil(PackageFolderTemplate.clean("..")); XCTAssertNil(PackageFolderTemplate.clean("   ")); XCTAssertEqual(PackageFolderTemplate.clean(".x"), "x")
        XCTAssertEqual(PackageFolderTemplate.directory(of: URL(string: "https://h/a/b/c.zip")!), "b")
    }

    func testAPackageFolderReallyDecidesWhereTheFileGoesAndNeverOverwrites() async throws {
        try await put("pk/one.bin", Data(repeating: 1, count: 300))
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/pk/one.bin"), at: Date().addingTimeInterval(3600)))
        let p = try XCTUnwrap(c.packages.create(name: "Where", members: [id], folder: "Set/Inner")?.package)
        XCTAssertEqual(c.ledger.record(id)?.engineMetadata["packageFolder"], "Set/Inner")
        // Start it: a task made by scheduleDownload runs when due; make it due now.
        c.ledger.update(id) { $0.scheduledAt = Date() }
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("Set/Inner"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: downloads.appendingPathComponent("Set/Inner/one.bin"))
        c.startScheduled(id)
        let record = await wait(id, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let path = try XCTUnwrap(record?.file.destinationPath)
        XCTAssertTrue(path.contains("/Set/Inner/"), path)
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("Set/Inner/one.bin")), "keep", "the file that was there is kept")
        _ = p
    }

    func testASymbolicLinkInAPackageFolderCannotCarryAFileOutOfDownloads() async throws {
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("Escape"), withDestinationURL: outside)
        try await put("pk/two.bin", Data(repeating: 2, count: 300))
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/pk/two.bin"), at: Date().addingTimeInterval(3600)))
        c.packages.create(name: "Esc", members: [id], folder: "Escape")
        c.startScheduled(id)
        let record = await wait(id, for: [.completed, .failed], seconds: 20)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty, "nothing landed outside the downloads folder")
        XCTAssertFalse((record?.file.destinationPath ?? "").contains("/outside/"))
    }
}

// MARK: - robots.txt and HTML parsing (no network)

final class RobotsAndHTMLTests: XCTestCase {
    private func allowed(_ rules: RobotsRules, _ path: String) -> Bool { rules.allows(URL(string: "https://site.example\(path)")!) }

    func testTheRFCExamples() {
        let r = RobotsRules.parse("""
        User-agent: *
        Disallow: /private/
        Allow: /private/public/
        Disallow: /*.json$
        Disallow: /tmp
        User-agent: BrowserSetu
        Disallow: /only-us/
        """)
        // The group that names this crawler replaces the `*` group.
        XCTAssertFalse(allowed(r, "/only-us/x")); XCTAssertTrue(allowed(r, "/private/x")); XCTAssertTrue(allowed(r, "/a.json"))
        let star = RobotsRules.parse("User-agent: *\nDisallow: /private/\nAllow: /private/public/\nDisallow: /*.json$\nDisallow: /tmp\nCrawl-delay: 3\n")
        XCTAssertFalse(allowed(star, "/private/x")); XCTAssertTrue(allowed(star, "/private/public/x"), "longest match wins")
        XCTAssertFalse(allowed(star, "/data.json")); XCTAssertTrue(allowed(star, "/data.json5"), "$ anchors the end"); XCTAssertFalse(allowed(star, "/tmpfile")); XCTAssertTrue(allowed(star, "/other"))
        XCTAssertEqual(star.crawlDelay, 3)
        let tie = RobotsRules.parse("User-agent: *\nDisallow: /a\nAllow: /a\n")
        XCTAssertTrue(allowed(tie, "/a"), "on a tie, allow wins")
        XCTAssertTrue(allowed(RobotsRules.parse("User-agent: *\nDisallow:\n"), "/anything"), "an empty Disallow allows everything")
        XCTAssertFalse(allowed(RobotsRules.parse("User-agent: *\nDisallow: /\n"), "/x"))
        XCTAssertTrue(allowed(RobotsRules.parse("User-agent: *\nDisallow: /\n"), "/robots.txt"), "robots.txt itself is always readable")
        XCTAssertTrue(allowed(RobotsRules.parse("Disallow: /\n"), "/x"), "a rule before any user-agent belongs to no group")
        XCTAssertFalse(allowed(RobotsRules.parse("User-agent: *\nDisallow: /a%2fb\n"), "/a%2Fb"), "escapes compare without case")
        XCTAssertFalse(allowed(RobotsRules.parse("user-agent: *\nDISALLOW: /x # comment\n"), "/x"))
        XCTAssertFalse(allowed(RobotsRules.parse("User-agent: *\nDisallow: /search?q=\n"), "/search?q=1"))
    }

    func testStatusesMeanWhatTheRFCSays() {
        XCTAssertEqual(RobotsRules.forStatus(404, body: nil), .allowAll); XCTAssertEqual(RobotsRules.forStatus(403, body: nil), .allowAll)
        XCTAssertEqual(RobotsRules.forStatus(503, body: nil), .denyAll); XCTAssertEqual(RobotsRules.forStatus(nil, body: nil), .denyAll)
        XCTAssertFalse(allowed(RobotsRules.forStatus(500, body: nil), "/x"))
        XCTAssertFalse(allowed(RobotsRules.forStatus(200, body: Data("User-agent: *\nDisallow: /x\n".utf8)), "/x"))
    }

    func testHostileRobotsFilesAreBounded() {
        let big = String(repeating: "Disallow: /a*a*a*a*a*a*a*a*a*b\n", count: 30_000)
        let r = RobotsRules.parse("User-agent: *\n" + big)
        let start = Date()
        _ = allowed(r, "/" + String(repeating: "a", count: 3000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "pattern matching does not blow up")
        XCTAssertLessThanOrEqual(r.rules.count, 20_000)
    }

    func testHTMLExtractionToleratesBrokenMarkupAndReadsOnlyAddresses() {
        let html = """
        <html><head><base href="/dir/"><script>var x = "<a href='/from-script.zip'>";</script><style>a{background:url(/css.png)}</style></head>
        <body><!-- <a href="/commented.zip"> -->
        <a href=plain.zip>one</a> <a href='quoted.zip' data-x="a>b">two</a> <A HREF="UPPER.ZIP">three</A>
        <a href="amp.php?a=1&amp;b=2">four</a> <a>no href</a> <a href="#frag">frag</a> <a href="">empty</a>
        <img srcset="small.jpg 1x, big.jpg 2x"> <video src=v.mp4><source src="s.webm"></video> <audio src="a.mp3"></audio>
        <form action="/post"><input type=password value="HUNTER2"><input type=hidden name=t value="TOKEN123"><textarea>PRIVATETEXT</textarea></form>
        <a href="unterminated.zip
        """
        let page = HTMLLinks.extract(html)
        let refs = page.links.map(\.reference)
        XCTAssertEqual(page.base, "/dir/")
        XCTAssertTrue(refs.contains("plain.zip")); XCTAssertTrue(refs.contains("quoted.zip")); XCTAssertTrue(refs.contains("UPPER.ZIP")); XCTAssertTrue(refs.contains("amp.php?a=1&b=2"))
        XCTAssertTrue(refs.contains("small.jpg")); XCTAssertTrue(refs.contains("v.mp4")); XCTAssertTrue(refs.contains("s.webm")); XCTAssertTrue(refs.contains("a.mp3"))
        for hidden in ["from-script", "css.png", "commented", "HUNTER2", "TOKEN123", "PRIVATETEXT", "#frag"] { XCTAssertFalse(refs.joined().contains(hidden), hidden) }
    }

    func testHTMLExtractionIsBounded() {
        let many = String(repeating: "<a href=x.zip>", count: HTMLLinks.maxLinks + 500)
        let page = HTMLLinks.extract(many)
        XCTAssertEqual(page.links.count, HTMLLinks.maxLinks); XCTAssertTrue(page.truncated)
        let junk = String(repeating: "<", count: 300_000)
        _ = HTMLLinks.extract(junk)                      // terminates
        _ = HTMLLinks.extract("<a href=\"" + String(repeating: "a", count: 50_000))
    }
}

// MARK: - Scope

final class ExplorerScopeTests: XCTestCase {
    private func scope(_ start: String, origin: DownloadRequestOrigin = .page) -> ExplorerScope { ExplorerScope(start: URL(string: start)!, origin: origin) }

    func testAPublicSiteCannotSendTheExplorerInsideTheNetwork() {
        let s = scope("https://files.example.com/pub/")
        for t in ["http://127.0.0.1/x", "http://localhost:8080/x", "http://192.168.1.1/x", "http://10.0.0.1/x", "http://[::1]/x", "http://printer.local/x", "http://169.254.169.254/latest"] {
            XCTAssertEqual(s.admits(URL(string: t)!), .insideYourNetwork, t)
        }
        var open = scope("https://files.example.com/pub/"); open.sameOriginOnly = false; open.extraHosts = ["127.0.0.1"]
        XCTAssertEqual(open.admits(URL(string: "http://127.0.0.1/x")!), .insideYourNetwork, "listing an internal host as allowed does not let a public start reach it")
    }

    func testAStartOnYourOwnNetworkIsOnlyForTheirOwnTyping() {
        XCTAssertEqual(scope("http://192.168.1.5/pub/", origin: .user).admits(URL(string: "http://192.168.1.5/pub/a.zip")!), .inScope)
        XCTAssertEqual(scope("http://192.168.1.5/pub/", origin: .page).admits(URL(string: "http://192.168.1.5/pub/a.zip")!), .insideYourNetwork, "a page-derived start is held to the page rules")
    }

    func testHostAndDirectoryBoundaries() {
        let s = scope("https://files.example.com/pub/docs/index.html")
        XCTAssertEqual(s.admits(URL(string: "https://files.example.com/pub/docs/sub/a.pdf")!), .inScope)
        XCTAssertEqual(s.admits(URL(string: "https://files.example.com/pub/other/a.pdf")!), .outsideDirectory)
        XCTAssertEqual(s.admits(URL(string: "https://files.example.com/pub/docs-evil/a.pdf")!), .outsideDirectory, "a longer name is not inside")
        XCTAssertEqual(s.admits(URL(string: "https://files.example.com/pub/docs/../secret/a.pdf")!.standardized), .outsideDirectory)
        XCTAssertEqual(s.admits(URL(string: "https://cdn.example.com/pub/docs/a.pdf")!), .otherWebsite)
        XCTAssertEqual(s.admits(URL(string: "http://files.example.com/pub/docs/a.pdf")!), .otherWebsite, "another scheme is another origin")
        XCTAssertEqual(s.admits(URL(string: "mailto:x@y.z")!), .notWeb); XCTAssertEqual(s.admits(URL(string: "javascript:alert(1)")!), .notWeb)
        var wide = s; wide.extraHosts = ["cdn.example.com"]; wide.stayInDirectory = false
        XCTAssertEqual(wide.admits(URL(string: "https://cdn.example.com/x/a.pdf")!), .inScope)
        XCTAssertEqual(wide.admits(URL(string: "https://files.example.com/anywhere/a.pdf")!), .inScope)
    }

    func testLimitsAreClamped() {
        var s = scope("https://a.example.com/"); s.maxDepth = 99; s.maxPages = 99_999; s.maxCandidates = 0; s.maxTotalBytes = Int.max; s.pacing = -5; s.timeLimit = 0; s.extraHosts = Set((0..<50).map { "h\($0).example.com" })
        let c = s.clamped()
        XCTAssertEqual(c.maxDepth, 3); XCTAssertEqual(c.maxPages, 100); XCTAssertEqual(c.maxCandidates, 1); XCTAssertEqual(c.maxTotalBytes, 50_000_000); XCTAssertEqual(c.pacing, 0); XCTAssertEqual(c.timeLimit, 5); XCTAssertEqual(c.extraHosts.count, 10)
    }
}

// MARK: - Exploring a local fixture site

@MainActor
final class ExplorerTraversalTests: MediaCase {
    private func html(_ body: String) -> String { "<html><head><title>t</title></head><body>\(body)</body></html>" }

    private func publishSite() async throws {
        try await put("site/index.html", text: html("""
        <a href="a.zip">a</a> <a href="a.zip#again">a again</a> <a href="sub/page.html">sub</a> <a href="../up/outside.pdf">up</a>
        <a href="http://localhost:18766/media/site/otherhost.zip">other host name</a> <a href="/media/other/elsewhere.html">else</a>
        <img src="pic.png"> <video src="clip"></video> <a href="index.html">self</a> <a href="mailto:x@y.z">m</a> <a href="javascript:void(0)">j</a>
        <a href="private/secret.html">secret</a> <a href="stream/index.m3u8">hls</a>
        <form><input type=hidden name=token value=HIDDENFORMTOKEN></form> <a href="broken.html">b<a href=unterminated
        """))
        try await put("site/sub/page.html", text: html("<a href='../b.pdf'>b</a> <a href='deeper/page.html'>d</a> <a href='../index.html'>back</a> <a href='/media/site/sub/inside.txt'>in</a>"))
        try await put("site/sub/deeper/page.html", text: html("<a href='c.zip'>c</a>"))
        try await put("site/private/secret.html", text: html("<a href='private.zip'>p</a>"))
        try await put("site/broken.html", text: "<<<>>><a href=x.zip <b <<")
        try await put("other/elsewhere.html", text: html("<a href='zzz.zip'>z</a>"))
        try await put("robots.txt", text: "User-agent: *\nDisallow: /media/site/private/\n")
    }

    private func explore(_ path: String = "/media/site/index.html", depth: Int = 2, pages: Int = 25, origin: DownloadRequestOrigin = .user, tweak: ((inout ExplorerScope) -> Void)? = nil) async throws -> (items: [ExplorerItem], summary: ExplorerSummary) {
        var scope = ExplorerScope(start: url(path), origin: origin)
        scope.maxDepth = depth; scope.maxPages = pages; scope.pacing = 0
        tweak?(&scope)
        let explorer = WebsiteExplorer(fetch: try WebsiteExplorer.networkFetch(scope: scope.clamped(), network: DownloadNetworkSetup()))
        var items: [ExplorerItem] = []
        let summary = await explorer.explore(scope) { items.append($0) }
        return (items, summary)
    }

    func testItProposesTheFilesInScopeAndNothingElse() async throws {
        try await publishSite()
        let (items, summary) = try await explore()
        XCTAssertEqual(Set(items.map(\.name)), ["a.zip", "pic.png", "clip", "index.m3u8", "b.pdf", "inside.txt", "c.zip", "x.zip"])
        XCTAssertEqual(items.first { $0.name == "pic.png" }?.category, .image); XCTAssertEqual(items.first { $0.name == "clip" }?.category, .video, "the page says it is a video"); XCTAssertEqual(items.first { $0.name == "index.m3u8" }?.category, .stream)
        XCTAssertTrue(items.allSatisfy { $0.availability == .proposed }, "nothing is called available because it was seen")
        XCTAssertTrue(summary.outOfScope >= 3, "up/outside.pdf, elsewhere.html and the other host name were not followed")
        XCTAssertEqual(summary.stop, .finished)
        XCTAssertEqual(items.count, Set(items.map(\.id)).count, "a.zip linked twice is proposed once")
        let h = await hits()
        XCTAssertEqual(h["site/index.html"], 1, "a cycle is not followed twice")
        XCTAssertNil(h["other/elsewhere.html"]); XCTAssertNil(h["up/outside.pdf"])
        XCTAssertNil(h["site/a.zip"], "no proposed file was fetched")
        XCTAssertFalse(String(describing: items).contains("HIDDENFORMTOKEN"))
    }

    func testRobotsKeepsItOutOfDisallowedPages() async throws {
        try await publishSite()
        let (items, summary) = try await explore()
        let h = await hits()
        XCTAssertNil(h["site/private/secret.html"], "disallowed: never requested")
        XCTAssertFalse(items.contains { $0.name == "private.zip" })
        XCTAssertGreaterThanOrEqual(summary.blockedByRobots, 1)
        XCTAssertEqual(h["robots.txt"], 1, "read once per website")
        let ignored = try await explore(tweak: { $0.respectRobots = false })
        _ = ignored
    }

    func testAnUnreachableRobotsFileMeansNothingIsRead() async throws {
        try await publishSite()
        _ = try await get("/_media_fault/robots/503")
        let (items, summary) = try await explore()
        XCTAssertTrue(items.isEmpty); XCTAssertEqual(summary.stop, .refusedByRobots)
        let _h = await hits()
        XCTAssertNil(_h["site/index.html"])
    }

    func testAMissingRobotsFileMeansNoRestrictions() async throws {
        try await publishSite()
        _ = try await put("robots.txt", Data())          // an empty file
        try await publishSite()
        _ = try await get("/_media_fault/robots/404")
        let (items, _) = try await explore()
        XCTAssertTrue(items.contains { $0.name == "a.zip" })
    }

    func testTheDepthIsHonoured() async throws {
        try await publishSite()
        let zero = try await explore(depth: 0)
        XCTAssertEqual(zero.summary.pagesVisited, 1); XCTAssertFalse(zero.items.contains { $0.name == "b.pdf" })
        _ = try await get("/_media_reset"); try await publishSite()
        let one = try await explore(depth: 1)
        XCTAssertTrue(one.items.contains { $0.name == "b.pdf" }); XCTAssertFalse(one.items.contains { $0.name == "c.zip" }, "two levels down is beyond depth 1")
        XCTAssertTrue(one.items.allSatisfy { $0.depth <= 1 })
    }

    func testPageAndResultLimitsStopItWithAReason() async throws {
        try await publishSite()
        let pages = try await explore(pages: 1)
        XCTAssertEqual(pages.summary.pagesVisited, 1); XCTAssertEqual(pages.summary.stop, .pageLimit)
        _ = try await get("/_media_reset"); try await publishSite()
        let few = try await explore(tweak: { $0.maxCandidates = 2 })
        XCTAssertEqual(few.items.count, 2); XCTAssertEqual(few.summary.stop, .candidateLimit)
    }

    func testAHugeNumberOfLinksIsBounded() async throws {
        try await put("big/index.html", text: html((0..<3000).map { "<a href='f\($0).zip'>f</a>" }.joined()))
        let (items, summary) = try await explore("/media/big/index.html", depth: 0)
        XCTAssertLessThanOrEqual(items.count, HTMLLinks.maxLinks)
        XCTAssertTrue(summary.stop == .finished || summary.stop == .candidateLimit)
    }

    func testAPageTooLargeForTheLimitFailsTheStart() async throws {
        try await put("large/index.html", Data(repeating: 0x61, count: 40_000))
        let (items, summary) = try await explore("/media/large/index.html", depth: 0, tweak: { $0.maxPageBytes = 10_000 })
        XCTAssertTrue(items.isEmpty); XCTAssertEqual(summary.stop, .startFailed)
    }

    func testARedirectOutOfScopeIsNotFollowedIntoItsLinks() async throws {
        try await put("redir/index.html", text: html("<a href='go.html?redirect=http://127.0.0.1:18766/media/other/elsewhere.html'>go</a>"))
        try await put("other/elsewhere.html", text: html("<a href='zzz.zip'>z</a>"))
        let (items, summary) = try await explore("/media/redir/index.html", depth: 1)
        XCTAssertFalse(items.contains { $0.name == "zzz.zip" }, "what the redirect led to is outside the folder")
        XCTAssertGreaterThanOrEqual(summary.outOfScope, 1)
    }

    func testCancellingStopsItPromptly() async throws {
        try await publishSite()
        let gate = AsyncGate()
        var scope = ExplorerScope(start: url("/media/site/index.html"), origin: .user)
        scope.pacing = 5
        let explorer = WebsiteExplorer(fetch: try WebsiteExplorer.networkFetch(scope: scope.clamped(), network: DownloadNetworkSetup()), sleep: { _ in await gate.wait() })
        let store = ExplorerStore(profile: "default")
        store.start(scope, explorer: explorer)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.phase, .running)
        store.cancel(); await gate.open()
        XCTAssertEqual(store.phase, .finished); XCTAssertEqual(store.summary.stop, .cancelled)
        try await Task.sleep(for: .milliseconds(300))
        let count = store.items.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.items.count, count, "nothing arrives after it was stopped")
    }

    func testRequestsToOneWebsiteArePaced() async throws {
        try await publishSite()
        let waits = WaitLog()
        var scope = ExplorerScope(start: url("/media/site/index.html"), origin: .user)
        scope.maxDepth = 1; scope.pacing = 2
        let explorer = WebsiteExplorer(fetch: try WebsiteExplorer.networkFetch(scope: scope.clamped(), network: DownloadNetworkSetup()), sleep: { await waits.add($0) })
        _ = await explorer.explore(scope) { _ in }
        let w = await waits.values
        XCTAssertFalse(w.isEmpty); XCTAssertTrue(w.allSatisfy { $0 > 0 && $0 <= 2 })
    }

    func testAStartPageOnTheLocalNetworkNamedByAPageIsRefused() async throws {
        try await publishSite()
        let (items, summary) = try await explore(origin: .page)
        XCTAssertTrue(items.isEmpty); XCTAssertEqual(summary.stop, .startFailed)
        let _h = await hits()
        XCTAssertNil(_h["site/index.html"])
    }

    func testAProxyBlocksPageDerivedExploration() {
        var net = DownloadNetworkSetup()
        net.proxy = DownloadNetworkSettings.Proxy(mode: .http, host: "127.0.0.1", port: 8080)
        XCTAssertThrowsError(try WebsiteExplorer.networkFetch(scope: ExplorerScope(start: URL(string: "https://a.example.com/")!, origin: .page), network: net), "the destination cannot be verified through a proxy")
    }
}

actor WaitLog { private(set) var values: [TimeInterval] = []; func add(_ t: TimeInterval) { values.append(t) } }

// MARK: - Proposals: filters, selection, LinkGrabber

@MainActor
final class ExplorerStoreTests: XCTestCase {
    private func item(_ name: String, host: String = "a.example.com", dir: String = "files", depth: Int = 0, category: ExplorerCategory? = nil) -> ExplorerItem {
        WebsiteExplorer.item(for: URL(string: "https://\(host)/\(dir)/\(name)")!, depth: depth, foundOn: "page", tag: nil, mime: nil)!
    }
    private func filled() -> ExplorerStore {
        let s = ExplorerStore(profile: "default")
        let ex = WebsiteExplorer(fetch: { _ in throw ExplorerFetchError.failed })
        _ = ex
        s.testSet([item("a.zip"), item("b.pdf"), item("c.zip", host: "b.example.com"), item("d.png", dir: "img", depth: 2)])
        return s
    }

    func testFiltersAndSelectionNeverIncludeWhatIsHidden() {
        let s = filled()
        s.selectAllVisible(); XCTAssertEqual(s.selectedVisible.count, 4)
        s.extensions = ["zip"]
        XCTAssertEqual(s.visible.map(\.name), ["a.zip", "c.zip"])
        XCTAssertEqual(s.selectedVisible.map(\.name), ["a.zip", "c.zip"], "selected but hidden items are not acted on")
        s.extensions = []; s.host = "b.example.com"; XCTAssertEqual(s.visible.map(\.name), ["c.zip"])
        s.host = nil; s.category = .image; XCTAssertEqual(s.visible.map(\.name), ["d.png"])
        s.category = nil; s.maxDepth = 1; XCTAssertEqual(s.visible.count, 3)
        s.maxDepth = nil; s.directoryContains = "IMG"; XCTAssertEqual(s.visible.map(\.name), ["d.png"])
        s.directoryContains = ""; s.search = "b."; XCTAssertEqual(Set(s.visible.map(\.name)), ["b.pdf", "c.zip"])
    }

    func testSelectByGroupExcludeAndClear() {
        let s = filled()
        s.select(host: "a.example.com"); XCTAssertEqual(s.selectedVisible.count, 3)
        s.excludeSelected(); XCTAssertEqual(s.items.map(\.name), ["c.zip"]); XCTAssertTrue(s.selection.isEmpty)
        s.selectAllVisible(); s.clearSelection(); XCTAssertTrue(s.selectedVisible.isEmpty)
    }

    func testAddingGoesToTheLinkGrabberAsPageDerivedLinksAndStartsNothing() {
        let s = filled(); s.selectAllVisible()
        let links = LinkGrabberStore(profile: "default", isPrivate: false)
        let r = s.addSelected(to: links)
        XCTAssertEqual(r.added, 4); XCTAssertTrue(links.items.allSatisfy { $0.provenance == .page })
        XCTAssertEqual(s.addSelected(to: links).duplicates, 4)
    }

    func testOnlyAskingMakesAnItemCheckedAndFailureIsNotAvailable() async throws {
        let s = filled(); s.selectAllVisible()
        XCTAssertTrue(s.items.allSatisfy { $0.availability == .proposed })
        let ids = s.items.map(\.id)
        s.verify(Array(ids.prefix(2))) { url in
            if url.lastPathComponent == "b.pdf" { throw URLError(.fileDoesNotExist) }
            return LinkMetadata(filename: nil, size: 123, acceptsRanges: true)
        }
        for _ in 0..<100 where s.items.prefix(2).contains(where: { $0.availability == .proposed }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(s.items[0].availability, .verified(size: 123, mime: nil))
        if case .unavailable = s.items[1].availability {} else { XCTFail("\(s.items[1].availability)") }
        XCTAssertEqual(s.items[2].availability, .proposed, "never asked about: not checked")
        s.onlyChecked = true; XCTAssertEqual(s.visible.count, 1)
    }

    func testAResultFromAnOldRunNeverAppearsInANewOne() async throws {
        let s = ExplorerStore(profile: "default")
        let gate = AsyncGate()
        let slow = WebsiteExplorer(fetch: { _ in await gate.wait(); throw ExplorerFetchError.failed })
        s.start(ExplorerScope(start: URL(string: "https://a.example.com/")!), explorer: slow)
        s.start(ExplorerScope(start: URL(string: "https://b.example.com/")!), explorer: WebsiteExplorer(fetch: { _ in throw ExplorerFetchError.failed }))
        await gate.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(s.phase, .finished)
        XCTAssertTrue(s.items.isEmpty)
    }
}

extension ExplorerStore {
    func testSet(_ new: [ExplorerItem]) { appendForTest(new) }
}

// MARK: - Review fixes

final class Phase19ReviewParsingTests: XCTestCase {
    func testRobotsGroupsSurviveSitemapLinesAndVersionedAgentNames() {
        let r = RobotsRules.parse("User-agent: foo\nSitemap: https://x/sitemap.xml\nUser-agent: BrowserSetu/1.0\nDisallow: /named/\nUser-agent: *\nDisallow: /star/\n")
        XCTAssertFalse(r.allows(URL(string: "https://x/named/a")!), "a version after the name is still this crawler"); XCTAssertTrue(r.allows(URL(string: "https://x/star/a")!))
        let delay = RobotsRules.parse("User-agent: a\nCrawl-delay: 2\nUser-agent: *\nDisallow: /z\n")
        XCTAssertTrue(delay.rules.contains { $0.pattern == "/z" })
    }

    func testEntitiesAreDecodedOnce() { XCTAssertEqual(HTMLLinks.decode("a&amp;quot;b"), "a&quot;b"); XCTAssertEqual(HTMLLinks.decode("x&amp;y&lt;"), "x&y<") }

    func testDotSegmentsCannotCarryALinkOutOfTheFolder() {
        var s = ExplorerScope(start: URL(string: "https://a.example.com/pub/docs/")!, origin: .page)
        s.stayInDirectory = true
        XCTAssertEqual(s.admits(URL(string: "https://a.example.com/pub/docs/../secret/a.zip")!), .outsideDirectory)
        XCTAssertEqual(s.admits(URL(string: "https://a.example.com/pub/docs/%2e%2e/secret/a.zip")!), .outsideDirectory)
        XCTAssertEqual(s.admits(URL(string: "https://a.example.com/pub/docs/./sub/a.zip")!), .inScope)
        XCTAssertEqual(ExplorerScope.resolved("/a/b/../../../c/./d/"), "/c/d/")
    }
}

@MainActor
final class Phase19ReviewFixTests: MediaCase {
    private func page(_ body: String) -> String { "<html><body>\(body)</body></html>" }
    private func run(_ path: String, depth: Int = 1, origin: DownloadRequestOrigin = .user) async throws -> (items: [ExplorerItem], summary: ExplorerSummary) {
        var scope = ExplorerScope(start: url(path), origin: origin); scope.maxDepth = depth; scope.pacing = 0
        let explorer = WebsiteExplorer(fetch: try WebsiteExplorer.networkFetch(scope: scope.clamped(), network: DownloadNetworkSetup()))
        var items: [ExplorerItem] = []
        let summary = await explorer.explore(scope) { items.append($0) }
        return (items, summary)
    }

    func testARedirectOutOfScopeIsNeverRequested() async throws {
        try await put("rs/index.html", text: page("<a href='go.html?redirect=http://127.0.0.1:18766/media/rs-other/page.html'>go</a><a href='ok.zip'>z</a>"))
        try await put("rs-other/page.html", text: page("<a href='bad.zip'>b</a>"))
        let (items, summary) = try await run("/media/rs/index.html")
        let h = await hits()
        XCTAssertNil(h["rs-other/page.html"], "the redirect target was not requested")
        XCTAssertFalse(items.contains { $0.name == "bad.zip" }); XCTAssertTrue(items.contains { $0.name == "ok.zip" }); XCTAssertGreaterThanOrEqual(summary.outOfScope, 1)
    }

    func testAStartPageThatMovesIsFollowedAndItsNewScopeUsed() async throws {
        try await put("moved/final/index.html", text: page("<a href='file.zip'>f</a><a href='more/inner.zip'>i</a>"))
        let (items, summary) = try await run("/media/moved/old.html?redirect=http://127.0.0.1:18766/media/moved/final/index.html")
        XCTAssertEqual(Set(items.map(\.name)), ["file.zip", "inner.zip"], "links on the page it moved to are in scope of its new place")
        XCTAssertEqual(summary.stop, .finished)
    }

    func testAStartPageThatMovesToARobotsDisallowedPlaceStops() async throws {
        try await put("robots.txt", text: "User-agent: *\nDisallow: /media/blocked/\n")
        try await put("blocked/index.html", text: page("<a href='x.zip'>x</a>"))
        let (items, summary) = try await run("/media/start2.html?redirect=http://127.0.0.1:18766/media/blocked/index.html")
        XCTAssertTrue(items.isEmpty); XCTAssertEqual(summary.stop, .refusedByRobots)
    }

    func testOtherClientErrorsOnRobotsMeanNoRestrictions() async throws {
        try await put("rb/index.html", text: page("<a href='a.zip'>a</a>"))
        _ = try await get("/_media_fault/robots/451")
        let (items, _) = try await run("/media/rb/index.html", depth: 0)
        XCTAssertTrue(items.contains { $0.name == "a.zip" })
    }

    func testARepeatedLinkIsQueuedOnceAndEveryRequestCountsTowardTheLimit() async throws {
        try await put("dup/index.html", text: page((0..<500).map { _ in "<a href='p.html'>p</a>" }.joined() + "<a href='q.html'>q</a>"))
        try await put("dup/p.html", text: page("<a href='f.zip'>f</a>")); try await put("dup/q.html", text: page("<a href='g.zip'>g</a>"))
        let (items, summary) = try await run("/media/dup/index.html")
        let h = await hits()
        XCTAssertEqual(h["dup/p.html"], 1); XCTAssertEqual(summary.pagesVisited, 3); XCTAssertEqual(Set(items.map(\.name)), ["f.zip", "g.zip"])
        // Pages that fail still use up the allowance.
        try await put("fail/index.html", text: page((0..<30).map { "<a href='missing\($0).html'>m</a>" }.joined()))
        var scope = ExplorerScope(start: url("/media/fail/index.html"), origin: .user); scope.maxDepth = 1; scope.maxPages = 5; scope.pacing = 0
        let ex = WebsiteExplorer(fetch: try WebsiteExplorer.networkFetch(scope: scope.clamped(), network: DownloadNetworkSetup()))
        let s = await ex.explore(scope) { _ in }
        XCTAssertEqual(s.stop, .pageLimit); XCTAssertLessThanOrEqual(s.pagesFailed + s.pagesVisited, 5)
    }

    func testPackageEventsAreWiredWithoutOpeningTheSheet() {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-p19-\(UUID().uuidString)", profile: "default")
        _ = model.packages
        XCTAssertNotNil(model.engine.downloads.packages.onEvent)
    }

    func testAnUnheardPackageEventIsHeldNotLost() async throws {
        let id = c.ledger.create(protocolID: .http, source: URL(string: "https://x.example.com/a.zip"), filename: "a.zip", isPrivate: false).id
        c.ledger.apply(.queued, to: id); c.ledger.apply(.started, to: id); c.ledger.apply(.running, to: id); c.ledger.apply(.verifying, to: id); c.ledger.apply(.completed(.verified), to: id)
        let p = try XCTUnwrap(c.packages.create(name: "Late", members: [id])?.package)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(c.packages.package(p.id)?.announced, "nobody was listening: not marked as announced")
        var heard: [String] = []
        c.packages.onEvent = { t, _, _ in heard.append(t) }
        c.ledger.update(id) { $0.updatedAt = Date() }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(heard, ["package.completed"])
    }

    func testMovingATaskDropsTheOldPackagesFolderAndAFullTargetKeepsTheRest() throws {
        func make(_ n: Int) -> UUID { let r = c.ledger.create(protocolID: .http, source: URL(string: "https://x.example.com/\(n).zip"), filename: "\(n).zip", isPrivate: false); c.ledger.apply(.queued, to: r.id); return r.id }
        let a = make(1), b = make(2)
        let withFolder = try XCTUnwrap(c.packages.create(name: "F", members: [a], folder: "Old/Place")?.package)
        let without = try XCTUnwrap(c.packages.create(name: "N", members: [])?.package)
        XCTAssertEqual(c.ledger.record(a)?.engineMetadata["packageFolder"], "Old/Place")
        c.packages.move([a], to: without.id)
        XCTAssertNil(c.ledger.record(a)?.engineMetadata["packageFolder"], "the task no longer carries the folder of the package it left")
        _ = (withFolder, b)
    }

    func testAnApprovedAutomationProposalRunsAsPageDerived() throws {
        // Approval is the person's act, but the address came from a program: it keeps the restricted rules.
        let id = try XCTUnwrap(c.scheduleDownload(url: URL(string: "https://x.example.com/p.zip")!, at: Date().addingTimeInterval(3600), origin: .page))
        XCTAssertEqual(c.ledger.record(id)?.engineMetadata["origin"], "page")
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/Phase19BatchTests.swift", with: "Shared/Downloads/Automation/AutomationService.swift"))
        XCTAssertTrue(source.contains("expectedSHA256: p.sha256, origin: .page)"), "the approval path passes a restricted origin")
    }
}

final class ExplorerFolderStartTests: XCTestCase {
    func testAStartThatIsAFolderStaysInThatFolder() {
        let s = ExplorerScope(start: URL(string: "https://a.example.com/pub/docs/")!, origin: .page)
        XCTAssertEqual(s.admits(URL(string: "https://a.example.com/pub/docs/a.zip")!), .inScope)
        XCTAssertEqual(s.admits(URL(string: "https://a.example.com/pub/other/a.zip")!), .outsideDirectory, "a folder start does not widen to its parent")
        XCTAssertEqual(s.admits(URL(string: "https://a.example.com/pub/a.zip")!), .outsideDirectory)
        let file = ExplorerScope(start: URL(string: "https://a.example.com/pub/docs/index.html")!, origin: .page)
        XCTAssertEqual(file.admits(URL(string: "https://a.example.com/pub/docs/a.zip")!), .inScope)
        XCTAssertEqual(file.admits(URL(string: "https://a.example.com/pub/a.zip")!), .outsideDirectory)
    }
}
