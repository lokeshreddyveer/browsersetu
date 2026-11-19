# Stage 0.5: defect triage, targeted fixes and baseline closure

Date: 2026-11-14. Builds on `STAGE_0_BASELINE.md`. Stage 1 was not started.

Everything here was run or read during this work. Where something was not run, or a result is unclear, it says so. Numbers are copied from the logs named next to them.

## 1. Executive summary

| Item | Outcome |
|---|---|
| **S0-1** a tab that becomes a visible split pane during the memory pass can be discarded | **Fixed** with a 9-line change in `TabLifecycle.swift`. The regression test reproduced the defect before and passes without any expected-failure wrapper after, for the second, third and fourth panes. Idle background tabs are still released |
| **S0-2** viewport insets sometimes end at zero | **Attributed to the tests, not production.** The first tests wrote insets straight to the engine while the tab's own page-load events re-applied the model's (zero) insets 0.4 to 1.9 s later. Two writers, so it looked intermittent. With the model as the single writer (the production path) the room holds: 0 wrong in every validated run on iPhone and iPad simulators |
| **S0-3** 15 to 19 s tab-switch outliers | **Attributed to the test runner, not the app.** In the instrumented run the app handled every selection in at most 3 ms and its longest main-thread stall was 820 ms; the two outliers were seen 19.3 s and 18.6 s after the key press while the app had received the command 0.2 s after it. Production code was not changed for this. The benchmark was corrected. The exact cause inside the runner (accessibility query or its wait for idle) is **not** proven |
| **S0-5/S0-6** stale callbacks from a replaced engine | **Latent, not changed.** The replaced engine is freed after a sleep (3 of 3 runs), so a late callback cannot arrive in the observed flow. If an old engine were kept alive, a late "process ended" notice does put an error page on the sleeping tab and counts a crash. Pinned by a strict expected failure. A one-line correction is proposed, not applied |
| iPad | iPad simulator created and used. 22 tests, 0 failures. One finding (S05-A: page 340 pt wide in a 320 pt window). No split panes exist on iPad |
| Isolation | One Mac unit run exited 70 because the isolation guard saw two cache files change (`Cache.db-shm`, `Cache.db-wal`). **Closed 2026-11-18** (section 14): reproduced on a clean Mac, attributed to `PrivacyIntegrationTests` loading its fixture server through the shared URL cache, fixed in the Debug-only test isolation, and the regression rerun passed isolation class by class (119 tests, 0 failures) |

Stage 1 readiness: **ready** (section 12, updated 2026-11-18).

## 2. Repository and working-tree provenance

| Item | Value |
|---|---|
| Branch / HEAD | `main` / `87e86e40881e584c48666e325e27ba12fa98b4ed` |
| Before Stage 0.5 | 16 modified tracked files and 10 untracked paths (the earlier Favorites, stress-test and Stage 0 files, plus `STAGE_0_BASELINE.md`), recorded before the work started. Nothing was reset, cleaned, stashed or overwritten |
| Stage 0 files kept | `Tests/Stage0BaselineTests.swift`, `Tests/Stage0RecoveryTests.swift`, `iOSTests/Stage0ViewportTests.swift` (the last two changed, see section 9) |
| Stage 0.5 production changes | `Shared/TabLifecycle.swift` (+9 −4, the fix); `Shared/ChromeTrace.swift` (+41, debug-only); `Shared/BrowserModel.swift` (+2 lines in `selectTab`, debug trace). Details in section 8 |
| Environment | Apple M4, 10 cores, 16 GB, macOS 27.3 (26C5035r), Xcode 27.2 (27B52). iPhone 17 simulator and a new iPad Pro 11-inch (M5) simulator `02C512CA-D9B2-402D-9806-82BB6C59B50C`, both iOS 27.0. Only this OS generation is testable here (macOS 14 and iOS 17 targets are not) |
| Data safety | Mac runs through `scripts/test-isolated.sh` (relocated home, before/after proof). iOS runs use simulator storage and throwaway model roots. The isolation guard passed for the stress run and the UI run; it flagged the unit run (section 10) |

