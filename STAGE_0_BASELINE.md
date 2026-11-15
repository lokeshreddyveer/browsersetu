# Stage 0: Architecture baseline and behavioral contract validation

Date: 2026-11-14. Scope: macOS (full), iOS (simulator, iPhone only), iPadOS (not run, see blockers).
No production code, configuration or project settings were changed. Changes are limited to three new test files and this report.

Everything below was measured or read during this work. Where something was not run or not measured, it says so. Numbers are copied from the logs named next to them.

## 1. Repository and environment

| Item | Value |
|---|---|
| Repository | `~/Documents/browser`, branch `main` |
| Commit | `87e86e40881e584c48666e325e27ba12fa98b4ed` ("Update feed for Browser Setu 0.4.3"), the same commit the architecture review cites |
| Working tree | 22 uncommitted paths before Stage 0 (16 modified Swift files in `Shared/`, `macOS/`, `Tests/`, plus 6 untracked Favorites and stress-test files from earlier work). Stage 0 added 3 untracked test files (25 in all). `project.yml` is unchanged |
| Consequence | Line numbers below are from the working tree. `BrowserModel.swift` is 4,772 lines now, 4,753 at the commit. `TabLifecycle.swift` and `iOS/PhoneRootView.swift` are unmodified, so their references are identical at the commit |
| Swift files | 865 under `apps/` |
| Deployment targets | macOS 14.0, iOS 17.0 (`apps/apple/project.yml:10-12`) |
| Mac | Apple M4, 10 cores, 16 GB RAM, macOS 27.3 (26C5035r); load average 3.93 during the UI timing run (recorded by the harness) |
| Xcode | 27.2 (27B52) |
| iOS simulator | iPhone 17 (`9BA6C0AF-0D29-4D29-8C1B-6FCE2F2B2C11`), runtime iOS 27.0, SDK 27.2. No iPad simulator is installed |
| Not available | macOS 14 and 26, iOS 17 and 26, iPadOS anything: only one OS generation was testable here |

Data safety: every Mac run went through `scripts/test-isolated.sh` (throwaway profile, relocated home, before/after proof). Each run printed `ISOLATION CHECK PASSED` with the evidence folder (for example `/private/tmp/bs-isolation-evidence/20261114-100010-all`). The installed Browser Setu was not running. The iOS simulator run used its own derived data (`/private/tmp/bs-s0-ios`) and the simulator's own storage; each test used a throwaway model root.

## 2. Behavioral contract matrix

Status: **Covered** (a test ran and passed), **Pinned defect** (a test shows a problem), **Gap** (no test, or not testable here).
"New" means added in Stage 0.

