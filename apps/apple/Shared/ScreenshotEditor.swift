import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// A screenshot kept in memory while it is looked at and marked up, and written anywhere only when the person saves, copies or shares it. Redaction here changes the PIXELS of the
// exported picture (black for "Black out", coarse blocks for "Hide"): nothing is just drawn over the top, so the original pixels are not in what leaves.

enum ShotTool: String, CaseIterable, Identifiable {
    case crop = "Crop", arrow = "Arrow", box = "Box", text = "Text", pen = "Pen", pixelate = "Hide", redact = "Black Out"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .crop: "crop"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .text: "textformat"
        case .pen: "pencil.tip"
        case .pixelate: "square.grid.3x3.fill"
        case .redact: "rectangle.fill"
        }
    }
    var hint: String {
        switch self {
        case .crop: "Drag over the part to keep."
        case .arrow: "Drag from where the arrow starts to where it points."
        case .box: "Drag to draw a box."
        case .text: "Tap where the text should go."
        case .pen: "Draw freely."
        case .pixelate: "Drag over what to hide. It is turned into coarse blocks in the saved picture."
        case .redact: "Drag over what to hide. It is made solid black in the saved picture."
        }
    }
}

struct ShotMark: Identifiable, Equatable {
    var id = UUID()
    var tool: ShotTool
    /// In the picture's own pixels, from the top left.
    var rect: CGRect = .zero
    var points: [CGPoint] = []
    var text = ""
    var color: [Double] = [0.9, 0.1, 0.1]
}

@MainActor
final class ScreenshotDocument: ObservableObject {
    /// The picture as captured, or as it is after Black Out was made permanent. Held in memory only.
    @Published private(set) var base: CGImage { didSet { finished = nil } }
    @Published private(set) var marks: [ShotMark] = [] { didSet { finished = nil } }
    @Published var crop: CGRect? { didSet { finished = nil } }
    /// The finished picture, kept until something changes it: drawing a line moves a finger sixty times a second, and none of that should redo the whole picture.
    private var finished: CGImage?
    private var history: [([ShotMark], CGRect?)] = []

    init(image: CGImage) { base = image }

    convenience init?(pngOrJPEG data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(image: image)
    }

    var size: CGSize { CGSize(width: base.width, height: base.height) }
    var canUndo: Bool { !history.isEmpty }
    var hasHidingMarks: Bool { marks.contains { $0.tool == .redact || $0.tool == .pixelate } }

    func add(_ mark: ShotMark) { history.append((marks, crop)); marks.append(mark) }

    func setCrop(_ rect: CGRect?) {
        history.append((marks, crop))
        crop = rect.map { $0.intersection(CGRect(origin: .zero, size: size)).integral }.flatMap { $0.width >= 8 && $0.height >= 8 ? $0 : nil }
    }

    func undo() { if let (m, c) = history.popLast() { marks = m; crop = c } }

    /// Makes the hiding marks permanent now: the base picture itself is changed, and Undo can no longer bring the hidden pixels back.
    func commitHiding() {
        let hiding = marks.filter { $0.tool == .redact || $0.tool == .pixelate }
        guard !hiding.isEmpty, let changed = Self.applyHiding(hiding, to: base) else { return }
        base = changed
        marks.removeAll { $0.tool == .redact || $0.tool == .pixelate }
        history = []
    }

    // MARK: Producing the picture

    /// The finished picture: cropped, with the hiding marks written into the pixels, then the arrows, boxes, text and lines drawn on top.
    func flattened() -> CGImage? {
        if let finished { return finished }
        let made = render()
        finished = made
        return made
    }

