import SwiftUI
import ImageIO

// The start page's picture: how it is positioned and adjusted, what the picture looks like (so the text on top stays readable), a small cache so it is
// decoded once and not on every redraw, and the quiet effects drawn over it. Everything here is local: no picture, colour or position ever leaves the device.

/// How the picture sits and is treated, kept as one setting so there is one place to reset and nothing to get out of step.
struct StartLook: Codable, Equatable {
    /// Which part of the picture stays in view when the window is a different shape (0 to 1 across and down), independent of the screen's size.
    var focalX = 0.5
    var focalY = 0.5
    /// Fit the whole picture inside the window instead of filling it.
    var fit = false
    var saturation = 1.0
    var brightness = 0.0
    /// Text and controls take light or dark ink to suit the middle of the picture.
    var adaptiveText = true
    /// A faint glow of the picture's own colour behind the content.
    var ambient = true
    /// A very soft light that follows the pointer (Mac).
    var pointerGlow = false
    /// The picture moves a few points against the pointer (Mac).
    var parallax = false
    /// The picture moves a few points as the device is tilted (iPhone and iPad). A flat picture has no real depth: this is a small shift, not a 3D effect.
    var motion = false

    enum CodingKeys: String, CodingKey { case focalX, focalY, fit, saturation, brightness, adaptiveText, ambient, pointerGlow, parallax, motion }

    func clamped() -> StartLook {
        var v = self
        v.focalX = min(max(v.focalX, 0), 1); v.focalY = min(max(v.focalY, 0), 1)
        v.saturation = min(max(v.saturation, 0), 2); v.brightness = min(max(v.brightness, -0.4), 0.4)
        return v
    }

    var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    /// What was saved; anything unreadable gives the defaults, and every value is brought back into range.
    static func decode(_ text: String?) -> StartLook {
        guard let text, let data = text.data(using: .utf8), let look = try? JSONDecoder().decode(StartLook.self, from: data) else { return StartLook() }
        return look.clamped()
    }
}

extension StartLook {
    /// A key that is missing (a look saved by an older or newer version) takes its default; it does not throw the whole look away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StartLook()
        focalX = try c.decodeIfPresent(Double.self, forKey: .focalX) ?? d.focalX
        focalY = try c.decodeIfPresent(Double.self, forKey: .focalY) ?? d.focalY
        fit = try c.decodeIfPresent(Bool.self, forKey: .fit) ?? d.fit
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? d.saturation
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        adaptiveText = try c.decodeIfPresent(Bool.self, forKey: .adaptiveText) ?? d.adaptiveText
        ambient = try c.decodeIfPresent(Bool.self, forKey: .ambient) ?? d.ambient
        pointerGlow = try c.decodeIfPresent(Bool.self, forKey: .pointerGlow) ?? d.pointerGlow
        parallax = try c.decodeIfPresent(Bool.self, forKey: .parallax) ?? d.parallax
        motion = try c.decodeIfPresent(Bool.self, forKey: .motion) ?? d.motion
    }
}

/// What a picture looks like, worked out once when it is chosen: how bright the middle is (where the text sits) and its main colour.
struct WallpaperAnalysis: Equatable {
    var luminance: Double
    var centerLuminance: Double
    var r: Double
    var g: Double
    var b: Double

    var tint: Color { Color(red: r, green: g, blue: b) }
}

enum WallpaperAnalyzer {
    /// From a 48-point copy of the picture, so it takes a few milliseconds. Nil for something that is not a picture.
    static func analyze(_ data: Data) -> WallpaperAnalysis? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 48,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var all = 0.0, allCount = 0.0, middle = 0.0, middleCount = 0.0
        var tr = 0.0, tg = 0.0, tb = 0.0, weights = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                all += luma; allCount += 1
                // Where the greeting, the search field and the favorites sit.
                if x >= w / 5, x < w * 4 / 5, y >= h / 5, y < h * 3 / 4 {
                    middle += luma; middleCount += 1
                    // Colourful pixels count for more than grey ones, so a mostly grey sky does not make the glow grey.
                    let weight = 0.05 + (max(r, g, b) - min(r, g, b))
                    tr += r * weight; tg += g * weight; tb += b * weight; weights += weight
                }
            }
        }
        guard allCount > 0, middleCount > 0, weights > 0 else { return nil }
        return WallpaperAnalysis(luminance: all / allCount, centerLuminance: middle / middleCount, r: tr / weights, g: tg / weights, b: tb / weights)
    }
}

