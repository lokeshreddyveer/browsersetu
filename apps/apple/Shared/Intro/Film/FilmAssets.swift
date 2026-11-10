import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// The asset contract: what the artwork must supply so the film can be built from it without changing the engine. Documented for artists in docs/intro-asset-contract.md.
// The artwork is declared in a manifest (Film/film.json in the app bundle), validated at launch, and kept out of the code. Without a valid manifest, the film is not shown (nothing placeholder ever reaches a person).

struct FilmManifest: Codable, Equatable {
    var version: Int
    var compositions: [String: Composition]       // "landscape" (Mac, iPad) and "portrait" (iPhone)
    var provenance: [Provenance]

    struct Composition: Codable, Equatable {
        var master: [Double]                       // the design space, [1920, 1080] or [1080, 1920]
        var screenQuad: [[Double]]                 // the laptop or phone screen's 4 corners (tl, tr, br, bl), in master space, at the camera's rest pose
        var screenSize: [Double]                   // the live page's own size, e.g. [1440, 900]
        var layers: [Layer]
    }
    struct Layer: Codable, Equatable {
        var id: String
        var role: String                           // room, laptop, person, handsA, handsB, foreground
        var file: String                           // an image in the asset catalog (transparent PNG or HEIC)
        var frame: [Double]                        // x, y, width, height in master space, at the camera's rest pose
        var depth: String                          // room, laptop, person, foreground: how much of the camera the layer follows
        var z: Int
    }
    struct Provenance: Codable, Equatable { var asset: String; var source: String; var license: String; var redistribution: String }
}

struct FilmIssue: Equatable, CustomStringConvertible {
    enum Severity { case error, warning }
    var severity: Severity
    var message: String
    var description: String { "\(severity == .error ? "error" : "warning"): \(message)" }
}

enum FilmAssetContract {
    static let requiredRoles = ["room", "laptop", "person", "handsA", "handsB"]
    static let optionalRoles = ["foreground"]
    static let depths: [String: CameraDepth] = ["room": .room, "laptop": .laptop, "person": .person, "foreground": .foreground]
    typealias CameraDepth = FilmCamera.Depth

    /// Checks a composition against the contract. Errors stop the film from being shown; warnings are reported.
    static func validate(_ manifest: FilmManifest, composition key: String, imageExists: (String) -> Bool = { _ in true }) -> [FilmIssue] {
        var issues: [FilmIssue] = []
        func err(_ m: String) { issues.append(FilmIssue(severity: .error, message: m)) }
        func warn(_ m: String) { issues.append(FilmIssue(severity: .warning, message: m)) }
        if manifest.version != 1 { err("unsupported manifest version \(manifest.version)") }
        guard let c = manifest.compositions[key] else { err("no \"\(key)\" composition"); return issues }
        guard c.master.count == 2, c.master[0] > 0, c.master[1] > 0 else { err("master must be [width, height]"); return issues }
        if c.screenSize.count != 2 || c.screenSize[0] <= 0 || c.screenSize[1] <= 0 { err("screenSize must be [width, height]") }
        // the screen quad: four points, inside the master space, convex, clockwise from the top left
        if c.screenQuad.count != 4 || c.screenQuad.contains(where: { $0.count != 2 }) { err("screenQuad must be four [x, y] points") }
        else {
            let q = c.screenQuad.map { CGPoint(x: $0[0], y: $0[1]) }
            if q.contains(where: { $0.x < 0 || $0.y < 0 || $0.x > c.master[0] || $0.y > c.master[1] }) { err("screenQuad has a corner outside the master space") }
            var sign = 0.0
            var convex = true
            for i in 0..<4 {
                let a = q[i], b = q[(i + 1) % 4], d = q[(i + 2) % 4]
                let cross = (b.x - a.x) * (d.y - b.y) - (b.y - a.y) * (d.x - b.x)
                if cross == 0 { convex = false }
                if sign == 0 { sign = cross } else if cross * sign < 0 { convex = false }
            }
            if !convex { err("screenQuad is not convex") }
            else if sign < 0 { err("screenQuad must run clockwise from the top left (tl, tr, br, bl)") }
        }
        var ids = Set<String>()
        for l in c.layers {
            if !ids.insert(l.id).inserted { err("duplicate layer id \(l.id)") }
            if l.frame.count != 4 || l.frame[2] <= 0 || l.frame[3] <= 0 { err("layer \(l.id): frame must be [x, y, width, height]") }
            if !(requiredRoles + optionalRoles).contains(l.role) { err("layer \(l.id): unknown role \(l.role)") }
            if depths[l.depth] == nil { err("layer \(l.id): unknown depth \(l.depth)") }
            if !imageExists(l.file) { err("layer \(l.id): image \"\(l.file)\" not found") }
            if !manifest.provenance.contains(where: { $0.asset == l.file }) { err("layer \(l.id): no provenance record for \"\(l.file)\" (source and licence are required)") }
        }
        for role in requiredRoles where !c.layers.contains(where: { $0.role == role }) { err("missing required layer role \(role)") }
        if let a = c.layers.first(where: { $0.role == "handsA" }), let b = c.layers.first(where: { $0.role == "handsB" }), a.frame != b.frame { err("handsA and handsB must share one frame (the poses differ only in the hands)") }
        for p in manifest.provenance where p.license.trimmingCharacters(in: .whitespaces).isEmpty || p.redistribution.trimmingCharacters(in: .whitespaces).isEmpty { warn("provenance for \(p.asset) has an empty licence or redistribution entry") }
        return issues
    }
}

