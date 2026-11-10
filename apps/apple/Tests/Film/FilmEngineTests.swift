import XCTest
@testable import Browser_Setu

/// The film engine, with no artwork: timeline arithmetic, easing, camera continuity, perspective mapping, the asset contract and availability. Nothing here depends on how the film looks.
final class FilmEngineTests: XCTestCase {

    // MARK: timeline

    func testTheFilmIsNineSecondsAtSixtyFramesPerSecond() {
        XCTAssertEqual(FilmSpec.frames, 540)
        XCTAssertEqual(FilmSpec.fps, 60)
        XCTAssertEqual(FilmSpec.duration, 9.0, accuracy: 1e-9)
        XCTAssertEqual(FilmSpec.frame(atTime: 1.0), 60, accuracy: 1e-9)
        XCTAssertEqual(FilmSpec.frame(atTime: 100), 539, "clamped to the last frame")
        XCTAssertEqual(FilmSpec.frame(atTime: -3), 0)
    }

    func testTheScenesCoverEveryFrameExactlyOnce() {
        var next = 0
        for scene in FilmSpec.scenes {
            XCTAssertEqual(scene.frames.lowerBound, next, "scene \(scene.id) starts where the last ended")
            next = scene.frames.upperBound + 1
        }
        XCTAssertEqual(next, FilmSpec.frames)
        for f in 0..<FilmSpec.frames { XCTAssertNotNil(FilmSpec.scene(ofFrame: f), "frame \(f) belongs to a scene") }
    }

    func testTheCheckpointsAreInRangeSortedAndIncludeEverySceneBoundary() {
        XCTAssertEqual(FilmSpec.checkpoints, FilmSpec.checkpoints.sorted())
        XCTAssertEqual(Set(FilmSpec.checkpoints).count, FilmSpec.checkpoints.count)
        XCTAssertTrue(FilmSpec.checkpoints.allSatisfy { (0..<FilmSpec.frames).contains($0) })
        for s in FilmSpec.scenes { XCTAssertTrue(FilmSpec.checkpoints.contains(s.frames.lowerBound), "start of scene \(s.id)"); XCTAssertTrue(FilmSpec.checkpoints.contains(s.frames.upperBound), "end of scene \(s.id)") }
        XCTAssertEqual(FilmSpec.checkpoints.count, 26)
    }

    func testTheCuesAreInsideTheFilmAndInOrder() {
        let order: [(Double, Double)] = [FilmCue.separate, FilmCue.requests, FilmCue.settle, FilmCue.adGrows, FilmCue.tracker, FilmCue.link, FilmCue.edgeTravels, FilmCue.boundaryCompletes, FilmCue.trackerFiltered, FilmCue.addressCleaned, FilmCue.settleProtection, FilmCue.calm, FilmCue.dissolve, FilmCue.brand]
        for c in order { XCTAssertLessThan(c.0, c.1); XCTAssertGreaterThanOrEqual(c.0, 0); XCTAssertLessThanOrEqual(c.1, FilmSpec.duration) }
        XCTAssertLessThanOrEqual(FilmCue.separate.1, FilmCue.requests.0 + 1e-9)
        XCTAssertLessThanOrEqual(FilmCue.settle.1, FilmCue.adGrows.0 + 1e-9, "the unseen activity settles before the first event")
        XCTAssertLessThanOrEqual(FilmCue.link.1, FilmCue.edgeTravels.0 + 1e-9, "the three events are over before the boundary lights")
        XCTAssertLessThanOrEqual(FilmCue.dissolve.1, FilmCue.brand.0 + 0.1)
    }

    // MARK: easing and tracks

