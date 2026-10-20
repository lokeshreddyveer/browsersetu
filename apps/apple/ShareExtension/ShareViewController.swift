#if APP_GROUP
import UIKit
import UniformTypeIdentifiers

/// The share sheet entry: "Open in Browser Setu", "Save to Reading List" and "Send to My Devices" for a web address or text from any app.
/// It does nothing but leave a note in the shared folder; the browser picks the note up and acts on it.
final class ShareViewController: UIViewController {
    private var address: URL?
    private var pageTitle = ""
    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.98)
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 12; stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                                     stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        let title = UILabel(); title.text = "Browser Setu"; title.font = .preferredFont(forTextStyle: .title2); title.textAlignment = .center
        status.text = "Reading what you shared…"; status.font = .preferredFont(forTextStyle: .footnote); status.textColor = .secondaryLabel; status.textAlignment = .center; status.numberOfLines = 2
        stack.addArrangedSubview(title); stack.addArrangedSubview(status)
        for (name, kind) in [("Open in Browser Setu", SharedStore.InboxItem.Kind.open), ("Save to Reading List", .readLater), ("Send to My Devices", .send)] {
            var config = UIButton.Configuration.filled(); config.title = name; config.cornerStyle = .capsule
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.choose(kind) })
            button.isEnabled = false; button.tag = 1
            stack.addArrangedSubview(button)
        }
        var cancel = UIButton.Configuration.plain(); cancel.title = "Cancel"
        stack.addArrangedSubview(UIButton(configuration: cancel, primaryAction: UIAction { [weak self] _ in self?.finish() }))
        Task { await load() }
    }

    private func load() async {
        for case let item as NSExtensionItem in extensionContext?.inputItems ?? [] {
            pageTitle = item.attributedContentText?.string ?? item.attributedTitle?.string ?? ""
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier), let url = value as? URL { address = url; break }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier), let text = value as? String,
                   let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil { address = url; break }
            }
            if address != nil { break }
        }
        await MainActor.run {
            let ok = address.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false
            status.text = ok ? (address?.host ?? "") : "Only web addresses can be shared with Browser Setu."
            for case let b as UIButton in (view.subviews.first as? UIStackView)?.arrangedSubviews ?? [] where b.tag == 1 { b.isEnabled = ok }
        }
    }

    private func choose(_ kind: SharedStore.InboxItem.Kind) {
        guard let address else { return }
        let saved = SharedStore.append(.init(kind: kind, url: address.absoluteString, title: String(pageTitle.prefix(200))))
        status.text = saved ? "Done. It will be there when you open Browser Setu." : "Browser Setu's shared folder is not available."
        if saved, kind == .open, let app = URL(string: "browsersetu://command?id=inbox") { openApp(app) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (saved ? 0.7 : 1.6)) { self.finish() }
    }

    /// An extension may not open its app directly; the responder chain is the long-standing way. If it does not work, the note waits for the next launch.
    private func openApp(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication { application.open(url, options: [:], completionHandler: nil); return }
            responder = r.next
        }
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}

#endif
