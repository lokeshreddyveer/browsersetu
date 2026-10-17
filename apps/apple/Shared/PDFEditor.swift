import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Holds the document being edited, and turns points on the screen into points on a page.
@MainActor
final class PDFEditorSession: ObservableObject {
    let source: URL
    let view = PDFView()
    @Published var document: PDFDocument?
    @Published var locked = false
    @Published var changes = 0
    @Published var savedCopy: URL?
    private var undoStack: [() -> Void] = []
    func undoStackAppend(_ item: @escaping () -> Void) { undoStack.append(item) }
    var canUndo: Bool { !undoStack.isEmpty }

    init(source: URL) {
        self.source = source
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        load(password: nil)
    }

    func load(password: String?) {
        guard let doc = PDFDocument(url: source) else { document = nil; return }
        if doc.isLocked { if let password, doc.unlock(withPassword: password) { locked = false } else { locked = true; document = nil; return } }
        locked = false
        document = doc; view.document = doc
        changes = 0; undoStack = []
    }

    func revert() { load(password: nil); if locked { return }; savedCopy = nil }

    /// A mark was added: it can be taken back with Undo.
    func added(_ annotation: PDFAnnotation?, on page: PDFPage) {
        guard let annotation else { return }
        changes += 1
        undoStack.append { [weak self] in page.removeAnnotation(annotation); self?.changes -= 1 }
        view.setNeedsDisplay(view.bounds)
    }

    func undo() { undoStack.popLast()?(); view.setNeedsDisplay(view.bounds) }

    /// A point in the overlay (top-left origin) as a page and a point on it.
    func locate(_ point: CGPoint) -> (page: PDFPage, point: CGPoint)? {
        #if os(macOS)
        let p = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
        #else
        let p = point
        #endif
        guard let page = view.page(for: p, nearest: true) else { return nil }
        return (page, view.convert(p, to: page))
    }

    func rect(from a: CGPoint, to b: CGPoint) -> (page: PDFPage, rect: CGRect)? {
        guard let first = locate(a), let second = locate(b), first.page === second.page else { return nil }
        return (first.page, CGRect(x: min(first.point.x, second.point.x), y: min(first.point.y, second.point.y), width: abs(first.point.x - second.point.x), height: abs(first.point.y - second.point.y)))
    }

    var currentPageIndex: Int { view.currentPage.flatMap { document?.index(for: $0) } ?? 0 }

    func saveCopy(suffix: String = "edited") -> URL? {
        guard let document else { return nil }
        let target = PDFEdit.copyURL(for: source, suffix: suffix)
        guard document.write(to: target) else { return nil }
        savedCopy = target
        return target
    }
}

struct PDFKitRepresentable: ViewRepresentableBase {
    let view: PDFView
    #if os(macOS)
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
    #else
    func makeUIView(context: Context) -> PDFView { view }
    func updateUIView(_ uiView: PDFView, context: Context) {}
    #endif
}

struct PDFThumbnails: ViewRepresentableBase {
    let pdfView: PDFView
    #if os(macOS)
    func makeNSView(context: Context) -> PDFThumbnailView { let t = PDFThumbnailView(); t.pdfView = pdfView; t.thumbnailSize = CGSize(width: 70, height: 90); return t }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {}
    #else
    func makeUIView(context: Context) -> PDFThumbnailView { let t = PDFThumbnailView(); t.pdfView = pdfView; t.thumbnailSize = CGSize(width: 70, height: 90); return t }
    func updateUIView(_ uiView: PDFThumbnailView, context: Context) {}
    #endif
}

#if os(macOS)
typealias ViewRepresentableBase = NSViewRepresentable
#else
typealias ViewRepresentableBase = UIViewRepresentable
#endif

enum PDFTool: String, CaseIterable, Identifiable {
    case browse = "Read", pen = "Pen", text = "Text", rectangle = "Box", oval = "Oval", sign = "Sign", redact = "Redact"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .browse: "hand.point.up.left"; case .pen: "pencil.tip"; case .text: "textformat"; case .rectangle: "rectangle"; case .oval: "circle"; case .sign: "signature"; case .redact: "rectangle.fill" }
    }
    /// The tools that take a mouse or finger drag over the page.
    var drawsOnPage: Bool { self != .browse }
}

