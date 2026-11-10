import SwiftUI
import XCTest
@testable import Browser_Setu

/// Renders every error page, in both appearances and at a full and a narrow size, to PNG files so they can be looked at (the folder is printed). The assertions are about
/// the rendering working at all; judging how it looks is done by eye on the images.
@MainActor
final class ErrorPageSnapshotTests: XCTestCase {
    private static let folder = NSTemporaryDirectory() + "error-pages/"

    private func sample(_ kind: BrowserErrorKind) -> BrowserErrorInfo {
        var info = BrowserErrorInfo(kind: kind, url: URL(string: "https://example.com/some/page"), deviceOnline: kind == .noInternet ? false : true)
        switch kind {
        case .noInternet: info.domain = NSURLErrorDomain; info.code = NSURLErrorNotConnectedToInternet
        case .dnsFailure: info.domain = NSURLErrorDomain; info.code = NSURLErrorCannotFindHost
        case .timedOut: info.domain = NSURLErrorDomain; info.code = NSURLErrorTimedOut
        case .serverUnavailable: info.domain = NSURLErrorDomain; info.code = NSURLErrorCannotConnectToHost
        case .pageMissing: info.httpStatus = 404
        case .certificate: info.domain = NSURLErrorDomain; info.code = NSURLErrorServerCertificateHasBadDate
        case .protectionBlocked: info.blockReason = .contentFilter
        case .unsupportedContent: info.domain = "WebKitErrorDomain"; info.code = 101
        case .processCrashed: info.crashCount = 2
        case .fileFailure: info.url = URL(string: "file:///Users/example/report.html")
        case .syncFailure: info = SyncProblem.passphrase.info
        case .mediaFailure: info.headline = "This device could not decode the video"; info.detail = "The file is damaged or uses a format this device cannot decode. Another quality or another site's copy may play."
        }
        return info
    }

    @discardableResult
    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws -> URL {
        try FileManager.default.createDirectory(atPath: Self.folder, withIntermediateDirectories: true)
        let content = view
            .frame(width: size.width, height: size.height)
            .background(Color.platformBackground)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "\(name) did not render")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000, "\(name) rendered as an empty picture")
        let url = URL(fileURLWithPath: Self.folder + name + ".png")
        try png.write(to: url)
        return url
    }

    func testEveryErrorPageRendersFullSizeInBothAppearances() throws {
        for kind in BrowserErrorKind.allCases {
            for dark in [false, true] {
                try render(ErrorPageView(info: sample(kind), canGoBack: true, isPublicWeb: true, perform: { _ in }), size: CGSize(width: 900, height: 620), dark: dark, name: "\(kind.rawValue)-\(dark ? "dark" : "light")")
            }
        }
        print("ERROR PAGE IMAGES: \(Self.folder)")
    }

    func testTheNarrowPanelVariantRendersForEveryKind() throws {
        for kind in BrowserErrorKind.allCases {
            try render(ErrorPageView(info: sample(kind), canGoBack: true, isPublicWeb: true, embedded: true, perform: { _ in }), size: CGSize(width: 380, height: 520), dark: true, name: "\(kind.rawValue)-narrow")
        }
    }

    func testTheInlinePanelsRenderForVideoFileAndSync() throws {
        for kind in [BrowserErrorKind.mediaFailure, .fileFailure, .syncFailure] {
            try render(ErrorInlineView(info: sample(kind), actions: [.reload, .copyAddress], perform: { _ in }).padding(16), size: CGSize(width: 460, height: 150), dark: true, name: "inline-\(kind.rawValue)")
        }
    }

    func testTheGamesRender() throws {
        try render(OfflineGamesView(accent: BrowserErrorKind.noInternet.accent).padding(20), size: CGSize(width: 460, height: 420), dark: true, name: "games")
    }
}
