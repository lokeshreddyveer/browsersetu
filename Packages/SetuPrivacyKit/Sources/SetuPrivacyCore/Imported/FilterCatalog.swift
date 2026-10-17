import Foundation

/// Curated public lists. Sizes were measured on 2026-10-13 and are approximate; real counts appear after download.
/// Lists above the per-list limit (HaGeZi Pro++ ~207k, HaGeZi Gambling ~584k, HaGeZi TIF ~950k) are deliberately absent.
/// Which lists ship enabled-or-available at install (`isDefault`) is a product decision, kept to the original seven for now.
public enum FilterCategory: String, CaseIterable, Sendable {
    case adsTrackers = "Ads & trackers"
    case malwarePhishing = "Malware & phishing"
    case privacy = "Privacy"
    case content = "Content"
    case regional = "Regional"
}
public struct CatalogList: Identifiable, Equatable, Sendable {
    public var id: String { url }
    public let name: String
    public let url: String
    public let category: FilterCategory
    public let approximateRules: Int
    public let summary: String
    /// Offered in the lists screen from the start (the original seven); the rest are added from the catalogue.
    public let isDefault: Bool
    public var sizeLabel: String { approximateRules >= 1000 ? "~\(Int((Double(approximateRules) / 1000).rounded()))k rules" : "~\(approximateRules) rules" }
}
public enum FilterCatalog {
    private static func item(_ name: String, _ url: String, _ category: FilterCategory, _ rules: Int, _ summary: String, isDefault: Bool = false) -> CatalogList {
        CatalogList(name: name, url: url, category: category, approximateRules: rules, summary: summary, isDefault: isDefault)
    }
    public static let all: [CatalogList] = [
        item("HaGeZi Light", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/light.txt", .adsTrackers, 56000, "Balanced ads and trackers; few false positives."),
        item("OISD Small", "https://small.oisd.nl/", .adsTrackers, 57000, "Compact ad and tracker list."),
        item("1Hosts Lite", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_24.txt", .adsTrackers, 102000, "Popular all-round ad, tracker and malware list."),
        item("HaGeZi Multi", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt", .adsTrackers, 158000, "Ads, trackers, malware and scams."),
        item("StevenBlack", "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", .adsTrackers, 73000, "Unified hosts list: ads and malware."),
        item("AdGuard DNS filter", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt", .adsTrackers, 183000, "AdGuard’s DNS ad and tracker list."),
        item("HaGeZi Pro++", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_51.txt", .adsTrackers, 207000, "HaGeZi’s aggressive level: everything in Pro plus more. A few sites may break."),
        item("HaGeZi Pro", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt", .adsTrackers, 193000, "Stronger blocking; may break some sites.", isDefault: true),
        item("OISD Big", "https://big.oisd.nl/", .adsTrackers, 237000, "Large, well-maintained general list."),
        item("Dan Pollock’s hosts", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_4.txt", .adsTrackers, 13000, "Long-running, conservative ad and tracker hosts."),
        item("Peter Lowe’s ad servers", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext", .adsTrackers, 3500, "Small, long-standing ad-server list.", isDefault: true),
        item("AWAvenue ads", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_53.txt", .adsTrackers, 900, "Ads inside mobile apps."),
        item("Anti push notifications", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_39.txt", .adsTrackers, 400, "Web push-notification spam services."),
        item("HaGeZi Fake & scams", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/fake.txt", .malwarePhishing, 17000, "Fake shops, scams and phishing."),
        item("Phishing Army (extended)", "https://phishing.army/download/phishing_army_blocklist_extended.txt", .malwarePhishing, 141000, "Phishing domains. Large: near the per-list limit."),
        item("PhishTank & OpenPhish", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt", .malwarePhishing, 33000, "Live phishing URLs reduced to domains."),
        item("URLhaus malware", "https://urlhaus.abuse.ch/downloads/hostfile/", .malwarePhishing, 400, "Domains serving malware (abuse.ch)."),
        item("ShadowWhisperer malware", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_42.txt", .malwarePhishing, 46000, "Broad malware domain list."),
        item("Anti-Malware (DandelionSprout)", "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt", .malwarePhishing, 12000, "Malware and scam domains.", isDefault: true),
        item("CERT Polska malicious domains", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_41.txt", .malwarePhishing, 108000, "Domains from the Polish national CERT. Large."),
        item("Scam blocklist (DurableNapkin)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_10.txt", .malwarePhishing, 900, "Scam and fraud sites."),
        item("uBlock badware risks", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt", .malwarePhishing, 2800, "Sites flagged as badware by uBlock Origin.", isDefault: true),
        item("ShadowWhisperer tracking", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_69.txt", .privacy, 116000, "Broad tracking and telemetry list. Large."),
        item("Smart TV tracking", "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt", .privacy, 500, "Telemetry from smart TVs and streaming boxes."),
        item("NoCoin (cryptojacking)", "https://raw.githubusercontent.com/hoshsadiq/adblock-nocoin-list/master/hosts.txt", .privacy, 300, "In-browser cryptocurrency miners."),
        item("Stalkerware indicators", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_31.txt", .privacy, 900, "Domains used by stalkerware apps."),
        item("Apple trackers (HaGeZi)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_67.txt", .privacy, 100, "Apple telemetry endpoints. May affect some Apple services."),
        item("Samsung trackers (HaGeZi)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_61.txt", .privacy, 200, "Samsung telemetry and ads."),
        item("Xiaomi trackers (HaGeZi)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_60.txt", .privacy, 350, "Xiaomi telemetry and ads."),
        item("OPPO & Realme trackers (HaGeZi)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_66.txt", .privacy, 500, "OPPO and Realme telemetry and ads."),
        item("Vivo trackers (HaGeZi)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_65.txt", .privacy, 250, "Vivo telemetry and ads."),
        item("Huawei trackers (HaGeZi)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_73.txt", .privacy, 150, "Huawei telemetry and ads."),
        item("LG webOS trackers (HaGeZi)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_72.txt", .privacy, 230, "LG smart-TV telemetry and ads."),
        item("Windows & Office trackers (HaGeZi)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_63.txt", .privacy, 400, "Microsoft telemetry. May affect some Microsoft services."),
        item("HaGeZi Anti-Piracy", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/anti.piracy.txt", .content, 55000, "Piracy and streaming-piracy domains."),
        item("Fake news & gambling", "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling/hosts", .content, 82000, "StevenBlack hosts plus fake news and gambling."),
        item("Social media (StevenBlack)", "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/social/hosts", .content, 77000, "StevenBlack hosts plus social networks."),
        item("Adult content (StevenBlack)", "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn/hosts", .content, 149000, "StevenBlack hosts plus adult sites. Very large."),
        item("Norwegian · Dandelion Sprout", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_13.txt", .regional, 335, "Nordic ad and tracker rules (Norwegian)."),
        item("Polish · Pi-hole filters", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_14.txt", .regional, 340, "Polish ad and tracker domains."),
        item("Korean · YousList", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_15.txt", .regional, 623, "Korean ad and tracker domains."),
        item("Korean · filterslists-KO", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_25.txt", .regional, 375, "More Korean ad domains."),
        item("Vietnamese · ABPVN", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_16.txt", .regional, 19000, "Vietnamese ads, trackers and scam sites."),
        item("Swedish · Frellwit", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_17.txt", .regional, 1150, "Swedish ad and tracker hosts."),
        item("Persian · PersianBlocker", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_19.txt", .regional, 257, "Persian-language sites' ads and trackers."),
        item("Macedonian · Pi-hole list", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_20.txt", .regional, 210, "Macedonian ad and tracker domains."),
        item("Chinese · anti-AD", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_21.txt", .regional, 101000, "Large Chinese-region ad and tracker list."),
        item("Chinese · AdRules DNS", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_29.txt", .regional, 204000, "Very large Chinese-region DNS ad list."),
        item("Indonesian · ABPindo", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_22.txt", .regional, 128, "Indonesian ad domains."),
        item("Turkish · turk-adlist", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_26.txt", .regional, 1200, "Turkish ad and tracker domains."),
        item("Turkish · Ad Hosts", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_40.txt", .regional, 2070, "Turkish ad hosts."),
        item("Hebrew · EasyList Hebrew", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_43.txt", .regional, 181, "Hebrew-language sites' ad domains."),
        item("Ukrainian · Security filter", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_62.txt", .regional, 1700, "Ukrainian scam and phishing domains."),
        item("Indian languages · IndianList (Hindi, Tamil, Telugu, others)", "https://easylist-downloads.adblockplus.org/indianlist.txt", .regional, 2231, "Ad domains on Indian-language sites."),
        item("Russian · RU AdList", "https://easylist-downloads.adblockplus.org/advblock.txt", .regional, 5720, "Russian-language sites' ad domains."),
        item("French · Liste FR", "https://easylist-downloads.adblockplus.org/liste_fr.txt", .regional, 6224, "French-language sites' ad domains."),
        item("German · EasyList Germany", "https://easylist-downloads.adblockplus.org/easylistgermany.txt", .regional, 1997, "German-language sites' ad domains."),
        item("Italian · EasyList Italy", "https://easylist-downloads.adblockplus.org/easylistitaly.txt", .regional, 1808, "Italian-language sites' ad domains."),
        item("Spanish · EasyList Spanish", "https://easylist-downloads.adblockplus.org/easylistspanish.txt", .regional, 1072, "Spanish-language sites' ad domains."),
        item("Portuguese · EasyList Portuguese", "https://easylist-downloads.adblockplus.org/easylistportuguese.txt", .regional, 838, "Portuguese-language sites' ad domains."),
        item("Dutch · EasyList Dutch", "https://easylist-downloads.adblockplus.org/easylistdutch.txt", .regional, 700, "Dutch-language sites' ad domains."),
        item("Polish · EasyList Polish", "https://easylist-downloads.adblockplus.org/easylistpolish.txt", .regional, 1268, "Polish-language sites' ad domains."),
        item("Czech & Slovak · EasyList", "https://easylist-downloads.adblockplus.org/easylistczechslovak.txt", .regional, 226, "Czech and Slovak ad domains."),
        item("Bulgarian · Bulgarian list", "https://easylist-downloads.adblockplus.org/bulgarian_list.txt", .regional, 382, "Bulgarian-language sites' ad domains."),
        item("Lithuanian · EasyList Lithuania", "https://easylist-downloads.adblockplus.org/easylistlithuania.txt", .regional, 337, "Lithuanian ad domains."),
        item("Nordic · Dandelion Sprout", "https://easylist-downloads.adblockplus.org/dandelion_sprouts_nordic_filters.txt", .regional, 1323, "Norwegian, Danish, Swedish, Icelandic and Finnish ad domains."),
        item("Chinese · EasyList China", "https://easylist-downloads.adblockplus.org/easylistchina.txt", .regional, 9354, "Chinese-language sites' ad domains."),
        item("EasyList (domains)", "https://raw.githubusercontent.com/yoavain/easylists-for-pihole/main/generated/easylist.txt", .adsTrackers, 47500, "The domain part of EasyList, the most used ad list. Rules that need page scripting are left out."),
        item("EasyPrivacy (domains)", "https://raw.githubusercontent.com/yoavain/easylists-for-pihole/main/generated/easyprivacy.txt", .privacy, 33800, "The domain part of EasyPrivacy, a large tracker list."),
        item("Crypto miners & scams (Blocklist Project)", "https://blocklistproject.github.io/Lists/alt-version/crypto-nl.txt", .malwarePhishing, 1272, "Cryptojacking and crypto-scam domains."),
        item("Ransomware (Blocklist Project)", "https://blocklistproject.github.io/Lists/alt-version/ransomware-nl.txt", .malwarePhishing, 1904, "Domains tied to ransomware."),
        item("Scams (Blocklist Project)", "https://blocklistproject.github.io/Lists/alt-version/scam-nl.txt", .malwarePhishing, 8527, "Known scam sites."),
        item("Tracking (Blocklist Project)", "https://blocklistproject.github.io/Lists/alt-version/tracking-nl.txt", .privacy, 143800, "Large tracker list. Very big; best for DNS filtering."),
        item("EasyPrivacy international", "https://raw.githubusercontent.com/easylist/easylist/master/easyprivacy/easyprivacy_specific_international.txt", .privacy, 1172, "Tracking domains on non-English sites."),
        item("Amazon trackers (HaGeZi)", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.amazon.txt", .privacy, 368, "Amazon device and app telemetry. May affect Alexa and Fire devices."),
        item("TikTok trackers (HaGeZi)", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.tiktok.txt", .privacy, 447, "TikTok telemetry and ad endpoints."),
        item("EasyList", "https://easylist.to/easylist/easylist.txt", .adsTrackers, 47000, "The most used ad list, including page rules that hide ad boxes and block ad URLs in Safari. Large."),
        item("EasyPrivacy", "https://easylist.to/easylist/easyprivacy.txt", .privacy, 34000, "Tracker list with URL rules for Safari."),
        item("Fanboy Annoyances", "https://secure.fanboy.co.nz/fanboy-annoyance.txt", .content, 1900, "Hides popups, newsletter prompts, chat widgets and other page annoyances in Safari."),
        item("Cookie notices (Fanboy)", "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt", .content, 700, "Hides cookie consent banners in Safari."),
        item("Fanboy Social", "https://secure.fanboy.co.nz/fanboy-social.txt", .content, 170, "Hides share buttons and social widgets in Safari."),
        item("Dating (ShadowWhisperer)", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_57.txt", .content, 1400, "Dating sites and apps.")
    ]
    public static var defaults: [CatalogList] { all.filter(\.isDefault) }
    public static func entry(forURL url: String) -> CatalogList? { all.first { $0.url == url } }
    public static func grouped() -> [(FilterCategory, [CatalogList])] {
        FilterCategory.allCases.compactMap { category in
            let items = all.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }
}
