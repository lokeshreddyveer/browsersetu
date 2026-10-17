import PDFKit
import SwiftUI

#if os(macOS)
import AppKit
typealias PDFColor = NSColor
typealias PDFImage = NSImage
#else
import UIKit
typealias PDFColor = UIColor
typealias PDFImage = UIImage
#endif

/// Changes to a PDF that do not need a screen: pages, annotations, signatures, redaction and passwords. Every function works on a document the caller owns and saves as a
/// new copy; the file a person opened is never changed.
enum PDFEdit {
    // MARK: Pages

    static func rotate(_ document: PDFDocument, pages: [Int], by degrees: Int) {
        for i in pages where i >= 0 && i < document.pageCount {
            guard let page = document.page(at: i) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
    }

    /// Removes pages. A document always keeps at least one page; returns how many were removed.
    @discardableResult
    static func delete(_ document: PDFDocument, pages: [Int]) -> Int {
        let wanted = Set(pages.filter { $0 >= 0 && $0 < document.pageCount })
        guard wanted.count < document.pageCount else { return 0 }
        for i in wanted.sorted(by: >) { document.removePage(at: i) }
        return wanted.count
    }

    static func move(_ document: PDFDocument, from: Int, to: Int) {
        guard from != to, from >= 0, from < document.pageCount, to >= 0, to < document.pageCount, let page = document.page(at: from) else { return }
        document.removePage(at: from)
        document.insert(page, at: to)
    }

    /// Adds every page of `other` to the end of `document`.
    static func append(_ other: PDFDocument, to document: PDFDocument) {
        for i in 0..<other.pageCount {
            if let page = other.page(at: i)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) }
        }
    }

    /// A new document holding only the pages in the range (1-based, inclusive), or nil when the range is outside the document.
    static func extract(_ document: PDFDocument, from first: Int, to last: Int) -> PDFDocument? {
        guard first >= 1, last >= first, first <= document.pageCount else { return nil }
        let out = PDFDocument()
        for i in (first - 1)..<min(last, document.pageCount) { if let page = document.page(at: i)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) } }
        return out.pageCount > 0 ? out : nil
    }

    /// "1-3, 5, 8-" as page numbers (1-based), within the document; nonsense gives nothing.
    static func parseRange(_ text: String, pageCount: Int) -> [Int] {
        var out = Set<Int>()
        for part in text.split(separator: ",") {
            let bits = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if bits.count == 1, let n = Int(bits[0]) { out.insert(n) }
            else if bits.count == 2, let a = bits[0].isEmpty ? 1 : Int(bits[0]), let b = bits[1].isEmpty ? pageCount : Int(bits[1]), a <= b { for n in a...b { out.insert(n) } }
        }
        return out.filter { $0 >= 1 && $0 <= pageCount }.sorted()
    }

    // MARK: Annotations

    /// A mark over the selected words, one per line of text. Returns the marks added.
    @discardableResult
    static func mark(_ selection: PDFSelection, type: PDFAnnotationSubtype, color: PDFColor) -> Int {
        var added = 0
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                annotation.color = type == .highlight ? color.withAlphaComponent(0.5) : color
                page.addAnnotation(annotation); added += 1
            }
        }
        return added
    }

    /// A box of text on a page, at a point in the page's own coordinates.
    @discardableResult
    static func addText(_ text: String, on page: PDFPage, at point: CGPoint, size: CGFloat = 14, color: PDFColor = .black) -> PDFAnnotation? {
        let clean = String(text.prefix(2000))
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let font = PDFFont.systemFont(ofSize: size)
        let width = min(max(ceil((clean as NSString).size(withAttributes: [.font: font]).width) + 10, 40), page.bounds(for: .cropBox).width - point.x)
        let lines = max(1, Int(ceil(CGFloat(clean.count) * size * 0.55 / max(width - 10, 1))))
        let box = CGRect(x: point.x, y: point.y - CGFloat(lines) * size * 1.3, width: width, height: CGFloat(lines) * size * 1.3 + 6)
        let annotation = PDFAnnotation(bounds: box, forType: .freeText, withProperties: nil)
        annotation.contents = clean
        annotation.font = font
        annotation.fontColor = color
        annotation.color = .clear
        annotation.alignment = .left
        page.addAnnotation(annotation)
        return annotation
    }

    /// A freehand line through points in the page's coordinates.
    @discardableResult
    static func addInk(_ points: [CGPoint], on page: PDFPage, color: PDFColor = .black, width: CGFloat = 2) -> PDFAnnotation? {
        guard points.count >= 2 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let pad = width + 2
        let box = CGRect(x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + 2 * pad, height: ys.max()! - ys.min()! + 2 * pad)
        let path = PDFBezierPath()
        path.move(to: CGPoint(x: points[0].x - box.minX, y: points[0].y - box.minY))
        for p in points.dropFirst() { path.extend(to: CGPoint(x: p.x - box.minX, y: p.y - box.minY)) }
        let annotation = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
        annotation.color = color
        let border = PDFBorder(); border.lineWidth = width; annotation.border = border
        annotation.add(path)
        page.addAnnotation(annotation)
        return annotation
    }

    /// A rectangle or an oval outline.
    @discardableResult
    static func addShape(_ type: PDFAnnotationSubtype, in rect: CGRect, on page: PDFPage, color: PDFColor = .systemRed, width: CGFloat = 2) -> PDFAnnotation? {
        guard type == .square || type == .circle, rect.width > 2, rect.height > 2 else { return nil }
        let annotation = PDFAnnotation(bounds: rect.standardized, forType: type, withProperties: nil)
        annotation.color = color
        let border = PDFBorder(); border.lineWidth = width; annotation.border = border
        page.addAnnotation(annotation)
        return annotation
    }

    // MARK: Signatures

    /// A signature as strokes: each stroke is a list of points, 0...1 across and up a unit square. It keeps its shape at any size and can be saved as text.
    struct Signature: Codable, Equatable {
        var strokes: [[CGPoint]]
        var typed: String? = nil
        var isEmpty: Bool { strokes.allSatisfy { $0.count < 2 } && (typed ?? "").isEmpty }

        /// Strokes drawn in any box, scaled into the unit square (the same shape, however big the box was).
        static func normalized(_ strokes: [[CGPoint]]) -> Signature {
            let all = strokes.flatMap { $0 }
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return Signature(strokes: []) }
            let scale = max(maxX - minX, maxY - minY, 1)
            return Signature(strokes: strokes.map { $0.map { CGPoint(x: ($0.x - minX) / scale, y: ($0.y - minY) / scale) } })
        }
    }

    /// Puts a signature on a page inside `rect`, as lines that stay sharp at any zoom (drawn) or as text (typed). Returns the marks added.
    @discardableResult
    static func place(_ signature: Signature, in rect: CGRect, on page: PDFPage, color: PDFColor = PDFColor(red: 0.05, green: 0.1, blue: 0.5, alpha: 1)) -> Int {
        guard !signature.isEmpty, rect.width > 4, rect.height > 4 else { return 0 }
        if let typed = signature.typed, !typed.isEmpty {
            let size = max(12, min(rect.height * 0.7, rect.width / CGFloat(max(typed.count, 1)) * 1.8))
            let annotation = addText(typed, on: page, at: CGPoint(x: rect.minX, y: rect.maxY), size: size, color: color)
            annotation?.font = PDFFont(name: "Snell Roundhand", size: size) ?? PDFFont.systemFont(ofSize: size)
            return annotation == nil ? 0 : 1
        }
        let strokes = signature.strokes.filter { $0.count >= 2 }
        var added = 0
        for stroke in strokes {
            let points = stroke.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            if addInk(points, on: page, color: color, width: max(1.2, rect.height / 40)) != nil { added += 1 }
        }
        return added
    }

    /// Puts a picture of a signature on one page. That page is redrawn with the picture on it (the other pages are left alone), so that page's text can no longer be selected.
    static func burnImage(_ image: CGImage, in rect: CGRect, onPageAt index: Int, of document: PDFDocument) -> Bool {
        guard index >= 0, index < document.pageCount, let page = document.page(at: index), rect.width > 4, rect.height > 4 else { return false }
        guard let flat = redrawn(page, drawing: { context, _ in context.draw(image, in: rect) }) else { return false }
        document.removePage(at: index)
        document.insert(flat, at: index)
        return true
    }

    // MARK: Redaction

    /// Blacks out areas for good. The page is redrawn as a picture with black boxes on it, so the words underneath no longer exist in the file. (A black box laid over live text
    /// would hide it from view but leave it in the file.) The page can no longer be searched or selected.
    @discardableResult
    static func redact(_ rects: [CGRect], onPageAt index: Int, of document: PDFDocument, dpi: CGFloat = 200) -> Bool {
        guard index >= 0, index < document.pageCount, let page = document.page(at: index), !rects.isEmpty else { return false }
        guard let flat = redrawn(page, asPicture: true, dpi: dpi, drawing: { context, _ in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for r in rects { context.fill(r) }
        }) else { return false }
        document.removePage(at: index)
        document.insert(flat, at: index)
        return true
    }

    /// A copy of a page with extra drawing on top. `asPicture` renders the page to pixels first, which is what makes redaction real.
    private static func redrawn(_ page: PDFPage, asPicture: Bool = false, dpi: CGFloat = 200, drawing: (CGContext, CGRect) -> Void) -> PDFPage? {
        let box = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var media = CGRect(origin: .zero, size: box.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        context.beginPDFPage(nil)
        if asPicture {
            let scale = dpi / 72
            guard let bitmap = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)))
            bitmap.scaleBy(x: scale, y: scale)
            bitmap.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: bitmap)
            bitmap.translateBy(x: box.minX, y: box.minY)
            drawing(bitmap, media)
            if let image = bitmap.makeImage() { context.draw(image, in: media) }
        } else {
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
            context.translateBy(x: box.minX, y: box.minY)
            drawing(context, media)
        }
        context.endPDFPage(); context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    // MARK: Protection

    /// Writes a copy that needs a password to open. Returns false when the password is empty or the copy could not be written.
    static func writeProtected(_ document: PDFDocument, to url: URL, password: String) -> Bool {
        guard !password.isEmpty else { return false }
        return document.write(to: url, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
    }

    /// The document opened, if it needed no password or the right one was given.
    static func open(_ url: URL, password: String?) -> PDFDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isLocked { guard let password, document.unlock(withPassword: password) else { return nil } }
        return document
    }

    /// A name for the saved copy beside the original, that does not take an existing file's name.
    static func copyURL(for source: URL, suffix: String) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + " " + suffix
        let name = DownloadRouting.uniqueName(base + ".pdf") { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        return folder.appendingPathComponent(name)
    }
}

#if os(macOS)
typealias PDFFont = NSFont
typealias PDFBezierPath = NSBezierPath
#else
typealias PDFFont = UIFont
typealias PDFBezierPath = UIBezierPath
#endif

extension PDFBezierPath {
    /// One name for adding a line segment on both platforms.
    func extend(to point: CGPoint) {
        #if os(macOS)
        line(to: point)
        #else
        addLine(to: point)
        #endif
    }
}
