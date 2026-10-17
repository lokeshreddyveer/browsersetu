# Browser Setu

A native, security-first web browser for **macOS** and **iPhone/iPad**. It renders with the system's own WebKit, keeps everything on your device, and
puts a small Rust core (tabs, address-bar logic, permission and navigation rules, per-profile SQLite storage) under a SwiftUI interface.

> **Status: release candidate, in the production-hardening phase (0.3.0).** It is a real, working browser with a large automated test suite (about 650 tests), but
> it is **not yet called production grade**: that needs the evidence in [`docs/RELEASE-BAR.md`](docs/RELEASE-BAR.md) to be complete and recorded. [`docs/capabilities.md`](docs/capabilities.md)
> lists every feature as *Checked*, *Built* (compiled, not exercised end to end) or *Parked* (switched off), with the evidence and the limits. Read both before you rely on anything.

## Download

- **Mac (Apple Silicon, macOS 14 or later):** the notarized DMG on the [Releases](../../releases) page. The downloadable build updates itself (see
  [Updates](#updates)).
- **iPhone and iPad (iOS 17 or later):** TestFlight. Ask the author for an invitation.

There is no Windows, Linux or Android version.

## What you get

### Tabs and windows

- Tabs across the top, down a resizable sidebar on either side, as a compact strip, or as an icon rail. Layout presets: Classic, Sidebar, Minimal,
  Floating, One Row and Custom, with a handle and a **Restore Standard Layout** command (⌥⇧⌘0) that always gets you back.
- Pinned tabs, tab groups with colours, workspaces (each remembers its own layout and, if you like, its own set of extensions), drag to reorder,
  split view (two or **three panels** side by side or stacked), several windows (each with its own tabs and layout, restored at the next start), a **guest
  window** on the Mac (private tabs only, nothing kept, not restored), focus mode, a tab overview with search and sorting, session restore with lazy
  loading, and "reopen closed tab".
- Tab tools: names, colours, notes and status on any tab, a tree view that shows which tab opened which, group-by-website, put all other tabs to
  sleep, find duplicates, saved split-view templates, and scratch tabs that leave no history and vanish when closed.
- Tabs you are not using give their memory back (Balanced, Saver and Performance modes), and the app tells you which tabs are asleep and why. A **never-sleep
  list** keeps chosen sites awake, and tabs in a split-view panel are never put to sleep.

### Address bar, search and commands

- One address bar that suggests from your own tabs, bookmarks and history first (all computed on your device). A search-engine menu in the bar, a
  custom engine, search shortcuts, and optional suggestions from your engine (off until you turn it on).
- A command palette (⌘K) with every command. **Workbench → Search** searches tabs, bookmarks, history, downloads, your research and your notes in one list.
- **Answers in the address bar:** sums (`12 * (3 + 4)`, `15% of 80`, `sqrt(2)`) and unit conversions (`5 km to miles`, `72 f in c`), worked out on the device; Return copies
  the answer. No currency (it needs a live rate).
- **Slash commands** (`/tabs`, `/close`, `/find`, `/group`, `/save`, `/open`, `/workspace`, `/forget`, `/split`…) and **search across all open tabs** that reads the
  text of every page, including tabs that are asleep (from the saved copy of pages you read), and forgives a slip of the keys ("kuberntes" finds "Kubernetes").
- Optional **Vim keys** (j, k, gg, G, H, L and more, with a keymap you can edit). They only act when no text field has the keyboard.
- **Mouse gestures** on the Mac (off by default): hold the middle button and drag (left for back, down for new tab, down then right to close…). The map is
  editable. A middle click still opens a link in a new tab, and closes a tab in the tab strip.
- On iPhone there is no toolbar: a dock of three pills, a search button, and an address bar that opens in place when you tap it.

### Privacy and security

- **Content blocking:** ads, trackers and session-recording scripts are blocked with WebKit's content-rule engine. A small built-in starter list ships in
  the app; about 90 public lists are offered as optional downloads, fetched straight from their publishers only when you press Update (or turn on
  automatic updates, which is off by default).
- **Link cleaning:** tracking parameters are stripped from links. **HTTPS upgrade** for plain-HTTP addresses. **De-AMP:** links through Google's AMP cache go to the
  site's own page, and an AMP page that names its own full version is replaced by it.
- **Fingerprint randomizing** (off by default): small, per-site changes to what canvas, WebGL read-back, audio and the processor count report, so a site cannot
  recognise this device by them; each site has its own off switch for the few pages that draw pictures. **YouTube ad skipping** (off by default) hides ad slots,
  presses Skip and mutes ads that cannot be skipped; it works by watching the player, so a change on YouTube's side can stop it. **JavaScript off for one site**,
  and a **style sheet for every website** (CSS applied to every page you open).
- **Private tabs:** a separate, non-persistent store. No history, no session, no saved sign-ins, no extensions, no scripts, and nothing from them is
  read by the browser's own tools.
- **Profiles** with fully separate website data; **containers** that keep one site's cookies apart from the rest inside a profile.
- **Per-site privacy page:** what the site stored (its cookies, third-party cookies by owner, storage), which permissions it holds, how it sees your
  browser, how safe its connection looks (certificate chain, redirects, mixed content) and **who the certificate says is on the other end** (a checked
  organisation's name beside the address, or a plain "encrypted, owner not verified" for a certificate that only proves the domain), and **Forget This Site Completely**. Automatic-deletion rules
  clear a site when its last tab closes or every time the app starts.
- **Permissions:** camera, microphone and location are asked for, per site, with "Allow", "Allow for an Hour", "Allow for This Session" or "Always
  Allow" (which itself expires). A log shows who asked for what and what you said. Insecure pages are always refused.
- **WebRTC switch** (stops pages learning this device's network address, with per-site exceptions), per-site browser identity (user agent), a **proxy**
  for page loads (HTTP or SOCKS5; it is not a VPN), and a download scanner that warns about risky file types.
- **Saved passwords:** after you sign in, the browser offers to keep the password in your Keychain, on this device, for this profile. Filling asks for
  Touch ID or your password first, only happens on the exact site, never over plain HTTP and never in a private tab. The browser reads the form just
  before it is sent; pages cannot send it anything. Sign-ins that never reload the page can be missed. There are **no passkeys yet** (Apple must grant
  browsers that permission), and Safari's iCloud Passwords cannot be used by other browsers.
- **Leaked-password check:** only when you press it (after Touch ID), each saved password's SHA-1 hash is made on the device and only its first five characters are
  sent to haveibeenpwned.com (k-anonymity), so no password, whole hash, site or user name leaves; reused passwords are flagged too.
- **Sensitive-settings lock** (Touch ID or password) in front of saved sign-ins, extension changes and similar; it refuses when the device cannot
  authenticate instead of opening.
- **Clear on quit**, **safe start** after repeated crashes, and an in-app **health check**.

### Extensions

- Web extensions through WebKit's own extension support (**Mac only**, macOS 15.4 or later). Add from a folder, a `.crx`/`.zip` file or a Chrome Web
  Store address. Every install shows what the extension asks for, warns about things Apple's support does not offer, and installs from a private copy
  that is hashed before and after, so what you approved is what runs.
- A permissions screen per extension: switch any permission off, restrict to "on click", specific sites or all sites, and see a history of changes.
- Pin extensions to the toolbar; popups open anchored to their button.
- Tools: conflict detection (shortcuts, request blocking, restyling, new-tab pages), presets (Cautious, Balanced, Open), what changed in the last update,
  go back to the previous version, per-workspace extension sets, a throwaway-profile load test with a score, and a backup of the installed files.
- **Limits:** VPN and privacy-API extensions cannot work (WebKit has no proxy or privacy APIs). Native messaging (password managers' helper programs) is
  written but switched off until Chrome package signatures are verified. On iPhone and iPad (iOS 18.4 or later) extensions install and run from the More menu; that
  was tried with one sample extension only. Real Bitwarden and 1Password packages were fetched for a compatibility report; see [`docs/extension-compatibility.md`](docs/extension-compatibility.md).

### Reading, research and writing

- Reader view, a reading list with offline copies, highlights, page notes, and "restore what I was typing".
- **Research collections:** save pages, highlights (each with a citation: title, address, author, dates), notes and PDFs, then export to Markdown, HTML
  or PDF. Copy a citation as plain text.
- Text from pictures (Vision, on device), dates, phone numbers and addresses from text (system detector), unit conversion, remember where you stopped
  reading, and keep a page's text to see what changed on your next visit (with price-drop detection).

### Downloads and files

- **PDF editor:** highlights, pen, text, shapes, rotate, delete, reorder, extract and merge pages, **signing** (drawn, typed or a picture, kept in the Keychain behind Touch ID),
  **redaction that removes the words from the file**, and password-protected copies. A signature is a picture or text placed on the page, not a certificate-based
  digital signature. Other documents (Word, Excel, Pages…) open in a preview.

- Resumable downloads, an optional sort into folders by kind, **rules by site and kind**, a duplicate finder, preview, share and reveal in Finder.
- A page's own "Download" button that hands over a `data:` or `blob:` file works: it is saved, never run as a page.
- A picture of the page (visible part or the whole page), and save as web archive.

### Developer tools

- Load numbers, a resource waterfall and **HAR export** built from the page's Resource Timing, a storage inspector (secrets masked), uncaught page
  errors, a JavaScript scratchpad (isolated world, never in private tabs), and a switch that lets Safari's Web Inspector attach.
- **Limits:** WebKit gives pages no request headers, response bodies or `console.log` output, so those are not available.

### Automation

- Workflows of fixed, safe steps (open, search, run a command, wait), `browsersetu://` links (open, search, command, workflow), Shortcuts actions, and
  scheduled page checks that run while the app is open. A workflow started from a link asks first. A permission store for scripts exists; there is no
  script runtime yet.

### Themes and the start page

- Eleven moods and ten classic palettes (Dracula, Nord, Gruvbox, Solarized, Catppuccin, Tokyo Night, Rosé Pine, One Dark and more), your own **Custom** theme with a photo
  (the accent is taken from the photo, and a warning appears when an accent is hard to see on its background), **theme files** you can import and export (colours only),
  and a **Customize panel** that slides in over the start page: theme, accent, what the page shows, icon size and search engine, all applied the moment you touch them.
- The start page is native; its tiles have visible keyboard focus rings, and an empty Favorites row says what it is for. Page loads show the window's own colour, not white.

### Accessibility

- Icon-only buttons have spoken labels; text follows the text-size setting on iPhone and iPad (capped so bars do not break); outlines get stronger with Increase
  Contrast; animations are skipped with Reduce Motion. **This has not been audited with VoiceOver or Accessibility Inspector.**

### Sync and backup

- **iCloud sync**, sealed with your own passphrase before it leaves the device, with device approval, a sync group, a history log, a conflicts screen and a status
  that says what is wrong (not signed in, needs a passphrase, devices waiting, space nearly full, last sent and received). **Each kind of thing has its own switch:**
  bookmarks, workspaces, saved sessions, open tabs, settings and themes, site rules and styles, **history** (the 800 most recent pages and deletions, off by default) and
  passwords (off by default). Switching one off sends nothing, takes nothing in and deletes nothing on your other devices. **Send a tab to another device** from the tab
  menu, the More menu or the command palette; it arrives once, as a web address only, and shows on that device's start page. (The downloadable Mac build has no iCloud
  sync; Apple only allows it for App Store builds.) **Wi-Fi sync** between your own devices uses a one-time 100-bit code. Neither has been run between two real
  devices yet; the tests run two in-process browsers.
- **Encrypted backup file** of bookmarks, settings and research collections (passphrase-sealed; passwords, cookies and history are never included).
- Bookmark import and export in the standard HTML format.

## What leaves your device

Browser Setu has no accounts, no analytics and no telemetry. The only network requests the app itself makes are:

| When | What | To |
|---|---|---|
| You load a page | the page | the site |
| You turn on search suggestions | what you type in the address bar | your search engine |
| A site icon is shown | the icon request | the site |
| You press Update on a filter list (or enable automatic updates) | the list address, with no cookies or identifiers | the list publisher |
| You add an extension from the Chrome Web Store | one package request | Google's store |
| The downloadable Mac build checks for updates (daily, can be turned off) | the app's version | github.com |
| You press Check Passwords for Leaks | the first five characters of each password's SHA-1 hash, nothing else | haveibeenpwned.com |
| You sync | an encrypted snapshot | your iCloud, or your own device over Wi-Fi |

Tests in `apps/apple/Tests/PrivacyIntegrationTests.swift` fail if networking code appears anywhere else, and if page scripts gain a channel back to the app.

## Updates

The App Store and TestFlight builds update through Apple. The downloadable Mac build includes [Sparkle](https://sparkle-project.org): it checks
[`appcast.xml`](appcast.xml) once a day, asks before installing, and refuses any update that is not signed with the publisher's key. Turn automatic
checks off in Settings → Advanced → Updates, or use **Browser Setu → Check for Updates…**.

## How it is built

```
apps/apple/   SwiftUI apps (macOS + iOS)
  Shared/       engine-neutral app code: BrowserModel, tabs, views, privacy, sync, research, workbench
  Shared/Engine/EngineAPI.swift   the contract between the app and a web engine
  Engines/WebKit/                 the WebKit engine, extensions, user scripts
  macOS/ iOS/ Direct/             platform shells (Direct = the downloadable Mac build with the updater)
  Tests/ UITests/ iOSTests/ iOSUITests/
core/         Rust workspace
  domain/       pure logic: tabs, omnibox, navigation and permission policy, profile names
  storage/      per-profile SQLite (WAL, versioned migrations, parameterised SQL only)
  ffi/          UniFFI surface used by Swift
Packages/SetuPrivacyKit   content-blocking policy builder and the WebKit rule installer
experiments/  a parked Blink/CEF engine bridge (not built)
docs/         capabilities (dated status ledger), threat model, extension compatibility, verification, privacy notes
scripts/      build-xcframework.sh, release.sh (sign, notarize, DMG), publish-release.sh, testflight.sh
```

**Engine.** WebKit on both platforms, for low memory and battery use and Apple's own security updates. Everything above the `BrowserEngine` protocol
is engine-neutral, so another engine could be added. WKWebView does not give Chrome-style site isolation, and the app makes no such claim.

**Security model** (details in [`docs/security/threat-model.md`](docs/security/threat-model.md)): web pages are untrusted and have no bridge to the core;
every navigation goes through a core policy (http/https only; mail and phone links need confirmation; `file`, `javascript` and `data` pages are
refused); downloads are renamed to a leaf name and never opened automatically; profile names are validated before they touch the file system; the Mac
app is sandboxed with the hardened runtime.

## Build from source

Requires Xcode, Rust (rustup; the toolchain is pinned in `core/rust-toolchain.toml`) and XcodeGen (`brew install xcodegen`).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-xcframework.sh                   # Rust core → XCFramework + Swift bindings
cd apps/apple && xcodegen generate
xcodebuild -scheme BrowserSetuMac build        # sandboxed Mac build, no updater (App Store)
xcodebuild -scheme BrowserSetuMacDirect build  # the downloadable build, with Sparkle
xcodebuild -scheme BrowserSetuiOS -destination 'generic/platform=iOS' build
```

Tests: `xcodebuild -scheme BrowserSetuMac test -only-testing:BrowserSetuMacTests`. UI and iPhone tests need `scripts/testserver.py`. The state of
verification is in [`docs/verification.md`](docs/verification.md) and [`docs/capabilities.md`](docs/capabilities.md).

Releasing: `scripts/release.sh <version> <build>` signs with Developer ID, notarizes, staples and makes the DMG; `scripts/publish-release.sh` uploads it and
adds it to the update feed; `scripts/testflight.sh` archives and uploads the iPhone build.

## Not built, on purpose

- Passkeys and iCloud Passwords (Apple has to grant browsers the entitlement; a request is the next step).
- VPN-type extensions and per-extension CPU or memory (WebKit reports none). A built-in VPN, Tor, and network throttling (WebKit gives no way to do them).
- Certificate-based digital signatures on PDFs (signing places a picture or text).
- Three-way split on iPhone (the iPhone has no split view); mouse gestures and guest windows on iPhone (no mouse, and private tabs cover guests).
- AI features and semantic search (skipped by choice).

## Licence

Copyright © 2026 Lokesh Reddy Veerabhadra. The source is published so you can read and audit it; all rights are reserved and no licence to reuse it is
granted. Third-party components keep their own licences (Sparkle is MIT). If you want to use the code, ask.
