import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Dates, phone numbers, emails and addresses found in text, read on this device with the system's own detector.
struct FoundDetail: Identifiable, Equatable {
    enum Kind: String { case event, phone, email, address }
    var id: String { kind.rawValue + "|" + text }
    var kind: Kind
    var text: String
    var date: Date?
    var duration: TimeInterval?
}

enum DetailExtractor {
    static func find(in text: String, limit: Int = 12) -> [FoundDetail] {
        let types: NSTextCheckingResult.CheckingType = [.date, .phoneNumber, .link, .address]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        var out: [FoundDetail] = []
        var seen = Set<String>()
        let capped = String(text.prefix(20000))
        for match in detector.matches(in: capped, range: NSRange(capped.startIndex..., in: capped)) {
            guard let range = Range(match.range, in: capped) else { continue }
            let snippet = String(capped[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: FoundDetail
            if match.resultType == .date, let date = match.date { detail = FoundDetail(kind: .event, text: snippet, date: date, duration: match.duration > 0 ? match.duration : nil) }
            else if match.resultType == .phoneNumber, let number = match.phoneNumber { detail = FoundDetail(kind: .phone, text: number) }
            else if match.resultType == .link, let url = match.url, url.scheme == "mailto" { detail = FoundDetail(kind: .email, text: url.absoluteString.replacingOccurrences(of: "mailto:", with: "")) }
            else if match.resultType == .address { detail = FoundDetail(kind: .address, text: snippet) }
            else { continue }
            if seen.insert(detail.id).inserted { out.append(detail) }
            if out.count >= limit { break }
        }
        return out
    }
}

/// Plain calendar and contact files. Opening one hands it to Calendar or Contacts, which asks you before adding it,
/// so Browser Setu itself never needs access to either.
enum CardFiles {
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func calendarEvent(title: String, start: Date, duration: TimeInterval?, link: String?, uid: String = UUID().uuidString) -> String {
        let end = start.addingTimeInterval(duration ?? 3600)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Browser Setu//EN", "BEGIN:VEVENT", "UID:\(uid)", "DTSTAMP:\(stamp(Date()))",
                     "DTSTART:\(stamp(start))", "DTEND:\(stamp(end))", "SUMMARY:\(escape(String(title.prefix(120))))"]
        if let link { lines.append("DESCRIPTION:\(escape(link))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func contactCard(name: String?, phones: [String], emails: [String], address: String?) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "FN:\(escape(name ?? emails.first ?? phones.first ?? "New Contact"))", "N:\(escape(name ?? ""));;;;"]
        lines += phones.map { "TEL:\(escape($0))" }
        lines += emails.map { "EMAIL:\(escape($0))" }
        if let address { lines.append("ADR:;;\(escape(address));;;;") }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Writes the file to a temporary folder and returns where, ready to open or share.
    static func write(_ content: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try content.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}

/// Lists what was found and lets you add an event to Calendar or the contact details to Contacts.
struct DetailsList: View {
    let details: [FoundDetail]
    let pageURL: String?

    var body: some View {
        if details.isEmpty {
            ContentUnavailableView("Nothing Found", systemImage: "calendar.badge.exclamationmark", description: Text("No dates, phone numbers, emails or addresses were recognised."))
        } else {
            List {
                ForEach(details) { detail in
                    HStack {
                        Image(systemName: symbol(detail.kind)).foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(detail.text).lineLimit(2)
                            if let date = detail.date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let file = file(for: detail) {
                            ShareLink(item: file) { Text(detail.kind == .event ? "Add to Calendar" : "Add to Contacts") }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if contactBundle != nil, let file = contactBundle {
                    ShareLink(item: file) { Label("Save All as One Contact", systemImage: "person.crop.circle.badge.plus") }
                }
            }
        }
    }

    private func symbol(_ kind: FoundDetail.Kind) -> String {
        switch kind { case .event: "calendar"; case .phone: "phone"; case .email: "envelope"; case .address: "mappin.and.ellipse" }
    }

    private func file(for detail: FoundDetail) -> URL? {
        switch detail.kind {
        case .event: detail.date.flatMap { CardFiles.write(CardFiles.calendarEvent(title: detail.text, start: $0, duration: detail.duration, link: pageURL), name: "Event.ics") }
        case .phone: CardFiles.write(CardFiles.contactCard(name: nil, phones: [detail.text], emails: [], address: nil), name: "Contact.vcf")
        case .email: CardFiles.write(CardFiles.contactCard(name: nil, phones: [], emails: [detail.text], address: nil), name: "Contact.vcf")
        case .address: CardFiles.write(CardFiles.contactCard(name: nil, phones: [], emails: [], address: detail.text), name: "Contact.vcf")
        }
    }

    private var contactBundle: URL? {
        let phones = details.filter { $0.kind == .phone }.map(\.text), emails = details.filter { $0.kind == .email }.map(\.text)
        let address = details.first { $0.kind == .address }?.text
        guard phones.count + emails.count + (address == nil ? 0 : 1) > 1 else { return nil }
        return CardFiles.write(CardFiles.contactCard(name: nil, phones: phones, emails: emails, address: address), name: "Contact.vcf")
    }
}
