import SwiftUI

/// Three ready-made sets of the privacy switches. Each one only moves the switches below; nothing else is hidden in it, and the person can still change any
/// switch afterwards (the picker then reads "Custom").
enum PrivacyPreset: String, CaseIterable, Identifiable {
    case standard, strict, paranoid
    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .strict: "Strict"
        case .paranoid: "Paranoid"
        }
    }

    var summary: String {
        switch self {
        case .standard: "Ads and trackers blocked, links cleaned, Global Privacy Control sent. Pages work as usual."
        case .strict: "Standard, and pages cannot reach your home network or load social widgets."
        case .paranoid: "Strict, and no Google analytics or fonts, no other site learns where you came from, WebRTC is off, and every site sees slightly different canvas and audio details. Some sites will look plainer, ask for a captcha more often, or need an exception."
        }
    }

    /// The switches this preset sets, as plain values; used both to apply and to recognise it again.
    private struct Values: Equatable {
        var localNetwork: Bool, social: Bool, google: Bool, fingerprint: Bool, sameSiteReferrer: Bool, webRTC: Bool, autoplay: Bool
    }

    private var values: Values {
        switch self {
        case .standard: Values(localNetwork: false, social: false, google: false, fingerprint: false, sameSiteReferrer: false, webRTC: false, autoplay: true)
        case .strict: Values(localNetwork: true, social: true, google: false, fingerprint: false, sameSiteReferrer: false, webRTC: false, autoplay: true)
        case .paranoid: Values(localNetwork: true, social: true, google: true, fingerprint: true, sameSiteReferrer: true, webRTC: true, autoplay: true)
        }
    }

    @MainActor func apply(to model: BrowserModel) {
        let v = values
        model.changingPrivacySwitches {
            model.globalPrivacyControl = true
            model.blockLinkPings = true
            model.debounceLinks = true
            model.stripTrackingParameters = true
            model.blockLocalNetwork = v.localNetwork
            model.blockSocialWidgets = v.social
            model.blockGoogleServices = v.google
            model.randomizeFingerprint = v.fingerprint
            model.referrerMode = v.sameSiteReferrer ? .sameSite : .standard
            model.blockWebRTC = v.webRTC
            model.blockAutoplay = v.autoplay
        }
    }

    /// The preset the switches add up to right now, or nil when they match none (Custom).
    @MainActor static func current(for model: BrowserModel) -> PrivacyPreset? {
        guard model.globalPrivacyControl, model.blockLinkPings, model.debounceLinks, model.stripTrackingParameters else { return nil }
        let now = Values(localNetwork: model.blockLocalNetwork, social: model.blockSocialWidgets, google: model.blockGoogleServices, fingerprint: model.randomizeFingerprint,
                         sameSiteReferrer: model.referrerMode == .sameSite, webRTC: model.blockWebRTC, autoplay: model.blockAutoplay)
        return allCases.first { $0.values == now }
    }
}

/// Settings › Privacy: the three presets, and the switches that go beyond the usual ones.
struct PrivacyPresetSection: View {
    @EnvironmentObject var model: BrowserModel
    private static let customTag = "custom"

    private var selection: String { PrivacyPreset.current(for: model)?.rawValue ?? Self.customTag }

    var body: some View {
        Group {
            Section("Privacy Level") {
                Picker("Level", selection: Binding(get: { selection }, set: choose)) {
                    ForEach(PrivacyPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if selection == Self.customTag { Text("Custom").tag(Self.customTag) }
                }
                .pickerStyle(.segmented)
                    .settingsNoted(PrivacyPreset.current(for: model)?.summary ?? "You have changed some switches, so this is your own mix.")
            }
            Section("Beyond the Usual") {
                Toggle("Skip trackers' redirect pages", isOn: $model.debounceLinks)
                    .settingsNoted("A link that goes through a click-logging page (Facebook, Google, Instagram, YouTube, Reddit and a few more) opens its real destination, and you are told where it went, with a button to use the original link. Sign-in, payment, invitation and signed links are never changed, and a link that only looks like a redirect is described, not rewritten. This is separate from removing tracking parameters.")
                TextField("Never skip for these sites (example.com, l.facebook.com)", text: Binding(get: { model.redirectSkipOff.sorted().joined(separator: ", ") }, set: { model.setRedirectSkipOff($0) }))
                    .autocorrectionDisabled().disabled(!model.debounceLinks)
                Toggle("Keep websites away from my home network", isOn: $model.blockLocalNetwork)
                    .settingsNoted("A page on the internet cannot load anything from this device (localhost) or from addresses like 192.168.x.x. Some apps that talk to a local helper need an exception, in This site…")
                Toggle("Refuse Google analytics, ads and fonts", isOn: $model.blockGoogleServices)
                    .settingsNoted("Pages that use Google Fonts fall back to your system fonts.")
                Toggle("Refuse social buttons and widgets on other sites", isOn: $model.blockSocialWidgets)
                    .settingsNoted("Embedded Like, Share and feed boxes from Facebook, X, LinkedIn, Instagram, Pinterest and Tumblr. The sites themselves still work.")
            }
        }
        .motion(.easeOut(duration: 0.2), value: selection)
    }

    private func choose(_ tag: String) {
        guard let preset = PrivacyPreset(rawValue: tag) else { return }
        preset.apply(to: model)
    }
}