A note on a count in the Stage 0 report: `Stage0BaselineTests` had 11 tests, not 14 (14 was Baseline plus Recovery). `STAGE_0_BASELINE.md` is corrected.

## 3. S0-1: split-pane release race

**Root cause.** `TabLifecycle.run` marked the active tab and the split panes as visible when it built the candidate list, awaited `tab.engine.isBusy()` (a real suspension: `requestMediaPlaybackState`, `WebKitEngine.swift:1172`), and then re-checked only `activeID`. A tab put into a split pane during that wait was discarded.
Before: `TabLifecycle.swift:142` (candidate flags), `:147` and `:150-151` (checks). Pane identifiers: `activeID`, `splitTabID`, `thirdSplitTabID`, `fourthSplitTabID` (`BrowserModel.swift:553-565`).

**Proof before the fix** (Stage 0, strict expected failure, with a control that proves the setup releases idle tabs): pass suspended at the busy check, tab moved into the second pane, `released=[1, 2, 3]` and `victimDiscarded=true` (`/private/tmp/bs-test-100555-all.xcresult.log`).

**Patch** (`Shared/TabLifecycle.swift:134`, `:147`, `:152`, `:155`). One private helper, `isVisible(_:in:)`, covers the selected tab and all three panes, and is used when building candidates, before the busy check, and again immediately before `discard()`:

```swift
private static func isVisible(_ id: UInt64, in model: BrowserModel) -> Bool {
    id == model.activeID || id == model.splitTabID || id == model.thirdSplitTabID || id == model.fourthSplitTabID
}
```
Reentrancy: the second check and `tab.discard()` are consecutive synchronous statements on the main actor (`@MainActor final class TabLifecycle`), so no pane change can fit between them. No lock or new framework was needed.

**Proof after the fix** (`/private/tmp/bs-test-103824-all.xcresult.log`, 195 tests, 0 failures, 3 iterations): `testATabMovedIntoASplitPaneDuringTheBusyCheckIsNotReleased` (second pane), `…IntoTheThirdPane…`, `…IntoTheFourthPane…` all pass with plain assertions. Each prints `suspendedWhenPaneChanged=true` (the race window was exercised; a test that did not exercise it skips) and the victim stays undiscarded; idle tabs are still released (`released=[2, 3]` and `[3]`).
Policy, pinned-tab, private-tab, media and critical-memory behavior: the pure policy is untouched; `ResourceGovernorTests`, `PageDefenseTests`, `TabRecencyTests`, `TabPrivacyTests`, `TabScalingTests` and `PerformanceBaselineTests` passed in the same run, and again in the final run (section 10).

**Siblings with the same pattern, not changed** (outside the confirmed defect): `suspendAll` (`Shared/TabOrganizer.swift:263-264`) and `hibernate` (`Shared/TabTools.swift:35-37`) also re-check only `activeID` after the same busy check. `suspendAll` excludes panes before the wait; `hibernate` does not exclude them at all. Worth a decision, not a silent change.

**Scope fact found in Stage 0.5:** the iPad UI has no split panes (nothing in `iOS/` reads `splitTabID`; test `testASecondPaneIsNotShownOnIPad`). The S0-1 race can only matter on the Mac.

## 4. S0-2: hosted viewport investigation

Method: real `UIWindow` hosting (`iOSTests/Stage05HostedViewportTests.swift`), hosted versus offscreen, bounded waits on the scroll view's own insets, requested/observed values recorded.

