# Verification status

Engine: WebKit (macOS + iOS). Last full run: Rust 20/20, SetuPrivacyKit 25/25, macOS 90 unit/hardening/privacy/layout/omnibox tests, iOS simulator 50 unit-test executions + 4 UI tests, iOS device SDK builds. Mac keyboard-driven UI tests have NOT run since the privacy work (see below).

Classification: **alpha, integration-tested, not release-qualified.**

## How to run

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer PATH=$HOME/.cargo/bin:$PATH
(cd core && cargo fmt --check && cargo clippy --all-targets && cargo test)   # 21 tests
scripts/ffi-smoke.sh                                                          # Rust -> Swift
scripts/build-xcframework.sh && (cd apps/apple && xcodegen generate)
python3 scripts/testserver.py 18765 &                                         # fixture server
(cd apps/apple && xcodebuild -scheme BrowserSetuMac test -only-testing:BrowserSetuMacTests)   # 44 unit/hardening/performance
scripts/run-ui-tests-when-idle.sh                                             # keyboard-driven UI tests
```

Sandbox enforcement must be checked on a container no Xcode test session has touched
(see the header of `scripts/sandbox-check.sh`):

```sh
xcodebuild -scheme BrowserSetuMac -derivedDataPath /tmp/dd2 PRODUCT_BUNDLE_IDENTIFIER=com.browsersetu.probe build
scripts/sandbox-check.sh "/tmp/dd2/Build/Products/Debug/Browser Setu.app" com.browsersetu.probe
```

## Results

| Area | Result | Notes |
|---|---|---|
| Rust core (fmt, clippy, 21 tests) | PASS | corrupt / newer-schema DBs stay byte-identical; groups, pins, workspaces, reorder persist |
| Rust -> Swift FFI | PASS | |
| Sandbox entitlements and enforcement (clean container) | PASS | re-checked after the interface work; Documents/Desktop blocked, no writes outside container |
| Sandbox inside Xcode's test host | NOT MEASURABLE | see `scripts/sandbox-check.sh` |
| Page load, history, back/forward/reload, bookmarks, tabs, session restore | PASS | |
| Downloads: completion, cancel, collisions, name sanitising | PASS | |
| Profile isolation, private browsing, permissions, tracker blocking | PASS | |
| Corrupt / newer database recovery | PASS | |
| Renderer-crash handler | PARTIAL | our handler tested; a real crash cannot be induced from the sandbox |
| HTTPS upgrade | PARTIAL | setting verified, live upgrade not exercised |
| Layout presets and resolver, sidebar width clamp, per-profile layout settings | PASS | unit tests |
| Web views survive every layout change, focus mode and overview | PASS | identity asserted in a test |
| Workspaces (create, rename, delete, move, persist, layout) | PASS | profile data unaffected |
| Tab reordering (UI order and core order) | PASS | |
| Split view ownership model and privacy rule | PASS | one live view per panel; private tabs cannot join a normal split |
| Command palette, fuzzy match, reopen closed tab, omnibox keyboard selection | PASS | unit tests; dangerous schemes never suggested |
| Performance: 40-tab switch ~1.3 ms, 40 layout changes ~1.7 ms; memory after closing 30 tabs bounded | PASS | measured, no "before" baseline exists to compare against |
| Keyboard-driven UI tests (address bar, tabs, bookmark, overview, suggestions, sidebar, palette, find, focus mode) | SEE BELOW | cannot run while someone is using the Mac |
| Visual check of sidebar rail, right-side sidebar, split view, focus mode, site info popover, settings window | NOT TESTED | built and compiled; not inspected in a real window |
| iOS compile (simulator + device SDK) | PASS | |
| iOS app runs; phone and iPad layouts render; iOS unit and UI tests | PASS | iOS 27 simulator; iPad seen in screenshot, not driven |
| GitHub CI | NOT TESTED | never executed |

## VayuSetu privacy integration (SetuPrivacyKit)

| Area | Result | Notes |
|---|---|---|
| Rule models, validation, parsing, precedence, snapshots | PASS | 20 package tests |
| WebKit accepts every rule shape we emit (all three modes, exceptions, user rules) | PASS | real `WKContentRuleListStore` |
| Identical rules reuse the compiled list; invalid rules keep the previous list installed | PASS | |
| Ads/trackers blocked in real pages; normal resources load | PASS | local server logs what actually arrived |
| Site exception lifts list blocks on that site only; user deny outranks exception; user allow outranks list | PASS | order verified against real WebKit |
| Private tabs, existing tabs and new tabs protected; first page load already filtered | PASS | |
| Strict: third-party tracking-endpoint requests blocked, Standard lets them through | PASS | |
| Strict: third-party cookie rule installs | PASS (install only) | its effect is not separately measurable: WebKit already refuses third-party cookies |
| Failed / garbage / HTTP list downloads leave protection unchanged | PASS | |
| Settings persist; isolated per profile; legacy "trackers off" carried over; corrupt config repaired | PASS | |
| No telemetry/analytics code; only the list updater, the opt-in search suggestions, the opt-out site icons and the user-started Chrome Web Store download use `URLSession`; no VPN/DNS/NetworkExtension | PASS (as of 16 Oct 2026) | static scan of the real sources (`PrivacyIntegrationTests`); the proxy setting pauses all of these but the page loads |
| Sandbox entitlements narrow; sandbox enforced on a clean container | PASS | |
| "Protected by VayuSetu" only when installed and complete | PASS | unit-tested state machine, and seen in a real window (on and off) |
| Simplified popover (shield, status, Light / Balanced / Strict only) | BUILT, NOT SEEN | compiles; level change, persistence and web-view preservation are tested; not yet viewed in a real window |
| Light = ad hosts only; Balanced = ads + trackers; Strict adds extras; old saved "standard" loads as Balanced | PASS | package + integration tests |
| Filter-list, rules, exceptions, diagnostics sheets | NOT TESTED visually | now reachable from Settings only |
| Mac keyboard UI tests for the shield and popover | NOT RUN | need an idle Mac |
| Upstream list licences | NOT VERIFIED | nothing third-party is bundled; see `docs/privacy/THIRD-PARTY-LISTS.md` |
| VayuSetu consuming the shared package | NOT DONE | files are copies; `scripts/check-privacy-kit-drift.sh` detects divergence |

Measured (this machine, app process only, no "before integration" baseline exists):
compile + install of 40,000 domain rules ≈ 180 ms and parse/build ≈ 1.7 s; model start ≈ 3–8 ms either way;
page load ≈ 190 ms with protection off and ≈ 180 ms on (5-load averages, local server); +0–1 MB for 20 blank tabs.
A cache hit skips recompilation.

## Interface redesign (macOS)

| Area | Result | Notes |
|---|---|---|
| Omnibox: native AppKit field, delegate wiring (focus, typing, backspace, page updates never overwrite typing, Escape, Return, suggestions, arrow keys, tab switch while editing) | PASS | 12 tests drive the real field's delegate entry points |
| Real key-by-key typing, paste, select-all | NOT RUN | needs a live field editor, which only exists in an active app; covered by the idle-Mac UI tests |
| Omnibox bug found by tests: field was read-only (`NSTextField(string:)` is a label) | FIXED | |
| Layouts: Classic, Minimal, Sidebar (no top bar, address bar in sidebar); tabs shown in exactly one place; layout switches keep web views | PASS | unit tests + in-app renders |
| Floating address bar routing (⌘L / new tab when the sidebar is hidden or in the icon rail) | PASS (logic) | not seen in a real window |
| Sidebar peek: dwell, linger, stays while pointer inside or a menu is open, flick never reveals | PASS (logic) | real pointer-edge behaviour NOT seen |
| Visual design: tinted chrome, rounded page card, raised tabs, floating sidebar card, shield pill | SEEN in in-app renders | page contents are blank in those renders (web view not captured) |
| Toolbar priority (buttons move to More as the window narrows) | PASS | |
| Mac keyboard UI tests after the redesign | NOT RUN | need an idle Mac |
| iPhone toolbar keeps Tab Overview and New Tab | PASS | a shared default change briefly removed them; caught by the iOS UI test and fixed |

Window screenshots cannot be taken while another app is in full screen (the app's windows open in that Space), so layout checks use renders produced by the app itself.

## Not implemented

This list went out of date as features were added. The current, dated state of what exists and what has been checked is in `docs/capabilities.md`.