    func testEveryCurveIsAnchoredAndMonotonic() {
        for c in [CubicBezier.linear, .easeInOut, .settle, .pullBack, .toBrand] {
            XCTAssertEqual(c.value(0), 0); XCTAssertEqual(c.value(1), 1)
            var last = -1.0
            for i in 0...200 { let v = c.value(Double(i) / 200); XCTAssertGreaterThanOrEqual(v, last - 1e-9); last = v }
        }
        XCTAssertEqual(CubicBezier.linear.value(0.37), 0.37, accuracy: 1e-6)
    }

    func testATrackInterpolatesBetweenItsKeysAndHoldsAtTheEnds() {
        let t = Track([.init(frame: 10, value: 0), .init(frame: 20, value: 1), .init(frame: 30, value: 0.5)])
        XCTAssertEqual(t.value(at: 0), 0); XCTAssertEqual(t.value(at: 10), 0); XCTAssertEqual(t.value(at: 15), 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.value(at: 20), 1); XCTAssertEqual(t.value(at: 25), 0.75, accuracy: 1e-9); XCTAssertEqual(t.value(at: 99), 0.5)
    }

    // MARK: camera

    func testTheCameraIsContinuousEverywhereAndStillAtEverySegmentBoundary() {
        let eps = 0.01
        for b in [120.0, 228, 432, 471, 531] {
            let before = FilmCamera.state(atFrame: b - eps), at = FilmCamera.state(atFrame: b), after = FilmCamera.state(atFrame: b + eps)
            XCTAssertEqual(before.zoom, at.zoom, accuracy: 1e-3, "zoom is continuous at frame \(b)"); XCTAssertEqual(after.zoom, at.zoom, accuracy: 1e-3)
            XCTAssertEqual(before.centre.x, at.centre.x, accuracy: 0.05); XCTAssertEqual(after.centre.y, at.centre.y, accuracy: 0.05)
            // no jump in velocity either: the speed on both sides of a boundary is the same (zero for eased segments)
            let vBefore = abs(at.zoom - FilmCamera.state(atFrame: b - 0.2).zoom) / 0.2, vAfter = abs(FilmCamera.state(atFrame: b + 0.2).zoom - at.zoom) / 0.2
            XCTAssertLessThan(abs(vBefore - vAfter), 0.01, "no velocity step at frame \(b)")
        }
    }

    func testTheCameraIsLockedOffThroughTheProtectionScenes() {
        let a = FilmCamera.state(atFrame: 228), b = FilmCamera.state(atFrame: 431)
        XCTAssertEqual(a, b, "the overlay is aligned to a locked shot")
        for f in stride(from: 228.0, through: 431, by: 7) { XCTAssertEqual(FilmCamera.state(atFrame: f), a) }
    }

    func testTheCameraPushesInThenPullsBack() {
        XCTAssertEqual(FilmCamera.state(atFrame: 0).zoom, 1.0, accuracy: 1e-9)
        XCTAssertEqual(FilmCamera.state(atFrame: 119.999).zoom, 1.95, accuracy: 0.01)
        XCTAssertGreaterThan(FilmCamera.state(atFrame: 300).zoom, FilmCamera.state(atFrame: 119).zoom)
        XCTAssertLessThan(FilmCamera.state(atFrame: 470).zoom, FilmCamera.state(atFrame: 431).zoom)
        var last = 0.0
        for f in stride(from: 0.0, through: 119, by: 1) { let z = FilmCamera.state(atFrame: f).zoom; XCTAssertGreaterThanOrEqual(z, last - 1e-9); last = z }
    }

    func testParallaxFollowsTheCameraInProportionToDepth() {
        let cam = CameraState(zoom: 2, centre: CGPoint(x: 1200, y: 540))
        let window = FilmSpec.master
        let room = FilmCamera.transform(cam, depth: 0.55, window: window), laptop = FilmCamera.transform(cam, depth: 1, window: window), person = FilmCamera.transform(cam, depth: 1.45, window: window)
        XCTAssertEqual(laptop.a, 2, accuracy: 1e-9, "the reference plane follows the camera fully")
        XCTAssertEqual(room.a, 1.55, accuracy: 1e-9); XCTAssertEqual(person.a, 2.45, accuracy: 1e-9)
        XCTAssertLessThan(room.a, laptop.a); XCTAssertLessThan(laptop.a, person.a)
        let rest = FilmCamera.transform(CameraState(zoom: 1, centre: CGPoint(x: 960, y: 540)), depth: 1.45, window: window)
        XCTAssertEqual(rest, CGAffineTransform.identity, "at rest every layer sits where the manifest puts it")
    }