Findings (iPad `…/ipad-timeline.log`, `…/ipad2.log`; iPhone `…/phone-timeline.log`):
1. Insets are applied instantly (time to the requested value 0 ms, p50 and p95), not by a slow animation. The first explanation (late animation start) was wrong.
2. A direct engine write made before the first page finishes loading is overwritten with 0/0 when the tab's own load events run: iPad 412 to 846 ms after the write (8 of 8, hosted and offscreen), iPhone 935 to 1,856 ms (7 of 8). Cause: `TabController.engineLoadingChanged` (`TabController.swift:404`) and `engineDidFinishLoading` (`:534`, `:543`) call `applyBottomInset()`, which applies the **model's** `phoneTopInset` and `phoneBottomInset` (`:284`), zero in a test.
3. The same write after the first load finished holds (iPad 4 of 4, iPhone 4 of 4).
4. With the model holding the room (the production path: `BrowserModel.swift:1236,1245` apply to every tab), the room stays 60/80 through the whole load, hosted: iPad 4 of 4, iPhone 4 of 4 (`S05DIAG timeline [model holds the room …]`).
5. Page commit with the model's room (`testTheRoomSurvivesAPageCommitHosted`, 12 trials × 3 iterations on iPhone): room lost during load 0, not back after load 0.
6. Hosted vs offscreen on quick sequences (two-quick and six-rapid, 25 trials each, `testHostedAndOffscreenAreComparedOnQuickSequences`): wrong final 0 of 50 hosted and 0 of 50 offscreen, repeated 3 times (iPhone) and once on iPad.
7. The 350 ms re-application (`PhoneRootView.swift:367-369`) is harmless today: `setViewportInsets` skips a request equal to the last applied one (`WebKitEngine.swift:518`) and the room does not accumulate (hosted and offscreen tests pass). Its purpose after a safe-area change was exercised: with an extra safe area of 47/34 pt, the told room became 121/64 while the scroll room stayed 20/30 (`S05DIAG viewport safe-area`), as designed (`WebKitEngine.swift:511-514`).

**Classification: attributed.** The Stage 0 "intermittent" result was two writers (test and tab) racing, not a defect in production code. Not reproduced in production-equivalent conditions. No production change. Not claimed: that nothing can ever go wrong with the first commit of a brand-new tab in the real app; the model's insets are zero until the phone layout measures them, and that interval was not examined.

## 5. S0-3: tab-switch latency attribution

**What was added** (all debug-only, active only when `BS_CHROME_TRACE` is set, compiled out of release builds): a main-thread watchdog (`Shared/ChromeTrace.swift`, `MainThreadWatchdog`: a 100 ms background timer, "STALL" lines when the main queue does not answer for over 250 ms) and a `SELECT done … in N ms` line in `selectTab` (`BrowserModel.swift:2729-2731`). The stress test (`UITests/RealWebsiteStressUITests.swift`) now records, on the app's own clock (system uptime), when each key was sent and when the new tab was seen, and prints four separate measures.

**Results, 115 real pages (45 light, 35 moderate, 35 heavy), two instrumented runs.** Logs: `/private/tmp/bs-test-111556-all.xcresult.log` and `/private/tmp/bs-test-114819-all.xcresult.log`.

| Measure | Run 1 | Run 2 (final, corrected benchmark) |
|---|---|---|
| Command handling, app `selectTab` | n 169: p50 0, p95 1, max 3 ms | n 183: p50 0, p95 2, max 3 ms |
| Key sent to the app's SELECT line | not recorded | n 24: p50 108, p95 223, max 305 ms |
| App main-thread stalls over 250 ms | 72, p50 329, max 820 ms, none ≥ 1 s, 26.0 s in total | 55, p50 301, p95 460, max 470 ms, 18.2 s in total |
| Seen by the test (key to new tab seen selected) | slowest 16.0 s (light), 17.2 s (moderate) | n 24: p50 756, p95 18,597, max 19,344 ms; over 5 s: 2 |
| Memory | 164 → 321 MB | 164 → 284 MB at the end, peak 299 MB |

