# What exists, and what has been checked

Dated ledger. It replaces the older PASS tables where they disagree. Status words: **Checked** (a test or a real run showed it), **Built** (written and compiled,
not exercised end to end), **Parked** (written but switched off).

Last updated 16 October 2026 (macOS 27.0 build 26A5425a, Xcode toolchain on this Mac).

| Area | Status | Evidence / limit |
|---|---|---|
| WebKit rendering, profiles, private tabs | Checked | `BrowserIntegrationTests`, `PrivacyIntegrationTests` |
| Content blocking | Checked | local-server tests in `PrivacyIntegrationTests`; WebKit reports no blocked counts |
| Web extensions on Mac (load, content scripts, permissions, revoke, update) | Checked | `ExtensionTests`, including a real content script stopping after a permission is revoked |
| Real Chrome Web Store extensions | Partly checked | `docs/extension-compatibility.md`: loads and page effect only; popups, blocking and sign-in not exercised |
| Extension install on iPhone | Refused in code | `ExtensionCenter.canInstall`; popup UI for iPhone not built |
| Extension native messaging (iCloud Passwords helper) | Parked | `NativeMessaging.swift`; stays off until CRX signatures and extension identity are verified (`chromeIDVerified` is never set) |
| Saved HTTP sign-ins | Checked | keyed by scheme, host, port, realm, method and proxy flag; `PowerFeatureTests` |
| Local sharing / Wi-Fi sync pairing | Built | 100-bit code, expiry, attempt limit, connection and inbox caps; format and key tests; not run between two real devices |
| iCloud sync | Built | per-profile passphrase and sync group, device approval, history; not run between two real devices |
| Proxy for page loads | Built | public WKWebsiteDataStore proxy API; not run against a real proxy; suggestions, list updates, site icons and store downloads are paused while it is on |
| Sensitive-settings lock | Checked | fails closed when the device cannot authenticate; `PowerFeatureTests` |
| Extension package unpacking | Checked | actual-size limits, CRC, overlap and duplicate refusal; `ExtensionPackageTests` |
| Performance | Measured, blank tabs only | `PerformanceBaselineTests`; no page, renderer or Safari comparison |
| Passkeys | Not available | needs Apple's browser entitlement |
| Releases | Reproducible by construction | Rust core rebuilt every release, locked dependencies, pinned toolchain; sandbox entitlement value is parsed |

## Added in the power-tools round

| Area | Status | Evidence / limit |
|---|---|---|
| Tab organiser (tree, auto-group, suspend others, names, colours, notes, duplicates, split templates, scratch tabs) | Checked (logic) | `TabOrganizerTests`; not looked at on screen |
| Layout state, handle, presets, per-workspace memory, restore command | Checked (logic) | `LayoutStateTests` covers every combination; window pictures are taken by `LayoutRegressionUITests`, not yet run |
| Layout across several windows or external displays | Not built | the browser keeps one model for one window; per-window state would have to be split out first |
| Research (collections, highlights, citations, Markdown/HTML/PDF export) | Checked (logic) | `ResearchTests`; export formats not opened in other apps |
| Per-site privacy page, temporary permissions, containers, auto-delete rules, WebRTC switch, forget-site | Checked (logic) | `SitePrivacyTests`; WebRTC switch not tried against a real call; WebKit has no finer WebRTC control |
| Vim keys | Checked (key logic) | `VimSearchAutomationTests`; the key hook in the page view and the text-field check are not exercised against a live page. No link hints |
| Search across tabs, bookmarks, history, downloads, research, notes, commands | Checked (ranking) | `VimSearchAutomationTests`; the Workbench screen is not looked at. Semantic search skipped (AI) |
| Workflows, link actions (`browsersetu://`), Shortcuts actions | Built | link parsing and workflow validation tested; Shortcuts actions compiled, not run in Shortcuts. Workflows only run a fixed list of steps and safe commands |
| Scheduled page checks | Built | runs while the app is open, in a throwaway tab with no sign-in |
| Scripting API with permission prompts | Partly built | the permission store exists; there is no script runtime yet |
| Developer tools (waterfall, HAR, storage, errors, scratchpad, performance, web archive, Web Inspector switch) | Built | HAR and waterfall are built from the page's own timing data: no headers or bodies, no `console.log` output (WebKit isolates each world's console). Parsing tested in `DevFilesTests`; the page script is not run against a real page |
| Download rules, duplicate finder | Checked (logic) | `DevFilesTests`; rules are applied when a download starts |
| Data and blob downloads from a page's own Download button | Built | a clicked link marked as a download is saved instead of blocked; not run against the site that showed the blocked message |
| PDF annotation | Built | highlights and notes saved to a copy with PDFKit; not run |
| Extension tools (conflicts, presets, update diff, rollback, diagnostics, throwaway load test, backup) | Checked (logic) | `ExtensionToolsTests`; rollback, backup and the load test are not run against a real extension. The score covers load-level checks, not features. No per-extension CPU or memory (WebKit reports none) |
| Per-workspace extension sets | Built | switching a workspace turns its extensions on and the rest off; not run |
| Backup now includes research and the new settings | Built | restore merges, never overwrites |

## Added with the first public release (0.2.0)

| Area | Status | Evidence / limit |
|---|---|---|
| Saved passwords for web login forms (save, update, never-for-site, fill behind Touch ID, Keychain per profile) | Checked (logic) / Built (page flow) | `WebLoginTests` cover origin rules, offers, capture limits and the vault; the form reading and filling scripts have not been run against real sites. Single-page logins that never navigate are missed. No passkeys. |
| Page layout under the status bar and above the dock on iPhone | Built | public WKWebView viewport-inset API; looked at in no real run yet |
| New tab responsiveness | Checked (blank-extension case) | `NewTabResponsivenessTests`: 8–13 ms of main-thread hold with a 4,000-row page open; not measured with extensions installed |
| Sparkle updater in the downloadable Mac build | Built | separate `BrowserSetuMacDirect` target; no update has been offered or installed end to end yet; iCloud sync is not in this build |
| Notarized DMG, GitHub release, TestFlight upload | See the release notes of each release | scripts: `release.sh`, `publish-release.sh`, `testflight.sh` |
