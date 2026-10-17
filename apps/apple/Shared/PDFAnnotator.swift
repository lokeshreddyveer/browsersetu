import PDFKit
import SwiftUI

/// Marks up a PDF from Downloads. Marks are saved to a new copy; the original is never changed.
@MainActor
final class PDFAnnotationSession: ObservableObject {
    let source: URL
    let document: PDFDocument?
    @Published var marks = 0
    let view = PDFView()

    init(source: URL) {
        self.source = source
        document = PDFDocument(url: source)
        view.document = document
        view.autoScales = true
    }

    /// Highlights whatever is selected, one mark per line of text.
    func highlightSelection() -> Bool {
        guard let selection = view.currentSelection else { return false }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                mark.color = .yellow.withAlphaComponent(0.5)
                page.addAnnotation(mark); marks += 1
            }
        }
        view.clearSelection()
        return true
    }

    /// A small sticky note on the page being looked at.
    func addNote(_ text: String) {
        guard let page = view.currentPage, !text.isEmpty else { return }
        let bounds = page.bounds(for: .cropBox)
        let note = PDFAnnotation(bounds: CGRect(x: bounds.minX + 36, y: bounds.maxY - 60, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = String(text.prefix(2000))
        note.color = .systemYellow
        page.addAnnotation(note); marks += 1
    }

    /// Where the marked copy goes: "name annotated.pdf" beside the original, or "name annotated 2.pdf" if that is taken.
    var destination: URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + " annotated"
        let name = DownloadRouting.uniqueName(base + ".pdf") { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        return folder.appendingPathComponent(name)
    }

    func save() -> URL? {
        guard marks > 0, let document else { return nil }
        let target = destination
        return document.write(to: target) ? target : nil
    }
}

#if os(macOS)
struct PDFKitRepresentable: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
#else
struct PDFKitRepresentable: UIViewRepresentable {
    let view: PDFView
    func makeUIView(context: Context) -> PDFView { view }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}
#endif

struct PDFAnnotatorView: View {
    @EnvironmentObject var model: BrowserModel
    @StateObject var session: PDFAnnotationSession
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    init(source: URL) { _session = StateObject(wrappedValue: PDFAnnotationSession(source: source)) }

    var body: some View {
        VStack(spacing: 0) {
            if session.document == nil {
                Text("This file could not be opened as a PDF.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PDFKitRepresentable(view: session.view)
                Divider()
                HStack {
                    Button("Highlight Selection") { if !session.highlightSelection() { model.notice = "Select some text first." } }
                    TextField("Note for this page", text: $note).textFieldStyle(.roundedBorder)
                    Button("Add Note") { session.addNote(note); note = "" }.disabled(note.isEmpty)
                    Spacer()
                    Text("\(session.marks) mark\(session.marks == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Button("Save Copy") { if let url = session.save() { model.notice = "Saved \(url.lastPathComponent)."; dismiss() } else { model.notice = "Add a mark first." } }
                        .disabled(session.marks == 0)
                }.padding(10)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}
