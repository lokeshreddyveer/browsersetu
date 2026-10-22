#if DIRECT_BUILD
import AppKit
import SwiftUI

/// Lets AI tools the person runs on this Mac (Claude Code, Gemini CLI, Codex, Cursor and anything else that speaks the Model Context Protocol) use web pages
/// in Browser Setu. Nothing is on unless the person turns it on, and nothing here talks to the internet: the server listens on this Mac's loopback address only.
///
/// The rules, all enforced here and in AgentPolicy rather than left to the AI tool:
///  - It sees only tabs the person shared and tabs it opened itself. Never private tabs.
///  - What is typed into a field is never read. Addresses are shown without their query or fragment.
///  - A tab is read only while it is on a website the person allowed. If a click or a redirect moves it to another origin, that origin must be allowed first.
///  - Clicking and typing need the person to allow the website for the session, and most buttons and most typing ask every time.
///    Anything that sends, pays, posts or deletes always asks. Password, card and one-time-code fields are never typed into.
///  - Page text is handed over labelled as untrusted. Every action is written to a log the person can read, and one button stops it all.
@MainActor
final class AgentBridge: ObservableObject, AgentHost {
    static let shared = AgentBridge()

    @Published private(set) var log: [AgentLogEntry] = []
    @Published private(set) var sharedTabs = Set<UInt64>()
    @Published private(set) var ownedTabs = Set<UInt64>()
    /// Origins (scheme, host and port) where clicking and typing are allowed this session.
    @Published private(set) var allowedOrigins = Set<String>()
    /// Origins a shared tab was on when the person shared it: reading them is allowed, acting on them is not until they are in `allowedOrigins`.
    private var readableOrigins = Set<String>()
    @Published private(set) var status = "Off"
    @Published private(set) var port: UInt16 = 47615

