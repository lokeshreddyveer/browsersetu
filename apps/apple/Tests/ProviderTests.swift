import CryptoKit
import XCTest
@testable import Browser_Setu

/// DX-12 against a local stand-in for GitHub, Hugging Face and S3/Azure (scripts/provider_fixture_server.py: one "service" origin and a separate "CDN" origin that records whether a credential reached it).
final class ProviderFixture {
    let port: Int, cdnPort: Int
    private var process: Process?, stdin: Pipe?
    var service: String { "http://127.0.0.1:\(port)" }
    init() throws {
        port = Int.random(in: 41_000..<44_000); cdnPort = port + 1
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/provider_fixture_server.py").path
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", script, String(port), String(cdnPort)]
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        try p.run(); process = p; stdin = i
        guard String(decoding: o.fileHandleForReading.availableData, as: UTF8.self).contains("ready") else { throw NSError(domain: "provider", code: 1) }
    }
    func stop() { try? stdin?.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8)); process?.terminate() }
    func get(_ path: String) async throws -> Data { try await URLSession(configuration: .ephemeral).data(from: URL(string: service + path)!).0 }
    struct Seen: Decodable { var side: String; var method: String; var path: String; var auth: Bool; var authValue: String?; var accept: String? }
    func log() async -> [Seen] { (try? JSONDecoder().decode([Seen].self, from: await get("/_log"))) ?? [] }
    func reset() async { _ = try? await get("/_reset") }
    func expect(_ name: String) async -> (size: Int, sha: String) {
        let d = (try? JSONSerialization.jsonObject(with: await get("/_expect/" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))) as? [String: Any]
        return (d?["size"] as? Int ?? -1, d?["sha256"] as? String ?? "")
    }
}

final class ProviderTests: MediaCase {
    var fx: ProviderFixture!
    var svc: ProviderService!
    override func setUp() async throws {
        try await super.setUp()
        fx = try ProviderFixture()
        AccountRouter.allowPlainHTTPForTests = true
        c.accountStore = AccountStore(profile: "provider-\(UUID().uuidString.prefix(6))", file: nil, secrets: MemoryAccountSecretStore())
        makeService()
    }
    override func tearDown() async throws { fx?.stop(); AccountRouter.allowPlainHTTPForTests = false; try await super.tearDown() }

    func makeService() {
        svc = ProviderService(coordinator: c)
        svc.githubAPI = URL(string: fx.service)!; svc.githubHost = "127.0.0.1"
        svc.hfEndpoint = URL(string: fx.service)!; svc.hfHost = "localhost"
        svc.pacing = 0
    }
    func addToken(_ token: String) { _ = c.accountStore!.add(name: "Test", host: "127.0.0.1", port: fx.port, method: .apiToken, secret: token); makeService() }
    func sha256(_ url: URL) -> String { SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined() }
    func gh(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(fx.port)\(path)")! }
    func hf(_ path: String) -> URL { URL(string: "http://localhost:\(fx.port)\(path)")! }
    func listing(_ url: URL) async throws -> ProviderListing { try await svc.listing(for: try XCTUnwrap(svc.route(for: url), "not recognised: \(url)")) }
    func find(_ root: URL, _ name: String) -> URL? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.lastPathComponent == name { return u }
        return nil
    }

    // MARK: Recognising addresses