**The outliers.** Run 1: the 16.7 s and 17.4 s switches (the eighth press of the light and moderate phases). The app's own trace for the 16.7 s one: `SELECT tab 8` 0.184 s after the key, `SELECT done … in 0 ms`, no app activity for the rest. Run 2: two late switches, seen after 19,345 ms and 18,598 ms; the app received the command 212 ms and 188 ms after the key and stalled 0 and 352 ms during them. The heavy phase had none over 1.9 s.

**Attribution (evidence-supported).** The ~16 to 19 s is waiting in the test runner after the app has finished, not app work: command handling is at most 3 ms, no app stall exceeds 820 ms, and the stalls overlapping the late switches total 0 to 352 ms. **Not proven:** which part of the runner's wait it is (the accessibility read of the tab strip, which grows with the tab count, or the runner's wait for the app to be idle while 100+ pages are active). Instruments and `xctrace` were not run; the watchdog and trace stand in for them.

**Decision rule applied:** the bottleneck is measurement infrastructure, so the benchmark was corrected and production logic was not changed. No performance improvement is claimed. The real, smaller, finding the watchdog shows: the app's main thread was unresponsive for 250 to 820 ms about 55 to 72 times during 115 pages (18 to 26 s in total), 0.30 s typical. That is real app-side jank under many live pages and is a Stage 1+ topic (it is not what the 16 s numbers were).

**Not measured:** first usable content (when the page is painted); only the model's selection and the UI-observed selection.

## 6. Stale-callback investigation (S0-5/S0-6)

Trace: `WebKitTab` holds its event target weakly (`WebKitEngine.swift:345`) and TabController is the target of both the old and the new engine. `discard()` calls `engine.stop()` and `engine.close()` (`TabController.swift:223-224`), builds a new engine with `events: self` (`:225`). `close()` removes only observers (`WebKitEngine.swift:1242-1246`); it does not clear the event target. Engine events carry no sender or generation (`EngineAPI.swift:35-49`).

Tests, with real objects and no test double (`Tests/Stage05StaleCallbackTests.swift`, run in the final unit run):
1. `testTheReplacedEngineIsFreedAfterTheTabSleeps`: the old engine is freed (3 of 3 runs, `S05DIAG old engine freed after sleep = true`). So in this flow no callback from it can arrive. Passes.
2. `testALateProcessEndFromAnOldEngineDoesNotChangeTheSleepingTab`: an old engine held on purpose, then its `webViewWebContentProcessDidTerminate` called: the sleeping tab shows an error page and a crash is counted (`showingError=true discarded=true crashesCounted=1`, 3 of 3). Pinned as a **strict expected failure**; it is not a passing behavioral guarantee.

**Classification: latent.** The precondition (an old engine outliving its replacement) was not observed. Proposed correction, not applied: `WebKitTab.close()` sets its event target to nil (`private weak var events`), which neutralizes every late callback from a closed engine, including the media and login hooks. Both call sites of `close()` (`TabController.swift:224`, `:357`) are followed by nothing that needs the old engine's events. Apply only on your decision; when applied, test 2 reports an unexpected pass and its wrapper must then be removed.

## 7. iPhone and iPadOS validation

iPad simulator created for this work (`xcrun simctl create … iPad-Pro-11-inch-M5-12GB … iOS-27-0`), booted, used, and reported below.