| # | Contract | Source evidence | Existing coverage | New coverage | Status |
|---|---|---|---|---|---|
| C1 | Switching layout never replaces a tab or its web view | `BrowserModel.layoutPreset` | `D1cOneRowModelTests.testSwitchingLayoutsKeepsEveryTabAndItsWebView` (6 presets) | `Stage0BaselineTests.testEveryLayoutKeepsEveryTabAndWebViewAcrossAFullCycle` (all 12 presets, forward and back, selected tab unchanged) | Covered |
| C2 | Last tab selected wins under rapid A→B→C; no web view replaced, none put to sleep | `BrowserModel.swift:2728-2765` | none found | `testRapidSwitchEndsOnTheLastTabAndReplacesNoWebView`, `testSelectingTheActiveTabAgainIsANoOpForIdentity` | Covered |
| C3 | Late snapshot and scroll-save work (started by `selectTab`) does not change the front tab | `BrowserModel.swift:2739,2741` | none | `testRapidSwitchLeavesSnapshotAndScrollWorkHarmlessAfterItSettles` (1.5 s settle) | Covered (see S0-4 limits) |
| C4 | Visible split pane is never released, when it is a pane before the memory pass starts | `TabLifecycle.swift:140-143` | `PageDefenseTests`, `ResourceGovernorTests` (pure policy only) | `testThePolicyNeverChoosesTheSelectedOrAnyMarkedActiveTab`, `testATabAlreadyInASplitPaneIsNotReleased`, control `testIdleBackgroundTabsAreReleasedWhenNothingProtectsThem` | Covered |
| C5 | A tab that becomes a split pane **during** the asynchronous busy check is not released | `TabLifecycle.swift:147-151` | none | `testATabMovedIntoASplitPaneDuringTheBusyCheckIsNotReleased` | **Pinned defect S0-1** |
| C6 | A tab keeps its id when its web view is replaced; waking reuses the replacement | `TabController.swift:219-233` | none | `testSleepingATabKeepsItsIdentityAndReplacesItsEngineObject` | Covered (characterization; no generation id exists, see S0-5) |
| C7 | Private tabs are never put to sleep | `TabController.swift:220` | `TabPrivacyTests`, `PrivateWindowTests` (ran, passed) | `testPrivateTabsAreNeverPutToSleep` | Covered |
| C8 | Restore: sleeping tabs load only when selected; private tabs are not restored | `TabController.swift:200-211` | `D1aClassicPersistenceTests`, `IOSLifecycleTests` (iOS, not run) | `testRestoredTabsStayAsleepUntilSelectedAndPrivateTabsAreNotRestored` | Covered (macOS) |
| C9 | Web-content process crash: background tab sleeps without an error page; repeated crashes end in a paused error, not a loop; one crash leaves other tabs alone | `TabController.swift:677-704`, `CrashGuard.swift` | `CrashGuardTests` (pure rule) | `Stage0RecoveryTests` (3 tests) | Covered |
| C10 | Private vs normal website-data isolation | `WebKitEngine.swift:85-110` (non-persistent stores per private session, per profile and container) | `PrivacyIntegrationTests`, `TabPrivacyTests`, `PrivateWindowTests`, `SitePrivacyTests` (ran, passed) | none | Covered by existing tests; cross-container and redirect cases not individually verified here |
| C11 | Window resizing and geometry stability (macOS) | n/a | `D1bGeometryUITests` (3), `D1bWindowCrashReproUITests` (15 launches, resize and layout loop), `LayoutRegressionUITests` (2) | none | Covered; drag-resize and full screen skipped by design (S0-8) |
| C12 | Multi-window ownership | `Windows.swift` | `MultiWindowUITests` (2) | none | Covered (2 scenarios only) |
| C13 | Viewport: same inset requested repeatedly does not accumulate (no double compensation) | `WebKitEngine.swift:508-537`, dedupe at `:518` | none (no test referenced `setViewportInsets`) | `Stage0ViewportTests.testApplyingTheSameInsetsRepeatedlyDoesNotAccumulate` | Covered (iOS) |
| C14 | Viewport: the 0.35 s re-application after a safe-area or tab change is harmless | `iOS/PhoneRootView.swift:367-369` | none | `testTheDelayedSecondApplicationIsIdempotent` | Covered (iOS) |
| C15 | Viewport: insets belong to their own web view; clearing removes all room; spaced changes end on the last request | `WebKitEngine.swift:508-537` | none | `testInsetsBelongToTheirOwnWebViewOnly`, `testClearingTheInsetsRemovesAllRoom`, `testTheLastRequestedInsetsWinWhenChangesAreSpacedApart` | Covered (iOS) |
| C16 | Viewport: quick successive changes end on the last request | same | none | `testTheSecondOfTwoQuickInsetChangesWins`, `testTheLastRequestedInsetsWinAfterRapidChanges` | **Pinned intermittent S0-2** |
| C17 | Keyboard, rotation and safe-area transitions | `PhoneRootView.swift:75-105,238-279,367-370` | `IOSUITests` (not run) | none | **Gap**: needs a hosted window and device orientation; not tested |
| C18 | Stale callbacks from an old web view cannot update its replacement | `EngineAPI.swift:35-49` (events carry no sender), `TabController.swift:677` | none | none | **Gap** (needs an engine test double; hypothesis S0-6) |
| C19 | Navigation policy and script-bridge security | `TabController.swift:704`, `WebKitEngine.swift:393-395,2241-2262` | `HardeningTests`, `PageDefenseTests`, `ExtensionTests` family (partly ran) | none | Gap for sender/frame validation and handler cleanup (S0-7) |