    func testAddressesAreRecognisedOnlyWhenTheyAreClearlyOneOfTheseAndOrdinarySitesAreLeftAlone() {
        XCTAssertEqual(GitHubProvider.parse(URL(string: "https://github.com/cli/cli")!), .releases(owner: "cli", repo: "cli"))
        XCTAssertEqual(GitHubProvider.parse(URL(string: "https://github.com/cli/cli/releases/tag/v2.0.0")!), .tag(owner: "cli", repo: "cli", tag: "v2.0.0"))
        XCTAssertEqual(GitHubProvider.parse(URL(string: "https://github.com/cli/cli/releases/latest")!), .latest(owner: "cli", repo: "cli"))
        XCTAssertEqual(GitHubProvider.parse(URL(string: "https://github.com/cli/cli/releases/download/v2/cli_mac.zip")!), .asset(owner: "cli", repo: "cli", tag: "v2", name: "cli_mac.zip"))
        XCTAssertEqual(GitHubProvider.parse(URL(string: "https://github.com/cli/cli/archive/refs/tags/v2.zip")!), .source(owner: "cli", repo: "cli", ref: "v2"))
        XCTAssertEqual(GitHubProvider.parse(URL(string: "https://github.com/cli/cli/actions/runs/123")!), .run(owner: "cli", repo: "cli", runID: 123))
        XCTAssertNil(GitHubProvider.parse(URL(string: "https://github.com/features")!), "one path part is not a repository")
        XCTAssertNil(GitHubProvider.parse(URL(string: "https://github.com/cli/cli/issues/5")!))
        XCTAssertNil(GitHubProvider.parse(URL(string: "https://github.com/../etc")!))
        XCTAssertNil(GitHubProvider.parse(URL(string: "https://evil.example/cli/cli")!), "only the service's own host")
        let m = HuggingFaceProvider.parse(URL(string: "https://huggingface.co/meta-llama/Llama-3/tree/main/sub")!)
        XCTAssertEqual(m, .init(kind: .model, repo: "meta-llama/Llama-3", revision: "main", path: "sub", isFile: false))
        XCTAssertEqual(HuggingFaceProvider.parse(URL(string: "https://huggingface.co/datasets/org/ds")!)?.kind, .dataset)
        XCTAssertEqual(HuggingFaceProvider.parse(URL(string: "https://huggingface.co/org/m/resolve/abc/dir/x.gguf")!), .init(kind: .model, repo: "org/m", revision: "abc", path: "dir/x.gguf", isFile: true))
        XCTAssertEqual(HuggingFaceProvider.parse(URL(string: "https://huggingface.co/org/m/tree/refs%2Fpr%2F1")!)?.revision, "refs/pr/1")
        XCTAssertNil(HuggingFaceProvider.parse(URL(string: "https://huggingface.co/spaces/org/app")!)); XCTAssertNil(HuggingFaceProvider.parse(URL(string: "https://huggingface.co/pricing")!))
        XCTAssertNil(HuggingFaceProvider.parse(URL(string: "https://huggingface.co/org/m/blob/main/../../x")!), "no path climbing")
        for site in ["https://example.com/a/b", "https://news.ycombinator.com/item?id=1", "https://www.google.com/search?q=github.com/a/b"] { XCTAssertNil(ProviderRoute.recognise(URL(string: site)!), site) }
        XCTAssertEqual(ProviderRoute.recognise(URL(string: "https://bucket.s3.us-east-1.amazonaws.com/pre/")!)?.label, "Cloud storage")
        XCTAssertEqual(ProviderRoute.recognise(URL(string: "https://h.example/file.bin?X-Amz-Signature=a&X-Amz-Date=20990101T000000Z&X-Amz-Expires=60")!)?.label, "Signed link")
    }

    func testPlatformClassificationAndRecommendationNeverGuess() {
        let t: [(String, ProviderPlatform.OS, ProviderPlatform.Arch)] = [
            ("App-1.0-macos-arm64.dmg", .mac, .arm64), ("tool_darwin_amd64.tar.gz", .mac, .x86_64), ("App-universal.dmg", .mac, .universal), ("setup-x64.exe", .windows, .x86_64),
            ("app_1.0_amd64.deb", .linux, .x86_64), ("machine-learning.zip", .unknown, .unknown), ("thing-aarch64-apple-darwin.tar.gz", .mac, .arm64), ("App.dmg", .mac, .unknown)]
        for (name, os, arch) in t { let p = ProviderPlatform.classify(name); XCTAssertEqual(p.os, os, name); XCTAssertEqual(p.arch, arch, name) }
        func f(_ n: String, _ pre: Bool = false) -> ProviderFile { var x = ProviderFile(id: n, name: n, url: URL(string: "https://x/\(n)")!, kind: .asset); x.platform = .classify(n); x.prerelease = pre; return x }
        XCTAssertEqual(GitHubRecommendation.pick([f("a-macos-arm64.dmg"), f("a-macos-x86_64.dmg"), f("a-windows.exe")], arch: .arm64).fileID, "a-macos-arm64.dmg")
        XCTAssertEqual(GitHubRecommendation.pick([f("a-macos-arm64.dmg"), f("a-macos-x86_64.dmg")], arch: .x86_64).fileID, "a-macos-x86_64.dmg")
        XCTAssertEqual(GitHubRecommendation.pick([f("a-universal.dmg"), f("a-windows.exe")], arch: .arm64).fileID, "a-universal.dmg")
        XCTAssertNil(GitHubRecommendation.pick([f("a-macos-arm64.dmg"), f("a-macos-arm64.zip")], arch: .arm64).fileID, "two files fit: no guess")
        XCTAssertNil(GitHubRecommendation.pick([f("a-macos-arm64.dmg")], arch: .x86_64).fileID, "the only Mac file is for the other processor")
        XCTAssertNil(GitHubRecommendation.pick([f("a-windows.exe"), f("a-linux.tar.gz")], arch: .arm64).fileID)
        XCTAssertNil(GitHubRecommendation.pick([f("a-beta-macos-arm64.dmg", true)], arch: .arm64).fileID, "a pre-release is never recommended")
        XCTAssertEqual(GitHubProvider.parseChecksumList("\(String(repeating: "a", count: 64))  one.dmg\n\(String(repeating: "B", count: 64)) *two.zip\nSHA256 (three.pkg) = \(String(repeating: "c", count: 64))\nbad  line\n\(String(repeating: "d", count: 64))  dir/x.bin\n"),
                       ["one.dmg": String(repeating: "a", count: 64), "two.zip": String(repeating: "b", count: 64), "three.pkg": String(repeating: "c", count: 64)], "other forms and paths with folders are ignored")
    }

    // MARK: GitHub

