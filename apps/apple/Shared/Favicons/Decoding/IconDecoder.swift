import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Turns untrusted icon bytes into one small, safe PNG. No UI framework drawing on the main thread, no trust in declared types or file names.
///
/// What it enforces, before anything large is decoded:
///  - at most `maxInputBytes` of input, at most `maxFrames` frames (an ICO is a list of images),
///  - every frame at most `maxDimension` on a side and `maxPixels` in all, so a tiny file that expands to a huge picture is refused,
///  - the picture is decoded as a thumbnail of at most `thumbnailSide` pixels, so even an accepted image is never held in full,
///  - SVG only after `SVGSanitizer` finds nothing active or external in it (macOS only; elsewhere an SVG is refused).
/// The output is always a `outputSide` x `outputSide` PNG, transparent padding, drawn to fit.
enum IconDecoder {
    static let outputSide = 64
    static let thumbnailSide = 128
    static let maxInputBytes = 300_000
    static let maxDimension = 4_096
    static let maxPixels = 4_194_304
    static let maxFrames = 32
    static let minLongSide = 8
    static let allowedTypes: Set<String> = ["public.png", "public.jpeg", "com.compuserve.gif", "com.microsoft.ico", "com.microsoft.bmp", "org.webmproject.webp", "public.heic", "public.heif"]

    struct Output: Sendable, Equatable {
        var png: Data
        /// The size of the picture that was chosen, before it was fitted into the output square.
        var sourceWidth: Int
        var sourceHeight: Int
    }

    enum Failure: String, Error, Sendable, Equatable {
        case empty, tooLarge, notAnImage, tooManyFrames, dimensionsTooLarge, tooSmall, unsafeSVG, unsupported, renderFailed
    }

    static func decode(_ data: Data) -> Result<Output, Failure> {
        guard data.count > 16 else { return .failure(.empty) }
        guard data.count <= maxInputBytes else { return .failure(.tooLarge) }
        if SVGSanitizer.looksLikeSVG(data) { return decodeSVG(data) }
        return decodeRaster(data)
    }

    // MARK: Raster (PNG, ICO, GIF, JPEG, WebP, ...)

