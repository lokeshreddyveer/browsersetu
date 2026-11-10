import SwiftUI

/// Downloads → Collect → Repositories & Models…: GitHub releases, Hugging Face models and datasets, buckets and signed links. Choose files, and they join the ordinary download queue as one collection.
struct ProviderFilesSheet: View {
    @EnvironmentObject var model: BrowserModel
    var done: () -> Void
    var body: some View { ProviderFilesContent(provider: model.providerSheet, model: model, done: done) }
}

private struct ProviderFilesContent: View {
    @ObservedObject var provider: ProviderSheetModel
    @ObservedObject var model: BrowserModel
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Repositories & Models").font(.system(size: 15, weight: .semibold))
                if !provider.routeLabel.isEmpty { Text(provider.routeLabel).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Close", action: done).keyboardShortcut(.cancelAction).accessibilityIdentifier("provider-close")
            }
            HStack(spacing: 8) {
                TextField("github.com/owner/repo, huggingface.co/owner/model, a bucket or a signed link", text: $provider.address).textFieldStyle(.roundedBorder)
                    .onSubmit { provider.load() }.accessibilityIdentifier("provider-address")
                Button("Look Up") { provider.load() }.disabled(provider.address.trimmingCharacters(in: .whitespaces).isEmpty || provider.phase == .loading).accessibilityIdentifier("provider-load")
            }
            content
            if let m = provider.message { Text(m).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("provider-message") }
        }
        .padding(18).frame(minWidth: 640, idealWidth: 720, minHeight: 480)
        .accessibilityElement(children: .contain).accessibilityIdentifier("provider-sheet")
        .onAppear { provider.isPrivate = model.active?.leavesNoTrace ?? false }
        .motion(.easeInOut(duration: 0.2), value: provider.phase)
    }

    @ViewBuilder private var content: some View {
        switch provider.phase {
        case .idle:
            Text("Paste an address and choose Look Up. Only the files you tick are downloaded, and an access token (Settings → Downloads → Accounts) is used only for private repositories and gated models you have been given access to.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        case .loading: VStack { Spacer(); ProgressView("Looking it up…").controlSize(.small); Spacer() }.frame(maxWidth: .infinity, minHeight: 260)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading).accessibilityIdentifier("provider-failed")
        case .listed: listed
        }
    }

    private var listed: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let l = provider.listing {
                Text(l.title).font(.system(size: 13, weight: .medium)).lineLimit(1).accessibilityIdentifier("provider-title")
                ForEach(l.notices, id: \.self) { Label($0, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let r = provider.recommendation {
                    HStack(spacing: 6) {
                        Image(systemName: r.fileID == nil ? "questionmark.circle" : "checkmark.seal").foregroundStyle(r.fileID == nil ? Color.secondary : Color.green)
                        Text(r.reason).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        if r.fileID != nil { Button("Choose It") { provider.selectRecommended() }.controlSize(.small).accessibilityIdentifier("provider-choose-recommended") }
                    }.accessibilityIdentifier("provider-recommendation")
                }
            }
            HStack(spacing: 8) {
                TextField("Filter by name", text: $provider.filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220).accessibilityIdentifier("provider-filter")
                if !provider.releases.isEmpty {
                    Picker("Release", selection: $provider.release) {
                        Text("All releases").tag(String?.none)
                        ForEach(provider.releases, id: \.self) { Text($0).tag(String?.some($0)) }
                    }.labelsHidden().frame(maxWidth: 200).accessibilityIdentifier("provider-release")
                } else if provider.showsFormats {
                    Picker("Format", selection: $provider.format) {
                        Text("All formats").tag(String?.none)
                        ForEach(provider.formats, id: \.self) { Text($0).tag(String?.some($0)) }
                    }.labelsHidden().frame(maxWidth: 200).accessibilityIdentifier("provider-format")
                }
                Spacer()
                Text("\(provider.matching.count) of \(provider.listing?.files.count ?? 0) files").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Button("Choose All Shown") { provider.selectMatching() }.controlSize(.small).disabled(provider.matching.isEmpty).accessibilityIdentifier("provider-select-all")
                Button("Clear") { provider.clearSelection() }.controlSize(.small).disabled(provider.selection.isEmpty).accessibilityIdentifier("provider-clear")
            }
            List {
                ForEach(provider.shown) { f in row(f) }
                if provider.matching.count > ProviderSheetModel.rowLimit {
                    Text("Showing the first \(ProviderSheetModel.rowLimit). Narrow the filter to see the rest, or choose all shown.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }.listStyle(.inset).frame(minHeight: 220).accessibilityIdentifier("provider-list")
            footer
        }
    }

    private func row(_ f: ProviderFile) -> some View {
        let on = provider.selection.contains(f.id)
        // A real button, not a tap gesture on the row: a gesture inside a List row can lose the click when the list's own row selection changes at the same moment (the second row clicked after
        // another was sometimes not chosen).
        return Button { provider.toggle(f.id) } label: { HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.relativePath).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if let g = f.group, provider.listing?.releaseNames.isEmpty == false { Text(g).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    if f.prerelease { badge("pre-release", .orange) }
                    if f.id == provider.recommendation?.fileID { badge("recommended", .green) }
                    if let c = f.checksumSource, f.sha256 != nil { badge("checksum from \(c)", .blue) }
                    if f.needsAccount { badge("needs token", .secondary) }
                    if f.kind == .lfsFile { badge("LFS", .secondary) }
                    if let n = f.note { Text(n).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer()
            Text(f.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—").font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
        }
        .contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine).accessibilityIdentifier("provider-row").accessibilityLabel(f.relativePath).accessibilityValue(on ? "chosen" : "not chosen")
        .accessibilityAddTraits(.isButton)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9.5, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1).background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(provider.selection.isEmpty ? "Nothing chosen" : "\(provider.summary(of: provider.selectedFiles)) chosen").font(.system(size: 12)).accessibilityIdentifier("provider-count")
            Spacer()
            if let p = provider.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 120)
                Button("Stop") { provider.cancel() }.controlSize(.small).accessibilityIdentifier("provider-stop")
            }
            Button("Download") { provider.startDownload() }.keyboardShortcut(.defaultAction)
                .disabled(provider.selection.isEmpty || provider.working).accessibilityIdentifier("provider-download")
        }
    }
}
