import SwiftUI

/// Step two of adding an eD2k link: what the link says, where the file goes, and what the person is agreeing to. Nothing is contacted until they press Download.
@MainActor
final class ED2KAddModel: ObservableObject {
    let coordinator: DownloadCoordinator
    let inspection: ED2KInspection
    let sha256: String?
    @Published var busy = false
    @Published var problem: String?

    init(coordinator: DownloadCoordinator, link: String, sha256: String?) throws {
        self.coordinator = coordinator; self.sha256 = sha256
        inspection = try coordinator.ed2k.inspect(link: link)
    }

    var enabled: Bool { coordinator.ed2kSettings.enabled }

    func start(done: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            do { _ = try await coordinator.ed2k.add(inspection.file, expectedSHA256: sha256); done() }
            catch { problem = (error as? LocalizedError)?.errorDescription ?? "The download could not be started." }
            busy = false
        }
    }
}

struct ED2KAddView: View {
    @ObservedObject var model: ED2KAddModel
    var done: () -> Void

    var body: some View {
        let f = model.inspection.file
        VStack(alignment: .leading, spacing: 10) {
            Text(f.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).textSelection(.enabled)
            Text("\(DownloadStats.bytes(f.size)) · saved to your Downloads folder").font(.system(size: 11.5)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("File hash (MD4)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Text(f.hashHex).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
            Text(model.inspection.identityNote).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(f.sources.isEmpty ? "The link lists no sources." : "The link lists \(f.sources.count) source\(f.sources.count == 1 ? "" : "s").")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(model.inspection.servers.isEmpty ? "No eD2k server is set up in Settings → Downloads." : "Servers asked for sources: " + model.inspection.servers.joined(separator: ", "))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Label(model.inspection.privacyNotice, systemImage: "eye").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.enabled {
                VStack(alignment: .leading, spacing: 4) {
                    Label("eD2k downloads are off. Turn them on in Settings → Downloads to continue.", systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings → Downloads") { SettingsRouter.open(.downloads) }.buttonStyle(.link).font(.system(size: 11.5))
                }
            }
            else if !model.inspection.hasWayToFindSources { Label("There is no way to find sources yet: add an eD2k server in Settings → Downloads.", systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange) }
            if let p = model.problem { Text(p).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: done)
                Button("Download", action: { model.start(done: done) }).buttonStyle(.borderedProminent)
                    .disabled(!model.enabled || !model.inspection.hasWayToFindSources || model.busy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 380)
    }
}
