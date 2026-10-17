# Extension compatibility: what was actually tried

Run on 16 October 2026, macOS 27.0 (build 26A5425a), Apple Silicon, Browser Setu Debug build. WebKit comes from the system.

The packages were downloaded from the Chrome Web Store with the same request the app makes. The report is `Tests/RealExtensionCompatibilityTests.swift`; it
does nothing unless `BS_COMPAT_DIR` names a folder of `.crx` files:

    TEST_RUNNER_BS_COMPAT_DIR=/path/to/crx-folder xcodebuild test -scheme BrowserSetuMac -only-testing:BrowserSetuMacTests/RealExtensionCompatibilityTests

## What the report does and does not check

- **Does:** unpacks the package, loads it with WebKit, installs it into a throwaway profile, lists what WebKit reports and what Browser Setu's own check
  says, and compares a blank web page with and without the extension (attributes on `<html>`, number of style sheets).
- **Does not:** open a popup, press a button, sign in anywhere, block a real network request, or measure memory and CPU. Those columns are therefore empty
  rather than guessed.

A class is given only where the evidence supports it. **Compatible** needs the extension to load, change a page and have a working popup; none of the
below has had its popup exercised in an automated run, so none is marked Compatible yet.

## Results

| Extension | Version | Manifest | Loads and installs | Effect on a page | Popup / settings | Class |
|---|---|---|---|---|---|---|
| Dark Reader | 4.9.133 | V3, service worker | Yes, no WebKit errors | Yes: a style sheet was added to the page | Not exercised | Partially verified (runs on pages; popup untested). Our check flags `fontSettings` |
| uBlock Origin Lite | 2026.1012.1545 | V3, service worker | Yes, no WebKit errors | None seen, as expected: it blocks requests and edits no page | Not exercised | Not verified. Blocking itself was not tested. Our check flags `offscreen`, `userScripts` |
| Vimium | 2.4.2 | V3, service worker | Yes, no WebKit errors | None seen, as expected: it reacts to keys | Not exercised | Not verified. Our check flags `bookmarks`, `history`, `sessions`, `search`, `favicon`: those features will not work |
| iCloud Passwords | 3.4.0 | V3, service worker | Yes, no WebKit errors | None | Popup opens but cannot get its code | **Unsupported** in the sandboxed build: it needs Apple's Passwords helper (native messaging). Observed by hand, plus the code review |
| Surfshark VPN | not captured | not captured | Yes, no WebKit errors (installed by hand) | not tested | Popup stays on its splash screen | **Unsupported**: it asks for `proxy`, `privacy`, `webRequestAuthProvider` and `browsingData`, none of which WebKit offers. Observed by hand |
| Bitwarden | not obtained | | | | | The store returned no package for the id tried |

A file saved as `surfshark.crx` for the automated run turned out to be the wrong id (it is HackBar 1.2.8, a different extension). It loads and installs
with no warnings, and was not tested further. It says nothing about Surfshark.

## Known limits

- "Loads" is not "works". Each extension needs its popup and its main feature tried by hand before it is called Compatible.
- Memory and CPU were not measured.
- Results are for this macOS build only. WebKit's extension support changes between releases, so the report should be re-run after system updates.
