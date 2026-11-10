import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Safe writing, splitting, pictures-to-PDF and reordering, added to the existing page operations in PDFEdit.swift. Nothing here ever changes the file a document was opened from.

extension PDFEdit {
    /// Writes the document as a new file the safe way: to a temporary file beside it, which is opened again and checked (same number of pages, every page has a size, and the
    /// optional `validate`), and only then moved into place. A target that already exists is replaced in one step and a failure leaves it exactly as it was; no temporary file is left.
    /// With a password the copy is written protected, and the check unlocks it with that password.
    @discardableResult
    static func writeValidated(_ document: PDFDocument, to target: URL, password: String? = nil, validate: ((PDFDocument) -> Bool)? = nil) -> Bool {
        guard document.pageCount > 0 else { return false }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).writing.pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        let written = password.map { writeProtected(document, to: temp, password: $0) } ?? document.write(to: temp)
        guard written, let reopened = PDFDocument(url: temp) else { return false }
        if reopened.isLocked { guard let password, reopened.unlock(withPassword: password) else { return false } }
        guard reopened.pageCount == document.pageCount else { return false }
        for i in 0..<reopened.pageCount { guard let page = reopened.page(at: i), page.bounds(for: .mediaBox).width > 0, page.bounds(for: .mediaBox).height > 0 else { return false } }
        if let validate, !validate(reopened) { return false }
        do {
            if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temp) }
            else { try FileManager.default.moveItem(at: temp, to: target) }
            return true
        } catch { return false }
    }

    // MARK: Split

    /// Documents made of the given page ranges (1-based, inclusive). A range outside the document is skipped.
    static func split(_ document: PDFDocument, ranges: [ClosedRange<Int>]) -> [PDFDocument] {
        ranges.compactMap { extract(document, from: $0.lowerBound, to: $0.upperBound) }
    }

    /// Documents of `count` pages each (the last may be shorter).
    static func split(_ document: PDFDocument, everyPages count: Int) -> [PDFDocument] {
        guard count >= 1, document.pageCount > 0 else { return [] }
        let ranges = stride(from: 1, through: document.pageCount, by: count).map { $0...min($0 + count - 1, document.pageCount) }
        return split(document, ranges: ranges)
    }

    /// The pages split at the pages in `after` (1-based): a split after page 3 makes 1-3 and 4-end.
    static func split(_ document: PDFDocument, after pages: [Int]) -> [PDFDocument] {
        let cuts = Set(pages.filter { $0 >= 1 && $0 < document.pageCount }).sorted()
        var start = 1
        var ranges: [ClosedRange<Int>] = []
        for cut in cuts { ranges.append(start...cut); start = cut + 1 }
        ranges.append(start...document.pageCount)
        return split(document, ranges: ranges)
    }

    /// Writes each part beside the source, named "<name> part 1.pdf", each through `writeValidated`. Returns the files written; stops at the first failure.
    static func writeParts(_ parts: [PDFDocument], beside source: URL) -> [URL] {
        var written: [URL] = []
        for (index, part) in parts.enumerated() {
            let target = copyURL(for: source, suffix: "part \(index + 1)")
            guard writeValidated(part, to: target) else { return written }
            written.append(target)
        }
        return written
    }

    // MARK: Order

    static func pages(of document: PDFDocument) -> [PDFPage] { (0..<document.pageCount).compactMap { document.page(at: $0) } }

    /// Puts the pages in `order` (the same pages, in a new sequence). Refused if it is not the same set of pages.
    @discardableResult
    static func setOrder(_ order: [PDFPage], in document: PDFDocument) -> Bool {
        let current = pages(of: document)
        guard order.count == current.count, Set(order.map(ObjectIdentifier.init)) == Set(current.map(ObjectIdentifier.init)) else { return false }
        for _ in 0..<document.pageCount { document.removePage(at: 0) }
        for (index, page) in order.enumerated() { document.insert(page, at: index) }
        return true
    }

    // MARK: Pictures

    /// A picture read from a file at a sensible size (the longest side at most `maxDimension` pixels), turned the right way up.
    static func loadImage(_ url: URL, maxDimension: Int = 3000) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxDimension]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// One page per picture, each page the size of its picture (at 72 pixels to the inch, no larger than 842 points on its longest side).
    static func imagesToPDF(_ images: [CGImage]) -> PDFDocument? {
        let document = PDFDocument()
        for image in images {
            let scale = min(1, 842.0 / CGFloat(max(image.width, image.height)))
            let size = CGSize(width: max(1, CGFloat(image.width) * scale), height: max(1, CGFloat(image.height) * scale))
            let data = NSMutableData()
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
            context.closePDF()
            guard let single = PDFDocument(data: data as Data), let page = single.page(at: 0) else { return nil }
            document.insert(page, at: document.pageCount)
        }
        return document.pageCount > 0 ? document : nil
    }

    static func imagesToPDF(urls: [URL]) -> PDFDocument? {
        let images = urls.prefix(100).compactMap { loadImage($0) }
        guard !images.isEmpty, images.count == min(urls.count, 100) else { return nil }
        return imagesToPDF(images)
    }
}