    private static let service = "com.browsersetu.agent"
    private static let portKey = "AIToolsPort"
    private var server: AgentServer?
    private var sharingNoticeSeen = false
    private var callTimes: [Date] = []
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Raised by every stop, so a call already under way can tell that it was cancelled.
    private var generation = 0

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        if saved > 1024 && saved < 65_535 { port = UInt16(saved) }
    }

    // MARK: Start, stop, token

    /// The token as it is right now. The server asks for it on every request, so a new token ends the old one at once.
    nonisolated static func liveToken() -> String? {
        guard let data = SecretStore.get(service: service, account: "token"), let text = String(data: data, encoding: .utf8), text.count >= 32 else { return nil }
        return text
    }

    /// The secret an AI tool must send. Made the first time it is needed and kept in the Keychain of this Mac only.
    var token: String { Self.liveToken() ?? renewToken(restart: false) }

    @discardableResult
    func renewToken(restart: Bool = true) -> String {
        let fresh = AgentHTTP.makeToken()
        _ = SecretStore.put(Data(fresh.utf8), service: Self.service, account: "token")
        // A new token ends every connection that used the old one, and what was shared and allowed goes with it.
        if restart, server != nil { stop(); forgetSession(); start() } else { forgetSession() }
        note("New token", "The old token no longer works", .done)
        return fresh
    }

    /// Opens or closes the connection to match the switches.
    func sync() {
        if AISwitches.shared.toolsActive { start() } else { stop(); forgetSession() }
    }

    private func start() {
        guard server == nil else { return }
        _ = token   // makes the token the first time
        let machine = AgentServer()
        server = machine
        status = "Starting…"
        machine.start(port: port, tokenProvider: { AgentBridge.liveToken() }, onPort: { [weak self] chosen in
            Task { @MainActor in
                guard let self else { return }
                self.port = chosen
                UserDefaults.standard.set(Int(chosen), forKey: Self.portKey)
                self.status = "On: 127.0.0.1:\(chosen)"
            }
        }, onFailure: { [weak self] reason in
            Task { @MainActor in self?.server = nil; self?.status = reason }
        }, handle: { body in
            await AgentMCP.handle(body, host: AgentBridge.shared)
        })
    }

    private func stop() {
        generation += 1
        server?.stop()
        server = nil
        status = "Off"
        // Calls waiting for their turn find the generation changed and give up.
        while !waiters.isEmpty { waiters.removeFirst().resume() }
        busy = false
    }

    /// The kill switch: closes every connection, cancels what is under way, and forgets which tabs were shared and which websites were allowed.
    func stopEverything() {
        AISwitches.shared.toolsOn = false
        stop()
        forgetSession()
        note("Stopped", "AI tools were switched off by you", .done)
    }

    private func forgetSession() {
        sharedTabs = []
        ownedTabs = []
        allowedOrigins = []
        readableOrigins = []
        sharingNoticeSeen = false
    }

    /// Whether a call that began at `started` may still change anything: the switch is on and nothing has been stopped since.
    private func live(_ started: Int) -> Bool { started == generation && AISwitches.shared.toolsActive }

    // MARK: Sharing

    func isShared(_ tab: TabController) -> Bool { sharedTabs.contains(tab.id) || ownedTabs.contains(tab.id) }

    func toggleShare(_ tab: TabController) {
        if tab.isPrivate { return }
        if sharedTabs.contains(tab.id) { sharedTabs.remove(tab.id); note("Unshared", tab.displayTitle, .done); return }
        Task { @MainActor in
            if !sharingNoticeSeen {
                let choice = await Dialogs.choose(
                    title: "Share this tab with AI tools?",
                    message: "The AI tool you connected can read this page’s text and use its buttons. That tool, such as Claude, ChatGPT or Gemini, usually sends what it reads to its own company’s servers, which Browser Setu can not see or control.\n\nDo not share pages with banking, health, work-confidential or other private details unless you are happy for that company to receive them.",
                    buttons: ["Share This Tab", "Cancel"])
                guard choice == 0 else { return }
                sharingNoticeSeen = true
            }
            sharedTabs.insert(tab.id)
            if let origin = AgentPolicy.origin(of: tab.url) { readableOrigins.insert(origin) }
            note("Shared", tab.displayTitle, .done)
        }
    }

    // MARK: The browser behind the tools

    private var model: BrowserModel? {
        let all = BrowserModel.activeModels.allObjects
        return all.first(where: { !$0.isSecondary && !$0.isGuest }) ?? all.first(where: { !$0.isGuest })
    }

    private func note(_ tool: String, _ detail: String, _ outcome: AgentLogEntry.Outcome) {
        log.append(AgentLogEntry(tool: tool, detail: String(detail.prefix(160)), outcome: outcome))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func clearLog() { log = [] }

    private func lock() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func overRate() -> Bool {
        let now = Date()
        callTimes = callTimes.filter { now.timeIntervalSince($0) < 60 }
        if callTimes.count >= 90 { return true }
        callTimes.append(now)
        return false
    }

    func runTool(_ name: String, arguments: [String: Any]) async -> AgentToolResult {
        guard AISwitches.shared.toolsActive, let model else { return AgentToolResult(text: "Browser Setu is not accepting AI tools right now.", isError: true) }
        if overRate() { return AgentToolResult(text: "Too many requests. Wait a moment.", isError: true) }
        let started = generation
        await lock()
        defer { unlock() }
        // The switch may have been turned off, or everything stopped, while this call waited its turn.
        guard live(started) else { return AgentToolResult(text: "AI tools were switched off.", isError: true) }
        return await perform(name, arguments, model, started)
    }

    /// A tab the person shared (or one a tool opened), never a private one.
    private func sharedTab(_ arguments: [String: Any], _ model: BrowserModel) -> TabController? {
        let raw = arguments["tab_id"]
        guard let id = (raw as? Int) ?? (raw as? Double).map(Int.init) ?? (raw as? String).flatMap(Int.init), id >= 0,
              let found = model.tabs.first(where: { $0.id == UInt64(id) }), !found.isPrivate, isShared(found) else { return nil }
        return found
    }

    private func perform(_ name: String, _ args: [String: Any], _ model: BrowserModel, _ started: Int) async -> AgentToolResult {
        func fail(_ text: String, _ outcome: AgentLogEntry.Outcome = .failed) -> AgentToolResult { note(name, text, outcome); return AgentToolResult(text: text, isError: true) }
        let missing = "That tab is not shared with AI tools. Call list_tabs to see which tabs you can use."
        let stopped = "AI tools were switched off."

        switch name {
        case "list_tabs":
            let rows = model.tabs.filter { !$0.isPrivate && isShared($0) && !$0.isBlank }.map {
                "[\($0.id)] \(AgentPolicy.prepare(pageText: $0.displayTitle, limit: 120)) — \(AgentPolicy.safeURL($0.url?.absoluteString ?? ""))"
            }
            note(name, "\(rows.count) tab(s)", .done)
            return AgentToolResult(text: rows.isEmpty ? "No tabs are shared. Ask the person to share a tab (Tools › Share This Tab with AI Tools), or use open_url." : rows.joined(separator: "\n"))

        case "open_url":
            guard let url = AgentPolicy.openable(args["url"] as? String ?? ""), let host = url.host?.lowercased() else { return fail("Only http and https addresses can be opened.", .refused) }
            guard await allowOrigin(url, wanting: "open pages and then click or type on") else { return fail("The person did not allow \(host).", .denied) }
            guard live(started) else { return fail(stopped, .refused) }
            let opened = model.openTab(url: url, isPrivate: false, select: false)
            ownedTabs.insert(opened.id)
            if let origin = AgentPolicy.origin(of: url) { readableOrigins.insert(origin) }
            note(name, AgentPolicy.safeURL(url.absoluteString), .done)
            return AgentToolResult(text: "Opened in tab \(opened.id). Call read_page with tab_id \(opened.id) once it has loaded.")

        case "read_page":
            guard let target = sharedTab(args, model) else { return fail(missing, .refused) }
            // The tab may have moved to another website since it was shared: that website is checked now, not the one it was on before.
            guard await mayRead(target) else { return fail("The person did not allow this website.", .denied) }
            guard live(started) else { return fail(stopped, .refused) }
            guard let snapshot = await target.engine.agentSnapshot() else { return fail("The page could not be read.") }
            // It may have moved again while it was being read.
            guard await mayRead(target), live(started) else { return fail("The page changed to a website that was not allowed.", .refused) }
            note(name, target.displayTitle, .done)
            return AgentToolResult(text: describe(snapshot))

        case "click":
            guard let target = sharedTab(args, model) else { return fail(missing, .refused) }
            guard let index = number(args["element"]) else { return fail("element must be a number from read_page.") }
            guard let host = target.url?.host?.lowercased(), await allowOrigin(target.url, wanting: "click and type on") else { return fail("The person did not allow this website.", .denied) }
            guard let info = await target.engine.agentInspect(index) else { return fail("That element is no longer on the page. Call read_page again.") }
            let element = Self.element(from: info)
            switch AgentPolicy.click(element, pageHost: host) {
            case .refuse(let why): return fail(why, .refused)
            case .confirm(let question):
                note(name, question, .asked)
                guard await confirm(question) else { return fail("The person said no.", .denied) }
            case .allow: break
            }
            // A link to another website: that website must be allowed before the tab goes there.
            if element.tag == "a", let destination = URL(string: element.href), AgentPolicy.origin(of: destination) != AgentPolicy.origin(of: target.url) {
                guard await allowOrigin(destination, wanting: "follow a link to") else { return fail("The person did not allow \(destination.host ?? "that website").", .denied) }
            }
            // The last check before the page is changed.
            guard live(started), target.url?.host?.lowercased() == host else { return fail(stopped, .refused) }
            guard await target.engine.agentClick(index) else { return fail("The click did not work. Call read_page again.") }
            note(name, "Clicked [\(index)] “\(element.text.isEmpty ? element.label : element.text)” on \(host)", .done)
            return AgentToolResult(text: "Clicked. Call read_page again to see the result.")

        case "type_text":
            guard let target = sharedTab(args, model) else { return fail(missing, .refused) }
            guard let index = number(args["element"]), let text = args["text"] as? String else { return fail("element and text are required.") }
            let enter = (args["press_enter"] as? Bool) ?? false
            guard let host = target.url?.host?.lowercased(), await allowOrigin(target.url, wanting: "click and type on") else { return fail("The person did not allow this website.", .denied) }
            guard let info = await target.engine.agentInspect(index) else { return fail("That element is no longer on the page. Call read_page again.") }
            let element = Self.element(from: info)
            switch AgentPolicy.type(element, text: text, pageHost: host) {
            case .refuse(let why): return fail(why, .refused)
            case .confirm(let question):
                note(name, question, .asked)
                guard await confirm(question) else { return fail("The person said no.", .denied) }
            case .allow: break
            }
            if enter, case .confirm(let question) = AgentPolicy.pressEnter(element, pageHost: host) {
                note(name, question, .asked)
                guard await confirm(question) else { return fail("The person said no.", .denied) }
            }
            guard live(started), target.url?.host?.lowercased() == host else { return fail(stopped, .refused) }
            guard await target.engine.agentType(index, text: text, pressEnter: enter) else { return fail("Typing did not work. Call read_page again.") }
            // What was typed is not written to the log, only how much.
            note(name, "Typed \(text.count) character(s) into [\(index)] on \(host)\(enter ? ", then Return" : "")", .done)
            return AgentToolResult(text: "Typed. Call read_page again to see the result.")

        case "scroll":
            guard let target = sharedTab(args, model) else { return fail(missing, .refused) }
            guard live(started) else { return fail(stopped, .refused) }
            await target.engine.agentScroll(down: (args["direction"] as? String) != "up")
            note(name, target.displayTitle, .done)
            return AgentToolResult(text: "Scrolled. Call read_page again.")

        case "go_back":
            guard let target = sharedTab(args, model) else { return fail(missing, .refused) }
            guard live(started) else { return fail(stopped, .refused) }
            target.goBack()
            note(name, target.displayTitle, .done)
            return AgentToolResult(text: "Went back. Call read_page after it loads.")

        case "close_tab":
            guard let target = sharedTab(args, model), ownedTabs.contains(target.id) else { return fail("Only tabs you opened can be closed.", .refused) }
            guard live(started) else { return fail(stopped, .refused) }
            ownedTabs.remove(target.id)
            model.closeTab(id: target.id, force: true)
            note(name, target.displayTitle, .done)
            return AgentToolResult(text: "Closed.")

        default:
            return fail("Unknown tool.")
        }
    }

    // MARK: Asking the person

    /// A shared tab may be read while it is on an origin that was shared or allowed. On any other origin the person is asked first.
    private func mayRead(_ tab: TabController) async -> Bool {
        guard let origin = AgentPolicy.origin(of: tab.url) else { return false }
        if readableOrigins.contains(origin) || allowedOrigins.contains(origin) { return true }
        guard await allowOrigin(tab.url, wanting: "read") else { return false }
        readableOrigins.insert(origin)
        return true
    }

    /// Permission belongs to the exact origin (scheme, host and port), not just the host name.
    private func allowOrigin(_ url: URL?, wanting purpose: String) async -> Bool {
        guard let origin = AgentPolicy.origin(of: url), let host = url?.host?.lowercased() else { return false }
        if allowedOrigins.contains(origin) { return true }
        note("Permission", origin, .asked)
        NSApp.activate(ignoringOtherApps: true)
        let choice = await Dialogs.choose(title: "Let an AI tool use \(host)?",
                                          message: "An AI tool connected to Browser Setu wants to \(purpose) \(origin), signed in as you. You will still be asked before most buttons are pressed and before anything is sent, paid or deleted. This lasts until you quit or switch AI tools off, and covers only this exact address (\(url?.scheme ?? "")://\(host)).",
                                          buttons: ["Allow for This Session", "Don’t Allow"])
        guard choice == 0 else { return false }
        allowedOrigins.insert(origin)
        note("Allowed", origin, .done)
        return true
    }

    private func confirm(_ question: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return await Dialogs.choose(title: "An AI tool wants to do this", message: question + "\n\nAllow it just this once?", buttons: ["Allow Once", "Don’t Allow"]) == 0
    }

    // MARK: Turning a page into text

    private func number(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func element(from info: [String: Any]) -> AgentPolicy.Element {
        func text(_ key: String) -> String { (info[key] as? String) ?? "" }
        func flag(_ key: String) -> Bool { (info[key] as? Bool) ?? false }
        return AgentPolicy.Element(tag: text("tag"), role: text("role"), type: text("type"), text: text("text"), label: text("label"), name: text("name"), autocomplete: text("autocomplete"),
                                   href: text("href"), insideForm: flag("insideForm"), formHasSecret: flag("formHasSecret"), isSubmit: flag("isSubmit"), editable: flag("editable"))
    }

    func describe(_ snapshot: [String: Any]) -> String {
        var out = AgentPolicy.untrustedNotice + "\n\n"
        out += "Title: " + AgentPolicy.prepare(pageText: (snapshot["title"] as? String) ?? "", limit: 200) + "\n"
        out += "Address: " + AgentPolicy.safeURL((snapshot["url"] as? String) ?? "") + "\n\n--- Page text ---\n"
        out += AgentPolicy.prepare(pageText: (snapshot["text"] as? String) ?? "") + "\n\n--- Things you can use (by number) ---\n"
        for raw in (snapshot["elements"] as? [[String: Any]]) ?? [] {
            let e = Self.element(from: raw)
            let index = (raw["i"] as? Int) ?? number(raw["i"]) ?? 0
            let secret = AgentPolicy.isSecretField(e)
            // A field is named by its label only, never by what is in it, and a secret field is not described beyond saying so.
            let words = e.editable ? e.label : (e.text.isEmpty ? e.label : e.text)
            let name = secret ? "" : AgentPolicy.prepare(pageText: words, limit: 80)
            let kind: String
            if e.tag == "a" { kind = "link" }
            else if secret { kind = "secret field (you cannot type here)" }
            else if e.editable { kind = "text field" }
            else if e.tag == "select" { kind = "menu" }
            else if e.type == "checkbox" || e.type == "radio" { kind = e.type }
            else { kind = "button" }
            let target = e.href.isEmpty ? "" : " → " + AgentPolicy.safeURL(e.href)
            out += "[\(index)] \(kind) “\(name)”\(target)\(e.isSubmit ? " (sends a form)" : "")\n"
        }
        return out
    }
}
#endif
