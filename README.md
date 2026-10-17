# Browser Setu

A native, security-first web browser for **macOS** and **iPhone/iPad**. It renders with the system's own WebKit, keeps everything on your device, and
puts a small Rust core (tabs, address-bar logic, permission and navigation rules, per-profile SQLite storage) under a SwiftUI interface.

> **Status: release candidate, in the production-hardening phase (0.3.3).** It is a real, working browser with a large automated test suite (about 650 tests), but
> it is **not yet called production grade**: that needs the evidence in [`docs/RELEASE-BAR.md`](docs/RELEASE-BAR.md) to be complete and recorded. [`docs/capabilities.md`](docs/capabilities.md)
> lists every feature as *Checked*, *Built* (compiled, not exercised end to end) or *Parked* (switched off), with the evidence and the limits. Read both before you rely on anything.

## Download

- **Mac (Apple Silicon, macOS 14 or later):** the notarized DMG on the [Releases](../../releases) page. The downloadable build updates itself (see
  [Updates](#updates)).
- **iPhone and iPad (iOS 17 or later):** TestFlight. Ask the author for an invitation.

There is no Windows, Linux or Android version.

## What you get

Everything below is in the app today. Each part says what it does and how it works. Where something is untested or limited, it says so; the full ledger, with
the evidence for each item, is [`docs/capabilities.md`](docs/capabilities.md). Mac-only and iPhone-only parts are marked.

**Contents:** [First minutes](#first-minutes) · [Layouts, windows and tabs](#layouts-windows-and-tabs) · [Address bar, search and commands](#address-bar-search-and-commands) ·
[Keyboard shortcuts](#keyboard-shortcuts) · [Privacy and security](#privacy-and-security) · [Passwords](#passwords) · [Extensions](#extensions) ·
[Reading, research and page tools](#reading-research-and-page-tools) · [Downloads, PDFs and documents](#downloads-pdfs-and-documents) · [Developer tools and automation](#developer-tools-and-automation) ·
[Themes, start page and settings](#themes-start-page-and-settings) · [Accessibility](#accessibility) · [Sync, backup and other devices](#sync-backup-and-other-devices) · [iPhone and iPad](#iphone-and-ipad)

### First minutes

1. **Open it.** A blank tab shows the start page: a search field, your favorites, a card to carry on where you were, and places you go often. Type to search or enter an address.
2. **Press ⌘K** for the command palette. Almost everything in this list is a command there, so you never have to remember where a thing lives.
3. **Choose a look** in Settings › Appearance: a layout (Classic, Sidebar, Minimal, Floating, One Row), a theme, and the buttons you want in the toolbar. **⌥⇧⌘0** always restores the standard layout.
4. **Privacy is on from the first page.** Ads and trackers are blocked, links are cleaned, plain-HTTP addresses are upgraded, and nothing leaves the device unless the [table below](#what-leaves-your-device) says so.

### Layouts, windows and tabs

- **Layouts (Mac).** Classic (tabs across the top, standard toolbar), Sidebar (tabs down the side, address bar in the sidebar), Minimal (one slim tab row), Floating (no bar: a pill shows
  the site, a search button opens the address bar, tabs slide in from the edge), One Row (tabs as icons beside the address field) and Custom. Each is a preset over a few switches
  (sidebar side, rail, auto-hide, single toolbar), so you can also set them one by one. A small handle appears whenever something essential would otherwise only show at a window edge.
- **Toolbar buttons (Mac).** In Classic, Minimal and One Row you choose the buttons in Settings › Appearance › Toolbar: sidebar, back and forward, reload, share, bookmark, new tab, tab overview,
  downloads, **workspaces**, **profile**, **split view**, history, bookmarks, find and the command palette. The bar fits as many as the window is wide and drops the optional ones in a fixed order;
  the More menu always has the rest.
- **Tabs.** Pinned tabs, groups with colours, drag to reorder, close with a middle click, tab overview with search and sorting, session restore with lazy loading, and Reopen Closed Tab.
  Give any tab a name, a colour or a note; see which tab opened which in a tree; group all tabs by website; find and close duplicates; open a **scratch tab** that keeps no history and
  leaves nothing behind.
- **Workspaces.** Switch whole sets of tabs (Work, Research, Personal…) with the workspace button, the Workspace menu or the sidebar. Each workspace can have its own accent colour,
  its own layout (applied when you open it) and, if you like, its own set of extensions. Deleting one moves its tabs to Personal. Settings › Tabs lists them as rows with swatches.
- **Several windows (Mac).** ⌘N opens another window; each has its own tabs, layout and workspace and they are all brought back at the next start. Right-click a tab › Move to Window, or **drag a tab
  from one window's tab bar or sidebar onto another's**: it moves with its page, history and place, and a window left with no tabs closes. **File › New Guest Window** (⌥⇧⌘N) opens private tabs only,
  keeps nothing and is not restored.
- **Split view (Mac).** Two to four pages in one window: two share it **exactly 50-50**, three are one tall page with two stacked beside it, four are a **2×2 grid**; or stack them instead of side by side.
  Start it from the Split View button in the toolbar, the Split View menu, the More menu, or right-click a tab › Open in Split View (then Add to Split View as a Panel). Drag the divider between two panels
  to resize them (double-click it to make them equal again), click a panel to make it the active one, swap panels or close the split from the same places. Every page in a panel stays loaded and is
  never put to sleep. Save the pair as a template to reopen it later.
- **Focus mode** drops the toolbar and card for an edge-to-edge page.
- **Memory.** Tabs you are not using give their memory back in Balanced, Saver or Performance mode, and the app tells you which tabs are asleep and why. A **never-sleep list** keeps chosen sites awake;
  **Put all other tabs to sleep** respects it. A sleeping tab keeps its title, address, history and scroll position and reloads when you open it.
- **Saved sessions** keep the tabs, their pinned state, each page's place in it and the workspace; open one with `/open` or from the Library menu.
- **Containers** keep one site's cookies and logins apart from the rest inside a profile, **profiles** keep everything apart, and **site rules** open a site where you want it (a private tab, a container,
  a group or a workspace) before it loads.

### Address bar, search and commands

- **One bar for everything.** It suggests from your own open tabs, bookmarks and history first (computed on the device), then page text you chose to keep a searchable copy of, then your search engine
  (suggestions are off until you turn them on). The search-engine menu sits in the bar; add your own engine, and search shortcuts such as `g cats` or `yt cats` use one engine for one search.
- **Answers.** Type a sum (`12 * (3 + 4)`, `15% of 80`, `sqrt(2)`) or a conversion (`5 km to miles`, `72 f in c`, `1 gb to mb`) and the answer appears under the first row; Return copies it. Worked out on the device, no currency.
- **Slash commands.** `/tabs`, `/close`, `/find`, `/group`, `/sleep`, `/duplicates`, `/save`, `/open`, `/workspace`, `/forget`, `/private`, `/scratch`, `/note`, `/split`, `/restore`: type a slash to see them, each
  explained as you type. Nothing runs until you press Return.
- **Search across all open tabs** (⇧⌘F, or `/find`) reads the text of every loaded page and finds tabs that are asleep through the saved copy of pages you read. It **forgives typos**
  ("kuberntes cluser" finds "Kubernetes cluster"), lists exact matches first and marks close ones "similar", and switching to a result finds the words in the page.
- **Command palette (⌘K).** Every command, every open tab, bookmarks and settings in one list; type `>` in the address bar for the same. **Workbench › Search** searches tabs, bookmarks, history,
  downloads, research and notes together.
- **Vim keys (optional).** j, k, gg, G, H, L and more, with an editable keymap. They act only when no text field has the keyboard.
- **Mouse gestures (Mac, off by default).** Hold the middle button and drag: left is back, right forward, down a new tab, down then right close, up scrolls to the top, and so on. The map is editable in Settings › Advanced.
  A middle click that does not move still opens a link in a new tab.
- **Selection actions.** Select words and search them with any engine from the command palette or Selection Actions…, which also shows details found in the selected text.

### Keyboard shortcuts

Every one can be changed in Settings › Shortcuts. The defaults:

| | |
|---|---|
| New tab / private tab / close / reopen | ⌘T / ⇧⌘N / ⌘W / ⇧⌘T |
| Open location / command palette / paste and go | ⌘L / ⌘K / ⇧⌘V |
| Back / forward / reload / stop | ⌘[ / ⌘] / ⌘R / ⌘. |
| Next / previous tab / select tab 1–9 | ⇧⌘] / ⇧⌘[ / ⌘1–⌘9 |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Find in all tabs / search tabs / tab overview | ⇧⌘F / ⇧⌘A / ⇧⌘\ |
| Bookmark / bookmarks / history / downloads | ⌘D / ⇧⌘B / ⌘Y / ⇧⌘J |
| Toggle sidebar / focus mode / restore standard layout | ⇧⌘L / ⌥⌘F / ⌥⇧⌘0 |
| Reader / share / print | ⇧⌘R / ⇧⌘S / ⌘P |
| Zoom in / out / actual size | ⌘+ / ⌘- / ⌘0 |
| New window / new guest window | ⌘N / ⌥⇧⌘N |

### Privacy and security

- **Content blocking.** Ads, trackers and session-recording scripts are blocked with WebKit's content-rule engine at three levels (Light, Balanced, Strict). A small starter list ships in the app; about 90 public
  lists are optional downloads, fetched straight from their publishers only when you press Update (or turn on automatic updates, which is off by default). WebKit does not report blocked counts, so none is shown.
- **Cleaner links and pages.** Tracking parameters are stripped from links (Copy Clean Link does the same); plain-HTTP addresses are upgraded to HTTPS; **De-AMP** sends links through Google's AMP cache to the site's
  own page, and replaces an AMP page that names its own full version.
- **No videos or sound starting by themselves (on by default).** A page can start media only after a real tap or key press (and for six seconds after one, so the page you open by tapping can start its own player), not
  while you scroll. On a phone a scroll counts as a touch to WebKit, which is how a feed such as YouTube's could start videos as you scrolled. Playlists and "Autoplay next" wait for a tap, and a site that needs to
  play by itself (a voice-chat page, say) can be allowed in Site Privacy or with Repair This Page.
- **Fingerprint randomizing (off by default).** Small, per-site changes to what canvas, WebGL read-back, audio and the processor count report, different for every site and every start, so a site cannot
  recognise this device by them. Each site has its own off switch for the few pages that draw pictures.
- **YouTube ad skipping (off by default).** Hides the ad slots, presses Skip, and mutes and jumps past an ad that cannot be skipped. It watches the player instead of blocking requests, so a change on YouTube's
  side can stop it, and it is not tried on youtube.com yet.
- **Per-site controls.** JavaScript off for one site, never-sleep, zoom, notes, your own style sheet, a browser identity (user agent), WebRTC exceptions. A **style sheet for every website** applies CSS everywhere
  (hide a cookie banner, say), with a site's own sheet on top.
- **Private tabs** use a separate, non-persistent store: no history, no session, no saved sign-ins, no extensions, no scripts of yours, and nothing in them is read by the browser's own tools.
- **Permissions.** Camera, microphone and location are asked for per site: Allow, Allow for an Hour, Allow for This Session or Always Allow (which itself expires). A log shows who asked for what and what you
  said. Insecure pages are always refused.
- **Site privacy page** (the lock beside the address, or the command palette): what the site stored (its cookies, third-party cookies by owner, storage), its permissions, how it sees you, how safe its
  connection looks (certificate chain, redirects, mixed content), and **Forget This Site Completely**. Automatic-deletion rules clear a site when its last tab closes or at every start.
- **Who is on the other end.** The certificate is read for the organisation it names. A site whose certificate names a checked organisation shows that name beside the address (green); a certificate that only
  proves the domain says "Encrypted, owner not verified". The lock's tooltip and the site info popover say the same in full.
- **WebRTC switch** (stops pages learning this device's network address), a **proxy** for page loads (HTTP or SOCKS5; it is not a VPN), a **threat list** of hosts you import (a warning before those pages load), and a
  **download scanner** that warns about risky file types and files whose contents do not match their name.
- **Sensitive-settings lock** (Touch ID or password) in front of saved sign-ins, extension changes and similar; it refuses when the device cannot authenticate instead of opening.
- **Clear on quit**, **safe start** after repeated crashes (tabs return but none loads), an in-app **health check**, and a **privacy dashboard** that shows what is on and what was cleaned.

### Passwords

- **Save and fill.** After you sign in, the browser offers to keep the password in your Keychain, on this device, for this profile. Filling asks for Touch ID or your password, only happens on the exact site,
  never over plain HTTP and never in a private tab. The browser reads the form just before it is sent; pages cannot send it anything. Sign-ins that never reload the page can be missed.
- **Check Passwords for Leaks** (Settings › Websites › Saved Sign-ins, behind Touch ID): each password is hashed on the device and only the first five characters of the hash go to haveibeenpwned.com, so no
  password, whole hash, site or user name leaves. It also flags a password used on more than one site. Nothing is stored from the answer.
- **Sign-in boxes** that websites show (HTTP authentication) are remembered per site, realm and method.
- **Import** passwords and history from Chrome, Firefox, Apple's Passwords and Safari (their exported files).
- **Limits.** Browser Setu cannot use Safari's iCloud Passwords (Apple does not allow it for other browsers), and there are **no passkeys yet** (Apple must grant browsers the permission).

### Extensions

- Web extensions through WebKit's own support (macOS 15.4 or later, and iOS 18.4 or later). Add from a folder, a `.crx` or `.zip`, or a Chrome Web Store address. Every install shows what the extension
  asks for, warns about what Apple's support does not offer, and installs from a private copy that is hashed before and after, so what you approved is what runs.
- A permissions screen per extension: switch any permission off, restrict to "on click", specific sites or all sites, and see a history of changes. Per-site allow and block rules; pin extensions to the toolbar.
- Tools: conflict detection (shortcuts, request blocking, restyling, new-tab pages), presets (Cautious, Balanced, Open), what changed in the last update, go back to the previous version, per-workspace extension sets,
  a throwaway-profile load test with a score, and a backup of the installed files.
- **Limits.** VPN and privacy-API extensions cannot work (WebKit has no proxy or privacy APIs). Native messaging (password managers' helper programs) is written but switched off until Chrome package signatures are
  verified. Real Dark Reader, uBlock Origin Lite, Vimium and Bitwarden/1Password packages were fetched for a compatibility report ([`docs/extension-compatibility.md`](docs/extension-compatibility.md)): "loads" is not "works",
  and password managers have not been tried end to end. On iPhone only one sample extension was tried.

### Reading, research and page tools

- **Reader** (⇧⌘R) for clean text, a **reading list** with offline copies, highlights and page notes, and "restore what I was typing" for forms.
- **Research collections.** Save pages, highlights (each with a citation: title, address, author, dates), notes and PDFs; save an **offline PDF copy** of a page; add a note anchored to a selected passage and jump back to it;
  export to Markdown, HTML or PDF; copy a citation as plain text.
- **Page Tools** (Library › Page Tools): **Images** (save, copy), **Tables** (export as CSV), **Documents** (links to files), **Outline** (jump to a heading), **Details** (dates, phone numbers, addresses found
  in the text, with a system detector), **Video** (speed, Picture in Picture, full screen), **Text**, **Versions** and **Listen** (the page read aloud with the system voice, following along on screen).
- **Page versions and price watch.** Keep a page's text and see what changed on your next visit, with price-drop detection and scheduled checks.
- **Search My Pages.** Optionally keep a searchable copy of the pages you read (on the device, never from private tabs); it feeds the address bar and the all-tabs search.
- **Shopping.** Compare products, keep coupons, and track subscriptions with the monthly and yearly cost.
- **Also:** text from pictures (Vision, on device), translate a page on the device, a QR code for a page, Repair This Page (infinite-scroll and broken-layout helpers), remember where you stopped reading, and Request Mobile Website.

### Downloads, PDFs and documents

- **Downloads you can see.** A card at the foot of the window shows progress while a file downloads, the Downloads button fills a ring and the Dock icon shows the percentage; when it finishes a card says
  "Downloaded" with Show in Finder and All Downloads (a file that can run code carries its warning in the same card instead of a box you have to dismiss).
- **Downloads.** Resumable, with a queue (priorities, hold until a time, pause and resume all, retry with back-off) that survives a restart, an optional sort into folders by kind, **rules by site and kind**,
  a duplicate finder, preview, share and reveal in Finder. A page's own "Download" button that hands over a `data:` or `blob:` file works: it is saved, never run as a page. Progress shows on the Dock icon.
- **PDF editor.** Open a downloaded or chosen PDF: highlight, draw, type, add shapes; rotate, delete, reorder, extract and merge pages; **sign** with a drawn, typed or picture signature kept in the Keychain behind Touch ID;
  **redact** (the words are removed from the file, not just covered); save a password-protected copy. A signature is a picture or text placed on the page, **not a certificate-based digital signature**.
- **Other documents** (Word, Excel, Pages…) open in a preview. Take a picture of the page (visible part or the whole page), or save it as a web archive.

### Developer tools and automation

- **Developer tools** (Workbench): load numbers, a resource waterfall and **HAR export** built from the page's Resource Timing, a storage inspector (secrets masked), uncaught page errors, a JavaScript scratchpad (isolated world,
  never in private tabs), an **element picker** (its selector, size, styles and HTML), **window-size presets** with a live size readout, and a switch that lets Safari's Web Inspector attach.
  WebKit gives pages no request headers, response bodies or `console.log` output, so those are not available, and there is no network throttling (WebKit cannot do it).
- **Automation.** Workflows of fixed, safe steps (open, search, run a command, wait), `browsersetu://` links (open, search, command, workflow), Shortcuts actions, and scheduled page checks that run while the app is open.
  A workflow started from a link asks first. A permission store for scripts exists; there is no script runtime yet.

### Themes, start page and settings

- **Themes.** Eleven moods (Slime Night, Blood Moon, Synthwave, Aurora, Paper, Arctic and more) and ten classic palettes (Dracula, Nord, Gruvbox, Solarized, Catppuccin, Tokyo Night, Rosé Pine, One Dark…), drawn in
  code with no downloaded art, painted under the **whole window including the title bar**. Make your own **Custom** theme (two background colours, an accent, optionally a photo whose main colour becomes the accent, with a
  warning when an accent is hard to see). **Import and export theme files** (colours only, so they are safe to share), or turn any theme into your Custom one to adjust it.
- **The toolbar takes the page's colour** (Settings › Appearance › Layout). It reads the page's theme colour, or its background when it names none. Under a theme the page adds a lighter touch; a colour that would
  clash with the window (a white page in a dark window) adds only a faint wash.
- **Start page.** Native and quick: a greeting, a search field, favorites (an empty row says how to fill it), a Continue card, often-visited and recently closed places, tabs on your other devices and tabs sent to this one.
  **Customize** slides a panel in from the right without leaving the page: theme, accent, what shows, icon size, search engine; it applies the moment you touch it and there is nothing to save.
- **Settings** (Mac: a toolbar of panels, with a search field that opens the right panel; iPhone: topics): General, Appearance, Tabs (layout, split view and windows help, groups, workspaces), Search, Privacy, Websites,
  Profiles, Performance, Extensions, Shortcuts, Advanced. Changes apply as you make them and are shared by every window.

### Accessibility

- Icon-only buttons have spoken labels; text follows the text-size setting on iPhone and iPad (capped so bars do not break); outlines get stronger with Increase Contrast; animations are skipped with Reduce Motion;
  the start page's tiles show a focus ring when the keyboard reaches them. **This has not been audited with VoiceOver or Accessibility Inspector.**

### Sync, backup and other devices

- **iCloud sync** (App Store and TestFlight builds; Apple allows it for those only), sealed with your own passphrase before it leaves the device, so Apple stores only scrambled bytes. You choose **what to sync, one switch
  for each**: bookmarks, workspaces, saved sessions, open tabs, settings and themes, site rules and styles, **history** (the 800 most recent pages, and deletions; off by default) and passwords (off by default).
  Switching one off sends nothing, takes nothing in and deletes nothing on your other devices. Two devices that edit the same thing end up the same, in any order; a deletion is remembered, not undone.
  New devices wait for your approval, devices are grouped by a sync group name, and a status row says exactly what is wrong (not signed in, needs a passphrase, devices waiting, space nearly full, last sent and received).
- **Send a tab to another device** from the tab menu, the More menu or the palette. It arrives once, as a web address only, and shows on that device's start page.
- **Tabs on your other devices** are listed, never opened by themselves. **Wi-Fi sync** and **Send to Another Device** work straight between your own devices with a one-time 100-bit code and no server.
- **Handoff and Spotlight.** Hand the page in front to your other devices, and find your bookmarks from Spotlight (both off for private tabs, history, passwords and page text).
- **Encrypted backup file** of bookmarks, settings and research (passphrase-sealed; passwords, cookies and history are never in it) and **bookmark import and export** in the standard HTML format.
- **Not run between two real devices yet:** the tests run two in-process browsers, so please report anything odd.

### iPhone and iPad

- A phone has no toolbar: a dock of three pills, a search button, and an address bar that opens in place when you tap it. The page keeps clear of the status bar and the dock, and a page without fixed bars gets
  a transparent top.
- The same privacy, passwords (with Face ID), sync, themes, start page with the Customize panel, PDF editor, page tools, address-bar answers, sent tabs and settings, as above. Extensions install and run from the More
  menu (iOS 18.4 or later). There is a speed-pill widget and Shortcuts actions.
- **Mac only:** several windows, guest windows, split view, mouse gestures, the sidebar layouts and the Workbench developer tools.

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