## 3. Tests executed

All commands are run from `~/Documents/browser`. Result bundles were kept (`BS_KEEP_RESULTS=1`).

| Run | Command (abbreviated) | Result | Log |
|---|---|---|---|
| A. Mac unit, 22 relevant classes | `scripts/test-isolated.sh --build -only-testing:BrowserSetuMacTests/<Stage0BaselineTests, D1cOneRowModelTests, ChromeLayoutTests, LayoutStateTests, LayoutConsistencyTests, TabChipRulesTests, TabBehaviorTests, TabRecencyTests, TabPrivacyTests, PrivateWindowTests, ResourceGovernorTests, PageDefenseTests, WindowTests, WindowPolicyTests, WorkspaceAndPerformanceTests, WorkspaceIdentityTests, D1aClassicPersistenceTests, ResilienceTests, ReliabilityTests, SitePrivacyTests, PrivacyIntegrationTests, PerformanceBaselineTests, TestIsolationTests>` | 229 tests, 228 passed, 1 failed. The failure was my first draft of the S0-1 test (its expectation was never met because the setup produced no release candidates; see S0-1). All 228 others passed | `/private/tmp/bs-test-100010-all.xcresult.log` |
| B. Mac unit, new tests ×3 iterations | `… -only-testing:…/Stage0BaselineTests -only-testing:…/Stage0RecoveryTests -only-testing:…/TabScalingTests -test-iterations 3` | 51 tests, 0 failures (`Stage0BaselineTests` 11 tests and `Stage0RecoveryTests` 3 tests, ×3 = 42, plus `TabScalingTests` 3 tests ×3 = 9) | `/private/tmp/bs-test-100800-all.xcresult.log` |
| C. Mac UI, geometry, windows, layouts | `… -only-testing:BrowserSetuMacUITests/{MultiWindowUITests, D1bGeometryUITests, D1bWindowCrashReproUITests, LayoutRegressionUITests}` | 8 tests, 0 failures (452 s). `D1bWindowCrashReproUITests`: 15 launches, 0 failures, no probe anomalies | `/private/tmp/bs-test-100937-all.xcresult.log` |
| D. Mac UI, timing | `… -only-testing:BrowserSetuMacUITests/{PerfStartupUITests, PerfTabsUITests, PerfWindowUITests}` | 4 tests: 3 passed, 1 skipped by the test itself (`testResizeAndFullScreen`: "window resize by drag and full screen cannot be driven reliably from the UI-test runner on this machine"), 0 failures | `/private/tmp/bs-test-101745-all.xcresult.log` |
| E. iOS unit, viewport | `xcodebuild test -scheme BrowserSetuiOS -destination 'platform=iOS Simulator,id=9BA6C0AF-…' -derivedDataPath /private/tmp/bs-s0-ios -only-testing:BrowserSetuiOSTests/Stage0ViewportTests -test-iterations 5` | 35 tests (7 × 5), 0 failures; the two S0-2 tests are non-strict expected failures and recorded the correct final value in all 10 of these iterations | `/private/tmp/bs-s0-ios3.log` |

Earlier runs in the same investigation (not repeated):
- Full Mac unit target, 2026-11-13 (before Stage 0): 4,027 tests, 64 skipped, 2 failures, both in `MediaToolsInstallerTests` (media installer, unrelated; the installer code is off limits). `/private/tmp/bs-test-172140-all.xcresult.log`.
- Real-website stress, 115 real pages: passed (`RealWebsiteStressUITests`, see section 5).

Not run, and why:
- iOS UI tests (`BrowserSetuiOSUITests`) and the other iOS unit tests: not needed for the Stage 0 contracts and not selected; no result is claimed.
- Anything on iPad or iPadOS: no iPad simulator installed. Command needed once one exists: `xcodebuild test -project apps/apple/BrowserSetu.xcodeproj -scheme BrowserSetuiOS -destination 'platform=iOS Simulator,name=<iPad name>' -only-testing:BrowserSetuiOSTests/Stage0ViewportTests`.
- macOS 14 and 26, iOS 17 and 26: only the installed OS generation is available.
- Instruments and signposts: not run.
- Full UI suite: not run (policy: targeted runs while developing).

