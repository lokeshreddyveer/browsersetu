import AVFoundation
import SwiftUI

/// What the page in front contains that is worth pulling out: pictures, tables, document links and its heading outline.
struct PageExtract: Equatable {
    struct Image: Identifiable, Equatable { var id: String { url }; var url: String; var alt: String; var width: Int; var height: Int }
    struct Table: Identifiable, Equatable { let id = UUID(); var caption: String; var rows: [[String]] }
    struct Document: Identifiable, Equatable { var id: String { url }; var url: String; var title: String; var kind: String }
    struct Heading: Identifiable, Equatable { let id = UUID(); var level: Int; var text: String; var index: Int }
    var images: [Image] = []
    var tables: [Table] = []
    var documents: [Document] = []
    var headings: [Heading] = []

    init() {}

    init(raw: [String: Any]) {
        images = (raw["images"] as? [[String: Any]] ?? []).compactMap { item in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            return Image(url: url, alt: item["alt"] as? String ?? "", width: (item["w"] as? NSNumber)?.intValue ?? 0, height: (item["h"] as? NSNumber)?.intValue ?? 0)
        }
        tables = (raw["tables"] as? [[String: Any]] ?? []).compactMap { item in
            let rows = (item["rows"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
            return rows.isEmpty ? nil : Table(caption: item["caption"] as? String ?? "", rows: rows)
        }
        documents = (raw["documents"] as? [[String: Any]] ?? []).compactMap { item in
            guard let url = item["url"] as? String else { return nil }
            return Document(url: url, title: item["title"] as? String ?? url, kind: item["kind"] as? String ?? "")
        }
        headings = (raw["headings"] as? [[String: Any]] ?? []).enumerated().compactMap { offset, item in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return Heading(level: (item["level"] as? NSNumber)?.intValue ?? 2, text: text, index: offset)
        }
    }
}

enum TableCSV {
    /// Comma-separated text that opens in Numbers, Excel and Sheets: quotes doubled, fields with commas, quotes or line breaks quoted.
    static func encode(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { field -> String in
                let flat = field.replacingOccurrences(of: "\r", with: " ")
                guard flat.contains(",") || flat.contains("\"") || flat.contains("\n") else { return flat }
                return "\"" + flat.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }
}

/// Reads text aloud with the system voice and reports which sentence it is on, so the page can follow along.
@MainActor
final class SpeechReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    @Published var spoken: Range<String.Index>?
    private let synthesizer = AVSpeechSynthesizer()
    private var text = ""

    override init() { super.init(); synthesizer.delegate = self }

    func start(_ text: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        stop()
        self.text = text
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")) ?? AVSpeechSynthesisVoice(language: "en-US")
        speaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
        spoken = nil
    }

    func pauseOrResume() {
        if synthesizer.isPaused { synthesizer.continueSpeaking() } else if synthesizer.isSpeaking { synthesizer.pauseSpeaking(at: .word) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.spoken = Range(characterRange, in: self.text) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.spoken = nil }
    }

    var spokenText: String { spoken.map { String(text[$0]) } ?? "" }
}

extension BrowserModel {
    func extractPageContent() async {
        extractingPage = true
        defer { extractingPage = false }
        guard let tab = active, !tab.isBlank, let raw = await tab.engine.extractPageData() else { pageExtract = PageExtract(); return }
        pageExtract = PageExtract(raw: raw)
    }
}

struct PageToolsView: View {
    enum Tool: String, CaseIterable, Identifiable { case images = "Images", tables = "Tables", documents = "Documents", outline = "Outline", details = "Details", video = "Video", text = "Text", versions = "Versions", listen = "Listen"; var id: String { rawValue } }
    @EnvironmentObject var model: BrowserModel
    @StateObject private var reader = SpeechReader()
    @State private var tool: Tool = .images
    @State private var pageText = ""
    @State private var details: [FoundDetail] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Tool.allCases) { item in
                        Button { tool = item } label: {
                            Text(item.rawValue).font(.callout.weight(tool == item ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(tool == item ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            Divider()
            Group {
                if model.extractingPage { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    switch tool {
                    case .images: images
                    case .tables: tables
                    case .documents: documents
                    case .outline: outline
                    case .details: DetailsList(details: details, pageURL: model.active?.url?.absoluteString)
                    case .video: VideoToolsView()
                    case .text: LiveTextView()
                    case .versions: PageVersionsView()
                    case .listen: listen
                    }
                }
            }
            .motion(.easeInOut(duration: 0.18), value: tool)
        }
        .task {
            await model.extractPageContent()
            details = DetailExtractor.find(in: await model.active?.engine.pageText() ?? "")
        }
        .onDisappear { reader.stop() }
        .accessibilityIdentifier("page-tools")
    }

    private var extract: PageExtract { model.pageExtract ?? PageExtract() }

    private func empty(_ title: String, _ symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text("Nothing of this kind was found on the page in front."))
    }

    @ViewBuilder private var images: some View {
        if extract.images.isEmpty { empty("No Images", "photo.on.rectangle") } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(extract.images) { image in
                        VStack(alignment: .leading, spacing: 4) {
                            AsyncImage(url: URL(string: image.url)) { phase in
                                switch phase {
                                case .success(let loaded): loaded.resizable().scaledToFill()
                                default: Rectangle().fill(.quaternary)
                                }
                            }
                            .frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(image.width > 0 ? "\(image.width) × \(image.height)" : "Size unknown").font(.caption2).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Copy Image Address") { copyToPasteboard(image.url) }
                            Button("Open in New Tab") { model.open(urlString: image.url, newTab: true) }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder private var tables: some View {
        if extract.tables.isEmpty { empty("No Tables", "tablecells") } else {
            List(extract.tables) { table in
                VStack(alignment: .leading, spacing: 6) {
                    Text(table.caption.isEmpty ? "Table, \(table.rows.count) rows" : table.caption).fontWeight(.medium)
                    Text(table.rows.prefix(3).map { $0.prefix(4).joined(separator: " · ") }.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    HStack {
                        Button("Copy as CSV") { copyToPasteboard(TableCSV.encode(table.rows)) }
                        ShareLink(item: TableCSV.encode(table.rows), subject: Text(table.caption.isEmpty ? "Table" : table.caption)) { Text("Share…") }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var documents: some View {
        if extract.documents.isEmpty { empty("No Documents", "doc") } else {
            List(extract.documents) { doc in
                Button { model.open(urlString: doc.url, newTab: true) } label: {
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(doc.title).lineLimit(1)
                            Text(doc.kind.uppercased() + " · " + displayHost(URL(string: doc.url))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var outline: some View {
        if extract.headings.isEmpty { empty("No Headings", "list.bullet.indent") } else {
            List(extract.headings) { heading in
                Button { Task { await model.active?.engine.scrollToHeading(heading.index) } } label: {
                    Text(heading.text).lineLimit(2).padding(.leading, CGFloat(max(0, heading.level - 1)) * 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var listen: some View {
        VStack(spacing: 14) {
            Image(systemName: reader.speaking ? "speaker.wave.3.fill" : "speaker.wave.2").font(.system(size: 34)).foregroundStyle(.secondary)
            if reader.speaking, !reader.spokenText.isEmpty {
                Text(reader.spokenText).font(.title3.weight(.medium)).multilineTextAlignment(.center).padding(.horizontal, 20)
            } else {
                Text("Reads the page aloud with the system voice. Nothing leaves this device.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 20)
            }
            HStack {
                Button(reader.speaking ? "Stop" : "Read This Page") {
                    if reader.speaking { reader.stop() } else { Task {
                        pageText = await model.active?.engine.pageText() ?? ""
                        if !pageText.isEmpty { reader.start(pageText) }
                    } }
                }
                .buttonStyle(.borderedProminent)
                if reader.speaking { Button("Pause / Resume") { reader.pauseOrResume() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
