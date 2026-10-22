import SwiftUI

/// Settings › AI. The first switch turns every AI-related feature off. On the Mac, the second lets outside AI tools use tabs you share.
struct AISettingsSection: View {
    @ObservedObject private var switches = AISwitches.shared
    #if os(macOS) && DIRECT_BUILD
    @ObservedObject private var bridge = AgentBridge.shared
    @State private var showToken = false
    @State private var copied = ""
    #endif

    var body: some View {
        Section {
            Toggle("AI features", isOn: $switches.aiEnabled.animation(.easeOut(duration: 0.2)))
            #if os(macOS) && DIRECT_BUILD
            if switches.aiEnabled {
                Toggle("Let AI tools use shared tabs", isOn: Binding(get: { switches.toolsOn }, set: { on in
                    if !on { withAnimation(.easeOut(duration: 0.2)) { switches.toolsOn = false }; return }
                    Task { @MainActor in
                        let choice = await Dialogs.choose(
                            title: "Let AI tools use Browser Setu?",
                            message: "Outside AI tools you run on this Mac (Claude, Gemini, Codex and others) will be able to read and use tabs you share with them. Those tools usually send what they read to their own company’s servers, which Browser Setu can not see or control.\n\nNothing is shared until you share a tab, and you will be asked before anything is sent, paid or deleted.",
                            buttons: ["Turn On", "Cancel"])
                        if choice == 0 { withAnimation(.easeOut(duration: 0.2)) { switches.toolsOn = true } }
                    }
                }))
                if switches.toolsOn { toolsDetail }
            }
            #endif
        } header: { Text("AI") } footer: {
            #if os(macOS) && DIRECT_BUILD
            Text("“AI features” covers page summaries and Ask This Page (both written on this device, nothing is sent) and the connection for outside AI tools. Switch it off and all of them stop. The tool connection is off until you turn it on, only works on this Mac, and an AI tool sees only tabs you share. Whatever an AI tool reads, it usually sends on to its own company’s servers; Browser Setu can not see or control that.")
            #else
            Text("Covers page summaries and Ask This Page, which are written on this device; nothing is sent anywhere. Switch it off and they stop.")
            #endif
        }
    }

    #if os(macOS) && DIRECT_BUILD
    @ViewBuilder private var toolsDetail: some View {
        LabeledContent("Status", value: bridge.status)
        LabeledContent("Address", value: "http://127.0.0.1:\(bridge.port)/mcp")
        HStack {
            Text("Token")
            Spacer()
            Text(showToken ? bridge.token : String(repeating: "•", count: 16)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button(showToken ? "Hide" : "Show") { showToken.toggle() }.buttonStyle(.borderless)
        }
        Menu("Copy Setup For…") {
            Button("Claude Code") { copy("claude mcp add --transport http browsersetu http://127.0.0.1:\(bridge.port)/mcp --header \"Authorization: Bearer \(bridge.token)\"", "Claude Code") }
            Button("Gemini CLI (settings.json)") {
                copy("{\n  \"mcpServers\": {\n    \"browsersetu\": {\n      \"httpUrl\": \"http://127.0.0.1:\(bridge.port)/mcp\",\n      \"headers\": { \"Authorization\": \"Bearer \(bridge.token)\" }\n    }\n  }\n}", "Gemini CLI")
            }
            Button("Codex CLI (config.toml)") {
                copy("[mcp_servers.browsersetu]\nurl = \"http://127.0.0.1:\(bridge.port)/mcp\"\nhttp_headers = { Authorization = \"Bearer \(bridge.token)\" }", "Codex CLI")
            }
            Button("Claude Desktop (via mcp-remote)") {
                copy("{\n  \"mcpServers\": {\n    \"browsersetu\": {\n      \"command\": \"npx\",\n      \"args\": [\"-y\", \"mcp-remote\", \"http://127.0.0.1:\(bridge.port)/mcp\", \"--header\", \"Authorization:${AUTH}\"],\n      \"env\": { \"AUTH\": \"Bearer \(bridge.token)\" }\n    }\n  }\n}", "Claude Desktop")
            }
            Divider()
            Button("Address and Token") { copy("http://127.0.0.1:\(bridge.port)/mcp\nAuthorization: Bearer \(bridge.token)", "address and token") }
        }
        if !copied.isEmpty { Text("Copied setup for \(copied). Paste it where that tool keeps its settings.").font(.caption).foregroundStyle(.secondary).transition(.opacity) }
        Button("Make a New Token…") { bridge.renewToken(); showToken = false }
        Button("Stop AI Tools and Forget Everything", role: .destructive) { bridge.stopEverything() }

        if !bridge.sharedTabs.isEmpty || !bridge.ownedTabs.isEmpty || !bridge.allowedOrigins.isEmpty {
            LabeledContent("Shared tabs", value: "\(bridge.sharedTabs.count)")
            LabeledContent("Tabs an AI tool opened", value: "\(bridge.ownedTabs.count)")
            LabeledContent("Sites allowed this session", value: bridge.allowedOrigins.sorted().joined(separator: ", "))
        }
        DisclosureGroup("What AI tools did (\(bridge.log.count))") {
            if bridge.log.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(bridge.log.suffix(40).reversed()) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(entry.tool).font(.callout.weight(.medium))
                        Spacer()
                        Text(entry.outcome.rawValue).font(.caption).foregroundStyle(entry.outcome == .done ? Color.secondary : Color.orange)
                    }
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !bridge.log.isEmpty { Button("Clear the Log") { bridge.clearLog() } }
        }
    }

    private func copy(_ text: String, _ name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeOut(duration: 0.2)) { copied = name }
    }
    #endif
}
