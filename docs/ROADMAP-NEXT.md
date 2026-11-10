# Next batches (3 November 2026)

Sources compared: LibreWolf, Waterfox, ungoogled-chromium (read 3 November 2026), then checked against this repo. Items the repo already had are left out (feed reader, page translation, Brave/Startpage/Qwant, referrer control, history retention, popup blocking, punycode warnings).

## Research notes that shape the work
- `WKWebpagePreferences.globalPrivacyControlEnabled` exists from macOS/iOS 27 and sends `Sec-GPC: 1` plus `navigator.globalPrivacyControl` itself. Older systems get the script property only (no header).
- `WKWebpagePreferences.isLockdownModeEnabled` is set per navigation (macOS 13, iOS 16), so it can be a per-site switch.
- Content rule lists: `load-type` is an array, `if-top-url`/`unless-top-url` are regexes on the whole top address and cannot be mixed with the domain triggers in one rule.
- Apple's Translation framework and a feed reader are already in the app; no work there.
- No public API warms up a web view; the only safe route is creating one ahead of time.

## Batch 1: small switches
1. Global Privacy Control (default on; Settings › Privacy).
2. Stop link click-tracking pings (script removes `ping` attributes).
3. Mojeek search preset.
4. A separate default search engine for private tabs (off until chosen).
5. Mac tab switches: double-click a tab to close it, hide tab close buttons, close the window with its last tab.

## Batch 2: privacy, larger
1. Block pages from reaching localhost and home-network addresses (per-site allow).
2. Per-site Lockdown Mode (This site… and a Strict preset).
3. Privacy presets: Standard, Strict, Paranoid, with a plain list of what each changes.
4. Larger tracking-parameter list with an allow-list.
5. Optional "no Google web services" host list.
6. Noise for element-size measurements, inside the existing fingerprint noise.
7. Debouncing: a link that goes through a tracker's redirect page (for example `l.facebook.com/l.php?u=`, `google.com/url?q=`) opens the real destination.
8. Optional social-widget blocker (embedded buttons and feeds), off by default.

## Batch 3: features
1. Feed autodiscovery on the page (a button when a page offers a feed).
2. OPML import and export for feeds.
3. Check browser import coverage (Firefox/Chrome bookmarks, history, passwords).

## Batch 4: speed
1. Read the smoothness report once the user copies it.
2. A spare, ready web view for the next new tab; measure before and after.

## Decided not to build yet: shared windows across a device
Each window owns its tabs today, by design. A Zen-style "shared workspace" mode would need a `TabRecord` (url, history, container, title, workspace) kept apart from a per-window `TabPresentationSession` (selected tab, scroll, split state), and a single `WKWebView` can only be in one window at a time, so a second window would show a snapshot or reload the page. That is a rewrite of the tab model, for a need nobody has shown. Keep independent windows as the default; revisit only if people ask, and then add it as an optional mode, never the default.

## Rules for every item
Off by default unless it only protects (GPC, ping); never touch the playback path; nothing leaves the device unless the user presses a button, apart from the few documented default-on requests (first-launch filter lists, YouTube rules, site icons, Mac updates), each with an off switch; each setting animates; README and release notes updated with each batch.
