import Cocoa
import UniformTypeIdentifiers

/// "Browser Setu" in the Share menu of Safari and other Mac apps: opens the page being shared in Browser Setu.
/// It reads only the web address, hands it to the browser through its own link scheme and closes. Nothing is stored or sent.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await handOver() }
    }

    private func handOver() async {
        var address: URL?
        search: for case let item as NSExtensionItem in extensionContext?.inputItems ?? [] {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = (value as? URL) ?? (value as? String).flatMap({ URL(string: $0) }) { address = url; break search }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                   let text = value as? String, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil { address = url; break search }
            }
        }
        if let address, ["http", "https"].contains(address.scheme?.lowercased() ?? ""), address.host != nil {
            var parts = URLComponents()
            parts.scheme = "browsersetu"; parts.host = "open"
            parts.queryItems = [URLQueryItem(name: "url", value: address.absoluteString)]
            if let link = parts.url { NSWorkspace.shared.open(link) }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