    // MARK: perspective

    private let quad = [CGPoint(x: 640, y: 232), CGPoint(x: 1500, y: 205), CGPoint(x: 1522, y: 760), CGPoint(x: 618, y: 776)]

    func testTheHomographyMapsTheScreenCornersExactlyOntoTheQuad() throws {
        let size = CGSize(width: 1440, height: 900)
        let h = try XCTUnwrap(FilmHomography.solve(from: size, to: quad))
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1440, y: 0), CGPoint(x: 1440, y: 900), CGPoint(x: 0, y: 900)]
        for (c, q) in zip(corners, quad) { let p = FilmHomography.apply(h, c); XCTAssertEqual(p.x, q.x, accuracy: 1e-6); XCTAssertEqual(p.y, q.y, accuracy: 1e-6) }
        // straight lines stay straight: the middle of the top edge lies on the top edge of the quad
        let m = FilmHomography.apply(h, CGPoint(x: 720, y: 0)), t0 = quad[0], t1 = quad[1]
        let cross = (t1.x - t0.x) * (m.y - t0.y) - (t1.y - t0.y) * (m.x - t0.x)
        XCTAssertEqual(cross, 0, accuracy: 1e-3)
    }

    func testTheCATransformIsTheSameMap() throws {
        let h = try XCTUnwrap(FilmHomography.solve(from: CGSize(width: 1440, height: 900), to: quad))
        let t = FilmHomography.transform3D(h)
        for p in [CGPoint(x: 100, y: 50), CGPoint(x: 1000, y: 700), CGPoint(x: 720, y: 450)] {
            // row-vector convention: [x y 0 1] * M
            let w = Double(p.x) * Double(t.m14) + Double(p.y) * Double(t.m24) + Double(t.m44)
            let x = (Double(p.x) * Double(t.m11) + Double(p.y) * Double(t.m21) + Double(t.m41)) / w
            let y = (Double(p.x) * Double(t.m12) + Double(p.y) * Double(t.m22) + Double(t.m42)) / w
            let q = FilmHomography.apply(h, p)
            XCTAssertEqual(x, Double(q.x), accuracy: 0.01); XCTAssertEqual(y, Double(q.y), accuracy: 0.01)
        }
    }

    func testADegenerateQuadHasNoMap() {
        XCTAssertNil(FilmHomography.solve(from: CGSize(width: 100, height: 100), to: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0)]))
        XCTAssertNil(FilmHomography.solve(from: .zero, to: quad))
    }

    // MARK: the asset contract

    private func goodManifest() -> FilmManifest {
        func layer(_ id: String, _ role: String, _ depth: String, _ z: Int, frame: [Double] = [0, 0, 1920, 1080]) -> FilmManifest.Layer { .init(id: id, role: role, file: "film_\(id)", frame: frame, depth: depth, z: z) }
        let layers = [layer("room", "room", "room", 0), layer("laptop", "laptop", "laptop", 1), layer("person", "person", "person", 3), layer("a", "handsA", "person", 4), layer("b", "handsB", "person", 4)]
        let comp = FilmManifest.Composition(master: [1920, 1080], screenQuad: [[640, 232], [1500, 205], [1522, 760], [618, 776]], screenSize: [1440, 900], layers: layers)
        return FilmManifest(version: 1, compositions: ["landscape": comp], provenance: layers.map { .init(asset: $0.file, source: "commissioned", license: "work for hire", redistribution: "app bundle") })
    }
    private func errors(_ m: FilmManifest) -> [String] { FilmAssetContract.validate(m, composition: "landscape").filter { $0.severity == .error }.map(\.message) }

    func testAValidManifestPasses() { XCTAssertEqual(errors(goodManifest()), []) }

    func testEachBreachOfTheContractIsReported() {
        var m = goodManifest(); m.compositions["landscape"]!.layers.removeAll { $0.role == "person" }
        XCTAssertTrue(errors(m).contains { $0.contains("missing required layer role person") })
        m = goodManifest(); m.compositions["landscape"]!.layers[1].id = "room"
        XCTAssertTrue(errors(m).contains { $0.contains("duplicate layer id") })
        m = goodManifest(); m.compositions["landscape"]!.screenQuad[1] = [2500, 205]
        XCTAssertTrue(errors(m).contains { $0.contains("outside the master space") })
        m = goodManifest(); m.compositions["landscape"]!.screenQuad = [[640, 232], [618, 776], [1522, 760], [1500, 205]]
        XCTAssertFalse(errors(m).isEmpty, "a counter-clockwise quad is refused")
        m = goodManifest(); m.compositions["landscape"]!.screenQuad = [[0, 0], [100, 100], [100, 0], [0, 100]]
        XCTAssertTrue(errors(m).contains { $0.contains("not convex") })
        m = goodManifest(); m.provenance.removeAll { $0.asset == "film_room" }
        XCTAssertTrue(errors(m).contains { $0.contains("provenance") })
        m = goodManifest(); m.compositions["landscape"]!.layers[3].frame = [10, 0, 1920, 1080]
        XCTAssertTrue(errors(m).contains { $0.contains("handsA and handsB must share one frame") })
        m = goodManifest(); m.compositions["landscape"]!.layers[0].depth = "sky"
        XCTAssertTrue(errors(m).contains { $0.contains("unknown depth") })
        m = goodManifest(); m.version = 2
        XCTAssertTrue(errors(m).contains { $0.contains("unsupported manifest version") })
        XCTAssertTrue(FilmAssetContract.validate(goodManifest(), composition: "landscape", imageExists: { _ in false }).contains { $0.message.contains("not found") })
        XCTAssertTrue(FilmAssetContract.validate(goodManifest(), composition: "portrait").contains { $0.message.contains("no \"portrait\"") })
    }

    func testTheManifestSurvivesJSON() throws {
        let data = try JSONEncoder().encode(goodManifest())
        XCTAssertEqual(try JSONDecoder().decode(FilmManifest.self, from: data), goodManifest())
    }

    // MARK: availability: no artwork, no film

    func testWithoutArtworkTheFilmIsNotShown() {
        XCTAssertEqual(FilmAvailability.load(bundle: Bundle(for: FilmEngineTests.self), env: [:]), .unavailable)
    }

    func testDiagnosticPlatesAreOnlyForEngineeringTests() {
        XCTAssertEqual(FilmAvailability.load(env: ["BS_FILM_TEST_PLATES": "1"]), .testPlates)
        XCTAssertNotEqual(FilmAvailability.load(bundle: Bundle(for: FilmEngineTests.self), env: ["BS_FILM_TEST_PLATES": "0"]), .testPlates)
    }

    func testTheDiagnosticPlatesSatisfyTheirOwnContractGeometry() {
        for key in ["landscape", "portrait"] {
            let c = FilmTestPlates.composition(key)
            XCTAssertEqual(c.screenQuad.count, 4)
            let m = FilmManifest(version: 1, compositions: [key: c], provenance: c.layers.map { .init(asset: $0.file, source: "generated in code", license: "n/a", redistribution: "never shipped") })
            XCTAssertEqual(FilmAssetContract.validate(m, composition: key).filter { $0.severity == .error }, [], key)
        }
    }
}
