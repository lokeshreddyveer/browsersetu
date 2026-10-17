# Data flow, for the App Store privacy questionnaire

Written 17 October 2026 from the source of version 0.2.0. It records what the app sends and where, so the App Store Connect answers can be checked against evidence.
**The empty collected-data list in the privacy manifest is provisional**: it must be reviewed against Apple's current definitions in App Store Connect before it is treated as final.

BrowserSetu has no analytics, no telemetry, no accounts and no server of its own. Tests in `apps/apple/Tests/PrivacyIntegrationTests.swift` fail if networking code appears outside the files listed below, or if a page gains a channel back to the app.

| Flow | When | What leaves the device | To whom | Notes for the questionnaire |
|---|---|---|---|---|
| Web pages | the person loads a page | the request | the site | Ordinary browsing; the browser is the user's agent. |
| Search suggestions | **off until the person turns it on** | the text typed in the address bar | the search engine the person chose | Disclose if Apple's definitions treat the chosen provider as a third-party recipient of user-entered data. No BrowserSetu server sees it. |
| A submitted search | the person submits | the query | the chosen search engine | Same. |
| Site icons | an icon is shown | an icon request | the site | No identifiers. |
| Filter-list updates | **off by default**; when pressed or enabled | the list address | the list publisher | No cookies, referrer, cache validators beyond the request, or identifiers. |
| Chrome Web Store extension | the person adds one by address | one package request | Google's store | HTTPS only, restricted to Google's download host. |
| Update check (downloadable Mac build only) | daily, can be turned off | the app's version | github.com | Sparkle; not in the App Store or iPhone builds. |
| iCloud sync | opt-in | bookmarks, and settings and open tabs if chosen | the person's own iCloud | Sealed with the person's own passphrase before upload; BrowserSetu cannot read it. Verify the current questionnaire wording for data transmitted through iCloud. |
| Leaked-password check | **only when the person presses Check Passwords for Leaks** (after Touch ID) | the first five characters of each saved password's SHA-1 hash, nothing else | haveibeenpwned.com (`api.pwnedpasswords.com`) | k-anonymity range lookup: no password, whole hash, site, user name, cookie or account is sent; padded responses; the match is made on the device and the result is not stored. |
| Wi-Fi sync / sharing | the person pairs two of their devices | the shared items | their own other device, on the same network | One-time 100-bit code; not through any server. |

## Identifiers
No advertising identifier, device identifier or fingerprint is read. The only identifiers are random IDs for devices in the person's own sync group. They are generated on the device and kept within the person's own iCloud group; they are not advertising identifiers.

## Not collected
No crash reports, usage statistics, URLs, search history or content are sent to the developer.

## Open questions to settle in App Store Connect
1. Does Apple count the user's chosen search provider, or iCloud transmission, as "collection" under today's definitions?
2. Are the random sync IDs a "Device ID" under Apple's wording, given they never leave the person's own iCloud?