## 4. New regression coverage

Files (all untracked, test-only):
- `apps/apple/Tests/Stage0BaselineTests.swift`: 11 tests (tab switching, web view identity, sleep and wake, restore, split-pane release control and race).
- `apps/apple/Tests/Stage0RecoveryTests.swift`: 3 tests (web-content process crash recovery).
- `apps/apple/iOSTests/Stage0ViewportTests.swift`: 7 tests (viewport insets on iOS).

Design rules used: each test makes its own temporary storage root; no production symbol was modified; a test that pins a defect uses `XCTExpectFailure`, so the suite is green while the defect exists and a fixed defect shows up as an unexpected pass (S0-1 is strict; S0-2 is non-strict because it is intermittent).

Two mistakes in my own tests were found and fixed during the work, and are recorded because they affect how far the first results can be trusted:
1. The first S0-1 test "passed" for the wrong reason: the blank test pages were still loading, so `isBusy()` returned true for every tab and nothing was ever released. A control test (`testIdleBackgroundTabsAreReleasedWhenNothingProtectsThem`) and a wait for real idleness were added. The race test now skips instead of passing if the pass was not actually suspended when the pane changed.
2. `testATabAlreadyInASplitPaneIsNotReleased` now also asserts that other idle tabs were released, so the protection was actually exercised.

## 5. Performance baseline

Honest scope: one machine, one OS generation, small repetition counts. In-process numbers are the cost of the model call only (no rendering). UI numbers include XCUITest automation overhead and are not user-perceived latency.

### 5.1 In-process (app-hosted unit tests, real `WKWebView`s), `PerformanceBaselineTests`, single run (run A)
- Model start: 21.0 ms. New tab: avg 0.56 ms (max 0.70). Tab switch (`select`): avg 0.041 ms (max 0.072). Suggestion refresh: avg 0.88 ms (max 1.33).
- Memory growth, 25 tabs: 2.9 MB (app process only). 20 blank tabs with protection on: +1 MB.
- Layout switching with 25 tabs (`select` p50 / p95): 0.05 / 0.08 ms for every preset except floating (0.08 / 0.11). Preset change itself (`switch-ms`): 0.07–0.37 ms, except `researchDesk` 2.32 ms.
- Startup (`model.start`): 23–24 ms (protection off, on cold, on warm).

### 5.2 Tab scaling, `TabScalingTests`, 3 iterations (run B). Only the lines present in the log are listed
| Tabs (loaded pages) | Open all (ms) | Select avg (ms) | Select max (ms) | App memory growth (MB) | Asleep after a critical event |
|---|---|---|---|---|---|
| 10 (10) | 46, 48, 59 | 0.10, 0.13, 0.18 | 0.24, 0.30, 0.30 | -6.8, 0.5, 1.3 | 8 of 10 |
| 50 (15) | 116, 148, 154 | 0.08, 0.27, 0.27 | 0.19, 0.42, 0.46 | 4.4, 8.0, 9.4 | 13 |
| 100 (15) | 167, 254 | 0.40, 0.44 | 0.77, 0.84 | 13.9, 14.6 | 13 (two of the three iterations produced a line) |
No 1-tab or 25-tab scaling run exists beyond the 25-tab figures in 5.1. p50 and p95 are not computed for these (3 samples).