extension PDFEditorSession {
    /// Page changes that can be taken back with Undo: the pages as they were are remembered, and put back.
    func reorder(to order: [PDFPage]) -> Bool {
        guard let document else { return false }
        let before = PDFEdit.pages(of: document)
        guard PDFEdit.setOrder(order, in: document) else { return false }
        view.document = document; changes += 1
        pushUndo { [weak self] in if let document = self?.document { PDFEdit.setOrder(before, in: document); self?.view.document = document } }
        return true
    }

    func rotate(_ pages: [PDFPage], by degrees: Int) {
        guard let document, !pages.isEmpty else { return }
        let before = pages.map { ($0, $0.rotation) }
        for page in pages { page.rotation = ((page.rotation + degrees) % 360 + 360) % 360 }
        view.document = document; changes += 1
        pushUndo { [weak self] in for (page, rotation) in before { page.rotation = rotation }; if let document = self?.document { self?.view.document = document } }
    }

    /// Removes pages (never all of them). Undo puts them back where they were.
    @discardableResult
    func remove(_ pages: [PDFPage]) -> Int {
        guard let document else { return 0 }
        let all = PDFEdit.pages(of: document)
        let indexes = pages.compactMap { page in all.firstIndex { $0 === page } }
        guard !indexes.isEmpty, indexes.count < all.count else { return 0 }
        let removed = indexes.sorted().map { ($0, all[$0]) }
        for index in indexes.sorted(by: >) { document.removePage(at: index) }
        view.document = document; changes += 1
        pushUndo { [weak self] in
            guard let document = self?.document else { return }
            for (index, page) in removed { document.insert(page, at: min(index, document.pageCount)) }
            self?.view.document = document
        }
        return indexes.count
    }

    /// Adds pictures as pages at the end. Undo takes them out.
    func appendPictures(_ urls: [URL]) -> Int {
        guard let document, let pictures = PDFEdit.imagesToPDF(urls: urls) else { return 0 }
        let added = PDFEdit.pages(of: pictures)
        for page in added { document.insert(page, at: document.pageCount) }
        view.document = document; changes += 1
        pushUndo { [weak self] in
            guard let document = self?.document else { return }
            for page in added { let all = PDFEdit.pages(of: document); if let i = all.firstIndex(where: { $0 === page }) { document.removePage(at: i) } }
            self?.view.document = document
        }
        return added.count
    }
}

/// Pages as a list of thumbnails: drag to reorder (the Mac; on the iPhone the list is in edit mode, with handles and check marks), select several, and rotate, remove, extract or split.
struct PDFPageOrganizer: View {
    @ObservedObject var session: PDFEditorSession
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    @State private var selection = Set<ObjectIdentifier>()
    @State private var splitEvery = 1
    @State private var splitting = false