struct PDFEditorView: View {
    @EnvironmentObject var model: BrowserModel
    @StateObject private var session: PDFEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var tool = PDFTool.browse
    @State private var drag: (start: CGPoint, now: CGPoint, trail: [CGPoint])?
    @State private var showPages = false
    @State private var askText = false
    @State private var textDraft = ""
    @State private var textPoint: CGPoint?
    @State private var signing = false
    @State private var signature: PDFEdit.Signature?
    @State private var signaturePicture: CGImage?
    @State private var merging = false
    @State private var protecting = false
    @State private var passwordDraft = ""
    @State private var extracting = false
    @State private var rangeDraft = ""
    @State private var redactions: [(page: PDFPage, rect: CGRect)] = []
    @State private var markColor = Color.yellow

    init(source: URL) { _session = StateObject(wrappedValue: PDFEditorSession(source: source)) }

    var body: some View {
        VStack(spacing: 0) {
            if session.locked { lockedView }
            else if session.document == nil { Text("This file could not be opened as a PDF.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { editor }
        }
        .frame(minWidth: 640, minHeight: 560)
        .sheet(isPresented: $signing) { SignatureSheet { picked, picture in signature = picked; signaturePicture = picture; tool = .sign } }
        .fileImporter(isPresented: $merging, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result, let doc = session.document else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let other = PDFDocument(url: url), !other.isLocked { PDFEdit.append(other, to: doc); session.changes += 1; model.notice = "Added \(other.pageCount) page\(other.pageCount == 1 ? "" : "s")." }
            else { model.notice = "That PDF could not be added (it may need a password)." }
        }
        .alert("Text", isPresented: $askText) {
            TextField("Type here", text: $textDraft)
            Button("Add") { if let p = textPoint, let spot = session.locate(p) { session.added(PDFEdit.addText(textDraft, on: spot.page, at: spot.point, color: .black), on: spot.page) }; textDraft = "" }
            Button("Cancel", role: .cancel) { textDraft = "" }
        }
        .alert("Extract pages", isPresented: $extracting) {
            TextField("Pages, such as 1-3, 5", text: $rangeDraft)
            Button("Save a New PDF") { extractPages() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The pages you name are saved as a new file beside this one.") }
        .alert("Password for the copy", isPresented: $protecting) {
            SecureField("Password", text: $passwordDraft)
            Button("Save Protected Copy") { saveProtected() }
            Button("Cancel", role: .cancel) { passwordDraft = "" }
        } message: { Text("The copy asks for this password to open. There is no way to recover it if it is forgotten.") }
    }

    private var lockedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc").font(.largeTitle).foregroundStyle(.secondary)
            Text("This PDF needs a password.")
            SecureField("Password", text: $passwordDraft).textFieldStyle(.roundedBorder).frame(maxWidth: 260).onSubmit { session.load(password: passwordDraft); passwordDraft = "" }
            Button("Open") { session.load(password: passwordDraft); passwordDraft = "" }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if showPages { PDFThumbnails(pdfView: session.view).frame(width: 96); Divider() }
                ZStack {
                    PDFKitRepresentable(view: session.view)
                    if tool.drawsOnPage { overlay }
                }
            }
            Divider()
            bottomBar
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PDFTool.allCases) { t in
                    Button { pick(t) } label: { Label(t.rawValue, systemImage: t.symbol).labelStyle(.titleAndIcon) }
                        .buttonStyle(.bordered).tint(tool == t ? .accentColor : .secondary)
                }
                Divider().frame(height: 20)
                Menu("Mark Selection") {
                    Button("Highlight") { mark(.highlight) }
                    Button("Underline") { mark(.underline) }
                    Button("Strike Through") { mark(.strikeOut) }
                }
                Menu("Pages") {
                    Button("Rotate Right") { act { PDFEdit.rotate($0, pages: [session.currentPageIndex], by: 90) } }
                    Button("Rotate Left") { act { PDFEdit.rotate($0, pages: [session.currentPageIndex], by: -90) } }
                    Button("Delete This Page", role: .destructive) { act { if PDFEdit.delete($0, pages: [session.currentPageIndex]) == 0 { model.notice = "A PDF keeps at least one page." } } }
                    Button("Move Up") { act { PDFEdit.move($0, from: session.currentPageIndex, to: session.currentPageIndex - 1) } }
                    Button("Move Down") { act { PDFEdit.move($0, from: session.currentPageIndex, to: session.currentPageIndex + 1) } }
                    Divider()
                    Button("Add Pages from Another PDF…") { merging = true }
                    Button("Extract Pages…") { extracting = true }
                }
                Button { showPages.toggle() } label: { Label("Thumbnails", systemImage: "sidebar.left") }.buttonStyle(.bordered)
                Button { session.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.buttonStyle(.bordered).disabled(!session.canUndo)
            }
            .padding(8)
        }
    }