### 5.3 UI-driven (run D, one run, `perf-report.txt` in the test runner's container: `~/Library/Containers/com.browsersetu.mac.uitests.xctrunner/Data/tmp/bs-perf-report/perf-report.txt`)
Machine at the time: load average 3.93 / 5.28 / 5.29, thermal nominal, low power off.
- Cold launch to a usable window: 2,701.6 ms (n = 1). Warm launches: median 1,379.2 ms, p95 1,497.9 ms (n = 5). Resident memory after startup: 152.9 MB (app process only).
- Tab create (⌘T), action to idle: median 510.0 ms, p95 1,705.6 ms (n = 12). Tab close (⌘W): median 468.9 ms, p95 861.4 ms (n = 12).
- Tab switch by ⌘-number, action to idle: median 120.1 ms, p95 143.2 ms, max 150.6 ms (n = 20). By click: median 625.0 ms, p95 717.0 ms (n = 12). One accessibility poll costs about 70 ms, so these include automation cost.
- Layout switch through the command palette (each n = 1): 513–1,265 ms to idle (palette open time included).
- Many tabs idle: app CPU 0.4 % of one core, resident memory 211.4 MB.
- Geometry at window widths 520, 560, 640, 800, 1200, 1600 pt: recorded in the same report (D1bGeometryUITests), no failures.

