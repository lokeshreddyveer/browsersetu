<p align="center">
  <img src="docs/brand/browser-setu-icon.svg" alt="Browser Setu" width="112" height="112">
</p>

<h1 align="center">Browser Setu</h1>

<p align="center"><b>A native, privacy-first web browser for Mac, iPhone and iPad.</b><br>
Apple's own WebKit, a small Rust core, a SwiftUI interface. No accounts, no analytics, no telemetry.</p>

<p align="center">
  <a href="../../releases"><img alt="Download" src="https://img.shields.io/badge/download-notarized%20DMG-0A84FF?style=flat-square&logo=apple&logoColor=white"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS%20%26%20iPadOS-17%2B-000000?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Rust" src="https://img.shields.io/badge/core-Rust-DEA584?style=flat-square&logo=rust&logoColor=black">
  <img alt="WebKit" src="https://img.shields.io/badge/engine-WebKit-1E90FF?style=flat-square&logo=safari&logoColor=white">
  <img alt="No telemetry" src="https://img.shields.io/badge/telemetry-none-2EA44F?style=flat-square">
</p>

<p align="center">
  <a href="#download">Download</a> ·
  <a href="#layouts">Layouts</a> ·
  <a href="#highlights">Highlights</a> ·
  <a href="#whats-new">What's new</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#documentation">Docs</a>
</p>

---

## Download