enum StartReadability {
    /// True when dark text reads better over the middle of the picture as it is shown (darkened and adjusted), false for light text; nil when nothing is known.
    static func prefersDarkInk(_ analysis: WallpaperAnalysis?, dim: Double, brightness: Double) -> Bool? {
        guard let analysis else { return nil }
        return analysis.centerLuminance * (1 - dim) + brightness > 0.55
    }
}

/// Decoded pictures, kept by size so a window that is resized or a second start page does not decode the same file again. The system empties it under memory pressure.
enum WallpaperImages {
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    /// Bounded by memory, not only by count: a 3840-point picture is about 60 MB decoded.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 6; c.totalCostLimit = 200_000_000; return c }()
    /// The longest side a stored picture keeps, and the largest step the cache decodes: enough for a 5K display.
    static let longestSide = 3840

    private static func fingerprint(_ data: Data) -> String { "\(data.count)-\(data.prefix(32).hashValue)-\(data.suffix(32).hashValue)" }

    /// Changes when the picture does, and only then: what a crossfade between two pictures is keyed on.
    static func identity(_ data: Data) -> String { fingerprint(data) }

    /// A picture made ready to keep: turned upright, cut down to `longestSide` (never enlarged), re-encoded as a good-quality JPEG with no camera or location details.
    /// Nil for something that is not a picture, or one too large to open safely (over 120 million pixels).
    static func prepared(_ data: Data, longSide: Int = longestSide) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= 120_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: min(longSide, max(width, height)),
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        // Only the pixels are added: no EXIF, GPS or maker notes are carried over.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    nonisolated(unsafe) private static var recent: [String: [Int]] = [:]
    nonisolated(unsafe) private static var holders: [String: Int] = [:]
    /// The small sizes decoded on the spot (placeholders, thumbnails), per picture, so letting the picture go lets them go too.
    nonisolated(unsafe) private static var small: [String: Set<Int>] = [:]
    private static let lock = NSLock()

    private static func key(_ id: String, _ bucket: Int) -> NSString { "\(id)-\(bucket)" as NSString }

    /// The size to decode for a picture drawn this many pixels on its long side: in steps of 320 up to `longestSide`.
    static func bucket(for longSide: CGFloat) -> Int {
        let steps = min(max((longSide / 320).rounded(.up), 1), CGFloat(longestSide / 320))
        return Int(steps) * 320
    }

    /// The picture, if it has already been decoded at this size.
    static func cached(_ data: Data, bucket: Int) -> CGImage? { cache.object(forKey: key(fingerprint(data), bucket))?.image }

    /// Decodes at this size off the main thread and keeps the result. Of all the sizes of one picture only this one and the one before it stay (a window being resized shows
    /// the old size until the new one is ready); the rest are let go at once, so resizing never piles up copies.
    static func decode(_ data: Data, bucket: Int) async -> CGImage? {
        let id = fingerprint(data)
        if let hit = cache.object(forKey: key(id, bucket)) { return hit.image }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            #if DEBUG
            let start = DispatchTime.now(), onMain = Thread.isMainThread
            let result = decodeSync(data, bucket: bucket)
            record(onMain: onMain, bucket: bucket, ms: Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            return result
            #else
            return decodeSync(data, bucket: bucket)
            #endif
        }.value
        guard let image else { return nil }
        lock.lock(); defer { lock.unlock() }
        // A page that went away while this was decoding has already let the picture go: the result is handed back but not kept, so nothing is left behind with no one to free it.
        guard (holders[id] ?? 0) > 0 else { return image }
        cache.setObject(Box(image), forKey: key(id, bucket), cost: image.width * image.height * 4)
        var sizes = recent[id] ?? []
        sizes.removeAll { $0 == bucket }
        sizes.insert(bucket, at: 0)
        for old in sizes.dropFirst(2) { cache.removeObject(forKey: key(id, old)) }
        recent[id] = Array(sizes.prefix(2))
        return image
    }

    /// A start page is showing this picture; it is let go (every decoded size of it) when the last page showing it goes.
    static func retain(_ id: String) { lock.lock(); holders[id, default: 0] += 1; lock.unlock() }

    static func release(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        holders[id, default: 1] -= 1
        guard (holders[id] ?? 0) <= 0 else { return }
        holders[id] = nil
        for size in recent[id] ?? [] { cache.removeObject(forKey: key(id, size)) }
        for size in small[id] ?? [] { cache.removeObject(forKey: key(id, size)) }
        recent[id] = nil
        small[id] = nil
    }