    func testGitHubReleaseListsAssetsChecksumsAndARecommendationThenDownloadsTheRealBytes() async throws {
        let l = try await listing(gh("/o/r"))
        XCTAssertEqual(l.releaseNames, ["v1.0", "v2.0-beta"])
        let by = Dictionary(l.files.filter { $0.kind == .asset }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let arm = try XCTUnwrap(by["App-1.0-macos-arm64.dmg"]), x86 = try XCTUnwrap(by["App-1.0-macos-x86_64.dmg"]), win = try XCTUnwrap(by["App-1.0-windows-x64.exe"])
        let armExpect = await fx.expect("App-1.0-macos-arm64.dmg"), x86Expect = await fx.expect("App-1.0-macos-x86_64.dmg")
        XCTAssertEqual(arm.sha256, armExpect.sha); XCTAssertEqual(arm.checksumSource, "GitHub digest")
        XCTAssertEqual(x86.sha256, x86Expect.sha); XCTAssertEqual(x86.checksumSource, "SHA256SUMS", "from the checksum list in the same release")
        XCTAssertNotNil(win.sha256); XCTAssertNil(by["App-2.0-beta-macos-arm64.dmg"]?.sha256, "no statement, no checksum")
        XCTAssertEqual(by["App-1.0-macos-arm64.dmg.sig"]?.note?.hasPrefix("Signature file"), true, "a signature is saved, never called verified")
        XCTAssertTrue(by["App-2.0-beta-macos-arm64.dmg"]?.prerelease == true)
        XCTAssertFalse(arm.needsAccount); XCTAssertEqual(arm.url.host, "127.0.0.1"); XCTAssertTrue(arm.url.path.hasSuffix("/releases/download/v1.0/App-1.0-macos-arm64.dmg"), "a public repository uses the public link")
        XCTAssertEqual(l.files.filter { $0.kind == .sourceArchive }.count, 4, "zip and tarball for each of two releases")
        let rec = GitHubRecommendation.pick(l.files, arch: .arm64); XCTAssertEqual(rec.fileID, arm.id)

        let seen0 = await fx.log(); XCTAssertTrue(seen0.allSatisfy { !$0.auth }, "no token was sent to a public repository")
        let out = await svc.download(l, files: [arm, x86], isPrivate: false)
        XCTAssertEqual(out.started, 2); XCTAssertEqual(out.source, "github:o/r")
        let pkg = try XCTUnwrap(c.packages.package(withSource: "github:o/r")); XCTAssertEqual(pkg.members.count, 2, "one collection")
        for id in pkg.members { let r = await wait(id, for: [.completed, .failed]); XCTAssertEqual(r?.state, .completed, r?.failure?.reason ?? "") }
        let a = try XCTUnwrap(find(downloads, "App-1.0-macos-arm64.dmg")), b = try XCTUnwrap(find(downloads, "App-1.0-macos-x86_64.dmg"))
        XCTAssertEqual(sha256(a), armExpect.sha, "the downloaded bytes are the file"); XCTAssertEqual(sha256(b), x86Expect.sha)
        let seen = await fx.log()
        XCTAssertTrue(seen.filter { $0.side == "cdn" }.allSatisfy { !$0.auth }, "nothing reached the storage host with a credential")
        XCTAssertFalse(seen.contains { $0.path.contains("token") }, "no token in any address")
        // Asking again adds nothing.
        let again = await svc.download(l, files: [arm, x86], isPrivate: false); XCTAssertEqual(again.started, 0); XCTAssertEqual(again.alreadyThere, 2)
    }

    func testGitHubLimitsAndPrivateRepositories() async throws {
        do { _ = try await listing(gh("/o/limited")); XCTFail() } catch let e as ProviderError {
            if case .rateLimited(let after, _) = e { XCTAssertGreaterThan(after ?? 0, 60); XCTAssertTrue(e.localizedDescription.contains("access token")) } else { XCTFail("\(e)") }
        }
        do { _ = try await listing(gh("/o/priv")); XCTFail("private without a token") } catch { XCTAssertEqual(error as? ProviderError, .notFound) }
        addToken("ghp_testtoken")
        let l = try await listing(gh("/o/priv"))
        let f = try XCTUnwrap(l.files.first { $0.kind == .asset })
        XCTAssertTrue(f.needsAccount); XCTAssertEqual(f.headers["Accept"], "application/octet-stream"); XCTAssertTrue(f.url.path.contains("/releases/assets/"))
        XCTAssertFalse(f.url.absoluteString.contains("ghp_"), "the token is never part of an address")
        await fx.reset()
        _ = await svc.download(l, files: [f], isPrivate: false)
        let pkg = try XCTUnwrap(c.packages.package(withSource: l.source))
        let r = await wait(try XCTUnwrap(pkg.members.first), for: [.completed, .failed]); XCTAssertEqual(r?.state, .completed, r?.failure?.reason ?? "")
        let expect = await fx.expect("secret-macos-arm64.dmg")
        XCTAssertEqual(sha256(try XCTUnwrap(find(downloads, "secret-macos-arm64.dmg"))), expect.sha)
        let seen = await fx.log()
        XCTAssertTrue(seen.contains { $0.side == "service" && $0.auth && $0.path.contains("/releases/assets/") && $0.accept == "application/octet-stream" }, "the token went to the API host with the asset request")
        XCTAssertTrue(seen.filter { $0.side == "cdn" }.allSatisfy { !$0.auth }, "and was dropped when GitHub sent the download to its storage host")
        XCTAssertFalse(seen.contains { $0.path.contains("ghp_") }, "never in an address")
        XCTAssertEqual(r?.engineMetadata["accept"], "application/octet-stream", "the Accept header is kept so a restart asks for the file, not for its description")
        XCTAssertFalse((r?.engineMetadata ?? [:]).values.contains { $0.contains("ghp_") }, "and no credential is saved with the task")
    }

    func testRecommendationRefusesToGuessWhenTwoFilesFit() async throws {
        let l = try await listing(gh("/o/two"))
        let r = GitHubRecommendation.pick(l.files, arch: .arm64)
        XCTAssertNil(r.fileID); XCTAssertTrue(r.reason.contains("2 files fit"), r.reason)
    }

    // MARK: Hugging Face

    func testHuggingFaceModelIsPinnedToACommitListsAllPagesChecksLFSObjectsAndKeepsFolders() async throws {
        let l = try await listing(hf("/org/model"))
        XCTAssertEqual(l.revision, "1234567890abcdef1234567890abcdef12345678"); XCTAssertEqual(l.files.count, 5, "both pages")
        XCTAssertTrue(l.files.allSatisfy { $0.url.path.contains("/resolve/1234567890abcdef1234567890abcdef12345678/") }, "every file is addressed at the commit, not at a moving name")
        let by = Dictionary(uniqueKeysWithValues: l.files.map { ($0.relativePath, $0) })
        let st = try XCTUnwrap(by["model.safetensors"]); let stExpect = await fx.expect("model.safetensors")
        XCTAssertEqual(st.sha256, stExpect.sha); XCTAssertEqual(st.size, Int64(stExpect.size)); XCTAssertEqual(st.kind, .lfsFile); XCTAssertEqual(st.checksumSource, "LFS object id")
        XCTAssertNil(by["config.json"]?.sha256, "a plain git file has no SHA-256 statement; only its size is checked")
        XCTAssertEqual(by["sub/tokenizer.json"]?.folders, ["sub"])
        XCTAssertEqual(Set(l.files.map { ProviderFormats.group($0.name) }), ["GGUF", "SafeTensors", "Config & docs", "PyTorch"])

        let chosen = ["config.json", "model.safetensors", "sub/tokenizer.json"].compactMap { by[$0] }
        await fx.reset()
        let out = await svc.download(l, files: chosen, isPrivate: false); XCTAssertEqual(out.started, 3)
        let pkg = try XCTUnwrap(c.packages.package(withSource: l.source))
        for id in pkg.members { let r = await wait(id, for: [.completed, .failed]); XCTAssertEqual(r?.state, .completed, r?.failure?.reason ?? "") }
        let tok = try XCTUnwrap(find(downloads, "tokenizer.json")); XCTAssertEqual(tok.deletingLastPathComponent().lastPathComponent, "sub", "the repository's folder structure is kept inside the collection folder")
        XCTAssertEqual(sha256(try XCTUnwrap(find(downloads, "model.safetensors"))), stExpect.sha, "the real bytes arrived through the storage redirect")
        let seen = await fx.log(); XCTAssertTrue(seen.filter { $0.side == "cdn" }.allSatisfy { !$0.auth })
    }

    func testAFileThatIsOnlyAnLFSPointerIsNeverKeptAsTheFile() async throws {
        let l = try await listing(hf("/org/model"))
        let p = try XCTUnwrap(l.files.first { $0.name == "pointer.bin" })
        _ = await svc.download(l, files: [p], isPrivate: false)
        let id = try XCTUnwrap(c.packages.package(withSource: l.source)?.members.first)
        let r = await wait(id, for: [.completed, .failed, .cancelled], seconds: 30)
        XCTAssertNotEqual(r?.state, .completed, "a pointer standing in for 5000 bytes is not the file")
        XCTAssertNil(find(downloads, "pointer.bin"), "nothing is left under the file's name")
        // The check itself: a pointer is recognised, a file that merely mentions the words is not.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lfs-\(UUID().uuidString.prefix(6))"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let ptr = dir.appendingPathComponent("p"), other = dir.appendingPathComponent("o"), big = dir.appendingPathComponent("b")
        try Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "a", count: 64))\nsize 10\n".utf8).write(to: ptr)
        try Data("hello version https://git-lfs.github.com/spec/v1".utf8).write(to: other)
        try (Data("version https://git-lfs.github.com/spec/v1\n".utf8) + Data(count: 5000)).write(to: big)
        XCTAssertTrue(HTTPDownloadRunner.isLFSPointer(atPath: ptr.path)); XCTAssertFalse(HTTPDownloadRunner.isLFSPointer(atPath: other.path)); XCTAssertFalse(HTTPDownloadRunner.isLFSPointer(atPath: big.path), "a large file is never a pointer")
    }

    func testGatedPrivateAndLimitedRepositoriesSayWhatToDoAndNothingWorksAround() async throws {
        let g = try await listing(hf("/org/gated"))
        XCTAssertTrue(g.notices.contains { $0.contains("gated") }); XCTAssertTrue(g.files.allSatisfy(\.needsAccount))
        _ = await svc.download(g, files: g.files, isPrivate: false)
        let id = try XCTUnwrap(c.packages.package(withSource: g.source)?.members.first)
        let r = await wait(id, for: [.completed, .failed], seconds: 20); XCTAssertEqual(r?.state, .failed, "the service said no, and that is the answer"); XCTAssertNil(find(downloads, "config.json"))
        do { _ = try await listing(hf("/org/private")); XCTFail() } catch { XCTAssertEqual(error as? ProviderError, .unauthorized(host: "127.0.0.1", hadToken: false)) }
        do { _ = try await listing(hf("/org/limited")); XCTFail() } catch let e as ProviderError {
            if case .rateLimited(let after, _) = e { XCTAssertEqual(after, 7); XCTAssertTrue(e.localizedDescription.contains("7 seconds")) } else { XCTFail("\(e)") }
        }
        do { _ = try await listing(hf("/org/nothing-here")); XCTFail() } catch { XCTAssertEqual(error as? ProviderError, .notFound) }
    }

    func testHuggingFacePrivateModelUsesTheTokenOnlyOnTheServiceHost() async throws {
        // (the fixture's private model answers only with the right token)
        _ = c.accountStore!.add(name: "HF", host: "127.0.0.1", port: fx.port, method: .apiToken, secret: "hf_testtoken"); makeService()
        let l = try await listing(hf("/org/private")); XCTAssertEqual(l.files.count, 1); XCTAssertTrue(l.files[0].needsAccount)
        await fx.reset()
        _ = await svc.download(l, files: l.files, isPrivate: false)
        let id = try XCTUnwrap(c.packages.package(withSource: l.source)?.members.first)
        let r = await wait(id, for: [.completed, .failed]); XCTAssertEqual(r?.state, .completed, r?.failure?.reason ?? "")
        let seen = await fx.log(); XCTAssertTrue(seen.contains { $0.side == "service" && $0.auth }); XCTAssertTrue(seen.filter { $0.side == "cdn" }.allSatisfy { !$0.auth })
    }

    // MARK: Datasets in bulk

    func testADatasetOfTwelveHundredFilesIsListedPagedChosenAndCollectedOnceWithoutDuplicates() async throws {
        let t0 = Date()
        let l = try await listing(hf("/datasets/org/bulk"))
        let listed = Date().timeIntervalSince(t0)
        XCTAssertEqual(l.files.count, 1200, "three pages"); XCTAssertEqual(l.files.first?.folders, ["data"])
        let model = ProviderSheetModel(coordinator: c, service: svc)
        model.open(address: hf("/datasets/org/bulk").absoluteString)
        for _ in 0..<200 where model.phase != .listed { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(model.phase, .listed); model.filter = "part-001"; XCTAssertEqual(model.matching.count, 100); XCTAssertEqual(model.shown.count, 100)
        model.filter = ""; XCTAssertEqual(model.shown.count, ProviderSheetModel.rowLimit, "only a screenful of rows is built; the choice still covers every match")
        model.selectMatching(); XCTAssertEqual(model.selection.count, 1200)
        let t1 = Date()
        let out = await svc.download(l, files: l.files, isPrivate: false)
        let started = Date().timeIntervalSince(t1)
        XCTAssertEqual(out.started, 1200); XCTAssertEqual(out.failedToStart, 0)
        // (The Downloads list keeps a bounded history of finished downloads, so "done" is: no task of this dataset is still unfinished.)
        let end = Date().addingTimeInterval(300)
        func unfinished() -> Int { c.ledger.records.values.filter { !$0.state.isFinal && $0.state != .failed }.count }
        while Date() < end, unfinished() > 0 { try await Task.sleep(nanoseconds: 250_000_000) }
        XCTAssertEqual(unfinished(), 0, "everything finished")
        XCTAssertEqual(c.ledger.records.values.filter { $0.state == .failed }.count, 0, "and nothing failed")
        let onDisk = (FileManager.default.enumerator(at: downloads, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "parquet" }
        XCTAssertEqual(onDisk.count, 1200, "all 1200 files are on disk")
        let sample = try XCTUnwrap(find(downloads, "part-00777.parquet")); XCTAssertEqual(try Data(contentsOf: sample), Data("part 777".utf8) + Data(repeating: UInt8(ascii: "."), count: 56))
        XCTAssertEqual(sample.deletingLastPathComponent().lastPathComponent, "data"); XCTAssertEqual(c.packages.packages.filter { $0.source?.hasPrefix(l.source) == true }.count, 2, "1200 files make two collections of at most 1000")
        print("PERF dataset: listed 1200 files in \(String(format: "%.2f", listed)) s; started 1200 in \(String(format: "%.1f", started)) s; all finished in \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
        let again = await svc.download(l, files: l.files, isPrivate: false); XCTAssertEqual(again.started, 0); XCTAssertEqual(again.alreadyThere, 1200, "a second run adds nothing")
    }

    func testARateLimitStopsTheBatchKeepsWhatStartedAndASecondRunAddsOnlyTheRest() async throws {
        let l = try await listing(hf("/datasets/org/rl")); XCTAssertEqual(l.files.count, 10)
        svc.pacing = 0.15
        let first = await svc.download(l, files: l.files, isPrivate: false)
        XCTAssertNotNil(first.stoppedBy, "told that the service is limiting requests"); XCTAssertGreaterThan(first.notStarted, 0); XCTAssertLessThan(first.started, 10)
        let pkg = try XCTUnwrap(c.packages.package(withSource: l.source)); let had = pkg.members.count
        await fx.reset()
        let second = await svc.download(l, files: l.files, isPrivate: false)
        XCTAssertGreaterThan(second.alreadyThere, 0, "what was started is not started again")
        XCTAssertGreaterThanOrEqual(c.packages.package(withSource: l.source)?.members.count ?? 0, had, "the collection kept what it had and only grew")
        XCTAssertLessThanOrEqual(c.packages.package(withSource: l.source)?.members.count ?? 99, 10, "and never holds a file twice")
    }

    // MARK: Cloud storage

    func testPublicBucketListsPagesWithPrefixAndDownloadsAndAClosedBucketSaysSo() async throws {
        var t = try XCTUnwrap(CloudStorageProvider.parse(URL(string: fx.service + "/pub-bucket")!))
        var l = try await svc.listing(for: .cloud(t)); XCTAssertEqual(l.files.map(\.relativePath).sorted(), ["data/a.csv", "data/b.csv", "data/sub/c.csv", "readme.txt"], "two pages of two")
        t = try XCTUnwrap(CloudStorageProvider.parse(URL(string: fx.service + "/pub-bucket/data/")!))
        l = try await svc.listing(for: .cloud(t)); XCTAssertEqual(l.files.map(\.relativePath).sorted(), ["a.csv", "b.csv", "sub/c.csv"])
        XCTAssertEqual(l.files.first { $0.name == "c.csv" }?.folders, ["sub"])
        _ = await svc.download(l, files: l.files, isPrivate: false)
        let pkg = try XCTUnwrap(c.packages.package(withSource: l.source))
        for id in pkg.members { let r = await wait(id, for: [.completed, .failed]); XCTAssertEqual(r?.state, .completed) }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(find(downloads, "c.csv"))), Data(repeating: 0, count: 0) + Data(String(repeating: "c,", count: 150).utf8))
        do { _ = try await svc.listing(for: .cloud(try XCTUnwrap(CloudStorageProvider.parse(URL(string: fx.service + "/locked")!)))); XCTFail() } catch { XCTAssertEqual((error as? ProviderError)?.localizedDescription.contains("does not allow listing"), true) }
    }

    func testAzureContainerWithSASListsAndDownloadsAndTheSecretIsNeverShown() async throws {
        let sas = [URLQueryItem(name: "sv", value: "2022-11-02"), URLQueryItem(name: "sig", value: "good"), URLQueryItem(name: "se", value: "2099-01-01T00:00:00Z")]
        let t = CloudStorageProvider.Target(flavor: .azure(container: "box"), base: URL(string: fx.service + "/acct/box")!, prefix: "", sas: sas)
        let l = try await svc.listing(for: .cloud(t)); XCTAssertEqual(l.files.map(\.relativePath).sorted(), ["dir/two.txt", "one.txt"])
        _ = await svc.download(l, files: l.files, isPrivate: false)
        for id in try XCTUnwrap(c.packages.package(withSource: l.source)).members { let r = await wait(id, for: [.completed, .failed]); XCTAssertEqual(r?.state, .completed, r?.failure?.reason ?? "") }
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(find(downloads, "two.txt")), encoding: .utf8), "azure two\n")
        let shown = SignedURL.redacted(l.files[0].url); XCTAssertFalse(shown.contains("good")); XCTAssertTrue(shown.contains("sig=***"), shown)
        let bad = CloudStorageProvider.Target(flavor: .azure(container: "box"), base: t.base, prefix: "", sas: [URLQueryItem(name: "sig", value: "wrong")])
        do { _ = try await svc.listing(for: .cloud(bad)); XCTFail() } catch { XCTAssertTrue(error is ProviderError) }
    }

    func testSignedLinksReportExpiryAndAnExpiredOneIsNeverStarted() async throws {
        let expired = URL(string: "https://h.example/f.bin?X-Amz-Signature=abc&X-Amz-Date=20200101T000000Z&X-Amz-Expires=60")!
        XCTAssertEqual(SignedURL.expiry(expired), ISO8601DateFormatter().date(from: "2020-01-01T00:01:00Z")); XCTAssertTrue(SignedURL.isExpired(expired))
        let live = URL(string: "https://h.example/f.bin?X-Amz-Signature=abc&X-Amz-Date=20990101T000000Z&X-Amz-Expires=3600")!; XCTAssertFalse(SignedURL.isExpired(live))
        XCTAssertNotNil(SignedURL.expiry(URL(string: "https://a.blob.core.windows.net/c/b?sv=1&sig=x&se=2020-02-02T00:00:00Z")!)); XCTAssertNil(SignedURL.expiry(URL(string: "https://h.example/plain.zip")!))
        do { _ = try await svc.listing(for: .signedFile(expired)); XCTFail() } catch { XCTAssertEqual(error as? ProviderError, .expiredLink); XCTAssertTrue(error.localizedDescription.contains("not retried")) }
        let l = try await svc.listing(for: .signedFile(live))
        XCTAssertFalse(l.notices.joined().contains("abc")); XCTAssertEqual(l.files.count, 1)
        let stale = ProviderListing(title: "t", source: "signed:x", files: [ProviderFile(id: "s", name: "f.bin", url: expired, kind: .object)])
        let out = await svc.download(stale, files: stale.files, isPrivate: false); XCTAssertEqual(out.started, 0); XCTAssertEqual(out.failedToStart, 1, "an expired address is reported, not retried")
        XCTAssertEqual(c.ledger.records.values.filter { $0.source.asURL?.host == "h.example" }.count, 0, "and no task was made for it")
    }

    // MARK: Security

    func testRedirectsDropCredentialsAcrossOriginsAndRefuseDowngradesAndPaginationNeverLeavesTheService() throws {
        var req = URLRequest(url: URL(string: "https://cdn.example/x")!); req.setValue("Bearer secret", forHTTPHeaderField: "Authorization"); req.setValue("a=b", forHTTPHeaderField: "Cookie")
        let same = URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://api.example/a")!, to: URL(string: "https://api.example/b")!, request: req, check: { _ in })
        XCTAssertEqual(same?.value(forHTTPHeaderField: "Authorization"), "Bearer secret", "the same origin keeps it")
        let other = URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://api.example/a")!, to: URL(string: "https://cdn.example/b")!, request: req, check: { _ in })
        XCTAssertNotNil(other); XCTAssertNil(other?.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(other?.value(forHTTPHeaderField: "Cookie"))
        let otherPort = URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://api.example/a")!, to: URL(string: "https://api.example:8443/b")!, request: req, check: { _ in })
        XCTAssertNil(otherPort?.value(forHTTPHeaderField: "Authorization"), "another port is another origin")
        XCTAssertNil(URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://api.example/a")!, to: URL(string: "http://api.example/b")!, request: req, check: { _ in }), "https to http is refused")
        XCTAssertNil(URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://api.example/a")!, to: URL(string: "file:///etc/passwd")!, request: req, check: { _ in }))
        struct Refused: Error {}
        XCTAssertNil(URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://api.example/a")!, to: URL(string: "https://10.0.0.1/b")!, request: req, check: { _ in throw Refused() }), "the network policy applies to every hop")
        let ep = URL(string: "https://huggingface.co")!, base = URL(string: "https://huggingface.co/api/models/o/m/tree/abc")!
        XCTAssertEqual(HuggingFaceProvider.nextLink("<https://huggingface.co/api/x?cursor=2>; rel=\"next\"", base: base, sameOriginAs: ep)?.absoluteString, "https://huggingface.co/api/x?cursor=2")
        XCTAssertNil(HuggingFaceProvider.nextLink("<https://evil.example/steal?cursor=2>; rel=\"next\"", base: base, sameOriginAs: ep), "a pagination link to another host is never followed")
    }

    func testHostileNamesFromAServiceCannotEscapeTheCollectionFolder() throws {
        let p = HuggingFaceProvider(transport: URLSessionProviderTransport(authorization: { _ in nil }))
        let t = HuggingFaceProvider.Target(kind: .model, repo: "o/m", revision: "main", path: "", isFile: false)
        func entry(_ path: String) -> HuggingFaceProvider.Entry { try! JSONDecoder().decode(HuggingFaceProvider.Entry.self, from: Data("{\"type\":\"file\",\"path\":\(String(decoding: try! JSONEncoder().encode(path), as: UTF8.self)),\"size\":1}".utf8)) }
        for bad in ["../../etc/passwd", "a/../../b", "./x", "a//b", "/abs", ""] { XCTAssertNil(p.makeFile(entry(bad), t, commit: String(repeating: "a", count: 40), isPrivate: false, gated: false), bad) }
        let ok = try XCTUnwrap(p.makeFile(entry("dir/na:me?.bin"), t, commit: String(repeating: "a", count: 40), isPrivate: false, gated: false))
        XCTAssertFalse(ok.name.contains("/")); XCTAssertEqual(ok.url.host, "huggingface.co"); XCTAssertTrue(ok.url.absoluteString.contains("na%3Ame%3F.bin"), "special characters are encoded in the address")
        XCTAssertEqual(ProviderNames.safe("../../x.bin"), "x.bin"); XCTAssertEqual(ProviderNames.safe(".."), "download")
    }

    func testPrivateTabsAndUnknownAddressesNeverReachTheNetwork() async throws {
        let model = ProviderSheetModel(coordinator: c, service: svc); model.isPrivate = true
        model.open(address: gh("/o/r").absoluteString)
        if case .failed(let why) = model.phase { XCTAssertTrue(why.contains("private tab")) } else { XCTFail("\(model.phase)") }
        let seen = await fx.log(); XCTAssertTrue(seen.isEmpty, "nothing was requested")
        model.isPrivate = false; model.open(address: "https://example.com/not/a/repo")
        if case .failed(let why) = model.phase { XCTAssertTrue(why.contains("not one this feature understands")) } else { XCTFail() }
        let still = await fx.log(); XCTAssertTrue(still.isEmpty)
        XCTAssertEqual(c.packages.package(withSource: "github:o/r"), nil)
    }

    func testHostileNumbersFromAServiceCannotCrashOrDefeatTheSpaceCheck() async throws {
        for bad in ["inf", "nan", "1e999", "-5"] {
            let r = ProviderResponse(status: 429, headers: ["retry-after": bad], body: Data(), finalURL: URL(string: "https://x.example")!)
            do { try ProviderStatus.check(r, host: "x.example", hadToken: false); XCTFail() } catch let e as ProviderError { XCTAssertFalse((e.errorDescription ?? "").isEmpty, bad) }
        }
        let reset = ProviderResponse(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "inf"], body: Data(), finalURL: URL(string: "https://x.example")!)
        XCTAssertThrowsError(try ProviderStatus.check(reset, host: "x", hadToken: false))
        XCTAssertEqual(ProviderError.wait(.infinity), "1440 minutes"); XCTAssertEqual(ProviderError.wait(-3), "0 seconds")
        XCTAssertEqual(ProviderNames.size(-5), 0); XCTAssertEqual(ProviderNames.size(Int64.max), 1 << 50)
        let huge = (0..<5000).map { ProviderFile(id: "\($0)", name: "f", size: ProviderNames.size(Int64.max), url: URL(string: "https://h.example/f")!) }
        XCTAssertGreaterThan(ProviderNames.sum(huge), 0, "thousands of absurd sizes add up without overflowing")
        XCTAssertThrowsError(try svc.checkSpace(huge))
    }

    func testBranchNamesWithSlashesAreNotGuessedAndDotSegmentsAreRefused() {
        XCTAssertNil(GitHubProvider.parse(URL(string: "https://github.com/o/r/tree/feature/login")!), "where the branch name ends is not in the address")
        XCTAssertEqual(GitHubProvider.parse(URL(string: "https://github.com/o/r/tree/main")!), .source(owner: "o", repo: "r", ref: "main"))
        XCTAssertNil(GitHubProvider.parse(URL(string: "https://github.com/o/r/releases/tag/..%2F..%2Fuser")!))
        XCTAssertNil(GitHubProvider.parse(URL(string: "https://github.com/o/r/releases/download/v1/../x")!))
    }

    func testQueryValuesWithPlusAndSlashSurviveInListingContinuationTokens() {
        XCTAssertEqual(CloudStorageProvider.enc("a+b/c=="), "a%2Bb%2Fc%3D%3D", "a + is never read back as a space")
    }

    func testRedirectFromAPublicAddressToThisComputerIsRefusedButATypedLocalAddressMayStayLocal() {
        let req = URLRequest(url: URL(string: "https://x.example/b")!)
        XCTAssertNil(URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://x.example/a")!, to: URL(string: "https://127.0.0.1/b")!, request: req, check: { _ in }), "public to local is refused")
        XCTAssertNil(URLSessionProviderTransport.Delegate.redirect(from: URL(string: "https://x.example/a")!, to: URL(string: "https://192.168.1.5/b")!, request: req, check: { _ in }))
        XCTAssertNotNil(URLSessionProviderTransport.Delegate.redirect(from: URL(string: "http://127.0.0.1:9/a")!, to: URL(string: "http://127.0.0.1:10/b")!, request: req, check: { _ in }), "a local service may send to its own storage")
    }

    func testNotEnoughDiskSpaceStopsBeforeAnythingStarts() throws {
        let huge = ProviderFile(id: "h", name: "huge.bin", size: Int64.max / 4, url: URL(string: "https://h.example/huge.bin")!)
        XCTAssertThrowsError(try svc.checkSpace([huge])) { e in if case ProviderError.notEnoughSpace = e {} else { XCTFail("\(e)") } }
        XCTAssertNoThrow(try svc.checkSpace([ProviderFile(id: "s", name: "s", size: 10, url: URL(string: "https://h.example/s")!)]))
    }
}
