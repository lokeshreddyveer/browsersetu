import SwiftUI
import AppKit

// The small list under the toolbar's Downloads button: what is moving, what finished lately, and a way into the full window. It reads the same view model as the window.
// Showing or hiding it never changes a download.

struct DownloadsPopover: View {
    @ObservedObject var vm: DownloadsViewModel
    var openAll: () -> Void

    private var current: [DownloadRow] { vm.rows.filter { $0.status.isActive || $0.status == .queued || $0.status == .paused || $0.status == .scheduled }.prefix(6).map { $0 } }
    private var recent: [DownloadRow] { vm.rows.filter { $0.status == .completed || $0.status == .failed || $0.status == .recoveryRequired }.sorted { $0.date > $1.date }.prefix(4).map { $0 } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let note = vm.holdNote { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 12).frame(height: 36)
            Divider().opacity(0.5)
            if current.isEmpty && recent.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                    Text("No downloads yet").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 90)
            } else {
                VStack(spacing: 0) {
                    ForEach(current) { PopoverRow(row: $0, vm: vm) }
                    if !current.isEmpty && !recent.isEmpty { Divider().opacity(0.4).padding(.vertical, 2) }
                    ForEach(recent) { PopoverRow(row: $0, vm: vm) }
                }.padding(.vertical, 4)
            }
            Divider().opacity(0.5)
            Button(action: openAll) { Text("Open Downloads").font(.system(size: 12.5)).frame(maxWidth: .infinity) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).frame(height: 32)
                .accessibilityIdentifier("downloads-open-all")
        }
        .frame(width: 340)
        .onAppear { vm.acquire() }
        .onDisappear { vm.release() }
    }
}

private struct PopoverRow: View {
    let row: DownloadRow
    @ObservedObject var vm: DownloadsViewModel

    var body: some View {
        HStack(spacing: 9) {
            DownloadFileIcon(row: row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.filename).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                if row.status == .downloading || row.status == .paused, let fraction = row.fraction {
                    ProgressView(value: fraction).tint(row.status == .paused ? Color.secondary : Theme.accent).controlSize(.small)
                } else if row.status == .downloading {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
                Text(row.detail.isEmpty ? row.statusText : row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            let only: Set<UUID> = [row.id]
            if row.actions.contains(.pause) { icon("pause.fill", "Pause") { vm.perform(.pause, on: only) } }
            if row.actions.contains(.resume) { icon("play.fill", row.resumeTitle) { vm.perform(.resume, on: only) } }
            if row.actions.contains(.retry) { icon("arrow.clockwise", "Try Again") { vm.perform(.retry, on: only) } }
            if row.actions.contains(.cancel) { icon("xmark", "Cancel") { vm.perform(.cancel, on: only) } }
            if row.actions.contains(.reveal), let url = vm.fileURL(for: row.id) { icon("magnifyingglass", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilitySummary)
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}
