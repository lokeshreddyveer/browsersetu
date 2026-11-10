import Darwin
import XCTest
@testable import Browser_Setu

/// Measured, not asserted to a guess: what SFTP costs in time, memory, CPU, descriptors and processes (loopback, real OpenSSH). The printed PERF lines are the figures reported; the assertions are only generous safety bounds.
final class RemotePerformanceTests: XCTestCase {
    var server: SSHDFixture!
    override func setUpWithError() throws { server = try SSHDFixture() }
    override func tearDown() { server?.stop() }

    static func residentMB() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
    static func cpuSeconds() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
    /// What this process has open, one line per descriptor (type and name), from lsof: used to say exactly what is left behind.
    static func lsof() -> Set<String> {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); p.arguments = ["-n", "-P", "-p", String(getpid()), "-Ftn"]
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice; try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        var out = Set<String>(), cur = ""
        for l in String(decoding: d, as: UTF8.self).split(separator: "\n") { if l.hasPrefix("f") { if !cur.isEmpty { out.insert(cur) }; cur = String(l) } else { cur += " " + l } }
        if !cur.isEmpty { out.insert(cur) }
        return out
    }
    static func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
    final class Peak: @unchecked Sendable { var mb = 0.0; var stop = false }

    final class Counter: @unchecked Sendable { var n = 0, firstAt: Date?; let start = Date(); let l = NSLock(); func add(_ c: Int) { l.lock(); if firstAt == nil { firstAt = Date() }; n += c; l.unlock() } }

    func testDirectoryListingOfTwentyThousandEntriesAndALargeTransferWithConcurrentSessions() async throws {
        _ = try await server.trustHostKey()
        // 20,000 files in one folder.
        let big = server.tree.appendingPathComponent("many"); try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<20_000 { FileManager.default.createFile(atPath: big.appendingPathComponent("file-\(String(format: "%05d", i)).dat").path, contents: Data([1])) }
        let s = SFTPSession(config: server.config(key: server.clientKey)); defer { s.close() }
        try await s.connect()
        let fdBefore = Self.openDescriptors(), rssBefore = Self.residentMB(); let openBefore = Self.lsof()
        var baseStats = malloc_statistics_t(); malloc_zone_statistics(nil, &baseStats)
        let counter = Counter()
        let t0 = Date()
        let r = try await s.list(big.path, limit: 100_000) { counter.add($0.count) }
        let total = Date().timeIntervalSince(t0), first = counter.firstAt.map { $0.timeIntervalSince(t0) } ?? total
        print("PERF list 20000 entries: first batch \(String(format: "%.0f", first * 1000)) ms, all \(String(format: "%.0f", total * 1000)) ms, +\(String(format: "%.1f", Self.residentMB() - rssBefore)) MB resident")
        XCTAssertEqual(r.count, 20_000); XCTAssertLessThan(Self.residentMB() - rssBefore, 150)

        // One 200 MB file: throughput, CPU, memory (peak, sampled), descriptors.
        let file = server.tree.appendingPathComponent("large.bin"); let size = 200 * 1_048_576
        var chunk = Data(count: 1 << 20); chunk.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 7 &+ (i >> 5)) } }
        FileManager.default.createFile(atPath: file.path, contents: nil); let h = try FileHandle(forWritingTo: file); for _ in 0..<200 { try h.write(contentsOf: chunk) }; try h.close()
        let out = server.root.appendingPathComponent("large.out"); FileManager.default.createFile(atPath: out.path, contents: nil); let fd = open(out.path, O_WRONLY); defer { close(fd) }
        let peak = Peak(); let sampler = Task.detached { while !peak.stop { peak.mb = max(peak.mb, Self.residentMB()); try? await Task.sleep(nanoseconds: 20_000_000) } }
        let cpu0 = Self.cpuSeconds(), t1 = Date(), rss1 = Self.residentMB()
        let got = try await s.download(file.path, into: fd, from: 0, size: UInt64(size)) { _ in }
        let secs = Date().timeIntervalSince(t1), cpu = Self.cpuSeconds() - cpu0
        peak.stop = true; _ = await sampler.value
        print("PERF 200 MB transfer: \(String(format: "%.2f", secs)) s = \(String(format: "%.0f", 200 / secs)) MB/s, app CPU \(String(format: "%.2f", cpu)) s (\(String(format: "%.0f", cpu / secs * 100)) % of one core), peak resident +\(String(format: "%.1f", peak.mb - rss1)) MB")
        XCTAssertEqual(got, UInt64(size))
        var stats = malloc_statistics_t(); malloc_zone_statistics(nil, &stats)
        print("PERF malloc after the transfer: in use \(stats.size_in_use / 1_048_576) MB, held by the allocator \(stats.size_allocated / 1_048_576) MB")
        let afterTransfer = Self.residentMB(); let relieved = malloc_zone_pressure_relief(nil, 0); print("PERF allocator returned \(relieved / 1_048_576) MB to the system")
        print("PERF memory: peak +\(String(format: "%.0f", peak.mb - rss1)) MB during the transfer, \(String(format: "%.0f", afterTransfer - rss1)) MB after it, \(String(format: "%.0f", Self.residentMB() - rss1)) MB after the allocator gives back what it holds")
        XCTAssertLessThan(Int(stats.size_in_use) - Int(baseStats.size_in_use), 20 * 1_048_576, "after a 200 MB transfer the app has not kept the data")
        XCTAssertLessThan(peak.mb - rss1, 60, "a 200 MB file is streamed, never held in memory")
        s.close()

        // Eight sessions at once (what a folder download with the per-host limit raised could do), 40 MB each.
        var sessions: [SFTPSession] = []
        for _ in 0..<8 { let x = SFTPSession(config: server.config(key: server.clientKey)); try await x.connect(); sessions.append(x) }
        let rss2 = Self.residentMB(), cpu2 = Self.cpuSeconds(), t2 = Date()
        let part = 40 * 1_048_576
        try await withThrowingTaskGroup(of: UInt64.self) { group in
            for (i, x) in sessions.enumerated() {
                let o = server.root.appendingPathComponent("c\(i).out"); FileManager.default.createFile(atPath: o.path, contents: nil)
                group.addTask { let d = open(o.path, O_WRONLY); defer { close(d) }; return try await x.download(file.path, into: d, from: 0, size: UInt64(part)) { _ in } }
            }
            for try await n in group { XCTAssertEqual(n, UInt64(part)) }
        }
        let secs2 = Date().timeIntervalSince(t2)
        print("PERF 8 concurrent sessions x 40 MB: \(String(format: "%.2f", secs2)) s = \(String(format: "%.0f", 320 / secs2)) MB/s total, CPU \(String(format: "%.2f", Self.cpuSeconds() - cpu2)) s, resident +\(String(format: "%.1f", Self.residentMB() - rss2)) MB")
        sessions.forEach { $0.close() }
        try await Task.sleep(nanoseconds: 800_000_000)
        let fdAfter = Self.openDescriptors()
        let leftOpen = Self.lsof().subtracting(openBefore); print("PERF still open that was not before: \(leftOpen.sorted())")
        print("PERF cleanup: descriptors \(fdBefore) -> \(fdAfter), ssh processes left \(processLines(matching: "-p \(server.port)").count)")
        XCTAssertEqual(processLines(matching: "-p \(server.port)"), [], "every ssh process ended")
        XCTAssertLessThanOrEqual(fdAfter, fdBefore + 2, "no descriptor leak across many sessions")
    }
}
