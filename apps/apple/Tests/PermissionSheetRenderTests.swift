import XCTest
import SwiftUI
@testable import Browser_Setu

/// Renders the permissions sheet for a real installed extension and keeps the picture (shot-permissions-*.png in the test's temporary folder).
@available(macOS 15.4, *)
@MainActor
final class PermissionSheetRenderTests: XCTestCase {
    func testPermissionsSheetShowsRowsAndAccessPicker() async throws {
        let root = NSTemporaryDirectory() + "bs-perm-\(UUID().uuidString)"
        let model = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await model.start()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-permfix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version": 3, "name": "Sample", "version": "1.0",
         "permissions": ["storage", "tabs", "scripting"], "host_permissions": ["<all_urls>", "https://example.test/*"],
         "action": {"default_title": "Sample"}}
        """
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        _ = try await model.extensionCenter.inspect(folder)
        try await model.extensionCenter.installPending()
        let info = try XCTUnwrap(model.extensionCenter.extensions.first)
        let rows = model.extensionCenter.permissionRows(info.id)
        print("PERMROWS \(rows.map { "\($0.isSite ? "site" : "api"):\($0.key)=\($0.granted)" })")
        print("PERMACCESS \(model.extensionCenter.siteAccess(info.id))")
        let calibration = NSHostingView(rootView: Text("calibration").font(.largeTitle).padding().background(Color.black).foregroundStyle(.white))
        calibration.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        let cw = NSWindow(contentRect: calibration.frame, styleMask: [.titled], backing: .buffered, defer: false)
        cw.contentView = calibration; cw.orderFront(nil)
        calibration.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let crep = try XCTUnwrap(calibration.bitmapImageRepForCachingDisplay(in: calibration.bounds)); calibration.cacheDisplay(in: calibration.bounds, to: crep)
        print("PERMCAL " + (crep.representation(using: .png, properties: [:])?.base64EncodedString() ?? ""))
        let host = NSHostingView(rootView: ExtensionPermissionsSheet(info: info).environmentObject(model).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let path = NSTemporaryDirectory() + "shot-permissions-dark.png"
        try png.write(to: URL(fileURLWithPath: path))
        if let dir = ProcessInfo.processInfo.environment["BS_SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("permissions.png")) }
        print("PERMPNG " + png.base64EncodedString())
        print("PERMSHOT \(path)")
    }
}
