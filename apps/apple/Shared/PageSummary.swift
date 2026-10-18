import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A short summary of the page in front, written by the language model that is part of the system, on this device. The page text is never sent
/// anywhere. Where the system has no such model (an older system, a device without it, or it switched off) the summary says so instead.
enum PageSummary {
    enum Failure: Error, Equatable { case noText, unavailable(String), failed(String) }

    /// The model reads only so much at once; a long page is cut at a paragraph near the limit.
    static let characterLimit = 9_000

    static func trimmed(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard clean.count > characterLimit else { return clean }
        let cut = clean.prefix(characterLimit)
        if let lastBreak = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: lastBreak) > characterLimit / 2 { return String(cut[..<lastBreak]) }
        return String(cut)
    }

    static func prompt(title: String, text: String) -> String {
        "Title: \(title)\n\nPage text:\n\(trimmed(text))"
    }

    static let instructions = "You summarize web pages for a reader in a hurry. Reply with a one-sentence gist, then three to five short bullet points of the main facts. Use only what the page says. If the text is mostly menus or has no real content, say so in one sentence."

    /// Whether this device can write a summary, and why not if it cannot.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This device does not support the on-device model."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to summarize pages."
                case .modelNotReady: return "The on-device model is still getting ready. Try again in a little while."
                @unknown default: return "The on-device model is not available."
                }
            }
        }
        #endif
        return "Summaries need macOS 26 or iOS 26 with Apple Intelligence."
    }

    static func summarize(title: String, text: String) async throws -> String {
        guard !trimmed(text).isEmpty else { throw Failure.noText }
        if let reason = unavailableReason { throw Failure.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt(title: title, text: text))
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw Failure.failed(error.localizedDescription)
            }
        }
        #endif
        throw Failure.unavailable("Summaries need macOS 26 or iOS 26 with Apple Intelligence.")
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// The sheet that shows a page's summary: working, the text, or the reason there is none.
struct PageSummaryView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var state: State = .working
    private enum State: Equatable { case working, done(String), failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft").foregroundStyle(Theme.accent)
                Text(model.active?.displayTitle ?? "This page").font(.headline).lineLimit(2)
            }
            switch state {
            case .working:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading the page on this device…").foregroundStyle(.secondary) }
            case .done(let text):
                ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Copy") { copyToPasteboard(text) }
                    Spacer()
                    Text("Written on this device. Check anything important against the page.").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 300)
        #endif
        .task { await load() }
    }

    private func load() async {
        guard let tab = model.active, !tab.isBlank else { state = .failed("Open a page first."); return }
        let text = await tab.engine.pageText() ?? ""
        do { state = .done(try await PageSummary.summarize(title: tab.displayTitle, text: text)) }
        catch PageSummary.Failure.noText { state = .failed("There is no readable text on this page.") }
        catch PageSummary.Failure.unavailable(let reason) { state = .failed(reason) }
        catch PageSummary.Failure.failed(let reason) { state = .failed("The summary could not be written: \(reason)") }
        catch { state = .failed(error.localizedDescription) }
    }
}
#endif
