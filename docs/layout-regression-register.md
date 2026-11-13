# Layout regression register

What each layout has been checked for, and what has not. "Runtime" means a test drove the real app in an isolated profile (`scripts/test-isolated.sh`) and passed; "source" means the code exists and was read or compiled, which is not evidence that it works. Dated 2026-11-13.

## Acceptance status

| Layout | Status |
|---|---|
| Classic | Accepted |
| Minimal | Accepted |
| One Row | Accepted |
| Classic Reversed | Accepted with caveats |
| Minimal Reversed | Accepted with caveats |
| Sidebar | Next (assessment only; no implementation approved) |

## Runtime-verified (Minimal Reversed, 2026-11-12)

- Unit: `D1cOneRowModelTests` 14 of 14, 0 skipped (preset, persistence, snapshots, preset-switch identity, `TitleBarTabHold` lifecycle); the wider layout, isolation and chrome unit set ran 74 tests with 0 failures but 3 skipped (the hold tests, which could not run until the key-window guard was removed), and was not rerun in full after that change.
- UI: `D1eMinimalReversedUITests` (10: row order and lights clearance, 520/1000/1600 pt, Library left/right, suggestions, tab drag against Minimal, window drag, movability after hover exit / drag / tab close / second window / app deactivation, single tab, Essentials + pinned + group, full screen); `D1eMinimalReversedParityUITests` (10: Minimal's 8 tests with the strip on top, hover preview, full-screen peek against Minimal).
- Regressions in the same run: Minimal 8, Classic Reversed 8, One Row 18, Transitions 4, then Classic 15 and Classic Reversed parity 18. Isolation check passed on every run.
- Classic Reversed (earlier): tab drag, fullscreen peek, empty-strip drag, Library both sides, suggestions, single-tab rule.

## Open items (not verified at runtime)

| Item | Applies to | Note |
|---|---|---|
| System Reduce Motion at runtime | all | Not tested. |
| Real VoiceOver | all | Labels are asserted; speech and rotor behavior are not. |
| Motion Off / Standard at UI level | Minimal Reversed | Only the model-level test covers it; there is no UI launch flag for it. |
| Empty-strip drag branch | Minimal Reversed (also Classic Reversed) | The test drags empty strip space only when the measured gap is over 80 pt. Its note could not be read from the sandboxed runner, so the test passing is not proof that branch ran. Fix when next touched: attach the measured gap as an `XCTAttachment`, or fail when the gap is too small. Classic Reversed's equivalent attaches `empty-strip-gap` and measured 62 pt. |
| Drag boundaries between pinned, Essentials and regular tabs | both Reversed layouts, and Classic | No test drags across those boundaries; only menu reordering is covered. |
| 520 pt AppKit crash (historical) | all | Not reproduced or ruled out. |
| 190 pt Library width (historical) | all | One-off observation, not reproduced. |
| `TitleBarTabHold` and hover-before-press | both Reversed layouts | Window-global (`NSWindow.isMovable`) workaround, kept as a known technical risk, not a proven solution. It lets go on hover exit, tab disappearance, window or app resign, window close, screen change and a mouse-up off the tab. The window server only honors it if the pointer arrived over the tab before the press, so an instant press with no prior pointer movement could still drag the window. The live `isMovable` value is not read by any UI test; movability is inferred from whether the window drags afterwards. |
| `testSelectedTabStaysInViewWithManyTabs` (Classic) | Classic | Failed once in a combined run ("100 tabs: the selected tab is not in view"), then passed 4 of 4 alone and 15 of 15 in the last run. Root cause not established. |
| Test-process `Cache.db` | test infrastructure | Memory-only `URLCache` for test processes is on hold. |
| `bs-test-rule-store-*` folders | test infrastructure | Small temporary rule stores; hygiene only. |
| Classic setup card art | Classic | Draws tabs on top; the real Classic order is toolbar then tabs. |

## Notes

- The Reversed layouts are left out of the first-run setup gallery by design; they are in Settings, the toolbar context menu and the command palette. `layoutCycle` is unchanged.
- Tests that need the pointer to arrive first (`hover()` before a drag) reflect how a person uses the mouse, not the worst case above.
