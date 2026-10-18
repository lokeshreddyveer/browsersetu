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
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            Button { preview = url } label: { Image(systemName: "eye") }.help("Preview")
            if url.pathExtension.lowercased() == "pdf" { Button { model.editPDF(at: url) } label: { Image(systemName: "pencil.and.signature") }.help("Edit or sign this PDF") }
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.help("Share")
            Menu {
                Button("Copy SHA-256") { checksum { copyToPasteboard($0); model.notice = "SHA-256 copied." } }
                Button("Verify Checksum…") { verify() }
            } label: { Image(systemName: "checkmark.seal") }.menuStyle(.borderlessButton).fixedSize().help("Checksum")
            #if os(macOS)
            Button { revealInSystem(url) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder")
            #endif
        }
        .buttonStyle(.borderless)
        .quickLookPreview($preview)
    }

    private func checksum(_ done: @escaping @MainActor (String) -> Void) {
        let file = url
        Task {
            let hash = await Task.detached { try? FileChecksum.sha256(of: file) }.value
            if let hash { done(hash) } else { model.notice = "Could not read that file." }
        }
    }

    private func verify() {
        Task { @MainActor in
            guard let expected = await Dialogs.promptText(title: "Verify Checksum", message: "Paste the SHA-256 the website published for \(url.lastPathComponent).", placeholder: "SHA-256"), !expected.isEmpty else { return }
            checksum { actual in
                model.notice = FileChecksum.matches(expected, actual) ? "Checksum matches. The file is what the site published." : "Checksum does NOT match. Do not open this file."
            }
        }
    }
}


extension BrowserModel {
    /// Opens a PDF in the editor. The original is never changed: edits are saved as a copy beside it.
    func editPDF(at url: URL) {
        pdfEditorURL = url
        sheet = .pdfEditor
    }

    /// Edits the PDF the tab in front is showing: it is fetched as a download (with the page's own sign-in, through WebKit), then opened in the editor when it arrives.
    func editCurrentPDF() {
        guard let tab = active, !tab.isPrivate, let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { notice = "Open a PDF in a normal tab first."; return }
        guard url.pathExtension.lowercased() == "pdf" || tab.title.lowercased().hasSuffix(".pdf") else { notice = "This page is not a PDF."; return }
        pendingPDFEdits.insert(url.absoluteString)
        downloads.starter?(url)
        notice = "Fetching the PDF to edit…"
    }

    /// A download finished: if it was fetched for editing, the editor opens on it.
    func openFinishedPDFIfWanted(source: URL?, filename: String) {
        guard let source, pendingPDFEdits.remove(source.absoluteString) != nil, let file = DownloadCoordinator.locate(filename: filename) else { return }
        editPDF(at: file)
    }

    /// Any file you choose: a PDF opens in the editor, anything else in Apple's own previewer (Word, Excel, Pages, Numbers, Keynote, PowerPoint, text, pictures and more).
    func openDocument(_ url: URL) {
        if url.pathExtension.lowercased() == "pdf" { editPDF(at: url) } else { previewURL = url }
    }
}
