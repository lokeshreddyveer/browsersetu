import Foundation

/// What an AI tool gets back from one tool call.
struct AgentToolResult: Equatable {
    var text: String
    var isError = false
}

/// The browser, as the protocol layer sees it.
@MainActor
protocol AgentHost: AnyObject {
    func runTool(_ name: String, arguments: [String: Any]) async -> AgentToolResult
}

/// The Model Context Protocol, the open standard Claude, ChatGPT, Gemini, Cursor and other AI tools use to call tools: JSON-RPC 2.0 messages over HTTP.
/// This is only the message handling; the browser's real work and the safety rules are behind `AgentHost`.
enum AgentMCP {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let tools: [[String: Any]] = [
        tool("list_tabs", "List the tabs the person has shared with AI tools, and the tabs you opened. Returns each tab's id, title and address.", [:], []),
        tool("open_url", "Open a web page (http or https only) in a new tab that is shared with you. Returns the tab id.",
             ["url": ["type": "string", "description": "The full web address."]], ["url"]),
        tool("read_page", "Read a shared tab: its visible text and a numbered list of things you can click or type into. Element numbers change when the page changes, so read again after acting.",
             ["tab_id": ["type": "integer", "description": "Tab id from list_tabs."]], ["tab_id"]),
        tool("click", "Click an element by its number from read_page. Buttons that send, pay, post or delete make the person confirm first; they may say no.",
             ["tab_id": ["type": "integer"], "element": ["type": "integer", "description": "Element number from read_page."]], ["tab_id", "element"]),
        tool("type_text", "Type text into a field by its number from read_page. Password, card and one-time-code fields are refused. Set press_enter to submit a search box.",
             ["tab_id": ["type": "integer"], "element": ["type": "integer"], "text": ["type": "string"],
              "press_enter": ["type": "boolean", "description": "Press Return afterwards. In a form this sends it, so the person is asked."]], ["tab_id", "element", "text"]),
        tool("scroll", "Scroll a shared tab up or down by about one screen.",
             ["tab_id": ["type": "integer"], "direction": ["type": "string", "enum": ["down", "up"]]], ["tab_id", "direction"]),
        tool("go_back", "Go back one page in a shared tab.", ["tab_id": ["type": "integer"]], ["tab_id"]),
        tool("close_tab", "Close a tab you opened. Tabs the person shared are left open.", ["tab_id": ["type": "integer"]], ["tab_id"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    /// Answers one HTTP request body. Nil means there is nothing to send back (a notification).
    @MainActor
    static func handle(_ body: Data, host: AgentHost) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return error(id: nil, code: -32700, "Parse error") }
        guard let message = object as? [String: Any] else { return error(id: nil, code: -32600, "Batches are not supported") }
        let id = message["id"]
        guard (message["jsonrpc"] as? String) == "2.0", let method = message["method"] as? String else { return error(id: id, code: -32600, "Invalid request") }
        // A message without an id is a notification; it gets no reply.
        if id == nil { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = supportedVersions.contains(asked) ? asked : supportedVersions[0]
            return result(id: id, ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]],
                                   "serverInfo": ["name": "Browser Setu", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"],
                                   "instructions": "Browser Setu lets you use web pages the person has shared with you. Always read_page before clicking. Anything that sends, pays or deletes asks the person to confirm, and they may refuse."])
        case "ping": return result(id: id, [:])
        case "tools/list": return result(id: id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String, tools.contains(where: { ($0["name"] as? String) == name }) else { return error(id: id, code: -32602, "Unknown tool") }
            let outcome = await host.runTool(name, arguments: params["arguments"] as? [String: Any] ?? [:])
            return result(id: id, ["content": [["type": "text", "text": outcome.text]], "isError": outcome.isError])
        default: return error(id: id, code: -32601, "Method not found")
        }
    }

    private static func result(id: Any?, _ value: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value])
    }

    private static func error(id: Any?, code: Int, _ message: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }
}