    private func render() -> CGImage? {
        var picture = Self.applyHiding(marks.filter { $0.tool == .redact || $0.tool == .pixelate }, to: base) ?? base
        let bounds = CGRect(origin: .zero, size: size)
        var offset = CGPoint.zero
        if let crop, let cropped = picture.cropping(to: crop.intersection(bounds)) { picture = cropped; offset = crop.origin }
        let w = picture.width, h = picture.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        let line = max(2, CGFloat(w) / 400)
        for mark in marks where mark.tool != .redact && mark.tool != .pixelate && mark.tool != .crop {
            context.saveGState()
            context.translateBy(x: -offset.x, y: CGFloat(h) + offset.y)
            context.scaleBy(x: 1, y: -1)                      // from here, the top left is the origin, as in the marks
            let color = CGColor(red: mark.color[0], green: mark.color[1], blue: mark.color[2], alpha: 1)
            context.setStrokeColor(color); context.setFillColor(color); context.setLineWidth(line); context.setLineCap(.round); context.setLineJoin(.round)
            switch mark.tool {
            case .box: context.stroke(mark.rect)
            case .arrow:
                if let a = mark.points.first, let b = mark.points.last, a != b {
                    context.move(to: a); context.addLine(to: b); context.strokePath()
                    let angle = atan2(b.y - a.y, b.x - a.x), head = line * 6
                    context.move(to: b)
                    context.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7)))
                    context.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7)))
                    context.closePath(); context.fillPath()
                }
            case .pen:
                if let first = mark.points.first { context.move(to: first); for p in mark.points.dropFirst() { context.addLine(to: p) }; context.strokePath() }
            case .text:
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(14, CGFloat(w) / 40), nil)
                let attributed = NSAttributedString(string: mark.text, attributes: [.font: font, .foregroundColor: color])
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = mark.rect.origin
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            default: break
            }
            context.restoreGState()
        }
        return context.makeImage()
    }

    func pngData() -> Data? { flattened().flatMap { Self.encode($0, type: UTType.png, quality: nil) } }
    func jpegData(quality: Double = 0.9) -> Data? { flattened().flatMap { Self.encode($0, type: UTType.jpeg, quality: quality) } }

    static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        // Nothing about where or when it was taken: only the pixels.
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Hiding, in the pixels

    /// A copy of `image` where each hiding mark's area has been overwritten: solid black, or coarse blocks of the average colour (blocks about half the area's short side, never smaller than 16 pixels,
    /// so small writing cannot be read back).
    static func applyHiding(_ marks: [ShotMark], to image: CGImage) -> CGImage? {
        guard !marks.isEmpty else { return image }
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let stride = context.bytesPerRow
        for mark in marks {
            let area = mark.rect.standardized.intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
            guard area.width >= 1, area.height >= 1 else { continue }
            let x0 = Int(area.minX), x1 = Int(area.maxX), y0 = Int(area.minY), y1 = Int(area.maxY)      // rows from the top
            // In a bitmap context's memory the first row is the TOP of the picture, so a row counted from the top is its own offset. (Getting this the wrong way up hid the mirror image
            // of the chosen area: caught by reading the exported picture with an independent OCR engine, see scripts/verify-screenshot-redaction.sh.)
            func row(_ y: Int) -> Int { y * stride }
            if mark.tool == .redact {
                for y in y0..<y1 { for x in x0..<x1 { let o = row(y) + x * 4; buffer[o] = 0; buffer[o + 1] = 0; buffer[o + 2] = 0; buffer[o + 3] = 255 } }
            } else {
                let block = max(16, Int(min(area.width, area.height) / 2))
                var by = y0
                while by < y1 {
                    let ey = min(by + block, y1)
                    var bx = x0
                    while bx < x1 {
                        let ex = min(bx + block, x1)
                        var r = 0, g = 0, b = 0, n = 0
                        for y in by..<ey { for x in bx..<ex { let o = row(y) + x * 4; r += Int(buffer[o]); g += Int(buffer[o + 1]); b += Int(buffer[o + 2]); n += 1 } }
                        let (ar, ag, ab) = (UInt8(r / max(n, 1)), UInt8(g / max(n, 1)), UInt8(b / max(n, 1)))
                        for y in by..<ey { for x in bx..<ex { let o = row(y) + x * 4; buffer[o] = ar; buffer[o + 1] = ag; buffer[o + 2] = ab; buffer[o + 3] = 255 } }
                        bx = ex
                    }
                    by = ey
                }
            }
        }
        return context.makeImage()
    }
}

/// The picture as something to share without writing a file first: the system asks for the bytes when it needs them.
struct ShotExport: Transferable, @unchecked Sendable {
    let document: ScreenshotDocument
    enum Failure: Error, LocalizedError { case couldNotMakePicture; var errorDescription: String? { "The picture could not be made." } }
    /// The picture is made only when the person actually shares it, not every time the screen is drawn; if it cannot be made the share fails, and no empty file is sent.
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await MainActor.run { guard let data = item.document.pngData(), !data.isEmpty else { throw Failure.couldNotMakePicture }; return data }
        }
        DataRepresentation(exportedContentType: .jpeg) { item in
            try await MainActor.run { guard let data = item.document.jpegData(), !data.isEmpty else { throw Failure.couldNotMakePicture }; return data }
        }
    }
}

