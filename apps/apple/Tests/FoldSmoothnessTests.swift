import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser_Setu

/// Measures the fold of the toolbar into the pill in a real window: how the page's height changes frame by frame.
/// A smooth fold moves in many small steps over a few tenths of a second; a jump moves in one or two big ones.
@MainActor
final class FoldSmoothnessTests: XCTestCase {
    private func firstWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let found = firstWebView(in: sub) { return found } }
        return nil
    }

    private func sample(duration: TimeInterval, every interval: TimeInterval = 1.0 / 120, read: () -> CGFloat) async -> [CGFloat] {
        var values: [CGFloat] = []
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            values.append(read())
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        return values
    }

    func testTheToolbarFoldsAndUnfoldsInManySmallSteps() async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-fold-\(UUID().uuidString)", profile: "default")
        await model.start()
        model.layoutPreset = .classic
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MacRootView().environmentObject(model).frame(width: 1100, height: 760))
        window.alphaValue = 0.02            // on screen so animation runs, but not something the user sees
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(700))

        guard let web = firstWebView(in: window.contentView!) else { throw XCTSkip("no web view found in the window") }
        let startHeight = web.frame.height
        XCTAssertGreaterThan(startHeight, 300)

        // Fold
        let folding = Task { await sample(duration: 1.0) { web.frame.height } }
        try await Task.sleep(for: .milliseconds(150))
        for _ in 0..<5 { model.pageScrolled(deltaY: -20) }
        XCTAssertTrue(model.chromeCollapsed)
        let down = await folding.value
        try await Task.sleep(for: .milliseconds(300))
        let folded = web.frame.height
        XCTAssertGreaterThan(folded, startHeight + 40, "the page rises into the room the toolbar left")

        let foldSteps = zip(down, down.dropFirst()).map { abs($1 - $0) }.filter { $0 > 0.5 }
        print("FOLD page height \(startHeight) -> \(folded); moving frames: \(foldSteps.count); biggest step: \(foldSteps.max() ?? 0)")
        XCTAssertGreaterThanOrEqual(foldSteps.count, 8, "the fold is spread over many frames, not one jump")
        XCTAssertLessThan(foldSteps.max() ?? 0, (folded - startHeight) * 0.45, "no single frame does close to half of the whole movement")

        // Unfold
        try await Task.sleep(for: .milliseconds(700))     // past the settling time
        let unfolding = Task { await sample(duration: 1.0) { web.frame.height } }
        try await Task.sleep(for: .milliseconds(150))
        model.expandChrome()
        let up = await unfolding.value
        try await Task.sleep(for: .milliseconds(300))
        let unfoldSteps = zip(up, up.dropFirst()).map { abs($1 - $0) }.filter { $0 > 0.5 }
        print("UNFOLD page height \(folded) -> \(web.frame.height); moving frames: \(unfoldSteps.count); biggest step: \(unfoldSteps.max() ?? 0)")
        XCTAssertEqual(web.frame.height, startHeight, accuracy: 1.5, "everything comes back to where it was")
        XCTAssertGreaterThanOrEqual(unfoldSteps.count, 8)
        XCTAssertLessThan(unfoldSteps.max() ?? 0, (folded - startHeight) * 0.45)
    }
}
