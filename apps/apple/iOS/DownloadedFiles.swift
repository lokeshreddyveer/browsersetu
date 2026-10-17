import ContactsUI
import EventKitUI
import PassKit
import UIKit

/// What happens when a download is a Wallet pass, a contact card or a calendar event: it opens in the system's own sheet (add to Wallet, add
/// the contact, add the event) instead of only landing in the downloads list. Everything is read on the device; nothing is sent anywhere.
@MainActor
enum DownloadedFiles {
    static func open(_ file: URL) {
        switch file.pathExtension.lowercased() {
        case "pkpass": pass(file)
        case "vcf": contact(file)
        case "ics": event(file)
        default: break
        }
    }

    private static func present(_ controller: UIViewController) {
        Dialogs.topViewController()?.present(controller, animated: true)
    }

    private static func pass(_ file: URL) {
        guard let data = try? Data(contentsOf: file), let pass = try? PKPass(data: data), PKAddPassesViewController.canAddPasses() else { return }
        present(PKAddPassesViewController(pass: pass) ?? UIViewController())
    }

    private static func contact(_ file: URL) {
        guard let data = try? Data(contentsOf: file), let card = (try? CNContactVCardSerialization.contacts(with: data))?.first else { return }
        let controller = CNContactViewController(forNewContact: card)
        let nav = UINavigationController(rootViewController: controller)
        present(nav)
    }

    private static func event(_ file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8), let details = ICSDetails(text) else { return }
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = details.title
        event.startDate = details.start
        event.endDate = details.end ?? details.start.addingTimeInterval(3600)
        event.location = details.location
        event.notes = details.notes
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = EventDismisser.shared
        present(controller)
    }
}

private final class EventDismisser: NSObject, EKEventEditViewDelegate {
    static let shared = EventDismisser()
    func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
        controller.dismiss(animated: true)
    }
}

/// The few fields of a calendar file that matter for adding an event: what, when, where.
struct ICSDetails {
    var title = "Event"
    var start: Date
    var end: Date?
    var location: String?
    var notes: String?

    init?(_ text: String) {
        // Folded lines continue on the next line with a leading space.
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
        var start: Date?
        for raw in unfolded.components(separatedBy: .newlines) {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let name = raw[..<colon].split(separator: ";").first.map(String.init)?.uppercased() ?? ""
            let value = String(raw[raw.index(after: colon)...])
            switch name {
            case "SUMMARY": title = Self.unescape(value)
            case "DTSTART": start = Self.date(value)
            case "DTEND": end = Self.date(value)
            case "LOCATION": location = Self.unescape(value)
            case "DESCRIPTION": notes = Self.unescape(value)
            default: break
            }
        }
        guard let start else { return nil }
        self.start = start
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
    }

    static func date(_ value: String) -> Date? {
        let formats = ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if format.hasSuffix("'Z'") { formatter.timeZone = TimeZone(identifier: "UTC") }
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