| What | Test (file `iOSTests/Stage05IPadTests.swift`) | Result |
|---|---|---|
| Page hosting at full-screen landscape 1194×834, portrait 834×1194, Split View 639 and 507 wide | `testThePageIsHostedInsideTheWindowAtEveryWidth` | Page inside the window at every size (12,134 origin; 1170×668 landscape; 810×1044 portrait; 615×1044 at 639; 483×1044 at 507) |
| Window resize keeps the same web view | `testResizingTheWindowKeepsTheSameWebViewInsideIt` | Passes (rotation and Split View are approximated by resizing the window) |
| Tab switching and rapid A→B→C | `testSwitchingTabsShowsTheSelectedTabsWebView` | Selected tab's page shown after each switch; last wins |
| Safe-area change | `testASafeAreaChangeKeepsThePageInsideTheWindow` | Passes |
| Sidebar | `testTheSidebarTakesRoomInAWideWindowAndStepsAsideInANarrowOne` | Wide window: page 869 of 1194 with the sidebar on. 507 window: page 433 to 436, about 50 pt narrower than without the sidebar (483); the sidebar mostly steps aside; the extra 50 pt was not investigated |
| Split-pane visibility | `testASecondPaneIsNotShownOnIPad` | iPad has no split panes: selected page stays, second page is not added |
| **Finding S05-A** Slide Over (320 pt) | `testSlideOverWidthPageFitsTheWindow` | The page is laid out 340 wide at x = −10, past both edges. Strict expected failure. Seen in a hosted test window only, not on a real Slide Over; Slide Over exists on the supported iPadOS 17 |
| Viewport and inset behavior on iPad | `Stage0ViewportTests`, `Stage05HostedViewportTests` | Pass (section 4) |

Not tested (blocked, with the reason): hardware keyboard shortcuts (not synthesizable in a unit-test host), software-keyboard presentation (no way to raise the keyboard in this harness), true device rotation and Stage Manager windows (the harness resizes a window instead), and iPad UI tests (`iOSUITests` are phone-oriented and assume the bottom bar). Everything here is hosted in a unit-test window, not the full app.

iPhone: the hosted viewport tests and `Stage0ViewportTests` ran on the iPhone 17 simulator (section 10); the eight iPad tests skip on a phone by design.

## 8. Exact production changes

| File | Change | Why |
|---|---|---|
| `Shared/TabLifecycle.swift` | `isVisible(_:in:)` helper (`:134`); used at `:147` (candidates), `:152` (before the busy check), `:155` (immediately before `discard()`) | S0-1 |
| `Shared/ChromeTrace.swift` | Debug-only `MainThreadWatchdog`; `ChromeTrace.log` starts it (only when `BS_CHROME_TRACE` is set); release builds compile it out | S0-3 diagnosis |
| `Shared/BrowserModel.swift` | Two lines at `:2730-2731`: record the start time and log `SELECT done … in N ms` (`ChromeTrace.log` is a no-op without the env variable and is compiled out of release builds) | S0-3 diagnosis |

No other production file, no project setting, no configuration, no WebKit API change. `BrowserModel.swift` also carries the earlier uncommitted Favorites work; only those two lines are Stage 0.5.

Added at closure (2026-11-18, section 14), test infrastructure only:

| File | Change | Why |
|---|---|---|
| `Shared/TestIsolation.swift` | `isolateSharedURLCache(home:)` (`:101-105`), called for a test process at `:81-82`. Inside `#if DEBUG && os(macOS)`, so release builds are unchanged | Isolation flag: test processes get their own URL cache inside the relocated home |
| `scripts/check-uitest-isolation.py` | `tolerated()` also names the bundle's own folder in the system cache directory (`:103`); every file inside it is still checked | macOS creates that folder for the Metal shader cache, which was already tolerated |

## 9. New or modified tests

| File | Tests | Status |
|---|---|---|
| `Tests/Stage0BaselineTests.swift` | 13 (S0-1 race test is now three, second, third and fourth pane, all plain assertions) | Modified from Stage 0 |
| `Tests/Stage0RecoveryTests.swift` | 3 | Kept |
| `Tests/Stage05StaleCallbackTests.swift` | 2 | New |
| `iOSTests/Stage0ViewportTests.swift` | 7 | Rewritten: the model is the single writer, waits are on observed values. The earlier non-strict expected-failure wrappers are gone |
| `iOSTests/Stage05HostedViewportTests.swift` | 7 | New (hosted window harness, timeline, page commit, safe area, tab switch) |
| `iOSTests/Stage05IPadTests.swift` | 8 | New (one diagnostic prints the hosted view tree; one strict expected failure, S05-A) |
| `UITests/RealWebsiteStressUITests.swift` | benchmark | Modified: per-switch timestamps and the four separate measures |

