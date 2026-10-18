import Foundation
import SwiftUI

/// What the page's own scripts printed and which connections they opened, collected while the developer capture is on. It runs in the page's world
/// (the only place a page's console can be seen from), so a page can detect it; it is off unless a developer turns it on.
struct ConsoleEntry: Equatable, Identifiable {
    var id = UUID()
    var level: String
    var text: String
    var at: Date
}

struct SocketEntry: Equatable, Identifiable {
    var id = UUID()
    var url: String
    var state: String
    var opened: Date
    var sent: Int
    var received: Int
    var bytesSent: Int
    var bytesReceived: Int
    var code: Int?
}

struct FailedResource: Equatable, Identifiable {
    var id = UUID()
    var url: String
    var tag: String
    /// True when the request never reached the network, so a blocker is the likely cause.
    var blocked: Bool
}

struct DevLog: Equatable {
    var console: [ConsoleEntry] = []
    var sockets: [SocketEntry] = []
    var failed: [FailedResource] = []

    init() {}

    init(raw: [String: Any]) {
        func date(_ v: Any?) -> Date { Date(timeIntervalSince1970: ((v as? NSNumber)?.doubleValue ?? 0) / 1000) }
        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        console = ((raw["console"] as? [[String: Any]]) ?? []).map { ConsoleEntry(level: $0["level"] as? String ?? "log", text: $0["text"] as? String ?? "", at: date($0["at"])) }
        sockets = ((raw["ws"] as? [[String: Any]]) ?? []).map {
            SocketEntry(url: $0["url"] as? String ?? "", state: $0["state"] as? String ?? "", opened: date($0["opened"]), sent: int($0["sent"]), received: int($0["received"]),
                        bytesSent: int($0["bytesSent"]), bytesReceived: int($0["bytesReceived"]), code: ($0["code"] as? NSNumber)?.intValue)
        }
        failed = ((raw["failed"] as? [[String: Any]]) ?? []).map { FailedResource(url: $0["url"] as? String ?? "", tag: $0["tag"] as? String ?? "", blocked: ($0["blocked"] as? NSNumber)?.boolValue ?? false) }
    }

    /// The console as plain text, one line per message, to save or share.
    var consoleText: String {
        let f = ISO8601DateFormatter()
        return console.map { "\(f.string(from: $0.at)) [\($0.level)] \($0.text)" }.joined(separator: "\n")
    }

    var socketText: String {
        sockets.map { "\($0.url) · \($0.state)\($0.code.map { " (\($0))" } ?? "") · sent \($0.sent) (\($0.bytesSent) B) · received \($0.received) (\($0.bytesReceived) B)" }.joined(separator: "\n")
    }
}

enum DevCaptureScript {
    static let source = """
    (function () {
      if (window.__bsDev) { return; }
      var dev = window.__bsDev = { console: [], ws: [], failed: [] };
      function push(list, item, max) { list.push(item); if (list.length > max) { list.shift(); } }
      function show(a) { try { if (typeof a === 'string') { return a; } if (a instanceof Error) { return a.stack || a.message; } return JSON.stringify(a); } catch (e) { return String(a); } }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try { push(dev.console, { level: level, text: Array.prototype.map.call(arguments, show).join(' ').slice(0, 1000), at: Date.now() }, 500); } catch (e) {}
          return original.apply(this, arguments);
        };
      });
      window.addEventListener('error', function (e) {
        var t = e.target;
        if (t && t !== window && t.tagName) {
          var u = t.currentSrc || t.src || t.href;
          if (u) { push(dev.failed, { url: String(u).slice(0, 300), tag: t.tagName.toLowerCase(), at: Date.now() }, 200); }
        } else {
          push(dev.console, { level: 'error', text: String(e.message) + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : ''), at: Date.now() }, 500);
        }
      }, true);
      window.addEventListener('unhandledrejection', function (e) { push(dev.console, { level: 'error', text: 'Unhandled promise rejection: ' + show(e.reason && e.reason.message ? e.reason.message : e.reason), at: Date.now() }, 500); });
      var Native = window.WebSocket;
      if (Native) {
        var size = function (d) { return typeof d === 'string' ? d.length : (d && (d.byteLength || d.size)) || 0; };
        var Wrapped = function (url, protocols) {
          var ws = protocols === undefined ? new Native(url) : new Native(url, protocols);
          var rec = { url: String(url).slice(0, 300), opened: Date.now(), state: 'connecting', sent: 0, received: 0, bytesSent: 0, bytesReceived: 0, code: null };
          push(dev.ws, rec, 50);
          ws.addEventListener('open', function () { rec.state = 'open'; });
          ws.addEventListener('message', function (e) { rec.received++; rec.bytesReceived += size(e.data); });
          ws.addEventListener('error', function () { rec.state = 'error'; });
          ws.addEventListener('close', function (e) { rec.state = 'closed'; rec.code = e.code; });
          var send = ws.send;
          ws.send = function (d) { rec.sent++; rec.bytesSent += size(d); return send.apply(this, arguments); };
          return ws;
        };
        Wrapped.prototype = Native.prototype;
        ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { Wrapped[k] = Native[k]; });
        window.WebSocket = Wrapped;
      }
    })();
    """

