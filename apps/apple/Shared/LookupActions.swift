import SwiftUI

extension BrowserModel {
    // MARK: Saved copy of a page that will not load

    /// The person pressed "Look for a saved copy". The page's address, without its query or fragment, goes to the Internet Archive; if it has a copy, the
    /// tab opens it.
    func openSavedCopy(of page: URL?, in tab: TabController) async {
        guard let page else { notice = "There is no page to look up."; return }
        notice = "Asking the Internet Archive for a saved copy…"
        switch await Wayback.lookup(page) {
        case .found(let copy, let date):
            let when = date.map { " from " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
            notice = "Opening a saved copy\(when)."
            tab.load(copy)
        case .none: notice = "The Internet Archive has no saved copy of this page."
        case .busy: notice = "The Internet Archive is busy. Try again in a minute."
        case .failed: notice = "The Internet Archive could not be reached."
        case .notPublic: notice = "Only pages on the public internet can be looked up."
        }
    }

    // MARK: A reference from the paper's DOI

    /// Finds the DOI on the page in front (what the page says about itself, its address, then its text) and copies the reference Crossref has for it.
    func copyCitationFromDOI(_ style: PageCitation.Style) async {
        guard let tab = active, !tab.isBlank else { notice = "Open a paper or article first."; return }
        var places: [String] = []
        if let doi = await tab.engine.pageMetadata()?["doi"], !doi.isEmpty { places.append(doi) }
        if let address = tab.url?.absoluteString { places.append(address) }
        if let text = await tab.engine.pageText() { places.append(String(text.prefix(15_000))) }
        guard let doi = DOI.find(in: places) else { notice = "No DOI found on this page. “Copy Citation for This Page” works without one."; return }
        notice = "Looking up \(doi) at Crossref…"
        guard let work = await Crossref.lookup(doi: doi) else { notice = "Crossref has nothing for \(doi), or could not be reached."; return }
        copyToPasteboard(Crossref.format(work, style: style))
        notice = "\(style.title) citation copied from Crossref."
    }
}

// MARK: Security headers (shown in the site panel)

struct SecurityHeadersSection: View {
    let host: String?
    @State private var outcome: SiteScan.Outcome?
    @State private var scanning = false

    private var scannable: Bool { PublicAddress.isPublicHost(host) }
    private func forgetResult() { outcome = nil; scanning = false }

    var body: some View {
        Section {
            Button {
                scanning = true
                Task { outcome = await SiteScan.scan(host: host); scanning = false }
            } label: {
                if scanning { HStack { ProgressView().controlSize(.small); Text("Asking Mozilla…") } } else { Text(outcome == nil ? "Check Security Headers with Mozilla" : "Check Again") }
            }
            .disabled(scanning || !scannable)
            switch outcome {
            case .done(let result)?:
                LabeledContent("Grade", value: "\(result.grade)  (\(result.score) of 100)")
                LabeledContent("Tests passed", value: "\(result.passed) of \(result.total)")
                if let details = result.details { Link("What was checked and what to fix", destination: details) }
            case .busy?: Text("Mozilla is busy. Try again in a minute.").font(.caption).foregroundStyle(.secondary)
            case .failed(let why)?: Text(why).font(.caption).foregroundStyle(.secondary)
            case .notPublic?: Text("Only sites on the public internet can be checked.").font(.caption).foregroundStyle(.secondary)
            case nil: EmptyView()
            }
        } header: { Text("Security headers") } footer: {
            Text(scannable ? "Sends only the site’s name, \(host ?? ""), to Mozilla’s HTTP Observatory, and only when you press the button. It grades the headers the site sends, such as Content-Security-Policy and Strict-Transport-Security; it says nothing about the page’s content."
                           : "Only sites on the public internet can be checked.")
        }
        .onChange(of: host) { _, _ in forgetResult() }
    }
}

// MARK: Currency (shown with a selection)

struct CurrencySection: View {
    let text: String
    @State private var results: [String: (lines: [String], date: String)] = [:]
    @State private var failed = Set<String>()
    @State private var asking = Set<String>()

    private var amounts: [Currency.Amount] { Currency.amounts(in: text) }

    var body: some View {
        if !amounts.isEmpty {
            Divider()
            ForEach(amounts) { amount in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(amount.source).fontWeight(.medium)
                        Spacer()
                        if let answer = results[amount.id] {
                            Text(answer.lines.joined(separator: "  ·  ")).fontWeight(.medium).transition(.opacity)
                        } else {
                            Button(asking.contains(amount.id) ? "Asking…" : "Convert") { convert(amount) }
                                .disabled(asking.contains(amount.id)).buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    if let answer = results[amount.id], !answer.date.isEmpty { Text("European Central Bank rate of \(answer.date)").font(.caption).foregroundStyle(.secondary) }
                    if failed.contains(amount.id) { Text("The rate could not be fetched.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("Pressing Convert sends only the currency codes (for example USD and INR) to frankfurter.dev, and nothing else. A “$” is read as US dollars. Rates are for information, not for paying.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func convert(_ amount: Currency.Amount) {
        asking.insert(amount.id)
        Task {
            let answer = await Currency.convert(amount)
            withAnimation(.easeOut(duration: 0.2)) {
                if let answer { results[amount.id] = answer; failed.remove(amount.id) } else { failed.insert(amount.id) }
                asking.remove(amount.id)
            }
        }
    }
}