    private var bottomBar: some View {
        HStack {
            if tool == .redact, !redactions.isEmpty {
                Button("Black Out \(redactions.count) Area\(redactions.count == 1 ? "" : "s") for Good", role: .destructive) { applyRedactions() }
                Button("Clear") { redactions = [] }
            } else {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.changes > 0 { Text("\(session.changes) change\(session.changes == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
            Button("Revert") { session.revert(); redactions = [] }.disabled(session.changes == 0)
            Menu("Save") {
                Button("Save a Copy") { save() }
                Button("Save a Protected Copy…") { protecting = true }
            }
            if let copy = session.savedCopy { ShareLink(item: copy) { Image(systemName: "square.and.arrow.up") } }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }

    private var hint: String {
        switch tool {
        case .browse: "Select words, then use Mark Selection. Form fields can be filled in directly."
        case .pen: "Draw on the page."
        case .text: "Click where the text should go."
        case .rectangle, .oval: "Drag to draw the shape."
        case .sign: signature == nil && signaturePicture == nil ? "Choose a signature first." : "Drag a box where the signature goes, or click to place it at the usual size."
        case .redact: "Drag over what to hide. Nothing changes until you black the areas out."
        }
    }

    // MARK: The drawing layer

    private var overlay: some View {
        GeometryReader { _ in
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let d = drag { preview(d) }
                ForEach(Array(redactions.enumerated()), id: \.offset) { _, _ in EmptyView() }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drag == nil { drag = (value.startLocation, value.location, [value.startLocation]) }
                    drag?.now = value.location
                    if tool == .pen { drag?.trail.append(value.location) }
                }
                .onEnded { value in finish(start: value.startLocation, end: value.location) })
        }
    }

    @ViewBuilder private func preview(_ d: (start: CGPoint, now: CGPoint, trail: [CGPoint])) -> some View {
        let box = CGRect(x: min(d.start.x, d.now.x), y: min(d.start.y, d.now.y), width: abs(d.start.x - d.now.x), height: abs(d.start.y - d.now.y))
        switch tool {
        case .pen: Path { p in p.addLines(d.trail) }.stroke(Color.black, lineWidth: 2)
        case .rectangle: Rectangle().stroke(Color.red, lineWidth: 2).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case .oval: Ellipse().stroke(Color.red, lineWidth: 2).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case .sign: Rectangle().stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [5])).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case .redact: Rectangle().fill(Color.black.opacity(0.55)).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        default: EmptyView()
        }
    }

    private func finish(start: CGPoint, end: CGPoint) {
        let trail = drag?.trail ?? []
        drag = nil
        switch tool {
        case .pen:
            let points = trail.compactMap { session.locate($0) }
            guard let page = points.first?.page else { return }
            session.added(PDFEdit.addInk(points.filter { $0.page === page }.map(\.point), on: page), on: page)
        case .text:
            textPoint = end; askText = true
        case .rectangle, .oval:
            if let r = session.rect(from: start, to: end) { session.added(PDFEdit.addShape(tool == .rectangle ? .square : .circle, in: r.rect, on: r.page), on: r.page) }
        case .sign:
            placeSignature(from: start, to: end)
        case .redact:
            if let r = session.rect(from: start, to: end), r.rect.width > 3, r.rect.height > 3 { redactions.append(r) }
        case .browse: break
        }
    }