    static let read = """
    if (!window.__bsDev) { return null; }
    var seen = performance.getEntriesByType('resource').map(function (r) { return r.name; });
    return { console: window.__bsDev.console, ws: window.__bsDev.ws,
             failed: window.__bsDev.failed.map(function (f) { return { url: f.url, tag: f.tag, blocked: seen.indexOf(f.url) < 0 }; }) };
    """
}

/// Response headers for an address, asked for fresh with no cookies. WebKit does not give a page's own headers to an app, so this is a new request.
enum ResponseHeaders {
    static func fetch(_ url: URL) async -> (status: Int, headers: [(name: String, value: String)])? {
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        var request = URLRequest(url: url, timeoutInterval: 10); request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession(configuration: config).data(for: request), let http = response as? HTTPURLResponse else { return nil }
        let pairs = http.allHeaderFields.compactMap { k, v -> (String, String)? in (k as? String).flatMap { name in (v as? String).map { (name, $0) } } }
        return (http.statusCode, pairs.sorted { $0.0.lowercased() < $1.0.lowercased() }.map { (name: $0.0, value: $0.1) })
    }

    /// Plain-language notes on the security headers that matter, from what came back.
    static func securityNotes(_ headers: [(name: String, value: String)]) -> [String] {
        let have = Set(headers.map { $0.name.lowercased() })
        var notes: [String] = []
        if !have.contains("strict-transport-security") { notes.append("No Strict-Transport-Security: the site does not ask browsers to always use HTTPS.") }
        if !have.contains("content-security-policy") { notes.append("No Content-Security-Policy: the page has no limit on where its scripts may come from.") }
        if !have.contains("x-content-type-options") { notes.append("No X-Content-Type-Options: browsers may guess file types.") }
        if !have.contains("x-frame-options") && !(headers.first { $0.name.lowercased() == "content-security-policy" }?.value.contains("frame-ancestors") ?? false) {
            notes.append("Nothing stops other sites from showing this page in a frame (clickjacking).")
        }
        if !have.contains("referrer-policy") { notes.append("No Referrer-Policy: the browser's default applies.") }
        return notes
    }
}

/// Console, WebSockets, failed resources, page source, response headers, TLS and the user agent, for the page in front.
struct DeveloperExtras: View {
    @EnvironmentObject var model: BrowserModel
    @State private var log: DevLog?
    @State private var level = "all"
    @State private var source: String?
    @State private var headers: (status: Int, headers: [(name: String, value: String)])?
    @State private var agent: String?
    @State private var showSource = false
    @State private var busy = false

    private var tab: TabController? { model.active.flatMap { $0.isPrivate || $0.isBlank ? nil : $0 } }

