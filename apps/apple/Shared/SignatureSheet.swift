import SwiftUI
import UniformTypeIdentifiers

/// Where a signature comes from: drawn with the mouse or a finger, typed, a picture of one, or one saved earlier.
struct SignatureSheet: View {
    /// Called with strokes (drawn, typed or saved) or with a picture (not both).
    let onPick: (PDFEdit.Signature?, CGImage?) -> Void
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    enum Way: String, CaseIterable, Identifiable { case draw = "Draw", type = "Type", picture = "Picture", saved = "Saved"; var id: String { rawValue } }
    @State private var way = Way.draw
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var typed = ""
    @State private var saveAs = ""
    @State private var choosing = false
    @State private var saved: [SignatureStore.Saved] = []
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signature").font(.title3.bold())
            Picker("", selection: $way) { ForEach(Way.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            switch way {
            case .draw: drawPane
            case .type:
                TextField("Your name", text: $typed).textFieldStyle(.roundedBorder)
                Text(typed.isEmpty ? " " : typed).font(.custom("Snell Roundhand", size: 40)).frame(maxWidth: .infinity, minHeight: 90).background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                Button("Use This") { use(PDFEdit.Signature(strokes: [], typed: String(typed.prefix(60)))) }.disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            case .picture:
                Text("Choose a picture of your signature, best on a white background.").font(.callout).foregroundStyle(.secondary)
                Button("Choose a Picture…") { choosing = true }
                Text("A picture is placed on the page by redrawing that page, so the words on that one page can no longer be selected.").font(.caption).foregroundStyle(.secondary)
            case .saved: savedPane
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("This puts the image of your signature on the document. It is not a certificate-based digital signature that proves who signed.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18).frame(minWidth: 420, minHeight: 360)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000, let image = SignatureSheet.cgImage(from: data) else { problem = "That picture could not be read."; return }
            onPick(nil, image); dismiss()
        }
        .onAppear { saved = SignatureStore.list(profile: model.profileName) }
    }

    private var drawPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, _ in
                for stroke in strokes + [current] where stroke.count > 1 { var p = Path(); p.addLines(stroke); context.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)) }
            }
            .frame(height: 140).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
            .overlay(alignment: .bottomLeading) { Text(strokes.isEmpty && current.isEmpty ? "Sign here" : "").font(.caption).foregroundStyle(.tertiary).padding(8) }
            .gesture(DragGesture(minimumDistance: 0).onChanged { current.append($0.location) }.onEnded { _ in if current.count > 1 { strokes.append(current) }; current = [] })
            HStack {
                Button("Clear") { strokes = []; current = [] }.disabled(strokes.isEmpty)
                Spacer()
                TextField("Name to save it as (optional)", text: $saveAs).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("Use This") {
                    // The drawing is upside down for the page: the screen's y grows downward, the page's grows upward.
                    let upright = strokes.map { $0.map { CGPoint(x: $0.x, y: -$0.y) } }
                    let signature = PDFEdit.Signature.normalized(upright)
                    if !saveAs.trimmingCharacters(in: .whitespaces).isEmpty, SignatureStore.save(signature, named: saveAs, profile: model.profileName) == nil { problem = "It could not be saved (the Keychain is full or the name is empty)." }
                    use(signature)
                }.disabled(strokes.isEmpty)
            }
        }
    }

    private var savedPane: some View {
        VStack(alignment: .leading) {
            if saved.isEmpty { Text("No saved signatures. Draw one and give it a name to keep it here, behind Touch ID.").foregroundStyle(.secondary) }
            ForEach(saved) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Button("Use") { Task { if await model.authenticateForSignature() { use(item.signature) } else { problem = "Not used: it could not be confirmed." } } }
                    Button(role: .destructive) { SignatureStore.forget(item, profile: model.profileName); saved = SignatureStore.list(profile: model.profileName) } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func use(_ signature: PDFEdit.Signature) { onPick(signature, nil); dismiss() }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