    private static func decodeSync(_ data: Data, bucket: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              // Never more pixels than the picture has: a small picture is not enlarged here, it is scaled when drawn.
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(bucket, max(width, height)),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// The picture at about this many pixels on its long side, decoded here and now. For small sizes only (thumbnails, the placeholder shown while a full-size one decodes);
    /// a full-size picture is decoded with `decode`, off the main thread.
    static func image(_ data: Data, longSide: CGFloat) -> CGImage? {
        let size = bucket(for: longSide)
        let id = fingerprint(data)
        if let hit = cache.object(forKey: key(id, size)) { return hit.image }
        guard let image = decodeSync(data, bucket: size) else { return nil }
        cache.setObject(Box(image), forKey: key(id, size), cost: image.width * image.height * 4)
        lock.lock(); small[id, default: []].insert(size); lock.unlock()
        return image
    }

    /// How many decoded sizes are kept for a picture (tests).
    static func keptSizes(_ data: Data) -> Int {
        let id = fingerprint(data)
        lock.lock(); defer { lock.unlock() }
        return (recent[id]?.count ?? 0) + (small[id]?.count ?? 0)
    }

    #if DEBUG
    nonisolated(unsafe) private static var decodeLog: [String] = []
    private static func record(onMain: Bool, bucket: Int, ms: Double) {
        lock.lock(); decodeLog.append("\(onMain ? "MAIN" : "off")/\(bucket)/\(Int(ms))ms"); lock.unlock()
    }
    /// Development only: how many decodes ran and where, and which sizes of which pictures are kept.
    static var debugState: String {
        lock.lock(); defer { lock.unlock() }
        return "pictures=\(recent.count) held=\(holders.values.reduce(0, +)) sizes=\(recent.values.map { $0.map(String.init).joined(separator: "/") }) decodes=\(decodeLog.count) onMain=\(decodeLog.filter { $0.hasPrefix("MAIN") }.count) last=\(decodeLog.suffix(3))"
    }
    #endif

    /// When every picture is removed or replaced.
    static func clear() {
        cache.removeAllObjects()
        lock.lock(); recent = [:]; small = [:]; lock.unlock()
    }
}

/// Where the pointer is over the start page. Only the background watches it, so moving the mouse never redraws the page's content.
final class StartPointer: ObservableObject {
    @Published var point: CGPoint?
    /// How far the device is tilted, from -0.5 to 0.5 each way (iPhone and iPad), when the motion effect is on.
    @Published var tilt: CGSize?
}

/// The picture, positioned and adjusted, with the ambient glow, the local scrim and the pointer effects over it.
struct StartBackdrop: View {
    let data: Data
    let look: StartLook
    let dim: Double
    let blur: Double
    let analysis: WallpaperAnalysis?
    @ObservedObject var pointer: StartPointer
    /// An animated wallpaper plays over the picture (which stays as its poster frame) while this is true.
    var playsVideo = false
    /// The full-size picture once decoded (nil until then).
    @State private var shown: CGImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let moving = (look.parallax || look.motion) && !reduceMotion
            ZStack(alignment: .topLeading) {
                // What shows if the picture cannot be read at all (a damaged file): the page's own dark background, never a black hole, never a broken-image mark.
                Color(red: 0.047, green: 0.059, blue: 0.090)
                // The full-size picture is decoded off the main thread; until it is ready (and while a resized window waits for its new size) the last one, or a small one, is drawn.
                if let cg = shown ?? WallpaperImages.image(data, longSide: 640) {
                    adjusted(picture(cg, in: size))
                        .scaleEffect(1 + blur / 400 + (moving ? 0.04 : 0))
                        .offset(shift(in: size, moving: moving))
                        .animation(.easeOut(duration: 0.4), value: shift(in: size, moving: moving))
                }
                if playsVideo { AnimatedWallpaperLayer().frame(width: size.width, height: size.height).transition(.opacity) }
                Color.black.opacity(dim)
                if look.adaptiveText, let darkInk = StartReadability.prefersDarkInk(analysis, dim: dim, brightness: look.brightness) {
                    // A soft pool behind the content, not a darkening of the whole picture: the rest of it keeps all its detail.
                    RadialGradient(colors: [(darkInk ? Color.white.opacity(0.20) : Color.black.opacity(0.26)), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: min(size.width, size.height) * 0.7)
                }
                if look.ambient, let analysis {
                    RadialGradient(colors: [analysis.tint.opacity(0.20), .clear], center: UnitPoint(x: 0.5, y: 0.36), startRadius: 0, endRadius: min(size.width, size.height) * 0.7)
                }
                if look.pointerGlow, let p = pointer.point {
                    RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: UnitPoint(x: p.x / max(size.width, 1), y: p.y / max(size.height, 1)), startRadius: 0, endRadius: 240)
                        .blendMode(.plusLighter)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .task(id: WallpaperDecodeKey(id: WallpaperImages.identity(data), bucket: WallpaperImages.bucket(for: max(size.width, size.height) * displayScale * (moving ? 1.06 : 1)))) {
                let bucket = WallpaperImages.bucket(for: max(size.width, size.height) * displayScale * (moving ? 1.06 : 1))
                if let hit = WallpaperImages.cached(data, bucket: bucket) { shown = hit; return }
                let made = await WallpaperImages.decode(data, bucket: bucket)
                if !Task.isCancelled, let made { shown = made }
            }
        }
        .animation(.easeOut(duration: 0.3), value: pointer.point == nil)
        .accessibilityHidden(true)
        .onAppear { WallpaperImages.retain(WallpaperImages.identity(data)) }
        .onDisappear { WallpaperImages.release(WallpaperImages.identity(data)); shown = nil }
    }