extension BrowserModel {
    /// Captures the page in front into memory and opens the editor. Nothing is written to disk.
    func startScreenshot(fullPage: Bool) async {
        guard let tab = active, !tab.isBlank, let data = await tab.engine.screenshot(fullPage: fullPage), let document = ScreenshotDocument(pngOrJPEG: data) else { notice = "This page could not be captured."; return }
        screenshotDraft = document
        sheet = .screenshot
    }
}

struct ScreenshotEditorView: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var document: ScreenshotDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetProvidesDone) private var sheetProvidesDone
    @State private var tool = ShotTool.arrow
    @State private var drag: (start: CGPoint, now: CGPoint, trail: [CGPoint])?
    @State private var colorIndex = 0
    @State private var askText = false
    @State private var textDraft = ""
    @State private var textPoint: CGPoint?
    @State private var saving = false
    /// The bytes being saved, made when Save was pressed (not on every redraw). Never an empty file: if the picture cannot be made, nothing is offered.
    @State private var pending: ShotFile?

    private static let palette: [[Double]] = [[0.9, 0.1, 0.1], [0.95, 0.65, 0.0], [0.1, 0.6, 0.2], [0.1, 0.35, 0.9], [0, 0, 0], [1, 1, 1]]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in canvas(in: geometry.size) }
            Divider()
            bottomBar
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Color.platformBackground)
        // Marks drawn or a crop would be lost: Done and Escape ask first (saving takes the save panel, so the choices are Discard Changes and Keep Editing).
        .guardsUnsavedChanges(isDirty: !document.marks.isEmpty || document.crop != nil)
        .alert("Add text", isPresented: $askText) {
            TextField("Text", text: $textDraft)
            Button("Add") { if let p = textPoint, !textDraft.isEmpty { document.add(ShotMark(tool: .text, rect: CGRect(origin: p, size: .zero), text: String(textDraft.prefix(200)), color: Self.palette[colorIndex])) }; textDraft = "" }
            Button("Cancel", role: .cancel) { textDraft = "" }
        }
        .fileExporter(isPresented: $saving, document: pending ?? ShotFile(data: Data(), type: .png), contentType: pending?.type ?? .png, defaultFilename: "Screenshot") { result in
            pending = nil
            switch result {
            case .success(let url): model.notice = "Saved \(url.lastPathComponent)."
            case .failure(let error): model.notice = "The picture could not be saved. \(error.localizedDescription)"
            }
        }
        .onDisappear { model.screenshotDraft = nil }
        .accessibilityIdentifier("screenshot-editor")
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ShotTool.allCases) { t in
                    Button { tool = t } label: { Label(t.rawValue, systemImage: t.symbol).labelStyle(.titleAndIcon) }.buttonStyle(.bordered).tint(tool == t ? .accentColor : .secondary)
                }
                Divider().frame(height: 20)
                ForEach(Self.palette.indices, id: \.self) { i in
                    Circle().fill(Color(red: Self.palette[i][0], green: Self.palette[i][1], blue: Self.palette[i][2])).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.primary.opacity(colorIndex == i ? 0.9 : 0.25), lineWidth: colorIndex == i ? 2 : 1)).onTapGesture { colorIndex = i }
                        .accessibilityLabel("Colour \(i + 1)")
                }
                Divider().frame(height: 20)
                Button { document.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.buttonStyle(.bordered).disabled(!document.canUndo).keyboardShortcut("z", modifiers: .command)
                if document.hasHidingMarks { Button("Make Hiding Permanent") { document.commitHiding() }.buttonStyle(.bordered) }
                if document.crop != nil { Button("Reset Crop") { document.setCrop(nil) }.buttonStyle(.bordered) }
            }.padding(8)
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(tool.hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("Copy") { copy() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Menu("Save") {
                Button("Save as PNG…") { startSaving(jpeg: false) }.keyboardShortcut("s", modifiers: .command)
                Button("Save as JPEG…") { startSaving(jpeg: true) }
            }
            ShareLink(item: ShotExport(document: document), preview: SharePreview("Screenshot")) { Image(systemName: "square.and.arrow.up").accessibilityLabel("Share") }
            // The sheet's own Done (top bar) is the one, with Escape; this one is only for when the editor is shown without it.
            if !sheetProvidesDone { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(10)
    }

    /// The picture, fitted into the room there is, with the marks being drawn on top of it.
    private func canvas(in available: CGSize) -> some View {
        let image = document.flattened()
        let currentCrop = document.crop
        let size = currentCrop?.size ?? document.size
        let scale = min(available.width / max(size.width, 1), available.height / max(size.height, 1), 1.0 * 4)
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (available.width - shown.width) / 2, y: (available.height - shown.height) / 2)
        // While cropping, the whole picture is shown so the area can be chosen on it.
        let full = tool == .crop ? document.size : size
        let fullScale = min(available.width / max(full.width, 1), available.height / max(full.height, 1))
        let activeScale = tool == .crop ? fullScale : scale
        let activeShown = CGSize(width: full.width * activeScale, height: full.height * activeScale)
        let activeOrigin = CGPoint(x: (available.width - activeShown.width) / 2, y: (available.height - activeShown.height) / 2)
        _ = (shown, origin)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.06)
            if tool == .crop {
                Image(decorative: document.base, scale: 1).resizable().frame(width: activeShown.width, height: activeShown.height).position(x: activeOrigin.x + activeShown.width / 2, y: activeOrigin.y + activeShown.height / 2)
            } else if let image {
                Image(decorative: image, scale: 1).resizable().frame(width: activeShown.width, height: activeShown.height).position(x: activeOrigin.x + activeShown.width / 2, y: activeOrigin.y + activeShown.height / 2)
            }
            if let drag { preview(drag, scale: activeScale, origin: activeOrigin) }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let start = drag?.start ?? value.startLocation
            drag = (start, value.location, (drag?.trail ?? [value.startLocation]) + [value.location])
        }.onEnded { value in
            defer { drag = nil }
            func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - activeOrigin.x) / activeScale + (tool == .crop ? 0 : (currentCrop?.minX ?? 0)), y: (p.y - activeOrigin.y) / activeScale + (tool == .crop ? 0 : (currentCrop?.minY ?? 0))) }
            let a = toImage(value.startLocation), b = toImage(value.location)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let color = Self.palette[colorIndex]
            switch tool {
            case .crop: if rect.width > 8, rect.height > 8 { document.setCrop(rect) }
            case .box: if rect.width > 3, rect.height > 3 { document.add(ShotMark(tool: .box, rect: rect, color: color)) }
            case .arrow: if hypot(a.x - b.x, a.y - b.y) > 8 { document.add(ShotMark(tool: .arrow, points: [a, b], color: color)) }
            case .pen: document.add(ShotMark(tool: .pen, points: (drag?.trail ?? [a, b]).map(toImage), color: color))
            case .text: textPoint = a; askText = true
            case .pixelate, .redact: if rect.width > 3, rect.height > 3 { document.add(ShotMark(tool: tool, rect: rect)) }
            }
        })
    }

    @ViewBuilder private func preview(_ d: (start: CGPoint, now: CGPoint, trail: [CGPoint]), scale: CGFloat, origin: CGPoint) -> some View {
        let box = CGRect(x: min(d.start.x, d.now.x), y: min(d.start.y, d.now.y), width: abs(d.start.x - d.now.x), height: abs(d.start.y - d.now.y))
        let color = Color(red: Self.palette[colorIndex][0], green: Self.palette[colorIndex][1], blue: Self.palette[colorIndex][2])
        switch tool {
        case .crop: Rectangle().stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [6])).background(Color.black.opacity(0.2)).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case .box: Rectangle().stroke(color, lineWidth: 2).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case .arrow: Path { p in p.move(to: d.start); p.addLine(to: d.now) }.stroke(color, lineWidth: 3)
        case .pen: Path { p in p.addLines(d.trail) }.stroke(color, lineWidth: 2)
        case .pixelate: Rectangle().fill(Color.gray.opacity(0.6)).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case .redact: Rectangle().fill(Color.black).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
        case .text: EmptyView()
        }
    }

    private func startSaving(jpeg: Bool) {
        guard let data = jpeg ? document.jpegData() : document.pngData(), !data.isEmpty else { model.notice = "The picture could not be made, so nothing was saved."; return }
        pending = ShotFile(data: data, type: jpeg ? .jpeg : .png)
        saving = true
    }

    private func copy() {
        guard let png = document.pngData(), !png.isEmpty else { model.notice = "The picture could not be made, so nothing was copied."; return }
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png)
        #else
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        #endif
        model.notice = "Copied the picture."
    }
}

/// What the save dialog writes: the finished picture's bytes, nothing else.
struct ShotFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .jpeg] }
    let data: Data
    var type: UTType
    init(data: Data, type: UTType) { self.data = data; self.type = type }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data(); type = .png }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }          // never an empty file that looks like a saved picture
        return FileWrapper(regularFileWithContents: data)
    }
}