/// What the film is built from.
enum FilmSource: Equatable {
    case production(FilmManifest)      // real artwork, validated
    case testPlates                    // disposable diagnostic plates, for engineering tests only (BS_FILM_TEST_PLATES=1)
    case unavailable                   // no artwork: the film is not shown
}

enum FilmAvailability {
    static var compositionKey: String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? "portrait" : "landscape"
        #else
        return "landscape"
        #endif
    }

    static func imageExists(_ name: String) -> Bool {
        #if canImport(AppKit)
        return NSImage(named: name) != nil
        #else
        return UIImage(named: name) != nil
        #endif
    }

    static func load(bundle: Bundle = .main, env: [String: String] = ProcessInfo.processInfo.environment) -> FilmSource {
        if env["BS_FILM_TEST_PLATES"] == "1" { return .testPlates }
        guard let url = bundle.url(forResource: "film", withExtension: "json", subdirectory: "Film") ?? bundle.url(forResource: "film", withExtension: "json"),
              let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(FilmManifest.self, from: data) else { return .unavailable }
        let issues = FilmAssetContract.validate(manifest, composition: compositionKey, imageExists: imageExists)
        return issues.contains(where: { $0.severity == .error }) ? .unavailable : .production(manifest)
    }

    /// The film is shown only when there is something real (or a test plate) to show.
    static var isAvailable: Bool { if case .unavailable = load() { return false } else { return true } }
}

/// Disposable plates for engineering tests: obviously diagnostic (grids, labels, registration marks), never artwork. Used only when BS_FILM_TEST_PLATES=1.
enum FilmTestPlates {
    static func composition(_ key: String) -> FilmManifest.Composition {
        let portrait = key == "portrait"
        let master: [Double] = portrait ? [1080, 1920] : [1920, 1080]
        // a slightly turned screen, so perspective is exercised
        let quad: [[Double]] = portrait ? [[190, 420], [900, 400], [915, 1480], [175, 1500]] : [[640, 232], [1500, 205], [1522, 760], [618, 776]]
        func layer(_ id: String, _ role: String, _ depth: String, _ z: Int) -> FilmManifest.Layer { .init(id: id, role: role, file: "test.\(role)", frame: [0, 0, master[0], master[1]], depth: depth, z: z) }
        return .init(master: master, screenQuad: quad, screenSize: portrait ? [900, 1600] : [1440, 900],
                     layers: [layer("room", "room", "room", 0), layer("laptop", "laptop", "laptop", 1), layer("person", "person", "person", 3), layer("hands.a", "handsA", "person", 4), layer("hands.b", "handsB", "person", 4)])
    }
}