    struct Item: Identifiable { let page: PDFPage; var id: ObjectIdentifier { ObjectIdentifier(page) } }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        thumbnail(item.page)
                        VStack(alignment: .leading) { Text("Page \(index + 1)").fontWeight(.medium); if item.page.rotation != 0 { Text("Turned \(item.page.rotation)°").font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                    }
                    .padding(.vertical, 4).frame(minHeight: 56)
                    .contextMenu { rowActions(item) }
                    #if os(iOS)
                    .swipeActions(edge: .trailing) { Button(role: .destructive) { remove([item.page]) } label: { Label("Delete", systemImage: "trash") } }
                    .swipeActions(edge: .leading) { Button { rotate([item.page], 90) } label: { Label("Rotate", systemImage: "rotate.right") }.tint(.blue) }
                    #endif
                }
                .onMove { from, to in
                    var next = items; next.move(fromOffsets: from, toOffset: to)
                    if session.reorder(to: next.map(\.page)) { items = next } else { reload() }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            Divider()
            actionBar
        }
        .frame(minWidth: 380, minHeight: 440)
        .onAppear(perform: reload)
        .confirmationDialog("Split into parts", isPresented: $splitting, titleVisibility: .visible) {
            Button("After the selected page\(selection.count == 1 ? "" : "s")") { splitAtSelection() }.disabled(selection.isEmpty)
            Button("Every page is its own file") { split(every: 1) }
            Button("Every 2 pages") { split(every: 2) }
            Button("Every 5 pages") { split(every: 5) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Each part is saved as a new file beside this one. This file is not changed.") }
    }

    private var actionBar: some View {
        HStack {
            Button { rotate(selectedPages, -90) } label: { Label("Left", systemImage: "rotate.left") }.disabled(selection.isEmpty)
            Button { rotate(selectedPages, 90) } label: { Label("Right", systemImage: "rotate.right") }.disabled(selection.isEmpty)
            Button(role: .destructive) { remove(selectedPages) } label: { Label("Delete", systemImage: "trash") }.disabled(selection.isEmpty)
            Button { extract() } label: { Label("Extract", systemImage: "square.and.arrow.up.on.square") }.disabled(selection.isEmpty)
            Button { splitting = true } label: { Label("Split", systemImage: "scissors") }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .labelStyle(.titleAndIcon).buttonStyle(.bordered).padding(10)
    }

    private var selectedPages: [PDFPage] { items.filter { selection.contains($0.id) }.map(\.page) }

    @ViewBuilder private func rowActions(_ item: Item) -> some View {
        Button("Rotate Right") { rotate([item.page], 90) }
        Button("Rotate Left") { rotate([item.page], -90) }
        Button("Delete", role: .destructive) { remove([item.page]) }
    }

    private func thumbnail(_ page: PDFPage) -> some View {
        let image = page.thumbnail(of: CGSize(width: 72, height: 96), for: .mediaBox)
        return Image(platform: image).resizable().scaledToFit().frame(width: 52, height: 68).background(Color.white).overlay(Rectangle().stroke(Color.primary.opacity(0.2)))
    }

    private func reload() { if let document = session.document { items = PDFEdit.pages(of: document).map(Item.init) } }

    private func rotate(_ pages: [PDFPage], _ degrees: Int) { session.rotate(pages, by: degrees); reload() }

    private func remove(_ pages: [PDFPage]) {
        if session.remove(pages) == 0 { model.notice = "A PDF keeps at least one page." }
        selection = []; reload()
    }

    private func extract() {
        guard let document = session.document else { return }
        let all = PDFEdit.pages(of: document)
        let numbers = selectedPages.compactMap { page in all.firstIndex { $0 === page }.map { $0 + 1 } }.sorted()
        let out = PDFDocument()
        for n in numbers { if let copy = document.page(at: n - 1)?.copy() as? PDFPage { out.insert(copy, at: out.pageCount) } }
        let target = PDFEdit.copyURL(for: session.source, suffix: "extract")
        model.notice = PDFEdit.writeValidated(out, to: target) ? "Saved \(target.lastPathComponent)." : "The pages could not be saved."
    }

    private func split(every count: Int) {
        guard let document = session.document else { return }
        report(PDFEdit.writeParts(PDFEdit.split(document, everyPages: count), beside: session.source))
    }

    private func splitAtSelection() {
        guard let document = session.document else { return }
        let all = PDFEdit.pages(of: document)
        let cuts = selectedPages.compactMap { page in all.firstIndex { $0 === page }.map { $0 + 1 } }
        report(PDFEdit.writeParts(PDFEdit.split(document, after: cuts), beside: session.source))
    }

    private func report(_ files: [URL]) { model.notice = files.isEmpty ? "The parts could not be saved." : "Saved \(files.count) file\(files.count == 1 ? "" : "s") beside this one." }
}

/// Makes a PDF from pictures (a page per picture), saved beside nothing until it is checked, then opened in the editor.
struct PicturesToPDFView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var working = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Make a PDF from pictures").font(.headline)
            Text("Choose pictures in the order they should appear. Each becomes a page. They are read on this device; nothing is sent anywhere.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(working ? "Working…" : "Choose Pictures…") { picking = true }.disabled(working).buttonStyle(.borderedProminent)
            Button("Cancel") { dismiss() }
        }
        .padding(24).frame(minWidth: 360)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            working = true
            let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (url, ok) in scoped where ok { url.stopAccessingSecurityScopedResource() } }
            guard let pdf = PDFEdit.imagesToPDF(urls: urls) else { model.notice = "Those pictures could not be read."; working = false; return }
            let folder = DownloadCoordinator.directory.appendingPathComponent("Page Screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = DownloadCoordinator.uniqueURL(in: folder, name: "Pictures.pdf")
            if PDFEdit.writeValidated(pdf, to: target) { dismiss(); model.editPDF(at: target) } else { model.notice = "The PDF could not be saved."; working = false }
        }
    }
}