Expected-failure tests that remain, and what they do and do not mean: `testALateProcessEndFromAnOldEngine…` (S0-5, latent) and `testSlideOverWidthPageFitsTheWindow` (S05-A). Both are strict (an unexpected pass is a failure that tells you to remove the wrapper). They document a known behavior; they are not guarantees that the behavior is right.

## 10. Test results

All commands run from `~/Documents/browser`. Logs are under `/private/tmp` (Mac) and `/private/tmp/bs-s05-logs` (iOS, scripts and scratch).

| Run | Result |
|---|---|
| Mac unit, S0-1 regression, 3 iterations (`/private/tmp/bs-test-103824-all.xcresult.log`): Stage 0 and 0.5 classes, `ResourceGovernorTests`, `PageDefenseTests`, `TabRecencyTests`, `TabBehaviorTests`, `TabFeaturePureTests`, `TabScalingTests`, `TabPrivacyTests`, `PerformanceBaselineTests` | 195 tests, 0 failures. Isolation passed |
| Mac unit, final regression (`/private/tmp/bs-test-114619-all.xcresult.log`): 27 classes covering layout, tabs, windows, privacy, lifecycle, performance, workspace and the Stage 0 and 0.5 tests | **246 tests, 0 failures, but exit 70: the isolation guard failed** (see below) |
| Mac UI, instrumented real-website stress (`/private/tmp/bs-test-114819-all.xcresult.log`) | passed (115 tabs, 115 titled, no crash report). Isolation passed |
| Mac UI, `MultiWindowUITests`, `D1bGeometryUITests`, `D1bWindowCrashReproUITests`, `LayoutRegressionUITests` (`/private/tmp/bs-test-120103-all.xcresult.log`) | 8 tests, 0 failures. Isolation passed |
| iPad simulator, `Stage0ViewportTests` + `Stage05HostedViewportTests` + `Stage05IPadTests` (`iosfinal-02C512CA-….log`) | 22 tests, 0 failures, exit 0 |
| iPhone 17 simulator, the same three classes (`iosfinal-9BA6C0AF-….log`) | 13 passed (7 viewport, 6 hosted), 8 iPad tests skipped by design, 1 (the timeline test) did not complete, but the invocation **exited 65**: during `testTimelineOfInsetsBeforeAndAfterTheFirstPageCommit` the test host went silent for about 68 s and was restarted. Run alone, that test passes (`phone-timeline.log`, exit 0). The cause of the one hang is unexplained |
| Earlier iOS runs | `Stage0ViewportTests` ×3 on iPad and on iPhone, 21 tests each, 0 failures; `Stage05IPadTests` ×3 on iPad, 21 tests, 0 failures; `testTheRoomSurvivesAPageCommitHosted` ×3 on iPhone, 0 failures |

**The isolation failure.** The guard reported `changed: …/C/com.browsersetu.mac/Cache.db-shm` and `Cache.db-wal` (the app's network cache in the per-user cache folder); nothing else (no profile, preferences, Keychain or downloads). The file times were 11:46:56 and 11:47:38, inside the unit run (11:46:19 to 11:48), which lines up with `PageDefenseTests`, `PerformanceBaselineTests` and `PrivacyIntegrationTests` (11:46:56 to 11:47:38). Those are older tests that passed the same check in earlier runs. The installed app was not running then (it was started at 13:03, and the run's own start check would have refused). **Not attributed**: the timing is circumstantial, and I could not bisect because the installed Browser Setu is running now and the isolated runner refuses to start. The URL cache lives in a folder the runner's relocated home does not cover, which is a gap in the isolation guard rather than in the new tests, but this was not proven. A retry needs the installed Browser Setu closed first.

Skipped and expected-failure counts: skipped 8 (iPad tests on iPhone, by design). Expected failures 2 tests (strict, section 9).

## 11. Remaining defects and risks