    private func placeSignature(from start: CGPoint, to end: CGPoint) {
        guard let spot = session.locate(end) else { return }
        var box = session.rect(from: start, to: end)?.rect ?? .zero
        if box.width < 20 || box.height < 12 { box = CGRect(x: spot.point.x - 80, y: spot.point.y - 28, width: 160, height: 56) }
        guard let page = session.rect(from: start, to: end)?.page ?? Optional(spot.page) else { return }
        if let picture = signaturePicture, let document = session.document, let index = document.index(for: page) as Int? {
            if PDFEdit.burnImage(picture, in: box, onPageAt: index, of: document) { session.changes += 1; session.view.document = document } else { model.notice = "The signature could not be placed." }
        } else if let signature {
            let before = Set(page.annotations.map { ObjectIdentifier($0) })
            if PDFEdit.place(signature, in: box, on: page) > 0 {
                let newOnes = page.annotations.filter { !before.contains(ObjectIdentifier($0)) }
                session.changes += 1
                session.pushUndo { newOnes.forEach { page.removeAnnotation($0) } }
            }
        }
        tool = .browse
    }

    // MARK: Actions

    private func pick(_ t: PDFTool) {
        tool = t
        if t == .sign, signature == nil, signaturePicture == nil { signing = true }
        if t != .redact { redactions = [] }
    }

    private func mark(_ type: PDFAnnotationSubtype) {
        guard let selection = session.view.currentSelection else { model.notice = "Select some words first."; return }
        let color: PDFColor = type == .highlight ? .yellow : (type == .underline ? .systemBlue : .systemRed)
        let before = session.view.currentPage.map { Set($0.annotations.map { ObjectIdentifier($0) }) } ?? []
        if PDFEdit.mark(selection, type: type, color: color) > 0, let page = session.view.currentPage {
            let added = page.annotations.filter { !before.contains(ObjectIdentifier($0)) }
            session.changes += 1
            session.pushUndo { added.forEach { page.removeAnnotation($0) } }
        }
        session.view.clearSelection()
    }

    private func act(_ change: (PDFDocument) -> Void) {
        guard let document = session.document else { return }
        change(document); session.changes += 1; session.view.document = document
    }

    private func applyRedactions() {
        guard let document = session.document else { return }
        var pages = Set<Int>()
        for item in redactions { if let i = Optional(document.index(for: item.page)), i != NSNotFound { pages.insert(i) } }
        for index in pages {
            let rects = redactions.filter { document.index(for: $0.page) == index }.map(\.rect)
            _ = PDFEdit.redact(rects, onPageAt: index, of: document)
        }
        session.changes += 1; session.view.document = document
        model.notice = "Blacked out for good. These pages can no longer be searched or selected."
        redactions = []; tool = .browse
    }

    private func save() {
        if let url = session.saveCopy() { model.notice = "Saved \(url.lastPathComponent)." } else { model.notice = "The copy could not be saved." }
    }

    private func saveProtected() {
        defer { passwordDraft = "" }
        guard let document = session.document else { return }
        let target = PDFEdit.copyURL(for: session.source, suffix: "protected")
        if PDFEdit.writeProtected(document, to: target, password: passwordDraft) { session.savedCopy = target; model.notice = "Saved \(target.lastPathComponent). It asks for the password to open." }
        else { model.notice = "The protected copy could not be saved." }
    }

    private func extractPages() {
        guard let document = session.document else { return }
        let pages = PDFEdit.parseRange(rangeDraft, pageCount: document.pageCount)
        guard let first = pages.first, let last = pages.last else { model.notice = "Those page numbers are not in this PDF."; return }
        let out = PDFDocument()
        for n in pages { if let p = document.page(at: n - 1)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
        _ = (first, last)
        let target = PDFEdit.copyURL(for: session.source, suffix: "pages \(rangeDraft.replacingOccurrences(of: "/", with: "-"))")
        model.notice = out.write(to: target) ? "Saved \(target.lastPathComponent)." : "The pages could not be saved."
        rangeDraft = ""
    }
}

extension PDFEditorSession {
    func pushUndo(_ undo: @escaping () -> Void) {
        // Kept separate from `added` because a signature or a mark can be several annotations at once.
        undoStackAppend { [weak self] in undo(); self?.changes = max(0, (self?.changes ?? 1) - 1) }
    }
}
