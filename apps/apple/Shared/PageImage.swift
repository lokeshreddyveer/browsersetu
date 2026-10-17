import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Turns what WebKit hands back (a picture, or a PDF of the whole page) into PNG data.
enum PageImage {
    /// The tallest picture made of a page, in pixels. Longer pages are cut off at the bottom rather than failing.
    static let maxHeight: CGFloat = 16_000

    static func png(from image: PlatformImage) -> Data? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return png(from: cg)
        #else
        return image.pngData()
        #endif
    }

    static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// One tall picture of every page of the PDF, top to bottom, on white. Used for the full-page screenshot.
    static func png(fromPDF pdf: Data, scale: CGFloat = 2) -> Data? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return nil }
        var pages: [CGPDFPage] = []
        for number in 1...document.numberOfPages { if let page = document.page(at: number) { pages.append(page) } }
        let boxes = pages.map { $0.getBoxRect(.mediaBox) }
        let width = (boxes.map(\.width).max() ?? 0) * scale
        var height = boxes.reduce(0) { $0 + $1.height } * scale
        guard width > 0, height > 0 else { return nil }
        height = min(height, maxHeight)
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var top = height          // pages stack from the top down; the context's origin is the bottom
        for (page, box) in zip(pages, boxes) {
            let pageHeight = box.height * scale
            top -= pageHeight
            context.saveGState()
            context.translateBy(x: 0, y: top)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.origin.x, y: -box.origin.y)
            context.drawPDFPage(page)
            context.restoreGState()
            if top <= 0 { break }
        }
        return context.makeImage().flatMap { png(from: $0) }
    }
}
