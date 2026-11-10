# Media tools: how yt-dlp, ffmpeg and the JavaScript runner ship

Status date: 2026-11-10. This is the one description of how the Direct (DMG) build gets its media tools, how a release produces them, and what is still open. **Engineering completion is not legal approval; see "Open before public distribution".**

## What ships, and where

| Piece | What it is | Where it lives in the app | Signed by | Size |
|---|---|---|---|---|
| yt-dlp 2026.10.26 | upstream PyInstaller build, thinned to arm64, re-signed | `Contents/Resources/Tools/yt-dlp/` | our Developer ID (Team X4MH29QNRS), hardened runtime | 27.3 MB zipped, 55 MB unpacked |
| ffmpeg + ffprobe 9.0.2 | LGPL-only minimal build from the pinned source (`scripts/build-ffmpeg-minimal.sh`) | `Contents/Resources/Tools/ffmpeg/` | same | 3.4 MB zipped, 7.2 MB unpacked |
| setu-jsc 1.0.0 | our own JavaScript runner on Apple's JavaScriptCore (`apps/apple/Helpers/JSProvider`) | `Contents/Helpers/setu-jsc` | same, **App Sandbox entitlement only** | 84 KB |
| yt-dlp plugin | `setu_jsc.py`, makes yt-dlp use the runner | `Contents/Resources/YtDlpPlugins/setu/yt_dlp_plugins/extractor/` | covered by the app signature | 3 KB |

The Mac App Store and iOS targets embed none of this and show the tools as "not available in this build".

## Decisions