    var body: some View {
        Group {
            Section {
                Toggle("Capture console, WebSockets and failed resources", isOn: $model.devCapture)
                Text("Turn on, then reload the page. The capture runs inside the page, so the page can notice it; it is off by default and never runs in private tabs.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh") { Task { log = await tab?.engine.devLog() } }.disabled(tab == nil)
                    Button("Copy Console") { copyToPasteboard(filteredConsole.map { "[\($0.level)] \($0.text)" }.joined(separator: "\n")); model.notice = "Console copied." }.disabled(filteredConsole.isEmpty)
                    Button("Save Console") { model.workbench.save(Data((log?.consoleText ?? "").utf8), name: "console-\(Int(Date().timeIntervalSince1970)).txt") }.disabled(filteredConsole.isEmpty)
                }
                Picker("Show", selection: $level) { Text("All").tag("all"); Text("Errors").tag("error"); Text("Warnings").tag("warn"); Text("Logs").tag("log") }.pickerStyle(.segmented)
                if log == nil { Text(model.devCapture ? "Nothing captured yet. Reload the page, use it, then Refresh." : "Capture is off.").foregroundStyle(.secondary) }
                ForEach(filteredConsole.suffix(200)) { entry in
                    Text("[\(entry.level)] \(entry.text)").font(.caption.monospaced()).foregroundStyle(entry.level == "error" ? Color.red : (entry.level == "warn" ? Color.orange : Color.primary)).textSelection(.enabled)
                }
            } header: { Text("Console") }
            if let log, !log.sockets.isEmpty {
                Section("WebSockets") {
                    ForEach(log.sockets) { s in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.url).font(.callout).lineLimit(1)
                            Text("\(s.state)\(s.code.map { " (\($0))" } ?? "") · sent \(s.sent) (\(s.bytesSent) B) · received \(s.received) (\(s.bytesReceived) B)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Copy") { copyToPasteboard(log.socketText) }
                }
            }
            if let log, !log.failed.isEmpty {
                Section("Failed Resources") {
                    ForEach(log.failed) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.url).font(.caption).lineLimit(1)
                            Text(f.blocked ? "\(f.tag) · never reached the network (likely blocked)" : "\(f.tag) · the request failed").font(.caption2).foregroundStyle(f.blocked ? Color.orange : Color.red)
                        }
                    }
                }
            }
            Section {
                Button(busy ? "Reading…" : "Read Source, Headers, TLS and User Agent") { Task { await read() } }.disabled(tab == nil || busy)
                if let agent { LabeledContent("User agent") { Text(agent).font(.caption.monospaced()).textSelection(.enabled) } }
                if let tab, let id = tab.identity { LabeledContent("Certificate") { Text(id.headline + ". " + id.detail).font(.caption).textSelection(.enabled) } }
                else if let tab, tab.isSecure { Text("Encrypted. The certificate names no checked owner.").font(.caption).foregroundStyle(.secondary) }
                if let h = headers {
                    DisclosureGroup("Response headers (HTTP \(h.status))") {
                        ForEach(Array(h.headers.enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 0) { Text(pair.name).font(.caption.weight(.semibold)); Text(pair.value).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                        ForEach(ResponseHeaders.securityNotes(h.headers), id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                }
                if source != nil { Button("View Page Source…") { showSource = true } }
            } header: { Text("Page Details") } footer: {
                Text("Headers come from a new request to the page's address (no cookies), since WebKit does not give an app a page's own headers; they can differ from what the page received. Source is the page as it is now, after its scripts ran.")
            }
        }
        .sheet(isPresented: $showSource) {
            NavigationStack {
                ScrollView { Text(source ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle("Page Source")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showSource = false } }
                               ToolbarItem(placement: .primaryAction) { Button("Copy") { copyToPasteboard(source ?? "") } } }
            }
            .frame(minWidth: 560, minHeight: 420)
        }
    }

    private var filteredConsole: [ConsoleEntry] {
        (log?.console ?? []).filter { level == "all" || ($0.level == level) || (level == "log" && ["info", "debug"].contains($0.level)) }
    }

    private func read() async {
        guard let tab else { return }
        busy = true
        source = await tab.engine.pageSource()
        agent = await tab.engine.userAgentString()
        if let url = tab.url, ["http", "https"].contains(url.scheme ?? "") { headers = await ResponseHeaders.fetch(url) }
        busy = false
    }
}