    private struct WallpaperDecodeKey: Hashable { var id: String; var bucket: Int }

    /// Saturation, brightness and blur are only applied when they change something: each one, even at its neutral value, makes the picture go through an extra
    /// off-screen render pass, which costs memory for nothing.
    @ViewBuilder private func adjusted<V: View>(_ view: V) -> some View {
        if look.saturation == 1, look.brightness == 0, blur == 0 { view }
        else { view.saturation(look.saturation).brightness(look.brightness).blur(radius: blur) }
    }

    /// Fill or fit, with the chosen point of the picture kept in view: the same fraction of the picture and of the window line up.
    private func picture(_ cg: CGImage, in size: CGSize) -> some View {
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let scale = look.fit ? min(size.width / iw, size.height / ih) : max(size.width / iw, size.height / ih)
        // Whole device pixels for the size and the position: a picture drawn at a fraction of a pixel is resampled, and looks soft.
        let pixel = max(displayScale, 1)
        func snapped(_ value: CGFloat) -> CGFloat { (value * pixel).rounded() / pixel }
        let w = (iw * scale * pixel).rounded(.up) / pixel, h = (ih * scale * pixel).rounded(.up) / pixel
        return Image(decorative: cg, scale: 1)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: w, height: h)
            .offset(x: snapped((size.width - w) * look.focalX), y: snapped((size.height - h) * look.focalY))
    }

    /// A few points against the pointer or the tilt of the device, at most.
    private func shift(in size: CGSize, moving: Bool) -> CGSize {
        if moving, let tilt = pointer.tilt { return CGSize(width: -min(max(tilt.width, -0.5), 0.5) * 16, height: -min(max(tilt.height, -0.5), 0.5) * 16) }
        guard moving, let p = pointer.point, size.width > 0, size.height > 0 else { return .zero }
        let nx = min(max(p.x / size.width - 0.5, -0.5), 0.5), ny = min(max(p.y / size.height - 0.5, -0.5), 0.5)
        return CGSize(width: -nx * 16, height: -ny * 16)
    }
}

/// A small copy of the picture to drag a dot on: whatever the dot is over stays in view when the window changes shape.
struct FocalPointPad: View {
    let data: Data
    @Binding var look: StartLook

    private static let presets: [(String, Double, Double)] = [("Center", 0.5, 0.5), ("Top", 0.5, 0), ("Bottom", 0.5, 1), ("Left", 0, 0.5), ("Right", 1, 0.5)]

    var body: some View {
        VStack(spacing: 6) {
            pad
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.0) { preset in
                    Button(preset.0) { animated(.easeOut(duration: 0.18)) { look.focalX = preset.1; look.focalY = preset.2 } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Keep the \(preset.0.lowercased()) of the picture in view")
                }
            }
        }
    }

    private var pad: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let cg = WallpaperImages.image(data, longSide: 480) {
                    Image(decorative: cg, scale: 1).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                Circle().strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().fill(Color.black.opacity(0.25)))
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: look.focalX * geo.size.width, y: look.focalY * geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                look.focalX = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                look.focalY = min(max(value.location.y / max(geo.size.height, 1), 0), 1)
            })
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.8))
        .accessibilityElement()
        .accessibilityLabel("Picture position")
        .accessibilityValue("\(Int(look.focalX * 100)) percent across, \(Int(look.focalY * 100)) percent down")
        .accessibilityAdjustableAction { direction in
            look.focalX = min(max(look.focalX + (direction == .increment ? 0.1 : -0.1), 0), 1)
        }
    }
}
