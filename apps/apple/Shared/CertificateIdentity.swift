import Foundation

/// What a site's certificate says about who is on the other end, in words a person can use. Read from the certificate itself (its subject and the policy it was issued under),
/// not guessed. A padlock only says the connection is private; this says whether anyone checked who owns the site.
struct CertificateIdentity: Equatable {
    /// How much the authority that issued the certificate checked.
    enum Level: Equatable {
        /// The organisation's legal existence was checked in detail.
        case extended
        /// The organisation's name was checked.
        case organization
        /// A named individual was checked.
        case individual
        /// Only that the requester controls the domain. Says nothing about who they are.
        case domain
    }

    var host: String
    var organization: String?
    var country: String?
    var commonName: String?
    var issuer: String
    var level: Level

    /// A site whose certificate names a checked organisation.
    var isVerified: Bool { organization != nil && level != .domain }

    /// The short line: "Verified: Apple Inc. (US)", or "Encrypted, owner not verified".
    var headline: String {
        if isVerified, let organization { return "Verified: " + organization + (country.map { " (\($0))" } ?? "") }
        return "Encrypted, owner not verified"
    }

    /// For the address bar: just the organisation, when there is a checked one.
    var shortLabel: String? { isVerified ? organization : nil }

    var detail: String {
        let by = issuer.isEmpty ? "" : " Certificate issued by \(issuer)."
        if isVerified, let organization {
            let how = level == .extended ? "checked in detail" : "checked"
            return "The authority that issued this site's certificate \(how) that \(organization) controls \(host).\(by)"
        }
        return "The certificate only proves this connection is really to \(host). It does not say who runs the site.\(by)"
    }

    // MARK: Reading the certificate

    /// From the certificate's DER bytes, or nil if they are not a certificate.
    static func parse(der: Data, host: String) -> CertificateIdentity? {
        let bytes = [UInt8](der)
        var outer = DERReader(bytes)
        guard let cert = outer.next(), cert.tag == 0x30 else { return nil }
        var certBody = DERReader(bytes, cert.content)
        guard let tbs = certBody.next(), tbs.tag == 0x30 else { return nil }
        var fields = DERReader(bytes, tbs.content)
        var field = fields.next()
        if field?.tag == 0xA0 { field = fields.next() }                       // version
        guard field?.tag == 0x02 else { return nil }                           // serial number
        guard fields.next()?.tag == 0x30 else { return nil }                   // signature algorithm
        guard let issuerField = fields.next(), issuerField.tag == 0x30 else { return nil }
        guard fields.next()?.tag == 0x30 else { return nil }                   // validity
        guard let subjectField = fields.next(), subjectField.tag == 0x30 else { return nil }
        let subject = names(in: bytes, subjectField.content)
        let issuer = names(in: bytes, issuerField.content)
        let organization = subject[.organization].flatMap { $0.isEmpty ? nil : $0 }
        let level: Level
        if contains(bytes, Policy.extended) { level = .extended }
        else if contains(bytes, Policy.organization) { level = .organization }
        else if contains(bytes, Policy.individual) { level = .individual }
        else if contains(bytes, Policy.domain) { level = .domain }
        else { level = organization != nil ? .organization : .domain }
        return CertificateIdentity(host: host, organization: organization, country: subject[.country], commonName: subject[.commonName],
                                   issuer: issuer[.organization] ?? issuer[.commonName] ?? "", level: level)
    }

    private enum Attribute { case commonName, country, organization }

    private static let attributeOIDs: [([UInt8], Attribute)] = [([0x55, 0x04, 0x03], .commonName), ([0x55, 0x04, 0x06], .country), ([0x55, 0x04, 0x0A], .organization)]

    /// The certificate policy identifiers of the CA/Browser Forum, as they appear inside a certificate (tag, length, identifier).
    private enum Policy {
        static let extended: [UInt8] = [0x06, 0x05, 0x67, 0x81, 0x0C, 0x01, 0x01]
        static let domain: [UInt8] = [0x06, 0x06, 0x67, 0x81, 0x0C, 0x01, 0x02, 0x01]
        static let organization: [UInt8] = [0x06, 0x06, 0x67, 0x81, 0x0C, 0x01, 0x02, 0x02]
        static let individual: [UInt8] = [0x06, 0x06, 0x67, 0x81, 0x0C, 0x01, 0x02, 0x03]
    }

    private static func names(in bytes: [UInt8], _ range: Range<Int>) -> [Attribute: String] {
        var out: [Attribute: String] = [:]
        var sets = DERReader(bytes, range)
        while let set = sets.next() {
            guard set.tag == 0x31 else { continue }
            var pairs = DERReader(bytes, set.content)
            while let pair = pairs.next(), pair.tag == 0x30 {
                var item = DERReader(bytes, pair.content)
                guard let oid = item.next(), oid.tag == 0x06, let value = item.next() else { continue }
                let id = Array(bytes[oid.content])
                guard let attribute = attributeOIDs.first(where: { $0.0 == id })?.1, out[attribute] == nil else { continue }
                if let text = string(bytes, value) { out[attribute] = text }
            }
        }
        return out
    }

    private static func string(_ bytes: [UInt8], _ element: DERReader.Element) -> String? {
        let raw = Array(bytes[element.content])
        switch element.tag {
        case 0x0C, 0x13, 0x16: return String(bytes: raw, encoding: .utf8)          // UTF8String, PrintableString, IA5String
        case 0x14: return String(bytes: raw, encoding: .isoLatin1)                  // TeletexString, as it is used in practice
        case 0x1E: return String(bytes: raw, encoding: .utf16BigEndian)             // BMPString
        default: return nil
        }
    }

    private static func contains(_ bytes: [UInt8], _ pattern: [UInt8]) -> Bool {
        guard bytes.count >= pattern.count else { return false }
        for start in 0...(bytes.count - pattern.count) where bytes[start] == pattern[0] {
            if Array(bytes[start..<start + pattern.count]) == pattern { return true }
        }
        return false
    }
}

/// Just enough of DER (the encoding certificates use) to walk down to a certificate's names: a tag, a length and where the content is.
struct DERReader {
    struct Element { var tag: UInt8; var content: Range<Int> }
    private let bytes: [UInt8]
    private var position: Int
    private let end: Int

    init(_ bytes: [UInt8], _ range: Range<Int>? = nil) {
        self.bytes = bytes
        position = range?.lowerBound ?? 0
        end = min(range?.upperBound ?? bytes.count, bytes.count)
    }

    mutating func next() -> Element? {
        guard position + 2 <= end else { return nil }
        let tag = bytes[position]
        var length = Int(bytes[position + 1])
        var at = position + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, at + count <= end else { return nil }
            length = 0
            for i in 0..<count { length = length << 8 | Int(bytes[at + i]) }
            at += count
        }
        guard at + length <= end else { return nil }
        position = at + length
        return Element(tag: tag, content: at..<at + length)
    }
}