    private static func decodeRaster(_ data: Data) -> Result<Output, Failure> {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return .failure(.notAnImage) }
        // Only the formats an icon is ever served in. ImageIO also reads RAW, TIFF, PSD, EXR and more, which a page has no business sending here.
        guard let type = CGImageSourceGetType(source) as String?, allowedTypes.contains(type) else { return .failure(.notAnImage) }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return .failure(.notAnImage) }
        guard count <= maxFrames else { return .failure(.tooManyFrames) }

        var best: (index: Int, width: Int, height: Int)?
        for index in 0..<count {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, options as CFDictionary) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { continue }
            guard w <= maxDimension, h <= maxDimension, w * h <= maxPixels else { return .failure(.dimensionsTooLarge) }
            let side = max(w, h)
            if let current = best {
                let c = max(current.width, current.height)
                // The smallest frame that is at least as large as the output; otherwise the largest there is.
                let better = (side >= outputSide && (c < outputSide || side < c)) || (side < outputSide && c < outputSide && side > c)
                if better { best = (index, w, h) }
            } else { best = (index, w, h) }
        }
        guard let chosen = best else { return .failure(.notAnImage) }
        guard max(chosen.width, chosen.height) >= minLongSide else { return .failure(.tooSmall) }

        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: thumbnailSide, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, chosen.index, thumb as CFDictionary) else { return .failure(.notAnImage) }
        guard let png = fittedPNG(image) else { return .failure(.renderFailed) }
        return .success(Output(png: png, sourceWidth: chosen.width, sourceHeight: chosen.height))
    }

    /// The picture drawn to fit a transparent `outputSide` square, as PNG data.
    private static func fittedPNG(_ image: CGImage) -> Data? {
        let side = outputSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(CGFloat(side) / max(w, 1), CGFloat(side) / max(h, 1))
        let dw = w * scale, dh = h * scale
        context.draw(image, in: CGRect(x: (CGFloat(side) - dw) / 2, y: (CGFloat(side) - dh) / 2, width: dw, height: dh))
        guard let out = context.makeImage() else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, out, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    // MARK: SVG

    private static func decodeSVG(_ data: Data) -> Result<Output, Failure> {
        guard SVGSanitizer.isSafe(data) else { return .failure(.unsafeSVG) }
        #if os(macOS)
        guard let image = NSImage(data: data) else { return .failure(.unsupported) }
        // A size the file declares is not trusted: it must be a real, finite number, and is clamped before it is used for anything.
        let declaredW = image.size.width, declaredH = image.size.height
        guard declaredW.isFinite, declaredH.isFinite, declaredW > 0, declaredH > 0 else { return .failure(.unsupported) }
        let w = min(declaredW, CGFloat(maxDimension)), h = min(declaredH, CGFloat(maxDimension))
        let side = outputSide
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return .failure(.renderFailed) }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let scale = min(CGFloat(side) / w, CGFloat(side) / h)
        let dw = w * scale, dh = h * scale
        image.draw(in: NSRect(x: (CGFloat(side) - dw) / 2, y: (CGFloat(side) - dh) / 2, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.current = previous
        guard let png = rep.representation(using: .png, properties: [:]) else { return .failure(.renderFailed) }
        return .success(Output(png: png, sourceWidth: Int(w), sourceHeight: Int(h)))
        #else
        return .failure(.unsupported)
        #endif
    }
}

/// Decides whether an SVG may be drawn at all. It does not clean an SVG up: anything outside a small allowlist makes it unsafe and the icon is refused (the site's
/// /favicon.ico is tried next).
///
/// The file is parsed as XML (external entities off), not searched for strings, so a namespace prefix (`<s:script>`), a character reference (`u&#114;l(`) or odd whitespace
/// cannot get past it: the rules see what a renderer would see.
///  - elements: only plain shapes, gradients, clip paths, masks, symbols, `use`, `style`, `title` and `desc`, whatever their prefix; no `script`, `image`, `foreignObject`, `a`, `text`, `animate`, `set`, filters;
///  - a `style` element or attribute is parsed, not searched: plain `selector { property: value }` rules, a short list of painting properties, no at-rules (`@import`, `@font-face`), no escapes, no `url()` that leaves the file (see `SVGStyle`);
///  - the root must be `svg`, in the SVG namespace; no element in any other namespace;
///  - attributes: no `on*` handler, no `style`; every `href` is `#...` (inside the file); every `url(...)` is `url(#...)`; no `javascript:`, `data:` or `@import`;
///  - no document type declaration except the standard public SVG one, no entities, no `xml-stylesheet`;
///  - at most 100 KB, 400 elements, 24 levels deep.
enum SVGSanitizer {
    static let maxBytes = 100_000
    static let maxElements = 400
    static let maxDepth = 24

    static func looksLikeSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1_024), as: UTF8.self).lowercased()
        return head.contains("<svg") || (head.contains("<?xml") && head.contains("svg"))
    }

    static func isSafe(_ data: Data) -> Bool {
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        if lower.contains("<!doctype"),
           lower.range(of: ##"<!doctype\s+svg\s+public\s+"-//w3c//dtd svg [^"]*"\s+"[^"]*"\s*>"##, options: .regularExpression) == nil { return false }
        if lower.contains("<!entity") || lower.contains("<!element") || lower.contains("<!attlist") || lower.contains("<?xml-stylesheet") { return false }
        let validator = SVGValidator()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        return parser.parse() && !validator.rejected && validator.sawRoot
    }
}

