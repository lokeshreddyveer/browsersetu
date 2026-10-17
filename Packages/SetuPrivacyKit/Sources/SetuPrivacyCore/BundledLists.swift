import Foundation

/// The small starter lists that ship inside the app so protection works offline from the first launch.
/// These are first-party: short compilations of well-known advertising, tracking and session-recording hostnames.
/// No third-party list text is redistributed. Larger public lists are offered from `FilterCatalog` and are only
/// downloaded when the user enables them.
public enum BundledLists {
    public struct List: Sendable { public let id: String; public let name: String; public let text: String }

    public static let ads = List(id: "bundled.ads", name: "BrowserSetu starter · Ads", text: """
    doubleclick.net
    googlesyndication.com
    googleadservices.com
    googletagservices.com
    adnxs.com
    adsrvr.org
    criteo.com
    criteo.net
    taboola.com
    outbrain.com
    pubmatic.com
    rubiconproject.com
    openx.net
    moatads.com
    adform.net
    amazon-adsystem.com
    casalemedia.com
    contextweb.com
    lijit.com
    smartadserver.com
    yieldmo.com
    sharethrough.com
    advertising.com
    adcolony.com
    appnexus.com
    mgid.com
    revcontent.com
    zedo.com
    media.net
    bidswitch.net
    """)

    public static let tracking = List(id: "bundled.tracking", name: "BrowserSetu starter · Trackers", text: """
    google-analytics.com
    googletagmanager.com
    scorecardresearch.com
    quantserve.com
    hotjar.com
    mixpanel.com
    segment.io
    amplitude.com
    facebook.net
    branch.io
    adjust.com
    appsflyer.com
    krxd.net
    bat.bing.com
    ads.twitter.com
    analytics.tiktok.com
    chartbeat.com
    parsely.com
    comscore.com
    demdex.net
    omtrdc.net
    everesttech.net
    bluekai.com
    addthis.com
    sharethis.com
    heap.io
    kissmetrics.com
    optimizely.com
    """)

    /// Strict and Custom (when enabled): hosts that record what you do on a page.
    public static let sessionRecording = List(id: "bundled.sessionrecording", name: "BrowserSetu starter · Session recording", text: """
    fullstory.com
    mouseflow.com
    crazyegg.com
    clarity.ms
    luckyorange.com
    smartlook.com
    inspectlet.com
    """)

    public static let all: [List] = [ads, tracking, sessionRecording]
}
