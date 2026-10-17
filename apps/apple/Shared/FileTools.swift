import QuickLook
import SwiftUI

extension BrowserModel {
    /// Saves the page in front as a PDF in Downloads, or says why it could not.
    func savePageAsPDF() async {
        guard let tab = active, !tab.isBlank else { return }
        guard !tab.isPrivate else { notice = "Pages from private tabs are not saved to disk."; return }
        guard let data = await tab.engine.pagePDF(), !data.isEmpty else { notice = "This page could not be saved as a PDF."; return }
        save(data, name: fileName(for: tab) + ".pdf", folder: nil, message: "Saved the page as a PDF")
    }

    /// Takes a picture of the page: what is on screen, or the whole page from top to bottom. Saved to Downloads › Screenshots.
    func takeScreenshot(fullPage: Bool) async {
        guard let tab = active, !tab.isBlank else { return }
        guard !tab.isPrivate else { notice = "Pictures of private tabs are not saved to disk."; return }
        guard let data = await tab.engine.screenshot(fullPage: fullPage), !data.isEmpty else { notice = "A picture of this page could not be taken."; return }
        save(data, name: fileName(for: tab) + (fullPage ? " (full page)" : "") + ".png", folder: "Screenshots",
             message: fullPage ? "Saved a full-page screenshot" : "Saved a screenshot")
    }

    private func fileName(for tab: TabController) -> String {
        let cleaned = tab.displayTitle.replacingOccurrences(of: "[/\\:\\n\\r]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-")))
        let name = String(cleaned.prefix(80))
        return name.isEmpty ? (displayHost(tab.url).isEmpty ? "Page" : displayHost(tab.url)) : name
    }

    private func save(_ data: Data, name: String, folder: String?, message: String) {
        var directory = DownloadCoordinator.directory
        if let folder { directory = directory.appendingPathComponent(folder, isDirectory: true) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = DownloadCoordinator.uniqueURL(in: directory, name: name)
            try data.write(to: target, options: .atomic)
            try? core.recordDownload(url: active?.url?.absoluteString ?? "", filename: target.lastPathComponent)
            notice = "\(message): \(target.lastPathComponent)."
        } catch {
            notice = "That could not be saved. \(error.localizedDescription)"
        }
    }
}

/// A finished download: preview it, share it, or show it in Finder.
struct DownloadFileActions: View {
    let url: URL
    @State private var preview: URL?

    var body: some View {
        HStack(spacing: 6) {
            Button { preview = url } label: { Image(systemName: "eye") }.help("Preview")
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.help("Share")
            #if os(macOS)
            Button { revealInSystem(url) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder")
            #endif
        }
        .buttonStyle(.borderless)
        .quickLookPreview($preview)
    }
}