| Platform | Requirements | Where |
|---|---|---|
| **Mac** | Apple Silicon, macOS 14 or later | the notarized DMG on the [Releases](../../releases) page; it updates itself (see [Updates](#updates)) |
| **iPhone and iPad** | iOS 17 or later | TestFlight |

Web extensions need macOS 15.4 / iOS 18.4 or later; the on-device page summary needs macOS 26 / iOS 26.

## Layouts

Choose how the window is laid out in first-run Setup or any time in Settings. Every layout keeps the same tabs, pages and settings, so switching never reloads anything. **⌥⇧⌘0** always brings back the standard layout.

| Group | Layouts |
|---|---|
| **Everyday** | **Classic**: a tab strip and a standard toolbar · **Minimal**: a compact strip of small tabs · **One Row**: tabs and address in a single row |
| **Organized** | **Sidebar**: tabs and the address bar in a sidebar · **Hybrid**: a sidebar for tabs with a full toolbar over the page |
| **Immersive** | **Floating**: no bar, a small pill, tabs slide in from the edge · **Canvas**: only the page, address on ⌘L, tabs on ⇧⌘A |
| **Productivity** | **Research Desk**: two pages side by side with a slim tab rail · **Workspace Deck**: every workspace listed, then its tabs |

## Highlights

| | |
|---|---|
| 🛡️ **Private by default** | Ads, trackers and session recording are blocked, links are cleaned and plain-HTTP addresses are upgraded from the first page. A shield card shows what was blocked. |
| 🗂️ **Tabs that stay organized** | Workspaces, pinned tabs, Essentials, tab groups, split view and a tab overview, the same in every layout. |
| ⌘ **Command palette** | Press **⌘K**: almost everything in the app is a command there. Every shortcut can be changed in Settings. |
| 🔑 **Passwords** | Kept in your Keychain. Filling asks for Touch ID, happens only on the exact site and never in a private tab. |
| ⬇️ **Downloads** | A queue you control, multi-connection downloads, torrents and magnet links, and optional video tools you choose to install. |
| ☁️ **Sync** | iCloud sync sealed with your own passphrase, one switch per kind of data. |
| 🧩 **Extensions** | WebKit web extensions from a folder, `.crx`, `.zip` or a Chrome Web Store address, with a permissions screen for each. |
| ♿ **Accessibility** | Spoken labels, text-size support on iPhone and iPad, Increase Contrast and Reduce Motion. |

The full list, with details for every feature, is in [`docs/features.md`](docs/features.md).

## Why it is built this way

- **System WebKit.** Low memory and battery use, and Apple's own security updates.
- **A small Rust core** (`core/`): tabs, address-bar logic, navigation and permission policy, and per-profile SQLite, exposed to Swift through UniFFI.
- **Untrusted pages.** Web pages have no bridge to the core; every navigation goes through a core policy. Threat model: [`docs/security/threat-model.md`](docs/security/threat-model.md).
- **Everything stays on your device** unless the next section says otherwise.

## What leaves your device

Browser Setu has no accounts, no analytics and no telemetry. The page you load goes to its site; search suggestions (off until you turn them on) go to your search engine; the downloadable Mac build checks for updates daily (you can turn that off); content-blocking lists come from their publishers; and a few actions you start yourself (a leak check, a currency conversion, a Chrome Web Store install, a large download) contact only the service named. The complete table is in [`docs/features.md`](docs/features.md#what-leaves-your-device).

## Optional video tools

Browser Setu does **not** include video downloaders or media converters in the app or the DMG. They are optional downloads that you choose, in the skippable step of first-run Setup or later in
Settings › Media, where they are called the **Video download tool** and the **Media processing tool**:

| Tool | Program | Version | Used for |
|---|---|---|---|
| Video download tool | yt-dlp | 2026.10.26 | finding a video's formats on more sites so you can pick the quality |
| Media processing tool | ffmpeg and ffprobe | 9.0.2 | converting, merging and extracting the sound of what you download |

- **Consent first.** The size is shown before anything is downloaded, nothing is installed silently, and a video window that needs a missing tool asks first. You can update, repair or remove each tool in Settings.
  Without them, browsing, ordinary downloads, streams and torrents work as before.
- **Checked before use.** Each tool is a separate package signed with the publisher's Developer ID and notarized. The app checks its package digest, every file, signature, Team ID, notarization and processor type
  against fingerprints built into the app before it keeps or runs it, keeps it in its own folder, and can roll back.
- **YouTube's JavaScript puzzles** are solved by a small runner built into the app (Apple's JavaScriptCore, in its own process under the App Sandbox with no network or file access), so no Deno or Node has to be installed.
  If it is ever unavailable, downloads still work but some YouTube formats may be missing. No website is guaranteed to work.
- **Licences and source.** The video download tool contains GPL and LGPL parts; ffmpeg is built LGPL-only. Notices and written offers are in Settings › Acknowledgements and the app's Notices folder, and the complete
  corresponding source is published at the [`sources-0.4.1-build24`](../../releases/tag/sources-0.4.1-build24) release. MP3 encoding in the app uses LAME 3.100 (LGPL-2.1) as a separate library you can replace.
- **The decision is permanent:** [`docs/decisions/0001-media-tools-optional-downloads.md`](docs/decisions/0001-media-tools-optional-downloads.md). How the packages are built, signed, hosted and checked: [`docs/media-tools.md`](docs/media-tools.md).

## What's new

### New in 0.4.3

- **Four new layouts.** Hybrid, Canvas, Research Desk and Workspace Deck, grouped with the others under Everyday, Organized, Immersive and Productivity.
- **Tab groups in every tab strip.** Groups now show inline in Classic, Minimal and One Row, with colour, collapse and drag in and out.
- **A calmer sidebar.** Workspaces, search and Essentials stay in place while pinned tabs, open tabs and groups scroll together. Floating's sidebar also opens from the keyboard.
- **Full screen keeps your toolbar**, and Esc leaves it when nothing else is open.
- **Private tabs are marked in every layout**, and moving a tab between windows keeps its privacy.
- **iPad and iPhone.** The iPad sidebar steps aside in narrow windows; every iPhone layout reaches all your tabs from the menu.

Earlier releases: [`docs/releases/`](docs/releases/).

## Updates

The App Store and TestFlight builds update through Apple. The downloadable Mac build includes [Sparkle](https://sparkle-project.org): it checks [`appcast.xml`](appcast.xml) once a day, asks before installing, and refuses any update that is not signed with the publisher's key. Turn automatic checks off in Settings › Advanced › Updates, or use **Browser Setu › Check for Updates…**.

## Build from source

Requires Xcode, Rust (the toolchain is pinned in `core/rust-toolchain.toml`) and XcodeGen (`brew install xcodegen`).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-xcframework.sh                   # Rust core -> XCFramework + Swift bindings
cd apps/apple && xcodegen generate
xcodebuild -scheme BrowserSetuMac build        # sandboxed Mac build, no updater (App Store)
xcodebuild -scheme BrowserSetuMacDirect build  # the downloadable build, with Sparkle
xcodebuild -scheme BrowserSetuiOS -destination 'generic/platform=iOS' build
```

Tests: `xcodebuild -scheme BrowserSetuMac test -only-testing:BrowserSetuMacTests`. UI and iPhone tests use `scripts/testserver.py`.
Releasing: `scripts/release.sh <version> <build>` signs with Developer ID, notarizes, staples and makes the DMG; `scripts/publish-release.sh` uploads it and adds it to the update feed; `scripts/testflight.sh` archives and uploads the iPhone build.

```
apps/apple/   SwiftUI apps (macOS + iOS): Shared/ (engine-neutral code), Engines/WebKit/, macOS/, iOS/, tests
core/         Rust workspace: domain (pure logic), storage (per-profile SQLite), ffi (UniFFI surface)
Packages/     SetuPrivacyKit: content-blocking policy builder and the WebKit rule installer
docs/         features, layouts, threat model, decisions, release notes, privacy notes
scripts/      build, release, publish and TestFlight scripts, release checks
```

## Documentation

| Read this | For |
|---|---|
| [`docs/features.md`](docs/features.md) | everything the app does, in detail, plus the privacy table |
| [`docs/layouts.md`](docs/layouts.md) | every layout and how it is built |
| [`docs/security/threat-model.md`](docs/security/threat-model.md) | the security model |
| [`docs/media-tools.md`](docs/media-tools.md) and [`docs/decisions/`](docs/decisions/) | the optional video tools and the decisions about them |
| [`docs/releases/`](docs/releases/) | release notes |
| [`docs/compliance/`](docs/compliance/) and [`docs/privacy/`](docs/privacy/) | licence, source and privacy records |

## Support

Questions, bug reports and requests for the corresponding source of a redistributed component: open an issue at <https://github.com/lokeshreddyveer/browsersetu/issues>.

## Licence

Copyright © 2026 Lokesh Reddy Veerabhadra. The source is published so you can read and audit it; all rights are reserved and no licence to reuse it is granted. Third-party components keep their own licences (Sparkle is MIT; the others are listed in Settings › Acknowledgements). If you want to use the code, ask.
