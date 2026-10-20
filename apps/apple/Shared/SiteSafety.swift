import Foundation

// MARK: Look-alike addresses

/// Spots addresses that imitate a well-known site: swapped letters and digits (paypa1), letters from other alphabets, one-letter typos, and a famous name
/// placed in front of a different site (paypal.com.example.net). It works on the address alone and sends nothing anywhere.
enum LookalikeCheck {
    struct Finding: Equatable {
        let imitates: String
        let reason: String
    }

    /// A brand's name as it appears in addresses, and the sites that really belong to it.
    static let brands: [String: Set<String>] = [
        "google": ["google.com", "google.co.uk", "google.co.in", "goo.gl", "googleapis.com", "gstatic.com", "youtube.com"],
        "youtube": ["youtube.com", "youtu.be"], "gmail": ["gmail.com"],
        "apple": ["apple.com", "icloud.com"], "icloud": ["icloud.com", "apple.com"],
        "microsoft": ["microsoft.com", "live.com", "office.com", "microsoftonline.com", "outlook.com"], "outlook": ["outlook.com", "live.com", "office.com"],
        "office365": ["office.com", "microsoft.com"],
        "amazon": ["amazon.com", "amazon.in", "amazon.co.uk", "amazon.de", "amazonaws.com", "amazon.ca"],
        "paypal": ["paypal.com", "paypal.me"], "netflix": ["netflix.com"], "facebook": ["facebook.com", "fb.com", "fb.me"],
        "instagram": ["instagram.com"], "whatsapp": ["whatsapp.com", "whatsapp.net"], "twitter": ["twitter.com", "x.com", "t.co"],
        "linkedin": ["linkedin.com"], "github": ["github.com", "githubusercontent.com", "github.io"], "dropbox": ["dropbox.com"],
        "coinbase": ["coinbase.com"], "binance": ["binance.com"], "metamask": ["metamask.io"], "spotify": ["spotify.com"],
        "adobe": ["adobe.com"], "yahoo": ["yahoo.com"], "ebay": ["ebay.com"], "walmart": ["walmart.com"],
        "chase": ["chase.com"], "wellsfargo": ["wellsfargo.com"], "bankofamerica": ["bankofamerica.com"], "citibank": ["citibank.com", "citi.com"],
        "americanexpress": ["americanexpress.com", "amex.com"], "hdfcbank": ["hdfcbank.com"], "icicibank": ["icicibank.com"], "sbi": ["sbi.co.in"],
        "paytm": ["paytm.com"], "phonepe": ["phonepe.com"], "flipkart": ["flipkart.com"], "dhl": ["dhl.com"], "fedex": ["fedex.com"],
        "usps": ["usps.com"], "irs": ["irs.gov"], "steam": ["steampowered.com", "steamcommunity.com"], "discord": ["discord.com", "discord.gg"],
        "telegram": ["telegram.org", "t.me"], "zoom": ["zoom.us"], "slack": ["slack.com"], "docusign": ["docusign.com", "docusign.net"],
        "wetransfer": ["wetransfer.com"], "stripe": ["stripe.com"], "airbnb": ["airbnb.com"], "uber": ["uber.com"],
    ]

    /// Letters that look like Latin ones, from Cyrillic and Greek, and the digits people swap in.
    private static let confusables: [Character: Character] = [
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "һ": "h", "ԛ": "q", "ԝ": "w", "к": "k", "м": "m", "т": "t", "н": "h", "в": "b",
        "ο": "o", "α": "a", "ν": "v", "ι": "i", "τ": "t", "ρ": "p", "κ": "k", "ε": "e", "υ": "u", "β": "b",
        "ı": "i", "ɡ": "g", "ɑ": "a", "ⅼ": "l", "ǀ": "l",
        "0": "o", "1": "l", "3": "e", "5": "s", "$": "s",
    ]

    private static let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu", "or", "ne", "go"]

    /// The part of an address a person registers: `mail.example.com` gives `example.com`, `shop.example.co.uk` gives `example.co.uk`.
    static func registrable(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 2 else { return parts.joined(separator: ".") }
        if parts[parts.count - 1].count == 2, secondLevel.contains(parts[parts.count - 2]) { return parts.suffix(3).joined(separator: ".") }
        return parts.suffix(2).joined(separator: ".")
    }

