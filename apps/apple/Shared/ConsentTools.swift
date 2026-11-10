import SwiftUI

/// What became of one cookie banner. Kept on this device only: the website, which consent tool it was, and the outcome. Nothing from the page is recorded.
struct ConsentRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var host: String
    var platform: String
    var outcome: CookieBanners.Outcome
    var why: String
    var catalog: Int
    var date: Date

    /// In plain words, so a hidden banner is never read as a refused one.
    var summary: String {
        switch outcome {
        case .refused: "Refused: the banner’s own “reject” button was pressed and the banner closed."
        case .hidden: "Hidden, NOT refused: the banner could not be refused (\(Self.reason(why))). It was hidden, and the site was not told “no”."
        case .failed: "Could not be refused (\(Self.reason(why))). The banner was left as it was."
        case .recognised: "Seen and left alone, as hiding is switched off (\(Self.reason(why)))."
        case .pending, .none: outcome.title
        }
    }

    static func reason(_ why: String) -> String {
        switch why {
        case "refusal-not-possible": "this consent tool gives a page no way to refuse"
        case "no-refuse-button": "no refusing button was showing"
        case "button-missing": "the button did not appear"
        case "still-showing": "the button was pressed but the banner stayed"
        case "click-failed": "the button could not be pressed"
        case "banner-closed": "the banner closed"
        case "site-off": "banners are left alone on this site"
        default: why.isEmpty ? "no reason given" : why
        }
    }
}

extension BrowserModel {
    /// The record of a banner's outcome for this site, never for a private tab.
    func recordConsent(host: String, platform: String, outcome: CookieBanners.Outcome, why: String, catalog: Int) {
        guard outcome != .none, outcome != .pending, let key = FaviconStore.key(forHost: host) else { return }
        // The same site and result within an hour is one record, not many.
        if let last = consentLog.first, last.host == key, last.outcome == outcome, last.platform == platform, Date().timeIntervalSince(last.date) < 3600 { return }
        consentLog.insert(ConsentRecord(host: key, platform: platform, outcome: outcome, why: why, catalog: catalog, date: Date()), at: 0)
        if consentLog.count > 200 { consentLog.removeLast(consentLog.count - 200) }
        saveConsentLog()
    }

    func saveConsentLog() { saveSetting("consent_log", (try? String(data: JSONEncoder().encode(consentLog), encoding: .utf8)) ?? "[]") }

    func clearConsentLog() { consentLog = []; saveConsentLog() }

    func consentHandling(forHost host: String?) -> Bool {
        guard let key = FaviconStore.key(forHost: host) else { return true }
        return !consentOffSites.contains(key)
    }

    /// Switches banner handling off or on for one site. Off leaves its banners exactly as the site made them. Takes effect on the next load.
    func setConsentHandling(host: String?, on: Bool) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if on { consentOffSites.remove(key) } else { consentOffSites.insert(key) }
        saveSetting("consent_off", encodedMap(["list": Array(consentOffSites).sorted()]))
        pushWebPolicy()
    }

    /// The most recent result for a site.
    func lastConsent(forHost host: String?) -> ConsentRecord? {
        guard let key = FaviconStore.key(forHost: host) else { return nil }
        return consentLog.first { $0.host == key }
    }

    /// The person asked for this page's banner to be looked at again (it came back, or a page was set aside).
    func handleBannerNow() {
        guard let tab = active, !tab.isPrivate else { return }
        tab.watchConsent(rerun: true)
    }
}

extension TabController {
    /// After a page has loaded, reads (a few times, over about fifteen seconds) what the banner script made of any consent banner, and keeps the result. Reads a short word
    /// and the name of the tool, never anything of the page's own.
    func watchConsent(rerun: Bool = false) {
        consentTask?.cancel()
        guard !leavesNoTrace, consentOwner?.hideCookieBanners == true, let host = url?.host else { return }
        let address = url
        consentTask = Task { @MainActor [weak self] in
            var first = rerun
            for wait in [3.0, 6.0, 6.0] {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled, self.url == address else { return }
                guard let raw = await self.engine.consentOutcome(rerun: first), let data = raw.data(using: .utf8),
                      let found = try? JSONDecoder().decode(ConsentFinding.self, from: data) else { first = false; continue }
                first = false
                if let outcome = CookieBanners.Outcome(rawValue: found.state), outcome != .none, outcome != .pending {
                    self.consentOwner?.recordConsent(host: host, platform: found.platform, outcome: outcome, why: found.why, catalog: found.catalog)
                    return
                }
            }
        }
    }
}

/// What the page script reports: a state word, the tool's own short name and a reason word. Nothing else is read.
struct ConsentFinding: Decodable {
    var state: String
    var platform: String
    var why: String
    var catalog: Int
}

/// Cookie banners in Settings › Privacy: what is done, and what was done.
struct ConsentLogSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Toggle("Hide banners that cannot be refused", isOn: $model.hideUnrefusableBanners)
                .disabled(!model.hideCookieBanners)
            if model.consentLog.isEmpty {
                Label("Nothing recorded yet", systemImage: "list.bullet").foregroundStyle(.secondary)
            } else {
                let refused = model.consentLog.filter { $0.outcome == .refused }.count
                let hidden = model.consentLog.filter { $0.outcome == .hidden }.count
                LabeledContent("Refused", value: "\(refused)")
                LabeledContent("Hidden, not refused", value: "\(hidden)")
                LabeledContent("Could not be refused", value: "\(model.consentLog.filter { $0.outcome == .failed }.count)")
                ForEach(model.consentLog.prefix(12)) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(record.host).fontWeight(.medium)
                            Spacer()
                            Text(record.outcome.title).font(.caption).foregroundStyle(record.outcome == .refused ? Color.green : .orange)
                        }
                        Text(record.summary).font(.caption).foregroundStyle(.secondary)
                        Text("\(CookieBanners.platforms.first { $0.id == record.platform }?.name ?? record.platform) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button("Clear This Record", role: .destructive) { model.clearConsentLog() }
            }
        } header: {
            Text("Cookie banners")
        } footer: {
            Text("“Refused” is recorded only when the site’s own refuse button was pressed and the banner then really closed. A hidden banner has not been refused: the site may still treat it as unanswered. This record stays on this device and holds only the site, the consent tool and the outcome (catalog \(CookieBanners.catalogVersion), \(CookieBanners.catalogDate)).")
        }
    }
}

/// On the site card: switch handling off for this site, look at the banner again, and see what happened last.
struct SiteConsentRows: View {
    @EnvironmentObject var model: BrowserModel
    let host: String?

    var body: some View {
        Toggle("Handle cookie banners here", isOn: Binding(get: { model.consentHandling(forHost: host) }, set: { model.setConsentHandling(host: host, on: $0) }))
            .disabled(!model.hideCookieBanners)
        if model.consentHandling(forHost: host), model.hideCookieBanners {
            Button("Look at this page’s banner again") { model.handleBannerNow() }
            if let last = model.lastConsent(forHost: host) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(last.outcome.title).font(.caption).fontWeight(.semibold)
                    Text(last.summary).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
