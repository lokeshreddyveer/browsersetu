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

## Added after 0.2.0 (not yet in a release)

| Area | Status | Evidence / limit |
|---|---|---|
| Passwords and history import from Chrome, Firefox, Apple's Passwords, Safari | Checked (parsing) | `ImportToolsTests`; real exported files from those browsers were not tried |
| Handoff and Spotlight for bookmarks | Checked (rules) / Built (system behaviour) | `ContinuityTests`; not seen on a second device |
| Sync: deterministic merge, deletions, stale copies, workspaces, saved sessions, opt-in passwords | Checked (logic and two in-process models) | `SyncMergeTests` (including random three-device runs), `SyncModelTests`, `SessionSyncTests`; **never run between two real devices** |
| Download queue: priorities, hold until a time, pause and resume all, retry with back-off, restore after quitting | Checked (logic) | `DownloadQueueTests`, `DownloadPersistenceTests`; no speed limit (WebKit offers none); iPhone background time not measured on a device |
| iPhone extensions: install, More-menu entries, popup sheet | Checked on a simulator (popup runs its script) | one sample extension only; no real store extension tried on iPhone |
| Per-site extension allow and block rules | Checked | `ExtensionTests` (a block rule stops a real content script and removing it brings it back) |
| Several windows (independent models, tab moves, restored at start) | Checked in real runs | driven through System Events (⌘N, ⌘W, File menu, quit and reopen); the XCUITest runner could not drive the app in this session; external-display layouts not built |
| Site rules ("when a site opens": private tab, container, group, workspace) | Checked | `SiteOpenRulesTests` and two real WebKit navigations |
| Slash commands in the address bar; search across all tabs including sleeping ones | Checked (logic and real tabs) | `SlashCommandTests`, `SlashModelTests`; sleeping tabs are found by title or, with the page index on, by saved text |
| Saved sessions keep each page's place and the workspace | Checked | `SessionSyncTests`; the scroll restore itself was not watched on a real page |
| Offline PDF copies and notes on selected passages in Research; go to passage | Checked (store and a real selection) | `ResearchOfflineTests`; "go to passage" uses the page's find and was not watched |
| Search the selected words with any engine | Checked (addresses) | `SelectionSearchTests`; no right-click menu entry (WebKit's menu is not customised) |
| Element picker and window-size presets with a live size readout | Checked (picker on a real page); Built (resize and readout) | `ElementPickerPageTests`; resizing was not watched |
| PDF editor: page tools, marks, signing (drawn, typed, picture; saved in the Keychain behind Touch ID), redaction, protected copies; opening documents | Checked (file operations) / Built (screens) | `PDFEditTests` (redaction removes the words from the file); the editor screens were not looked at on a display. A signature is a picture or text placed on the page, not a certificate-based digital signature |
| Mouse gestures (Mac, off by default): hold the middle button and drag | Checked (path recognition) / Built (the mouse handling) | `MouseGestureTests`; not tried with a physical mouse. Middle-click closes a tab in the tab strip |
| Address-bar answers: sums, percentages and unit conversions | Checked | `QuickAnswerTests`; no currency (it needs a network rate) |
| Leaked-password check (haveibeenpwned.com, k-anonymity) and reused-password flags | Checked (hashing, parsing, grouping, with a fake server) | `BreachCheckTests`; the live service was not called in tests. The one network call is listed in `docs/privacy/DATA-FLOW.md` |
| Guest window (Mac): private tabs only, nothing kept, not restored | Checked (model) | `WindowTests`; a guest window still uses the same app, so it hides but does not lock away the owner's data: bookmarks are not suggested, but the owner's other windows stay open |
| Read aloud (Page Tools → Listen) | Built | uses the system voice; the sentence being read is followed on screen |
| Accessibility pass: labels on icon-only buttons, text that follows the text-size setting on iPhone and iPad (capped so bars do not break), stronger outlines with Increase Contrast, motion respects Reduce Motion | Built; **not audited with VoiceOver or Accessibility Inspector** | no automated or manual screen-reader run was possible in this environment |
| Never-sleep list for chosen sites | Checked (policy and saved list) | `PageDefenseTests`; also respected by "put all other tabs to sleep" |
| JavaScript off for one site (per navigation, so it also holds on reload) | Checked on a real page | `PageDefensePageTests`; the tab's own switch still works |
| De-AMP: AMP-cache links go to the site's own page; AMP pages that name their canonical page are replaced | Checked (link rules, and a real AMP page via the local test server) | on by default; Google can change its AMP addresses, which would need new rules |
| Fingerprint randomizing (canvas, WebGL read-back, audio, processor count) | Checked on a real page (stable in a site, different between sites, off by default, per-site exceptions) | does not touch fonts, screen size or WebGL renderer names; a script that checks whether the browser's functions were replaced can notice the change |
| Skip and mute YouTube video ads | Checked against a stand-in page: it hides the ad slots and presses Skip. The mute-and-jump-to-the-end path for an ad that cannot be skipped is **not exercised** (the test host cannot load media) | **not tried on youtube.com**: it works by watching the player, so a YouTube change can stop it; off by default |
| Themes drawn solid under the whole window, including behind the title bar; the toolbar takes the page's colour (read from the page when it names none) | Checked on screen (Mac, Debug build, with a blue test page and the Synthwave theme: toolbar and tab row measured the same colour) | the page colour is a lighter touch under a theme; a colour that would clash with the window (white page in a dark window) is only a faint wash |
| Toolbar buttons for workspaces, profile, split view, history, bookmarks, find and the command palette, in Classic, Minimal and One Row; One Row has the same bookmark, downloads and More menu | Checked on screen (One Row) / Built (the others) | workspaces and split view are on by default, the rest are off; Settings › Appearance › Toolbar |
| Dragging a tab from one window's tab bar or sidebar to another's moves it with its page; the emptied window closes | Checked in a real run with synthetic mouse events (after fixing a bug where the moved page went blank) | a drop needs a real mouse; not tried on the sidebar layout |
| Settings: workspaces as tidy rows with colour swatches, split view and window help in the Tabs panel | Checked on screen (Tabs panel) | |
| Split view: two panels exactly 50-50, three (one tall, two stacked) and four (2×2), draggable dividers, double-click to equalise | Checked on screen (two, three and four panels, equal shares) and in tests (`ThreePanelSplitTests`) | divider dragging was not tried with a real mouse |
| Network throttling | **Not possible** | WebKit gives no way to slow a page's loads; macOS's Network Link Conditioner can be used from outside |
| Saving a password: the sign-in is noticed by form, Enter, button or script, including inside a frame from another site; a "Save password?" card appears as the password is typed; clicking a password field offers the saved sign-in (also inside frames) | Checked in a real tab (`LoginPromptFlowTests`, `LoginWatcherTests`: form, script-sent, cross-origin frame via the local test server, typed password, and the page-side half). **Not tried on App Store Connect or another live site by the tests** | the scripts were being wiped by the user-scripts installer before; fixed and covered |
| Keep passwords in iCloud Keychain; passwords in the encrypted backup | Checked (storage fall-back, moving, backup round trip, restore refuses odd entries: `PasswordKeepingTests`) | **iCloud Keychain carrying them to a second device is not checked**; an unsigned build falls back to this device and says so |
| Pop-ups: a window opened right after a real click or key press is allowed and joined to its opener; others are blocked with Open Once / Always Allow; per-site list | Checked in a real run for the gesture rule; **real sign-in pop-ups (Google, Apple) not tried** | window.open without a click is refused |
| YouTube ad blocking on by default: ad schedule removed from the player's data in the page's own world; rules are data only, validated, refreshed at most daily | Checked on a stand-in page (`YouTubeStripTests`), rule validation (`YouTubeAdRulesTests`) | **not tried on live YouTube**; YouTube changes this often; the update file `rules/youtube-ads.json` must be published |
| iPhone second autoplay guard (pauses media that starts with no tap in the last six seconds) | Built | **not run on a device by the tests** |
| Right-click menus (sidebar, also auto-hidden; toolbar; tab strip; new tab; page links with new tab, background, split, private), drag-to-customize sidebar and address bar buttons, tab tree folding, stacks, hover previews, web panels, break mode, page actions, command chains, theme schedule, Pure Black, Settings as a tab | Built (the Mac app compiles and the settings and models are covered where logic exists) | **mostly not looked at on screen**; break mode and page actions were no-ops until the page-script call was declared properly |
| Library panels (Bookmarks, History, Downloads), start page and Settings redesign, message cards, "Show more" lists | Built | not looked at on screen |
| First-run setup assistant | Built | not looked at on screen; the privacy answers apply at once |
| Message handlers: three, all in the isolated world a page cannot reach | Checked (`PrivacyIntegrationTests` allows exactly these and fails on any other) | replaces the earlier rule of "no message handlers at all" |
