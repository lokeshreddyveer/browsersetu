import Foundation
import WebKit

/// The only way a user script can reach the browser, and a narrow one: one handler per script, in that script's own world, that knows which script it belongs to (the
/// script cannot name another), accepts only a fixed set of small messages, and checks the permission the person gave on every call. It can report that it ran, report
/// errors and log lines, keep its own saved values, and (with the permission) make a request to a website it listed. There is nothing else on it: no Keychain, no files,
/// no history, no tabs, no settings. A script in the page's world is held to reporting only.
final class UserScriptBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let script: UserScript
    private weak var storage: UserScriptStorage?
    private init(script: UserScript, storage: UserScriptStorage?) { self.script = script; self.storage = storage }

    /// The handler's name. It exists only inside one script's own named world, so another script, the page and its frames cannot see it.
    static let handlerName = "bsus"

    /// The only place a user script's handler is registered, and always in the private world made for that one script (never the page's world or the browser's own).
    @MainActor static func register(for script: UserScript, storage: UserScriptStorage?, world: WKContentWorld, on controller: WKUserContentController) {
        precondition(world != .page && world != .defaultClient, "a user script's bridge is never registered in a shared world")
        controller.addScriptMessageHandler(UserScriptBridge(script: script, storage: storage), contentWorld: world, name: handlerName)
    }

    @MainActor static func unregister(world: WKContentWorld, from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { replyHandler(nil, nil); return }
        let script = self.script, storage = self.storage
        let text = (body["text"] as? String).map { String($0.prefix(300)) } ?? ""
        let reportOnly = ["ran", "err", "log", "denied"]
        guard !script.inPageWorld || reportOnly.contains(op) else { replyHandler(nil, nil); return }
        switch op {
        case "ran": Task { @MainActor in UserScriptDiagnostics.shared.ran(script.id) }; replyHandler(nil, nil)
        case "err": Task { @MainActor in UserScriptDiagnostics.shared.failed(script.id, text) }; replyHandler(nil, nil)
        case "log": Task { @MainActor in UserScriptDiagnostics.shared.log(script.id, text) }; replyHandler(nil, nil)
        case "denied": Task { @MainActor in UserScriptDiagnostics.shared.denied(script.id, text) }; replyHandler(nil, nil)
        case "set", "del":
            guard script.allows(.storage), let key = body["key"] as? String, key.count <= 200 else {
                Task { @MainActor in UserScriptDiagnostics.shared.denied(script.id, "saved values") }; replyHandler(nil, nil); return
            }
            let value = op == "set" ? (body["value"] as? String) : nil
            if op == "set", value == nil || value!.utf8.count > UserScriptStorage.maxBytes { replyHandler(nil, nil); return }
            Task { @MainActor in
                if storage?.setValue(script.id, key, value) != true { UserScriptDiagnostics.shared.failed(script.id, "Its saved values are full.") }
            }
            replyHandler(nil, nil)
        case "xhr":
            guard script.allows(.network), let address = body["url"] as? String else {
                Task { @MainActor in UserScriptDiagnostics.shared.denied(script.id, "GM_xmlhttpRequest") }
                replyHandler(["error": "This script was not given permission to contact websites."], nil); return
            }
            let method = (body["method"] as? String) ?? "GET"
            let headers = (body["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            let data = body["data"] as? String
            let timeout = (body["timeout"] as? Double ?? 15000) / 1000
            let connects = script.connects
            Task {
                let result = await UserScriptNet.request(method: method, address: address, headers: headers, body: data, timeout: timeout, connects: connects)
                if let error = result["error"] as? String { await MainActor.run { UserScriptDiagnostics.shared.failed(script.id, error) } }
                replyHandler(result, nil)
            }
        default:
            replyHandler(nil, nil)
        }
    }
}
