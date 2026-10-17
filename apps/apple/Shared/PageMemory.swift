import Foundation
import SwiftUI

/// Where you stopped reading, and text you were typing, remembered on this device only.
struct ReadingPosition: Codable, Equatable { var fraction: Double; var date: Date }

struct FormDraft: Codable, Equatable {
    struct Field: Codable, Equatable { var key: String; var value: String }
    var fields: [Field]
    var date: Date
}

enum PageMemoryKey {
    /// The page's address without the part after # and without tracking parameters, so the same article matches itself.
    static func key(for url: URL) -> String? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        var parts = URLComponents(url: TrackingParameters.clean(url) ?? url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.string
    }
}

enum PageMemoryRules {
    static let maxEntries = 300
    /// Do not bother remembering the very top or an article that is finished.
    static func worthRemembering(_ fraction: Double) -> Bool { fraction > 0.04 && fraction < 0.96 }

    /// Words in a field's name that mean it holds something that must never be saved.
    static let sensitiveWords = ["pass", "pin", "otp", "code", "card", "cvv", "cvc", "ssn", "secret", "token", "iban", "account", "security", "social"]

    static func isSensitive(name: String, type: String, autocomplete: String) -> Bool {
        let lowered = (name + " " + autocomplete).lowercased()
        if ["password", "email", "tel", "number", "hidden", "file", "date"].contains(type.lowercased()) { return true }
        if autocomplete.lowercased().contains("cc-") || autocomplete.lowercased().contains("one-time") || autocomplete.lowercased().contains("password") { return true }
        return sensitiveWords.contains { lowered.contains($0) }
    }

    static func prune<T>(_ map: [String: T], date: (T) -> Date) -> [String: T] {
        guard map.count > maxEntries else { return map }
        let keep = map.sorted { date($0.value) > date($1.value) }.prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}

extension BrowserModel {
    /// Looks at the page in front every few seconds (only when one of the two settings is on) and remembers its scroll position and unsent text.
    func startPageMemory() {
        guard pageMemoryTask == nil else { return }
        pageMemoryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await self?.samplePage()
            }
        }
    }

    private func samplePage() async {
        guard rememberReadingPosition || keepFormDrafts,
              let tab = active, !tab.isPrivate, !tab.isBlank, !tab.isLoading, let url = tab.url,
              let key = PageMemoryKey.key(for: url) else { return }
        if rememberReadingPosition, let fraction = await tab.engine.scrollFraction() {
            if PageMemoryRules.worthRemembering(fraction) { readingPositions[key] = ReadingPosition(fraction: fraction, date: Date()) }
            else { readingPositions[key] = nil }
            readingPositions = PageMemoryRules.prune(readingPositions) { $0.date }
        }
        if keepFormDrafts, let raw = await tab.engine.formDraftFields() {
            let fields = raw.compactMap { item -> FormDraft.Field? in
                guard let k = item["key"] as? String, let v = item["value"] as? String else { return nil }
                return FormDraft.Field(key: k, value: v)
            }
            if fields.isEmpty { formDrafts[key] = nil } else { formDrafts[key] = FormDraft(fields: fields, date: Date()) }
            formDrafts = PageMemoryRules.prune(formDrafts) { $0.date }
        }
    }

    /// A page just finished loading: go back to where you stopped, and say if typed text can be restored.
    func pageMemoryDidLoad(_ tab: TabController) {
        showPassage(in: tab)
        // A page opened from a saved session goes back to where it was saved, whether or not remembering reading places is on.
        if let fraction = sessionScroll.removeValue(forKey: tab.id) {
            Task { try? await Task.sleep(for: .seconds(0.8)); await tab.engine.scrollTo(fraction: fraction) }
        }
        guard !tab.isPrivate, let url = tab.url, url.fragment == nil, let key = PageMemoryKey.key(for: url) else { return }
        if rememberReadingPosition, let saved = readingPositions[key], PageMemoryRules.worthRemembering(saved.fraction) {
            Task {
                try? await Task.sleep(for: .seconds(0.8))
                guard tab.url == url else { return }
                await tab.engine.scrollTo(fraction: saved.fraction)
            }
        }
        if keepFormDrafts, formDrafts[key] != nil { notice = "Text you were typing here was saved. Use “Restore Typed Text” in the command palette to put it back." }
    }

    func restoreTypedText() async {
        guard let tab = active, let url = tab.url, let key = PageMemoryKey.key(for: url), let draft = formDrafts[key] else { notice = "No saved text for this page."; return }
        let count = await tab.engine.restoreFormDraft(draft.fields.map { ["key": $0.key, "value": $0.value] })
        notice = count > 0 ? "Restored text in \(count) field\(count == 1 ? "" : "s")." : "The fields on this page are not empty or have changed."
    }

    func clearPageMemory() {
        readingPositions = [:]
        formDrafts = [:]
        pageSnapshots = [:]
        watchedPages = [:]
    }
}

struct GesturesSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            #if os(iOS)
            Toggle("Swipe from the edge to go back and forward", isOn: $model.gestureBackForward)
            Toggle("Pull down to reload", isOn: $model.gesturePullRefresh)
            Toggle("Swipe the address bar to switch tabs", isOn: $model.swipeAddressPill)
            #else
            Toggle("Swipe with two fingers to go back and forward", isOn: $model.gestureBackForward)
            #endif
            Toggle("Pinch to zoom", isOn: $model.gesturePinchZoom)
        } header: { Text("Gestures") } footer: {
            #if os(iOS)
            Text("Swipe the address bar up for the tab overview. Press and hold a link to preview it.")
            #else
            Text("Double-tap with two fingers to zoom in on part of a page.")
            #endif
        }
    }
}

struct PageMemorySection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Toggle("Remember where I stopped reading", isOn: $model.rememberReadingPosition)
            Toggle("Keep unfinished text in forms", isOn: $model.keepFormDrafts)
            Toggle("Pause endless scrolling until I ask", isOn: $model.pauseInfiniteScroll)
            Text("Saved only on this device, never in private tabs, and never from password, email, phone, number, card or code fields. Only long text boxes such as comments and messages are kept.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Forget All Saved Positions and Text", role: .destructive) { model.clearPageMemory() }
                .disabled(model.readingPositions.isEmpty && model.formDrafts.isEmpty && model.pageSnapshots.isEmpty && model.watchedPages.isEmpty)
        } header: { Text("Pages") }
    }
}