    static func check(host rawHost: String) -> Finding? {
        let host = decoded(rawHost.lowercased())
        let registered = registrable(host)
        guard let name = registered.split(separator: ".").first.map(String.init), !name.isEmpty else { return nil }
        let labelsBefore = host.split(separator: ".").dropLast(registered.split(separator: ".").count).map(String.init)

        // The real thing: the name is exactly a brand and the site really belongs to it.
        if let real = brands[name], real.contains(registered) { return nil }

        let squeezed = skeleton(name)
        for (brand, owned) in brands {
            if owned.contains(registered) { continue }
            // A brand's own name on a different ending (paypal.me, google.fr) is not what this checks.
            if name == brand { continue }
            if squeezed == brand, name != brand {
                return Finding(imitates: brand, reason: "The address uses look-alike letters or digits to imitate \(brand.capitalized).")
            }
            // One letter added, dropped or changed in a long name.
            if brand.count >= 6, name.count >= 5, abs(name.count - brand.count) <= 1, oneEdit(name, brand) {
                return Finding(imitates: brand, reason: "The address is one letter away from \(brand.capitalized).")
            }
            // Hyphenated: paypal-login.com, secure-paypal.com, paypal-support.net.
            let bait: Set<Substring> = ["login", "signin", "secure", "support", "account", "verify", "update", "help", "service", "billing", "wallet", "recovery", "alert", "confirm"]
            let pieces = name.split(separator: "-")
            if brand.count >= 5, pieces.contains(where: { $0 == brand }), pieces.contains(where: { bait.contains($0) }) {
                return Finding(imitates: brand, reason: "The address puts \(brand.capitalized) in front of a different site.")
            }
        }
        // A famous name used as a part in front: paypal.com.example.net, login.paypal.example.org.
        for label in labelsBefore where registered != "github.io" {
            let squeezedLabel = skeleton(label)
            if let owned = brands[label] ?? brands[squeezedLabel], !owned.contains(registered) {
                return Finding(imitates: brands[label] != nil ? label : squeezedLabel, reason: "A well-known name is used in front of a different site, \(registered).")
            }
        }
        return nil
    }

    /// The name with look-alike characters replaced and `rn` / `vv` read as `m` / `w`.
    static func skeleton(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() { out.append(confusables[ch] ?? ch) }
        return out.replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "vv", with: "w")
    }

    static func oneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x == y { return false }
        if x.count == y.count { return zip(x, y).filter { $0 != $1 }.count == 1 }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        var i = 0, j = 0, skipped = false
        while i < short.count, j < long.count {
            if short[i] == long[j] { i += 1; j += 1; continue }
            if skipped { return false }
            skipped = true; j += 1
        }
        return true
    }

    // MARK: Punycode (RFC 3492), so an address written as xn--... is read as the letters it stands for

    static func decoded(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false).map { part -> String in
            let label = String(part)
            guard label.hasPrefix("xn--"), let text = punycodeDecode(String(label.dropFirst(4))) else { return label }
            return text
        }.joined(separator: ".")
    }

    static func punycodeDecode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var n = 128, i = 0, bias = 72
        var output: [Character] = []
        var rest = Substring(input)
        if let dash = input.lastIndex(of: "-") {
            output = Array(input[..<dash])
            rest = input[input.index(after: dash)...]
        }
        func digit(_ c: Character) -> Int? {
            guard let v = c.asciiValue else { return nil }
            switch v { case 48...57: return Int(v) - 22; case 65...90: return Int(v) - 65; case 97...122: return Int(v) - 97; default: return nil }
        }
        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var d = first ? delta / damp : delta / 2
            d += d / count
            var k = 0
            while d > ((base - tMin) * tMax) / 2 { d /= base - tMin; k += base }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        var chars = Array(rest)
        var index = 0
        while index < chars.count {
            let oldi = i
            var w = 1, k = base
            while true {
                guard index < chars.count, let d = digit(chars[index]) else { return nil }
                index += 1
                i += d * w
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if d < t { break }
                w *= base - t
                k += base
            }
            bias = adapt(i - oldi, output.count + 1, oldi == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard let scalar = Unicode.Scalar(n) else { return nil }
            output.insert(Character(scalar), at: i)
            i += 1
        }
        chars = []
        return String(output)
    }
}

// MARK: Privacy score

/// A grade for how a page treats the person, from what the browser already knows about it. Nothing is fetched to work it out.
struct SiteScore: Equatable {
    struct Reason: Equatable, Identifiable { var id: String { text }; var text: String; var good: Bool }
    var points: Int
    var reasons: [Reason]

    var grade: String {
        switch points { case 90...: "A"; case 75..<90: "B"; case 60..<75: "C"; case 40..<60: "D"; default: "F" }
    }
    var summary: String {
        switch grade {
        case "A": "Respectful: little tracking, a secure connection."
        case "B": "Mostly fine, with some outside services."
        case "C": "Several outside services watch this page."
        case "D": "Heavy tracking or a weak connection."
        default: "Poor: be careful what you enter here."
        }
    }

