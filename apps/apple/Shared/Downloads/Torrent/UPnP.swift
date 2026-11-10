import Foundation
import Network

// MARK: UPnP Internet Gateway Device (the third way of asking the router to forward the listening port, after PCP and NAT-PMP)
//
// Used only when the person turned port forwarding on, and only after PCP and NAT-PMP got no answer. The router is asked directly (a unicast SSDP search to its own address, which a connected socket allows
// inside the sandbox; a multicast search would need the Local Network multicast delivery that is not available here). What the router answers with is never trusted further than the router itself:
// the description address and the control address must both be on the router's own IPv4 address (a router that points elsewhere is how a LAN device is made to fetch or post to a stranger), replies are
// size-capped, redirects are refused, requests ignore any system proxy, and only two actions are ever sent: AddPortMapping and DeletePortMapping.

struct UPnPService: Sendable, Equatable {
    var controlURL: URL
    var serviceType: String
}

enum UPnP {
    static let port: UInt16 = 1900
    static let searchTarget = "urn:schemas-upnp-org:device:InternetGatewayDevice:1"
    static let maxDocument = 256 * 1024

    /// Preferred first. WANIPConnection:2 and :1 are the usual ones; WANPPPConnection is for routers that dial.
    static let serviceTypes = ["urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANPPPConnection:1"]

    static func searchRequest(host: String) -> Data {
        Data("M-SEARCH * HTTP/1.1\r\nHOST: \(host):\(port)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(searchTarget)\r\n\r\n".utf8)
    }

    /// The description address from an SSDP answer, only if it is an http address on the router's own IPv4 address.
    static func location(fromSearchReply data: Data, gateway: String) -> URL? {
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 200") || first.hasPrefix("HTTP/1.0 200") else { return nil }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return onRouter(URL(string: value), gateway: gateway)
            }
        }
        return nil
    }

    /// nil unless it is http on exactly the router's address with a usable port: no names, no other hosts, no other schemes.
    static func onRouter(_ url: URL?, gateway: String) -> URL? {
        guard let url, url.scheme?.lowercased() == "http", url.host == gateway, url.user == nil, url.password == nil else { return nil }
        if let p = url.port, !(1...65535).contains(p) { return nil }
        return url
    }

    /// The control address of the best WAN connection service in a device description.
    static func service(fromDescription data: Data, location: URL, gateway: String) -> UPnPService? {
        guard data.count <= maxDocument else { return nil }
        let parser = XMLParser(data: data)
        let collector = DescriptionCollector()
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        let base = collector.urlBase.flatMap { URL(string: $0) } ?? location
        for wanted in serviceTypes {
            if let s = collector.services.first(where: { $0.type == wanted }), let control = URL(string: s.control, relativeTo: base)?.absoluteURL, let ok = onRouter(control, gateway: gateway) {
                return UPnPService(controlURL: ok, serviceType: wanted)
            }
        }
        return nil
    }

    private final class DescriptionCollector: NSObject, XMLParserDelegate {
        var services: [(type: String, control: String)] = []
        var urlBase: String?
        private var path: [String] = [], text = "", type = "", control = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name); text = ""
            if name == "service" { type = ""; control = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if text.count < 2048 { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "serviceType" { type = value }
            else if name == "controlURL" { control = value }
            else if name == "URLBase", path.count == 2 { urlBase = value }
            else if name == "service", !type.isEmpty, !control.isEmpty, services.count < 64 { services.append((type, control)) }
            _ = path.popLast(); text = ""
        }
    }

    // MARK: Actions

    private static func envelope(_ service: UPnPService, action: String, arguments: [(String, String)]) -> (headers: [String: String], body: Data) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let args = arguments.map { "<\($0.0)>\(esc($0.1))</\($0.0)>" }.joined()
        let xml = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(service.serviceType)\">\(args)</u:\(action)></s:Body></s:Envelope>"
        return (["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPAction": "\"\(service.serviceType)#\(action)\""], Data(xml.utf8))
    }

    static func addPortMapping(_ service: UPnPService, externalPort: UInt16, internalPort: UInt16, client: String, tcp: Bool, lease: UInt32) -> (headers: [String: String], body: Data) {
        envelope(service, action: "AddPortMapping", arguments: [("NewRemoteHost", ""), ("NewExternalPort", "\(externalPort)"), ("NewProtocol", tcp ? "TCP" : "UDP"), ("NewInternalPort", "\(internalPort)"),
                                                                ("NewInternalClient", client), ("NewEnabled", "1"), ("NewPortMappingDescription", "Browser Setu"), ("NewLeaseDuration", "\(lease)")])
    }

    static func deletePortMapping(_ service: UPnPService, externalPort: UInt16, tcp: Bool) -> (headers: [String: String], body: Data) {
        envelope(service, action: "DeletePortMapping", arguments: [("NewRemoteHost", ""), ("NewExternalPort", "\(externalPort)"), ("NewProtocol", tcp ? "TCP" : "UDP")])
    }

    /// The UPnP error code in a fault answer (725: only permanent leases; 718: that external port is in use; 501: action failed), when there is one.
    static func errorCode(in data: Data) -> Int? {
        guard let text = String(data: data.prefix(8192), encoding: .utf8), let open = text.range(of: "<errorCode>"), let close = text.range(of: "</errorCode>", range: open.upperBound..<text.endIndex) else { return nil }
        return Int(text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    static func errorText(_ code: Int?) -> String {
        switch code {
        case 718?: "The router says that port is already forwarded to another computer"
        case 725?: "The router only accepts permanent port forwards"
        case 724?, 726?, 727?, 729?: "The router refuses this kind of port forward"
        case 606?: "The router does not allow this (port forwarding is turned off, or needs its password)"
        case 501?: "The router could not carry out the request"
        case let c?: "The router answered with an error (\(c))"
        default: "The router refused the request"
        }
    }
}

/// What UPnP needs from the network. A seam so it can be tested without a router.
protocol UPnPTransport: AnyObject, Sendable {
    /// Sends a search to the router's own address and returns the first answer.
    func search(gateway: String, timeout: TimeInterval) async -> Data?
    func fetch(_ url: URL, timeout: TimeInterval) async -> Data?
    func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async -> (status: Int, body: Data)?
}

/// The real transport: a connected UDP socket for the search and a URLSession with no proxy, no redirects, no cookies and no cache for the two HTTP calls.
final class NWUPnPTransport: UPnPTransport, @unchecked Sendable {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    deinit { session.finishTasksAndInvalidate() }
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]          // a request to the router never goes through the person's proxy
        c.httpShouldSetCookies = false; c.httpCookieAcceptPolicy = .never; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        c.timeoutIntervalForResource = 8          // an overall deadline: a router that sends a byte at a time cannot hold a request open
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }()

    func search(gateway: String, timeout: TimeInterval) async -> Data? {
        guard let t = NWPortMapTransport(gateway: gateway, port: UPnP.port) else { return nil }
        defer { t.close() }
        return await t.exchange(UPnP.searchRequest(host: gateway), timeout: timeout)
    }

    func fetch(_ url: URL, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        guard let (bytes, response) = try? await session.bytes(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var data = Data()
        do { for try await b in bytes { data.append(b); if data.count > UPnP.maxDocument { return nil } } } catch { return nil }
        return data
    }

    func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let (bytes, response) = try? await session.bytes(for: request), let http = response as? HTTPURLResponse else { return nil }
        var data = Data()
        do { for try await b in bytes { data.append(b); if data.count > UPnP.maxDocument { return nil } } } catch { return nil }
        return (http.statusCode, data)
    }
}