1. ~~**Isolation flag** (section 10): unattributed; the "all regressions rerun in isolation" item is therefore only partly closed.~~ Closed 2026-11-18 (section 14). Nine other test files still load fixtures through the shared session (`URLSession.shared`, for example `Phase12BrowserIntegrationTests.swift:303`, `HardeningTests.swift:24`, `BrowserIntegrationTests.swift:24`); they are now covered by the same isolated cache, but they were not part of this rerun.
2. **S0-5** latent; one-line correction proposed, awaiting your decision. **Siblings** `suspendAll` and `hibernate` share the S0-1 pattern.
3. **S05-A**: 340 pt page in a 320 pt window on iPad, in a hosted test only.
4. **S0-3**: the cause inside the runner is unproven. The app's own jank under many live pages (55 to 72 stalls of 0.25 to 0.8 s over 115 pages) is real and not addressed.
5. **iPhone hang** during the timeline test, once, unexplained; passes alone.
6. Coverage blocked: keyboard presentation, real rotation, Stage Manager, hardware shortcuts, iPad UI tests, macOS 14 and iOS 17.
7. Instruments and `xctrace` were not run.
8. The brand-new-tab interval before the phone layout reports its insets was not examined (section 4).
9. ~~32 uncommitted paths in the working tree; none of this work is committed.~~ Committed on `main` (2026-11-18, `cc6ff3c`).
10. The iPad simulator device created for this work still exists (`xcrun simctl delete 02C512CA-D9B2-402D-9806-82BB6C59B50C` removes it).

## 12. Stage 1 readiness

| Exit item | Status |
|---|---|
| S0-1 fixed, deterministic regression green | **Met** |
| S0-2 attributed or classified | **Met** (test artifact, with evidence) |
| S0-3 profiled with reproducible traces | **Met** for attribution (two consistent runs); cause inside the runner not proven |
| Stale-callback risk tested or documented | **Met** (latent, tested) |
| iPad and hosted iPhone tests executed, or blockers recorded | **Met**, with the blockers in section 7 |
| Relevant regressions rerun in isolation | **Met** (2026-11-18, section 14): 13 classes, 119 tests, 0 failures, isolation passed for every class. Earlier: 246, 8 and 195 tests passed |
| Report with an explicit decision | **Met** (this section) |

**Decision (2026-11-18): ready for Stage 1.** The one condition, the isolation flag, is closed (section 14). The open items in section 11 do not block a Stage 1 start; they are carried into the scope below. Stage 1 is not started and needs the owner's approval of its plan first.

## 13. Updated recommended Stage 1 scope (not started)

1. **Pure viewport solver in shadow mode, iPhone path only** (`PhoneRootView.swift:367-369`, `TabController.applyBottomInset`, `WebKitEngine.setViewportInsets`). Its acceptance baseline is now trustworthy: the model-as-single-writer tests (`Stage0ViewportTests`, `Stage05HostedViewportTests`) and the page-load timeline. The solver must reproduce: the room is applied once, held through a page load, never doubled, and the told room (with the safe area) differs from the scroll room (without it).
2. **One rule to carry into the design:** exactly one writer of the room per tab. The Stage 0 "intermittent" result was caused by two writers; a viewport engine should make that impossible by construction.
3. **Decide separately, before or alongside:** the S0-1 siblings (`suspendAll`, `hibernate`), and the S0-5 one-line `close()` correction.
4. **iPad layout:** schedule S05-A and the 50 pt sidebar observation as their own small items; iPad has no split panes, so Research Desk-style work stays macOS-only.
5. **Session and resource identity (Stage 2) inputs:** the app's own main-thread stalls under many pages (section 5) and the latent stale-callback exposure are the two concrete measurements to carry forward; the tab-switch command itself is already cheap (≤ 3 ms).
6. Keep the benchmark as corrected: it separates command handling from what the UI observes.

## 14. Closure of the isolation flag (2026-11-18)