1. **Bundled, not downloaded, for the Direct build.** The two third-party tools add about 62 MB unpacked / 31 MB compressed to a 67 MB DMG, and they work offline with no hosting dependency. The app's notarization covers them.
2. **The installer stays** (approved hosts, size, SHA-256, tree digest, architecture, Team ID, Apple's assessment, atomic activation, rollback). It is for later updates of a tool, and only offers a package once one is hosted and verified (`sourceURL` is empty until then, so no install button can fail).
3. **One embedder.** `scripts/embed-media-tools.sh` is the only thing that puts yt-dlp and ffmpeg in an app; the Xcode project embeds nothing (it only copies the pinned templates so Debug/App Store builds can say "not available"). `scripts/embed-js-provider.sh` owns the runner.
4. **YouTube's JavaScript challenges are solved by our own sandboxed runner, not by Deno or Node.** See below. Deno stays the documented fallback for a case the native runner genuinely cannot handle; it is not shipped and not required.
5. **Apple Silicon only**, because the app itself is arm64-only (`release.sh` builds `ARCHS=arm64`). `embed-media-tools.sh` takes the app's own architecture and refuses a universal app until the tools are built per architecture.

## The JavaScript runner

yt-dlp needs a JavaScript engine for YouTube's `n` and signature challenges. It has no built-in engine; it runs the `yt_dlp_ejs` solver scripts in an external runtime (Deno by default, also Node, QuickJS, Bun).

### Measured (2026-11-10, Apple Silicon, shipped helper from the built app)

Real YouTube player `a5c2aafe`, seven player variants (`es6`, `main`, `tce`, `es6_tce`, `tv`, `tv_es6`, `phone`; `es5` returns 404), the exact solver scripts bundled with yt-dlp 2026.10.26 (EJS 0.8.0), 5 runs each. Machine load was still settling (about 11) at the start of the run.

| | setu-jsc (JavaScriptCore, sandboxed) | Deno 2.9.8 | Node 26.8.2 `--permission` |
|---|---|---|---|
| Solver output on all 7 variants | identical | identical | identical |
| Median solve time | 1.18 s (0.83-1.71) | 0.34 s | 0.32 s |
| Peak memory | 130-203 MB | 219-284 MB | 230-284 MB |
| Process startup (trivial script) | 15 ms | 13 ms | 43 ms |
| Live `yt-dlp -F`, one video, median of 3 | 3.78 s | 3.31 s | not run |
| Size added to the app | 104 KB (+3 KB plugin) | about 81 MB unpacked | not bundled |
| Relaxed code-signing entitlements | none (App Sandbox only) | four (JIT, unsigned memory, no page protection, no library validation) | n/a |

Also measured: 8 simultaneous solves finish in 4.5 s wall at 181 MB each; five repeat solves gave identical output with flat timing; with no provider a live listing takes 1.9 s but returns fewer formats (24 instead of 25 on the test video; the missing format needs the challenge solved).

QuickJS was not measured: downloading and running an unvetted third-party binary was blocked in the session that did this work.

### Why this design

- JavaScriptCore as reached through the public framework runs interpreter-only here (the JIT option made no measurable difference), which is why it is about 3.5x slower than V8. It solves once per player per extraction, so about half a second more end to end is acceptable. A persistent helper is not worth it: startup is 15 ms, the cost is parsing the player, and a long-lived process would carry state between requests. yt-dlp's own preprocessed-player cache is disabled upstream (large files); not worth adding for one second.
- **Isolation.** A separate process, a fresh `JSVirtualMachine` per run, no DOM/`fetch`/timers/modules/WebAssembly, and confinement by the **App Sandbox entitlement alone**. Verified two ways: the OS's own `sandbox_check` against the *running* shipped helper (`scripts/tests/test_js_helper.py`, with a positive control showing an unconfined process comes out ALLOWED) reports DENIED for the user's Documents, Desktop, Downloads, the BrowserSetu data folder, cookies, Safari data, shell dotfiles, `~/.ssh`, `/tmp`, every file write, and network outbound, inbound and bind; the system's own frameworks stay readable because it must run. The helper **refuses to run outside the sandbox** (exit 3); an environment variable cannot switch that off in a release build. It shares nothing with the browser's WKWebView pages, cookies or profiles; the browser never talks to it. No XPC service is needed because the process-level sandbox demonstrably enforces the restrictions.
- **Not used:** `sandbox_init`/SBPL profiles (Apple documents them as deprecated and unsupported for third parties; the named profiles kill the process on macOS 27) and the third-party `yt-dlp-apple-webkit-jsi` plugin (WKWebView inside yt-dlp's own process through PyObjC, which this frozen build does not have; it also subclasses the same private EJS class).
- **Bounded:** the helper enforces input 16 MB, output 8 MB, a wall-clock deadline (default 120 s; the plugin asks for 50), CPU 120 s, and a 1 GiB memory footprint watchdog; the plugin additionally times the whole run out at 45 s and stops using the helper after two consecutive infrastructure failures. Failures are classified (`js-error`, `input`, `unsandboxed`, `output-limit`, `memory-limit`, `deadline`, `timeout`, `crash`, `protocol`, `solver`) so they are never guessed.

### Fallback order: implemented, and prepared but not shipped

| Tier | State in 0.4.1 | Evidence |
|---|---|---|
| 1. Built-in solver (sandboxed JavaScriptCore helper + plugin) | **Implemented, shipped, used** | Real app and real yt-dlp: 40 formats incl. format 18; 7 player variants identical to Deno and Node; 7 historical player versions match yt-dlp's expected answers exactly |
| 2. Managed Deno (installed and verified by Browser Setu) | **Prepared in the code, NOT shipped, NOT hosted, NOT offered, NOT required.** With no `BundledDeno.json` (no 0.4.1 build has one) it is absent and changes nothing. | Gating logic unit-tested; the future package pipeline builds and signs it on request (never part of `--tool all`) |
| 3. No solver | **Implemented** (it is what yt-dlp does by itself) | Real app: tampered plugin or helper gives 32 formats (format 18 missing), clean exit; a crashing or hanging helper is bounded and extraction continues |

How the tiers are chosen: the app passes yt-dlp `--plugin-dirs <verified folder>` and, **only if a managed Deno passes every check**, `--js-runtimes deno:<absolute path>`. yt-dlp ranks the native provider above Deno, so Deno is only ever used when the native one is unavailable. PATH is never searched; no Homebrew or user-installed Deno or Node is ever found (the fixed environment has `PATH=/usr/bin:/bin` and the app never passes a bare runtime name). The Settings row and `JSSolver.report()` (also printed by the Debug self-test) state which tier is in use and why a tier is not.

A managed Deno is used only if: its manifest (`BundledDeno.json`, generated by the pipeline from the verified package) is present; the installed files equal the pinned tree digest; the executable is inside Browser Setu's own tools folder; it is signed with the **app's own Team ID** (valid strict signature, hardened runtime, entitlements a subset of the four Deno needs); its Mach-O header matches this Mac's processor and the pin; its version is at least yt-dlp's minimum (2.3.0); and the pin lists the yt-dlp release the app carries. Any single failure is "not used", with the reason. It reuses the existing managed-tool machinery (versioned folder, atomic install, rollback); there is no second installer. The package pipeline accepts `--tool deno` (signed with Deno's entitlements, upstream's signature and version checked first) and caches it exactly like the others; this was prepared without changing the cache keys of the already notarized packages.

A yt-dlp the person chose in Settings > Media is **never** given any of this: it receives exactly the page arguments it always did (no plugin folder, no runtime, no config flags), and it is still only used after the existing consent and identity checks. `ExternalExtractor.launchArguments` is the single place that decides, and it is tested.

Failure handling inside tier 1 (all measured): a helper that crashes or exits abnormally is classified; after **two** consecutive failures in one yt-dlp run it is not started again in that run (three videos asked about: two helper starts); a helper that never answers is ended at 45 s and extraction continues; the next run is a new process with a fresh counter and uses the real helper again.

When the puzzle cannot be solved, the error says plainly that YouTube hides some addresses behind a puzzle, that the built-in solver could not solve it or is unavailable, to try again later and check for an update, and that Settings > Media can use a yt-dlp the person installed. It does not recommend installing Deno, because Browser Setu has no such workflow.

### Security model, and what it does not cover

The chain is BrowserSetu -> yt-dlp -> provider plugin -> setu-jsc. An independent review (2026-11-10) found real defects that were fixed and are now tested; what each layer guarantees:

- **Only the approved plugin loads.** The app always passes `--no-plugin-dirs` first, then `--plugin-dirs <Resources/YtDlpPlugins>` only after verification. Tested against decoy plugins planted in every location yt-dlp searches by default (`~/.config/yt-dlp/plugins`, `$XDG_CONFIG_HOME/yt-dlp/plugins`, `~/yt-dlp-plugins`, `PYTHONPATH`, the working directory, next to the executable), with the control proving the live ones actually load without the app's flags. The app pins the **whole plugin folder** (`pluginTreeSHA256`), not just the one file, because yt-dlp imports every module under the folder it is given; an extra module, package, cache file or link makes the provider unavailable. `pluginDirectory` must be a single named folder (never `.` or all of Resources).
- **The helper is the team's, checked by Apple's code-signing API at run time**, not by trusting the manifest: valid strict signature, Developer ID anchor, Team ID equal to the running app's own, identifier `com.browsersetu.mac.jsc`, hardened runtime, and exactly one entitlement (`com.apple.security.app-sandbox`). An unsigned development build has no Team ID of its own and never uses the provider.
- **The helper refuses to run unconfined, by the kernel's answer.** It asks `sandbox_check` whether *it* is denied network access; it no longer trusts an environment variable (the first version did, and the review showed an unsandboxed copy launched with `APP_SANDBOX_CONTAINER_ID` set ran scripts unconfined; fixed and tested).
- **Bounded, whatever the script does:** input 16 MB (read incrementally; the wall-clock deadline also covers reading, so a stdin that never closes cannot hold it), stdout 8 MB, **stderr 64 KB** (an uncapped flood produced 72 MB in 8 s), wall clock, CPU, 1 GiB footprint watchdog (`_exit`, so no exit handlers run while the script thread does). Large single allocations end in an engine out-of-memory error or the watchdog within a second.
- **The plugin cannot leak an unhandled exception into yt-dlp:** byte-mode I/O (no decode errors), a recursion bomb in the helper's answer is a classified `[protocol]` error, any unforeseen exception becomes `[internal]`, answers are schema-validated, a *partial* answer is a failure of that request, and every message that came from the helper is flattened to short printable ASCII before it reaches a log or dialog.
- **Release preflight on the built app:** manifest paths stay inside the app, the plugin folder is exactly the one plugin file and matches its pin, the solver scripts are hashed as text the way the plugin hashes them, the yt-dlp-ejs version and the yt-dlp version are read from the embedded yt-dlp itself, yt-dlp must actually find the plugin folder, and the final signed helper's limits are exercised (not only its `--version`).

**Residual risks, stated plainly.** (1) Someone who can write inside the signed app can replace the app itself; the checks defend against accidental corruption and unprivileged tampering in a user-writable install, not against an attacker with that access. (2) The verification happens when the app builds yt-dlp's arguments; yt-dlp loads the plugin and the plugin starts the helper a moment later, and the plugin does not re-hash the helper (it checks the helper's `--version` handshake, which any program could print). The window is milliseconds and needs the same write access as (1). (3) The App Sandbox does let the helper start a child (which inherits the sandbox); the script has no API to do so. (4) Spawning is not denied by the helper's own profile because we deliberately use no custom sandbox profile. (5) The memory watchdog polls twenty times a second; a script cannot exceed the limit for long, but it is not a hard cap.

### Upstream compatibility

- The plugin uses only yt-dlp's documented public provider API (`yt_dlp.extractor.youtube.jsc.provider`). It does **not** import yt-dlp's private `EJSBaseJCP`. The one unavoidable EJS-specific piece, how the `lib` and `core` solver scripts are called (contract 1), is the small adapter `ejs_script_v1`.
- `COMPATIBILITY` at the top of the plugin is the single record of what this release was verified against: the yt-dlp version, the EJS version **and the SHA-256 of its exact `lib` and `core` scripts**, the helper protocol, the script contract and the challenge types. At run time the plugin is unavailable (yt-dlp falls back to its other providers, and says so once) unless yt-dlp's version, the EJS scripts' digests and the helper's `--version` handshake (`setu-jsc <version> protocol <n>`) all match. The app (`JSChallengeProvider.swift`) refuses to hand yt-dlp the plugin folder unless the helper and plugin match the digests in `BundledJSProvider.json` and the manifest was written for the pinned yt-dlp. The release preflight enforces all of it on the built app.
- The helper's answer is schema-validated (type, response count, text-to-text data, only the challenges asked, length limits) before yt-dlp sees it.
- **Every yt-dlp or EJS bump therefore fails the release preflight until `COMPATIBILITY` is updated deliberately.** The procedure is below; the live check is part of it.

### Compatibility actually established, and not

**Established (2026-11-10, shipped helper, real yt-dlp 2026.10.26 and its bundled EJS 0.8.0 scripts):**
- 7 variants of YouTube player `a5c2aafe` (`es6`, `main`, `tce`, `es6_tce`, `tv`, `tv_es6`, `phone`): solver output identical on JavaScriptCore, Deno and Node.
- 7 further, older player versions from yt-dlp's own EJS fixtures (`scripts/tests/test_js_players.py`): **7 of 7 gave exactly yt-dlp's expected answers**, for both challenge types, including control characters and `%`, `/`, `=` inside challenges. None were unavailable.
- Live metadata listing of two public videos: format IDs identical to a Deno baseline; the native provider is discovered and selected; concurrent extractions work; offline fails fast and cleanly; with no provider extraction still works, with fewer formats.
- Through the real app binary (isolated profile, real launcher): 40 formats including format 18; a tampered plugin or helper degrades to 32 formats, clean exit.
- Failure handling with the real yt-dlp: a crashing helper opens the breaker after two starts (three videos asked about), extraction continues, and the next run recovers; a helper that never answers is ended at the 45 s deadline with no process left behind.

**Not established:** playlists and live streams (the tests exist; they need URLs: `BS_LIVE_PLAYLIST`, `BS_LIVE_STREAM`); players newer than the ones available when this was run; other websites (they need no JavaScript); any claim that every video works; QuickJS (blocked); a click-through GUI session (see below).

**Real GUI-level testing was not possible for the signed release app.** The release build has no test hooks by design, so it cannot be given an isolated profile, and it carries the iCloud entitlement; driving it would touch real user data. What was done instead: the real application binary, with the Debug-only self-test and an isolated throwaway profile, signed with the team identity so the production signature checks run for real, using the app's own launcher and verifier. Clicking through the download sheet (consent, quality list, progress, cancel) is **unverified** for the new provider; the existing UI tests cover that flow with stand-in extractors.

## Release procedure

```
scripts/release.sh <version> <build>              # full release
scripts/release.sh <version> <build> --verify-only # same pipeline up to the final signature and preflight, in a temp folder; nothing notarized
```

1. `scripts/release-media-tools.sh --ensure` (called by `release.sh`) reuses a cached signed + notarized package when its key is unchanged **and** it re-verifies from its bytes (zip and tree digests, every signature, Team ID, hardened runtime, Developer ID chain, exact architecture, an Accepted notarization record naming that very zip). Otherwise it builds, signs, submits to Apple, requires "Accepted", and caches. Cache: `~/Library/Caches/BrowserSetu/media-tools` (override `MEDIA_TOOLS_CACHE`). The key is the version, architecture, Team ID, the pinned upstream inputs and the packaging recipe (the `RECIPE-BEGIN..END` block of the script), so a new certificate of the same team reuses packages and a changed recipe rebuilds them. Upgrading a tool leaves the old entry in place for rollback.
2. The app is built; `embed-media-tools.sh` and `embed-js-provider.sh` put the tools in it. Manifests are **generated** from the verified package (`scripts/media_tools_cache.py manifest`), never copied from the templates in `ThirdParty/*/MANIFEST.json`.
3. `scripts/check-media-tools.sh <app> --team ... --readme README.md` fails the release unless the built app is consistent: manifests valid and free of stale text, embedded files equal their digests, every Mach-O Developer ID signed with the right Team/runtime/timestamp/architecture, notarization record Accepted, licence texts and source offers present, the runner and plugin match their pins and entitlements, no unhosted download address, and the README claims nothing the app does not contain.
4. The app and DMG are notarized, stapled and assessed by `release.sh`.

When a tool is bumped: edit its template in `ThirdParty/<tool>/MANIFEST.json` (version and upstream pins only), run `scripts/fetch-bundled-tools.sh` (yt-dlp) or `scripts/build-ffmpeg-minimal.sh` (ffmpeg), and run the release; the cache rebuilds only what changed.

After any yt-dlp / EJS bump: (1) read yt-dlp's `jsc/_builtin/ejs.py` `_construct_stdin` and the EJS release notes for a changed script contract; (2) update `COMPATIBILITY` in `setu_jsc.py` (versions and the SHA-256 of the new `lib.min.js` and `core.min.js`; `shasum -a 256` on the files in the embedded tool); (3) run the opt-in live suite on the built app:
```
BS_LIVE=1 BS_APP=<built app> BS_DENO=<deno binary> python3 -I -m unittest discover -s scripts/tests -p 'test_js_live.py' -v
```
It must find `SetuJSC … (external)`, report solving with Browser Setu's helper, and list the same format IDs as Deno. `test_js_chain.py` (decoy plugins, environment, process-group kill) and `test_js_helper.py` (hostile scripts, limits, the sandbox of the running helper; `BS_JSC_HELPER=<app>/Contents/Helpers/setu-jsc` tests the shipped binary) run against the built app too.

## Hosting (not done)

Nothing is hosted. When authorized: upload each cached `package.zip` as an immutable GitHub release asset (`media-tools-<tool>-<version>`), verify the hosted file's SHA-256 equals the manifest's, then pass the URL to `media_tools_cache.py manifest --hosted-url` and run the check with `--hosted-verified`. Never use a mutable `latest` URL.

## Open before public distribution

- **Legal review is not complete.** The combined yt-dlp executable is GPL-3.0-or-later (GNU Readline GPL-3.0+, mutagen GPL-2.0+, and others listed in `THIRD_PARTY_LICENSES.txt`); ffmpeg is LGPL-2.1+; LAME is LGPL-2.1. Corresponding-source archives and a written offer are prepared (`docs/compliance/media-tools-release-assets/`), but the complete corresponding source of every GPL component inside the PyInstaller build has not been collected, and no one has signed off. See `docs/compliance/media-tools-redistribution.md`.
- Source archives are not yet hosted anywhere.
- Intel Macs are unsupported until the app and the tools are built for x86_64.
