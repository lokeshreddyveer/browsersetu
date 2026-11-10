import XCTest
import SwiftUI
@testable import Browser_Setu

/// Renders the popover and the inspector with sample tasks to PNG files, so the layout can be looked at. Writes only when DOWNLOADS_RENDER_DIR names a folder.
@MainActor
final class DownloadsRenderTests: XCTestCase {
    func testRenderPopoverAndInspector() throws {
        guard let dir = ProcessInfo.processInfo.environment["DOWNLOADS_RENDER_DIR"] else { throw XCTSkip("no render folder") }
        let c = DownloadCoordinator()
        func add(_ name: String, _ events: [DownloadEvent], total: Int64? = nil, done: Int64 = 0, url: String = "https://files.example.com/a/\(UUID().uuidString.prefix(3)).bin") {
            let r = c.ledger.create(protocolID: .http, source: URL(string: url), filename: name, isPrivate: false)
            for e in events { _ = c.ledger.apply(e, to: r.id) }
            c.ledger.update(r.id) { $0.transfer.totalBytes = total; $0.transfer.completedBytes = done }
        }
        add("Example-video-with-a-rather-long-file-name-that-must-truncate.mp4", [.queued, .started, .running], total: 1_400_000_000, done: 600_000_000)
        add("Archive.zip", [.queued])
        add("Report.pdf", [.queued, .started, .running, .verifying, .completed(.verified)], total: 12_000_000, done: 12_000_000)
        add("broken.iso", [.queued, .started, .failed(DownloadFailureInfo(code: "http-404", reason: "x", retryable: true))])
        add("half.dmg", [.queued, .started, .running, .paused(resumeAvailable: true)], total: 900_000_000, done: 300_000_000)
        let vm = DownloadsViewModel(coordinator: c, defaults: nil)
        vm.refreshNow()
        for scheme in [ColorScheme.light, .dark] {
            try render(DownloadsPopover(vm: vm) {}.background(Color(nsColor: .windowBackgroundColor)), scheme, "\(dir)/popover-\(scheme).png")
            vm.selection = [vm.rows.first { $0.status == .failed }!.id]
            try render(DownloadInspector(vm: vm).content.frame(width: 290, height: 520).background(Color(nsColor: .windowBackgroundColor)), scheme, "\(dir)/inspector-failed-\(scheme).png")
            vm.selection = [vm.rows.first { $0.status == .downloading }!.id]
            try render(DownloadInspector(vm: vm).content.frame(width: 290, height: 520).background(Color(nsColor: .windowBackgroundColor)), scheme, "\(dir)/inspector-active-\(scheme).png")
            vm.selection = Set(vm.rows.prefix(3).map(\.id))
            try render(DownloadInspector(vm: vm).content.frame(width: 290, height: 260).background(Color(nsColor: .windowBackgroundColor)), scheme, "\(dir)/inspector-multi-\(scheme).png")
            try render(VStack(spacing: 0) { ForEach(vm.rows) { DownloadNameCell(row: $0).padding(.horizontal, 10).frame(width: 420, alignment: .leading); Divider() } }
                .background(Color(nsColor: .windowBackgroundColor)), scheme, "\(dir)/rows-\(scheme).png")
        }
    }

    private func render<V: View>(_ view: V, _ scheme: ColorScheme, _ path: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).fixedSize(horizontal: false, vertical: true))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no image for \(path)") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