**Environment.** Apple M6, 16 GB, macOS 27.2.1 (26B7131), Xcode 27.2 (27B52). A new Mac on which Browser Setu had never been installed, so every file the guard saw in the app's own places was made by the tests. Branch `main`, HEAD `cc6ff3c`, plus the two files in section 8 (uncommitted).

**Reproduction.** `zsh scripts/test-isolated.sh --per-class -only-testing:BrowserSetuMacTests/<Class> …` with the 13 classes below, before any change:

| Class | Guard result |
|---|---|
| `Stage0BaselineTests` (13 tests, 0 failures) | **failed**: `added: $DARWIN_USER_CACHE_DIR/com.browsersetu.mac` (its only content `com.apple.metalfe`, the tolerated Metal shader cache). Evidence `/private/tmp/bs-isolation-evidence/20261118-232006-BrowserSetuMacTests_Stage0BaselineTests` |
| 11 classes, from `Stage0RecoveryTests` to `TabScalingTests` | passed |
| `PrivacyIntegrationTests` (30 tests, 0 failures) | **failed**: `added: …/com.browsersetu.mac/Cache.db`, `Cache.db-shm`, `Cache.db-wal`, the same files as the original flag. Evidence `/private/tmp/bs-isolation-evidence/20261118-232311-BrowserSetuMacTests_PrivacyIntegrationTests` |

**Attribution (proven).** `Cache.db` held exactly two responses, `http://127.0.0.1:18765/_reset` and `http://127.0.0.1:18765/_requests`: the fixture server calls in `Tests/PrivacyIntegrationTests.swift:32-33` (`String(contentsOf:)`). Those load through the shared URL loading system, whose disk cache macOS keeps in the per-user system cache folder named after the bundle id. That folder is outside the home the runner relocates, so it is shared with the person's own app. The app's own networking was not involved; `testNoTelemetryOrAnalyticsOrBackgroundNetworkingInSources` already restricts it. The earlier flag's timing (section 10) fits this class.

**Correction** (section 8): a test process gets its own URL cache inside the relocated home (`TestIsolation.isolateSharedURLCache`, Debug only), and the guard tolerates the bundle's system cache folder itself, macOS-made for the Metal cache, while still checking every file inside it. No test was weakened and no assertion changed. The first version of the change failed `testNoTelemetryOrAnalyticsOrBackgroundNetworkingInSources` because its doc comment named the shared session; the comment was reworded and the test was left as it is.

**Proof.** The test-made cache folder was moved aside, then:

| Run | Result |
|---|---|
| `--per-class --build` `Stage0BaselineTests`, `PrivacyIntegrationTests` (`/private/tmp/bs-test-232541-…`, `bs-test-232711-…`) | 13 and 30 tests, 0 failures; isolation passed for both; the system folder afterwards holds only `com.apple.metalfe` (no `Cache.db`) |
| Final gate, `--per-class`, 13 classes, 167 s (`/private/tmp/bs-test-2328*` to `bs-test-2330*`, evidence `/private/tmp/bs-isolation-evidence/20261118-232808-…` to `20261118-233004-…`) | **119 tests, 0 failures, 0 skipped, isolation passed for all 13 classes**: Stage0Baseline 13, Stage0Recovery 3, Stage05StaleCallback 2, ResourceGovernor 6, TabRecency 9, TabBehavior 10, TabFeaturePure 6, TabPrivacy 9, Favorites 22, PageDefense 4, PerformanceBaseline 2, TabScaling 3, PrivacyIntegration 30 |

Expected failures in that gate: 1 test, `testALateProcessEndFromAnOldEngineDoesNotChangeTheSleepingTab`. XCTest reports it as passed because the strict wrapper accepted its two known assertion failures (`Stage05StaleCallbackTests.swift:48-49`). It still documents S0-5 as latent; it is not a passing guarantee.

**Not rerun at closure:** the wider 27-class set of section 10 (its class list was in a log on the previous Mac), the Mac UI tests and the iOS and iPad tests. None of them is affected by the change, which applies only to Mac test processes.
