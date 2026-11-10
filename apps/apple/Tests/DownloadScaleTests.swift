import XCTest
@testable import Browser_Setu

/// How the Downloads list behaves with a lot in it: thousands of finished records and hundreds of queued ones. Timings are printed so a regression is visible; the limits are generous (a slow CI machine must pass).
final class DownloadScaleTests: XCTestCase {
    private func records(finished: Int, queued: Int, folder: URL) -> [DownloadTaskRecord] {
        var out: [DownloadTaskRecord] = []
        for i in 0..<finished {
            var r = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: URL(string: "https://files.test/d/\(i).bin")), filename: "file-\(i).bin")
            r.state = .completed; r.completedAt = Date(timeIntervalSinceNow: -Double(i)); r.file.destinationPath = folder.appendingPathComponent("file-\(i).bin").path
            r.transfer = DownloadTransfer(totalBytes: 1000, completedBytes: 1000, resumeAvailable: false)
            out.append(r)
        }
        for i in 0..<queued {
            var r = DownloadTaskRecord(protocolID: .http, profile: "default", source: DownloadSourceRef(url: URL(string: "https://files.test/q/\(i).bin")), filename: "queued-\(i).bin")
            r.state = .queued; out.append(r)
        }
        return out
    }

    func testAThousandsLongHistoryAndHundredsQueuedBuildTheListQuickly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let all = records(finished: 5000, queued: 400, folder: folder)
        var stats = 0
        var snap = DownloadsSnapshot(records: all)
        snap.fileExists = { r in stats += 1; return FileManager.default.fileExists(atPath: r.file.destinationPath ?? "") }
        let start = Date()
        let rows = DownloadRowProjector.rows(from: snap)
        let took = Date().timeIntervalSince(start)
        print("SCALE rows(5400 records)=\(String(format: "%.3f", took)) s, rows=\(rows.count), fileExists calls=\(stats)")
        XCTAssertEqual(rows.count, 1000, "the list never grows past its bound")
        XCTAssertEqual(rows.filter { !$0.status.isOver }.count, 400, "every queued one is kept, history is what is cut")
        XCTAssertLessThan(took, 2.0)
    }
}