private final class SVGValidator: NSObject, XMLParserDelegate {
    static let allowed: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "lineargradient", "radialgradient", "stop", "clippath", "mask", "use", "symbol", "style", "title", "desc"]
    static let svgNamespace = "http://www.w3.org/2000/svg"
    var rejected = false
    var sawRoot = false
    private var depth = 0
    private var elements = 0
    private var inStyle = false
    private var sheet = ""

    private func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }
    private func local(_ name: String) -> String { (name.split(separator: ":").last.map(String.init) ?? name).lowercased() }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elements += 1; depth += 1
        if elements > SVGSanitizer.maxElements || depth > SVGSanitizer.maxDepth { return reject(parser) }
        let name = local(elementName)
        if let namespaceURI, !namespaceURI.isEmpty, namespaceURI != Self.svgNamespace { return reject(parser) }
        if depth == 1 { sawRoot = true; guard name == "svg" else { return reject(parser) } }
        guard Self.allowed.contains(name) else { return reject(parser) }
        if name == "style" {
            if let type = attributeDict["type"], type.lowercased() != "text/css" { return reject(parser) }
            inStyle = true; sheet = ""
        }
        for (key, value) in attributeDict {
            let attribute = local(key), text = value.lowercased()
            if attribute.hasPrefix("on") { return reject(parser) }
            if attribute == "style", !SVGStyle.isSafe(declarations: value) { return reject(parser) }
            if attribute == "href", !value.hasPrefix("#") { return reject(parser) }
            if text.contains("javascript:") || text.contains("data:") || text.contains("@import") { return reject(parser) }
            if text.range(of: ##"url\(\s*["']?(?!#)"##, options: .regularExpression) != nil { return reject(parser) }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        if inStyle, local(elementName) == "style" {
            inStyle = false
            if !SVGStyle.isSafe(sheet: sheet) { reject(parser) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inStyle { sheet += string; if sheet.utf8.count > 20_000 { reject(parser) } } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if inStyle { sheet += String(decoding: CDATABlock, as: UTF8.self); if sheet.utf8.count > 20_000 { reject(parser) } } }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { rejected = true }
}


/// The small part of CSS an icon needs: plain rules that set painting properties. Parsed, not searched, so an escape (`\75rl(`), a comment in the middle of a word, an at-rule
/// or an unknown property is refused rather than guessed at. Anything this does not recognise makes the whole stylesheet unsafe.
enum SVGStyle {
    static let properties: Set<String> = ["fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
                                          "opacity", "fill-opacity", "stroke-opacity", "fill-rule", "clip-rule", "stop-color", "stop-opacity", "color", "display", "visibility"]
    static let maxBytes = 20_000

    static func isSafe(sheet raw: String) -> Bool {
        guard raw.utf8.count <= maxBytes else { return false }
        var text = raw
        // Comments are removed first (an unterminated one is refused), so nothing can hide in one.
        while let open = text.range(of: "/*") {
            guard let close = text.range(of: "*/", range: open.upperBound..<text.endIndex) else { return false }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // At-rules (@import, @font-face, @media), escapes and markup have no place in an icon's stylesheet.
        if text.contains("@") || text.contains("\\") || text.contains("<") || text.contains("&") { return false }
        var rest = Substring(text)
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.isEmpty { return true }
            guard let open = rest.firstIndex(of: "{"), let close = rest.firstIndex(of: "}"), open < close else { return false }
            guard selectorIsSafe(rest[..<open]), isSafe(declarations: String(rest[rest.index(after: open)..<close])) else { return false }
            rest = rest[rest.index(after: close)...]
        }
    }

    /// Element, class and id selectors, `*`, lists and descendant or child combinators. No attribute selectors and no pseudo-classes.
    static func selectorIsSafe(_ selector: Substring) -> Bool {
        let text = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200 else { return false }
        return text.range(of: #"^[A-Za-z0-9_.#*,\s>-]+$"#, options: .regularExpression) != nil
    }

    static func isSafe(declarations: String) -> Bool {
        for part in declarations.split(separator: ";") {
            let declaration = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if declaration.isEmpty { continue }
            guard let colon = declaration.firstIndex(of: ":") else { return false }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            guard properties.contains(name) else { return false }
            if value.hasSuffix("!important") { value = String(value.dropLast("!important".count)).trimmingCharacters(in: .whitespaces) }
            // Numbers, colours, keywords and `url(#id)`: no quotes, no colons, no backslashes, so no scheme and no escape can be written.
            guard value.range(of: #"^[a-z0-9#%.,()\s\-+/]*$"#, options: .regularExpression) != nil else { return false }
            if value.range(of: #"url\(\s*(?!#)"#, options: .regularExpression) != nil { return false }
            if value.contains("expression") || value.contains("behavior") || value.contains("binding") { return false }
        }
        return true
    }
}
