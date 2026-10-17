import Foundation
import SwiftUI

/// Sharing what you are looking at with another device, as plain links. No cookies, passwords or accounts leave this device.
enum TabSharing {
    /// One address per line, titles above them, ready to paste or send.
    static func text(for tabs: [(title: String, url: URL)]) -> String {
        tabs.map { "\($0.title)\n\(TrackingParameters.clean($0.url) ?? $0.url)" }.joined(separator: "\n\n")
    }

    /// The page's address with the time the video is at, so the other device starts where this one is. Uses the common `t=` seconds form.
    static func link(_ url: URL, atSeconds seconds: Double) -> URL {
        guard seconds >= 5, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (parts.queryItems ?? []).filter { $0.name != "t" }
        items.append(URLQueryItem(name: "t", value: String(Int(seconds))))
        parts.queryItems = items
        return parts.url ?? url
    }
}

struct ShareTabsView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var includeAll = false
    @State private var videoLink: URL?

    private var shared: [(title: String, url: URL)] {
        let source = includeAll ? model.tabs.filter { !$0.isPrivate } : (model.active.map { [$0] } ?? [])
        return source.compactMap { tab in tab.url.map { (tab.title, $0) } }
    }

    var body: some View {
        Form {
            Section {
                Toggle("All open tabs", isOn: $includeAll)
                let text = TabSharing.text(for: shared)
                if let image = QRCode.image(for: text), shared.count == 1 {
                    Image(platform: image).interpolation(.none).resizable().scaledToFit().frame(width: 200, height: 200).frame(maxWidth: .infinity)
                }
                ShareLink(item: text) { Label("Share \(shared.count) link\(shared.count == 1 ? "" : "s")", systemImage: "square.and.arrow.up") }.disabled(shared.isEmpty)
                Button("Copy Links") { copyToPasteboard(text) }.disabled(shared.isEmpty)
            } header: { Text("Share Tabs") } footer: { Text("Only addresses and titles are shared. Private tabs are never included.") }
            Section {
                Button("Link at the Current Video Time") {
                    Task {
                        guard let tab = model.active, let url = tab.url, let item = await tab.engine.mediaElements()?.first,
                              let time = (item["currentTime"] as? NSNumber)?.doubleValue else { videoLink = nil; model.notice = "No video is playing on this page."; return }
                        videoLink = TabSharing.link(url, atSeconds: time)
                    }
                }
                if let videoLink {
                    ShareLink(item: videoLink) { Label("Share Link", systemImage: "square.and.arrow.up") }
                    Text(videoLink.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } header: { Text("Continue a Video") } footer: { Text("Works on sites that understand a start time in the link, such as YouTube.") }
        }
        .formStyle(.grouped)
    }
}
