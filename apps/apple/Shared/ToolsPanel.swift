import SwiftUI

/// The Tools panel: one list of small local tools (see ToolRegistry). What is typed here lives only in this panel's own state while it is open: it is not saved, not added to
/// history or search, not synced, and is cleared when the panel closes or the tool changes.
struct ToolsPanel: View {
    @EnvironmentObject var model: BrowserModel
    @State private var toolID = "json"
    @State private var values: [String: String] = [:]
    /// The latest result, worked out once after typing pauses and off the main thread, so a slow tool never freezes typing or the rest of the browser.
    @State private var output = ToolOutput()
    @State private var working = false

    private struct Key: Hashable { var tool: String; var values: [String: String] }

    private var tool: ToolDescriptor? { ToolRegistry.tool(toolID) }

    var body: some View {
        PanelList {
            if let tool {
                Section {
                    Picker("Tool", selection: $toolID) {
                        ForEach(ToolRegistry.paletteEntries, id: \.id) { Label($0.title, systemImage: $0.symbol).tag($0.id) }
                    }
                    Text(tool.summary).font(.caption).foregroundStyle(.secondary)
                    ForEach(tool.inputs) { input in field(input) }
                    HStack {
                        if !tool.example.isEmpty { Button("Try an Example") { values = tool.example.merging(initialValues(tool)) { given, _ in given } }.buttonStyle(.borderless) }
                        Button("Clear Input") { values = initialValues(tool) }.buttonStyle(.borderless)
                        Spacer()
                        if !output.primary.isEmpty { Button("Copy Result") { copyResult(output.primary) }.buttonStyle(.borderless) }
                    }
                } footer: {
                    Text("Everything runs on this device. Nothing typed here is saved, added to your history or synced, and it is cleared when you close this.").font(.caption)
                }
                Section {
                    if working { ProgressView().controlSize(.small) }
                    if let error = output.error { Text(error).foregroundStyle(allEmpty ? Color.secondary : Color.red) }
                    ForEach(Array(output.rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.label).font(.caption).foregroundStyle(.secondary)
                            Text(row.value.isEmpty ? " " : row.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            if !row.value.isEmpty { Button("Copy") { copyResult(row.value) }.buttonStyle(.borderless).font(.caption) }
                        }
                    }
                    ForEach(output.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                } header: { Text("Result") }
            }
        }
        .onAppear {
            if let wanted = model.toolSelection, ToolRegistry.tool(wanted) != nil { toolID = wanted }
            if let tool { values = initialValues(tool) }
        }
        .onChange(of: toolID) { _, _ in if let tool { values = initialValues(tool) } }
        .onDisappear { values = [:]; output = ToolOutput() }
        .task(id: Key(tool: toolID, values: values)) {
            guard let tool else { return }
            // Wait for a pause in typing; a newer keystroke cancels this and starts the wait again.
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
            working = true
            let job = ToolJob(tool: tool, values: values)
            let result = await Task.detached(priority: .userInitiated) { job.run() }.value
            if Task.isCancelled { return }
            output = result
            working = false
        }
        .accessibilityIdentifier("tools-panel")
    }

    /// A result is copied the ordinary way, except what came out of a token: its contents can be a sign-in, so it is marked as a secret and cleared after a minute.
    private func copyResult(_ text: String) {
        if toolID == "jwt" { copySecretToPasteboard(text, clearAfter: 60) } else { copyToPasteboard(text) }
    }

    private var allEmpty: Bool { values.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    private func initialValues(_ tool: ToolDescriptor) -> [String: String] { Dictionary(uniqueKeysWithValues: tool.inputs.map { ($0.id, $0.initial) }) }

    @ViewBuilder private func field(_ input: ToolInputSpec) -> some View {
        let binding = Binding(get: { values[input.id] ?? input.initial }, set: { values[input.id] = $0 })
        switch input.kind {
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                Text(input.label).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: binding).font(.system(.callout, design: .monospaced)).frame(height: 96).autocorrectionDisabled()
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            }
        case .text:
            FormTextField(input.label, text: binding).autocorrectionDisabled()
        case .choice(let options):
            Picker(input.label, selection: binding) { ForEach(options, id: \.self) { Text($0).tag($0) } }
        case .flag:
            Toggle(input.label, isOn: Binding(get: { binding.wrappedValue == "1" }, set: { binding.wrappedValue = $0 ? "1" : "0" }))
        }
    }
}
