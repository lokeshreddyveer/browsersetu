# Roadmap

**Target:** a WebKit-native, privacy-first browser with Chrome-level product completeness where Apple exposes the capability, and explicit limitations where WebKit does not.
The engine stays WebKit. Built areas (research, privacy controls, tab organisation, extension package security, encrypted sync design, backup recovery, download resume, fuzzing, SBOM) are preserved and extended, not rewritten.

Status words as in `docs/capabilities.md`: **Checked** (a test or real run showed it), **Built** (compiled, not exercised end to end), **Open**.
Agreed order of work (17 Oct 2026): daily-driver essentials, then sync, then iPhone extensions, then multi-window.

| # | Area | Built so far | Open |
|---|---|---|---|
| 1 | Multi-window | Independent model per window sharing one database and engine, tab moves between windows, windows restored at start, per-window layout and workspace | External-display layouts; per-window extension state (extensions are shared by design) |
| 2 | WebKit extensions | Install review, hash-bound approval, per-permission revoke and restore, site-access modes, conflicts, rollback, MV2/MV3 notes, compatibility notes, throwaway load test | Per-site host permissions UI beyond access modes, native side-panel equivalent, iPhone extension menu, a real compatibility test matrix |
| 3 | Performance | Tab sleep modes, resource dashboard, signposts, blank-tab baselines, new-tab responsiveness test, opt-in real-page timing test | Per-tab CPU and memory (WebKit gives none: estimates only, labelled as such), memory-pressure responses, thermal policy, 10/50/100-tab benchmarks |
| 4 | Downloads | Resume (also after quitting), rules by site and kind, duplicate finder, PDF annotation, priority queue, hold until a time, pause and resume all, retry with back-off, iPhone background time | Bandwidth limits (WebKit offers none), downloads that continue after iOS suspends the app |
| 5 | Passwords | Save, update, fill behind Touch ID, import from Chrome, Firefox and Apple's Passwords, export behind Touch ID, generator, edit | Passkeys (needs Apple's entitlement), single-page-app login coverage |
| 6 | Sync | Passphrase-sealed snapshots, device approval, conflicts screen, deterministic merge with stamps and deletions, stale copies ignored, workspaces, sessions and opt-in passwords, extension list shown | **Two real devices**, history sync (needs a larger store than iCloud's key-value) |
| 7 | WebKit diagnostics | Waterfall, HAR, storage, page errors, load numbers, scratchpad, Web Inspector switch | Permission inspection; disclosure stays: no console output, request headers or bodies |
| 8 | Automation and accessibility | Workflows, links, Shortcuts, scheduled checks while open, label checks, iPhone landscape and large-text UI tests | Sandboxed script runtime, scheduled workflows when the app is closed (Apple restricts background work), VoiceOver, keyboard, Dynamic Type, reduced motion and high contrast validated across screens |