    static func score(secure: Bool, thirdParties: Int, blocked: Int, permissionsGranted: Int, lookalike: Finding?) -> SiteScore {
        var points = 100
        var reasons: [Reason] = []
        if secure { reasons.append(.init(text: "Secure connection (HTTPS)", good: true)) }
        else { points -= 45; reasons.append(.init(text: "Not a secure connection: others on the network could read or change it", good: false)) }
        if thirdParties == 0 { reasons.append(.init(text: "Loads nothing from other sites", good: true)) }
        else {
            points -= min(30, thirdParties * 2)
            reasons.append(.init(text: "Loads from \(thirdParties) other site\(thirdParties == 1 ? "" : "s")", good: thirdParties <= 3))
        }
        if blocked > 0 {
            points -= min(15, blocked)
            reasons.append(.init(text: "\(blocked) ad or tracker request\(blocked == 1 ? "" : "s") stopped", good: true))
        } else { reasons.append(.init(text: "No trackers seen", good: true)) }
        if permissionsGranted > 0 {
            points -= min(15, permissionsGranted * 5)
            reasons.append(.init(text: "You allowed \(permissionsGranted) permission\(permissionsGranted == 1 ? "" : "s") on this site", good: false))
        }
        if let lookalike {
            points -= 60
            reasons.append(.init(text: lookalike.reason, good: false))
        }
        return SiteScore(points: max(0, min(100, points)), reasons: reasons)
    }
    typealias Finding = LookalikeCheck.Finding
}

// MARK: Asking for things in plain words

/// "that recipe from last week": the words are looked for in history, limited to the time the person named. Everything is worked out on the device.
enum PlainRecall {
    struct Request: Equatable {
        var terms: [String]
        var from: Date?
        var to: Date?
        var phrase: String
    }

    /// Nil when the text names no time, so ordinary searches are left alone.
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Request? {
        var words = text.lowercased()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        var range: (Date, Date)?
        var phrase = ""
        func take(_ p: String, _ r: (Date, Date)) { if range == nil, words.contains(p) { range = r; phrase = p; words = words.replacingOccurrences(of: p, with: " ") } }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? day(-6)
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? day(-29)
        take("day before yesterday", (day(-2), day(-1)))
        take("yesterday", (day(-1), today))
        take("last week", (calendar.date(byAdding: .day, value: -7, to: weekStart)!, weekStart))
        take("this week", (weekStart, day(1)))
        take("last month", (calendar.date(byAdding: .month, value: -1, to: monthStart)!, monthStart))
        take("this month", (monthStart, day(1)))
        take("today", (today, day(1)))
        take("this morning", (today, calendar.date(byAdding: .hour, value: 12, to: today)!))
        take("last night", (calendar.date(byAdding: .hour, value: -6, to: today)!, calendar.date(byAdding: .hour, value: 4, to: today)!))
        if range == nil, let match = words.range(of: #"\b(\d{1,3}) (day|days|week|weeks|month|months) ago\b"#, options: .regularExpression) {
            let bits = words[match].split(separator: " ")
            if let n = Int(bits[0]) {
                let unit: Calendar.Component = bits[1].hasPrefix("day") ? .day : (bits[1].hasPrefix("week") ? .weekOfYear : .month)
                if let start = calendar.date(byAdding: unit, value: -n, to: today), let end = calendar.date(byAdding: .day, value: 1, to: start) {
                    range = (start, end); phrase = String(words[match]); words.removeSubrange(match)
                }
            }
        }
        guard let range else { return nil }
        let filler: Set<String> = ["the", "a", "an", "that", "this", "i", "saw", "read", "found", "visited", "opened", "from", "on", "in", "at", "of", "my", "me", "was", "were", "where", "what", "which", "site", "page", "pages", "website", "article", "about", "show", "find", "looking", "for", "had", "went", "to", "and", "it"]
        let terms = words.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !filler.contains($0) && $0.count > 1 }
        return Request(terms: terms, from: range.0, to: range.1, phrase: phrase)
    }

    static func matches(_ item: HistoryItem, _ request: Request) -> Bool {
        let when = Date(timeIntervalSince1970: TimeInterval(item.lastVisit))
        if let from = request.from, when < from { return false }
        if let to = request.to, when >= to { return false }
        let haystack = (item.title + " " + item.url).lowercased()
        return request.terms.allSatisfy { haystack.contains($0) }
    }
}

// MARK: Focus schedule

/// "On weekdays from 9 to 17, use the Work workspace." Applied once as the time begins, so a change made by hand afterwards stays.
struct FocusRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Calendar weekdays, 1 = Sunday.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var startMinute: Int = 9 * 60
    var endMinute: Int = 17 * 60
    var workspace: String = ""
    var enabled = true

    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, weekdays.contains(calendar.component(.weekday, from: date)) else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return startMinute <= endMinute ? (minute >= startMinute && minute < endMinute) : (minute >= startMinute || minute < endMinute)
    }
}

enum FocusSchedule {
    /// The rule in force now, the first one that matches.
    static func current(_ rules: [FocusRule], at date: Date = Date(), calendar: Calendar = .current) -> FocusRule? {
        rules.first { $0.isActive(at: date, calendar: calendar) }
    }
}
