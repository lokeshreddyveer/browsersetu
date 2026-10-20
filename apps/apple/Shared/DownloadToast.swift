import SwiftUI

/// A download that has just finished, for the card that says so.
struct DownloadBanner: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var fileURL: URL?
    /// Set for a kind of file that can run code: shown in the card, not in a box that has to be dismissed.
    var warning: String?
}

extension BrowserModel {
    /// Called when a download finishes: the card appears, and goes by itself (later when it carries a warning).
    func showDownloadBanner(filename: String, fileURL: URL?, warning: String?) {
        let banner = DownloadBanner(filename: filename, fileURL: fileURL, warning: warning)
        animated(.easeOut(duration: 0.22)) { downloadBanner = banner }
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(warning == nil ? 7 : 14))
            guard !Task.isCancelled else { return }
            animated(.easeOut(duration: 0.22)) { if self?.downloadBanner == banner { self?.downloadBanner = nil } }
        }
    }

    func dismissDownloadBanner() { bannerTask?.cancel(); animated(.easeOut(duration: 0.2)) { downloadBanner = nil } }

    func revealDownload(_ banner: DownloadBanner) {
        #if os(macOS)
        if let url = banner.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { sheet = .downloads }
        #else
        sheet = .downloads
        #endif
        dismissDownloadBanner()
    }
}

/// What a download looks like while it happens and when it is done: a small card at the foot of the window, so a download is never silent.
struct DownloadToast: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var coordinator: DownloadCoordinator
    @Environment(\.colorScheme) private var scheme

    /// A solid card, so its words are readable over any page (a translucent one turned grey over a white page).
    private var surface: Color { ThemeState.raised ?? Color(white: scheme == .dark ? 0.19 : 0.97) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !coordinator.active.isEmpty { progressCard.transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .move(edge: .bottom)).combined(with: .opacity)) }
            if let banner = model.downloadBanner { doneCard(banner).transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .move(edge: .bottom)).combined(with: .opacity)) }
        }
        .motion(.easeOut(duration: 0.22), value: coordinator.active.isEmpty)
        .motion(.easeOut(duration: 0.22), value: model.downloadBanner)
        .accessibilityElement(children: .contain)
    }

    private var progressCard: some View {
        let items = coordinator.active.values.sorted { $0.filename < $1.filename }
        let average = items.map(\.fraction).reduce(0, +) / Double(max(items.count, 1))
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.03, average)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(items.count == 1 ? items[0].filename : "\(items.count) downloads").font(.callout.weight(.medium)).lineLimit(1)
                Text(items.count == 1 && !items[0].detail.isEmpty ? items[0].detail : "Downloading… \(Int((average * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Show") { model.sheet = .downloads }.buttonStyle(.borderless)
        }
        .padding(12).frame(width: 320)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloading, \(Int((average * 100).rounded())) percent")
    }

    private func doneCard(_ banner: DownloadBanner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: banner.warning == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22)).foregroundStyle(banner.warning == nil ? Color.green : Color.orange)
                    .modifier(BounceOnChange(value: banner.id))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloaded").font(.caption).foregroundStyle(.secondary)
                    Text(banner.filename).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button { model.dismissDownloadBanner() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).accessibilityLabel("Dismiss") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            if let warning = banner.warning { Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                #if os(macOS)
                Button("Show in Finder") { model.revealDownload(banner) }
                #endif
                Button("All Downloads") { model.sheet = .downloads; model.dismissDownloadBanner() }
            }
            .buttonStyle(.borderless).font(.callout)
        }
        .padding(12).frame(width: 320)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
    }
}