### 5.4 Real websites, 115 tabs (`RealWebsiteStressUITests`, 2026-11-13, passed)
Resident memory 154 MB at start, 227 MB after 45 light pages, 264 MB after 80, 280 MB after 115, 311 MB after 90 churn steps (the harness' "peak" misses the final sample, a test bug). Next-tab switch measured by that test: average about 2.0–2.5 s with one switch of about 15–16 s in every phase; one strip read costs only 0.3–0.7 s, so the test's own reads do not explain it. Unattributed (S0-3).

### 5.5 Not measured
- Discarded tab activation time (only that it wakes with its address; `TabScalingTests` asserts this).
- Warm-tab activation p95 against the review's 150 ms goal: the closest number is 143.2 ms for ⌘-number, which includes automation overhead; no reference device was defined.
- WebView creation and replacement counts: production code has no counter. Stage 0 only characterizes behavior (replaced on sleep; not replaced on switch or layout change).
- Web-content process recovery time: only functional behavior was tested.
- Viewport stability on iPad, keyboard and orientation: not measured.
- Layout switch p50 and p95 from the UI: only n = 1 per target.

## 6. Confirmed defects versus hypotheses

### Confirmed
- **S0-1: the memory release pass can release a tab that has just become a visible split pane.** `TabLifecycle.run` marks active and split tabs when it builds candidates (`TabLifecycle.swift:140-143`), awaits `tab.engine.isBusy()` (`:148`), and then rechecks only `id != model.activeID` (`:150-151`). Evidence: with the pass confirmed suspended at the busy check (`suspendedWhenPaneChanged=true`), moving the oldest tab into `splitTabID` led to `released=[1, 2, 3]` and `victimDiscarded=true` (diagnostic line from `/private/tmp/bs-test-100555-all.xcresult.log`). Controls in the same setup: `released=[1, 2, 3]` with nothing protecting (so the setup works), and a tab placed in a split pane before the pass is not released. Reproduced in the 3-iteration run B (strict expected failure, 2 of 3 iterations captured as passing lines, no unexpected pass). Not fixed, per instructions.

### Observed, not attributed
- **S0-2: viewport insets requested in quick succession can end at zero instead of the last request** (iOS simulator, web view not in a window). Tally of final-state observations: two-quick-changes test, 2 wrong of 8; six-change test, 1 wrong of 9; total 3 wrong of 17. The wrong runs were early (the first run after a build and the first iteration of the next); all 10 observations in the final 5-iteration run were correct. The spaced-apart control passed in every run. Not known whether production code (`WebKitEngine.swift:508-537` animated insets) or the offscreen test host is responsible. The test is a non-strict expected failure.
- **S0-3: the 15–16 s tab switch seen in the real-website stress run** (5.4). No cause found.
- **S0-8: tab reorder by drag did not change the order** in `PerfTabsUITests` (`FAILED: tab reorder | order unchanged after drag` in the perf report; the test itself passed because it records the measurement). May be an XCUITest drag limitation; not verified.

### Verified facts about the review's claims (not defects)
- The 0.35 s delayed second application exists: `iOS/PhoneRootView.swift:367-369`. It is harmless today because `setViewportInsets` ignores a request equal to the last applied value (`WebKitEngine.swift:518`); tested (C14).
- `selectTab` starts asynchronous snapshot and scroll-save work for the tab it leaves (`BrowserModel.swift:2739,2741`). Holds a reference to that tab, so the tests found no change to the front tab (C3).
- The web view is replaced when a tab sleeps (`TabController.swift:225`); nothing numbers the replacement generations (C6).

### Hypotheses (nothing proven)
- **S0-5/S0-6: stale engine callbacks.** `TabEngineEvents` methods carry no sender or generation (`EngineAPI.swift:35-49`), and `engineProcessCrashed` and the others act on whatever tab owns the events. After a sleep replaces the engine, the old engine's late callback could update the new one. Not tested; needs an engine test double (the `TabEngine` protocol has about 100 members, so none exists).
- **S0-7: script handler cleanup.** `WebKitTab.close()` removes only observers (`WebKitEngine.swift:1242-1246`); a search found no `removeScriptMessageHandler`. The handlers registered at `:393-395` are stateless instances; whether anything leaks is unverified. The login handler resolves its sender through a weak web-view-to-tab map (`:2241-2262`), which is a sound pattern; frame and origin validation were not reviewed.
- Shared `WKProcessPool` (`WebKitEngine.swift:83,87`): benchmark and review, as the review suggests; no measurement was made.

## 7. Risks and open questions
1. Only one OS generation (macOS 27.3, iOS 27.0) could be tested; the review's matrix wants macOS 14 and 26, iOS 17 and 26, iPadOS 17 and 26. Deployment targets are macOS 14.0 and iOS 17.0, so older behavior is unverified.
2. iPad is entirely untested here.
3. S0-2 needs a test that hosts the web view in a real window (or on a device) before it can be attributed.
4. The many-tab stall (S0-3) is the largest unexplained performance signal and bears on the review's tab-switch concerns.
5. UI timings include automation cost and were taken at load average ~4; they are indicative only.
6. 22 working-tree changes from earlier Favorites and layout work are uncommitted. Results describe the working tree, not the commit alone (production files touched by that work include `BrowserModel.swift`, `StartPage.swift`, `CollapsedBar.swift`, `MacRootView.swift`).
7. Two media-installer unit tests fail on the baseline (earlier full run); unrelated to Stage 0 contracts.
8. The `TabScalingTests` 100-tab case logged only 2 of 3 iterations; reason not investigated.

## 8. Stage 0 exit gate

**Decision: conditionally met for macOS and iPhone; not met for iPad and for the older OS targets.**

Met:
- A reproducible baseline exists for layout switching, tab selection, split-pane protection, sleep and wake, restore, crash recovery, private-data isolation tests, window geometry and multi-window on macOS, plus viewport insets on the iPhone simulator.
- One defect is confirmed with evidence (S0-1) and pinned by a test; two observations are recorded honestly (S0-2, S0-3).
- No production code, configuration or user data was touched.

Not met (these should be closed or explicitly accepted before the stages that depend on them):
- iPad and iPadOS coverage; macOS 14 and iOS 17 coverage.
- Keyboard, orientation and safe-area transition tests (needs a hosted window).
- Stale-callback coverage (needs an engine test double, which is a test-only addition).
- Discarded-tab activation time, view creation and replacement counts, process-recovery time, Instruments traces.

## 9. Recommended Stage 1 scope (not started)

Stage 1 as the review describes it: a pure viewport solver run in shadow mode, logging mismatches only, with legacy application unchanged. Suggested limits, in this order:
1. Start with the iPhone path only (`PhoneRootView.swift:367-369`, `TabController.applyBottomInset`, `WebKitEngine.setViewportInsets`) because that is where inputs and the legacy behavior are both concrete. Leave macOS chrome and iPad for later.
2. Before writing the solver, close S0-2: re-run the viewport tests with the web view hosted in a window, so the shadow solver has a trustworthy legacy reference.
3. Use the Stage 0 viewport tests (C13 to C16) as the acceptance baseline: the solver's output must equal the legacy result for every sequence they cover.
4. Treat S0-1 as a separate, small change decided on its own (a test already pins it); it should not wait for the viewport work.
5. Add an engine test double (test-only) if stale-callback work is planned for Stage 2.

Stage 1 was not started.
