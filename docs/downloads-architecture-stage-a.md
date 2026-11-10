# Downloads: capability-driven architecture, Stage A decision record

Status: **plan only**. No code was changed for this record. Source of truth: the repository as it stands today (about 427 uncommitted paths, nothing committed since the Downloads work began) plus `docs/media-downloads.md`. Everything marked *unverified* below was not tested or could not be confirmed from an authoritative page.

## 1. Current implementation inventory

| Layer | Component | Owner (file) | Real work or display only | Verified how |
|---|---|---|---|---|
| Discovery | 13-category link classifier, page scan, chips, popovers | `Shared/Downloads/Detection/ResourceDetection.swift`, `macOS/Chrome/ToolbarExtras.swift` | Real (reads link addresses, classifies) | 16+ unit tests, native click-throughs |
| Discovery | Player observer, media candidates | `Engines/WebKit/MediaPageObserver.swift`, `Shared/Downloads/Media/MediaDiscovery.swift` | Real | DX-07 tests |
| Resolution | Provider recognition and sources (Vimeo, PeerTube, TikTok export) | `MediaProviders.swift`, `MediaProviderFlow.swift` | Real for 3 routes; watch pages of other providers: **no resolver** | DX-09 tests, fixtures only |
| Resolution | HLS/DASH manifests | `MediaManifest.swift` (1040 lines), `MediaRunner.swift` | Real | DX-08 tests, fixture streams |
| Resolution | External extractor (user-chosen program) | `ExternalExtractor.swift` | Real process launch + parser | stand-in script only |
| Normalization | `NormalizedMediaSource` (direct tracks, manifest) | `NormalizedMedia.swift` | Real | matrix tests |
| Planning | Options per source, save operations | `VideoOptions.swift`, `VideoSaver.swift`, `NormalizedMediaSaver.swift` | Real | interop tests |
| Transfer | HTTP engine, multipart, torrent, stream engine | `Shared/Downloads/HTTP/*`, `Torrent/*`, `MediaRunner.swift` | Real | earlier phases |
| Processing | Join tracks (AVFoundation passthrough), M4A extraction, MP3 (LAME 3.100, dynamic) | `MediaAssembler.swift`, `MediaProcessing/*`, `MP3Encoder.swift` | Real | probed outputs |
| Lifecycle | Queue, ledger, state machine | `Shared/DownloadCoordinator.swift`, `DownloadLedger.swift`, `DownloadStateMachine.swift` | Authoritative | earlier phases |
| UI | Chips, list, Download sheet, picker, consent, Settings › Media | `ToolbarExtras.swift`, `VideoDownloadSheet.swift`, `MediaDiscoveryView.swift`, `ProviderSettings.swift` | Real | UI tests |
| Safety | Consent store, executable trust, process lifecycle | `MediaConsent.swift`, `ExternalExtractor.swift` | Real | adversarial tests |
| Packaging | Targets (Mac, Direct, share extensions), arm64 only, Sparkle in Direct | `project.yml` | | |

**Where capability selection happens today, and why it is fragile.** There is no single place. Selection is spread over: `ResourceClassifier` (category by extension), `MediaClassifier` (kind by element/type), `ProviderRecognizer`/`ProviderRegistry` (provider by host), `VideoOptions.options(for:)` and `NormalizedMediaSource.options()` (two parallel option builders), `VideoDownloadSheet` (a switch on subject kind: provider video → extractor view, stream → picker, file → file body) and `SourceSaveOperation.run` (switch on source shape). Consequences: the same media can be offered different choices depending on which door it came through (picker vs chip list vs sheet); the external extractor is reachable only from provider-video entries; nothing decides "this page needs an extractor" except the sheet's `providerVideo` case. Two option builders is the clearest duplication.

## 2. Capability router

**Decision.** Add one small pure type, `DownloadRouter`, that maps a *resource descriptor* to an ordered *route* (a list of candidate resolution steps, each with a timeout and a fallback rule). It does not fetch, spawn, queue or track state. `DownloadCoordinator` stays the single owner of task lifecycle. The router's output is data that the existing sheet and `SourceSaveOperation` execute.

Input (what is already known, never re-probed): kind (file URL, media element, playlist, video page, metadata-only, gallery, torrent/magnet, developer artifact, cloud share, remote protocol), any descriptor already in hand (direct tracks, manifest), whether a probe for this normalized address was already made (a small in-memory cache keyed by `LinkClassifier.normalizedKey`, per tab navigation, 5 minutes), user settings, consent state, tab privacy.

Rules, in priority order (first applicable wins; a later one runs only if the earlier one returned a *structured* "no sources" result, never on a timeout or a permission refusal):
1. A descriptor already exists (direct tracks, manifest) → no resolver; plan directly.
2. File URL / HTML5 element / torrent / magnet → native; no resolver.
3. Known provider with a documented route (Vimeo, PeerTube, TikTok export) → provider adapter.
4. Video page with no descriptor → extractor step, then re-enter at rule 1 with what it returned.
5. Otherwise → "Source not resolved", with the reason, and no format list.

Timeouts: native probe 10 s; provider API 20 s; extractor 60 s (existing). One attempt per step per normalized address per navigation; failures are remembered so the same page is not re-run. An extractor is run only on a user action (the Download click), never in the background.

Alternatives considered:
- **A. A router type beside `ProviderRegistry` (chosen).** Small, testable as a pure function, no new state owner. Risk: one more concept. 
- **B. Grow `ProviderRegistry` into the router.** Fewer types, but the registry is provider-shaped (hosts, accounts, scopes); making it route files, galleries and torrents would recreate domain-driven selection and mix concerns.
- **C. Let each entry point decide (today).** Zero work, but it is the fragility described above.

## 3. Responsibility boundaries

Discovery says *what is on the page*. Router says *which step could turn it into media*. Resolvers (native, provider, extractor) return a `MediaSourceDescriptor` or a structured failure. The planner turns a descriptor plus a choice into a `DownloadPlan`. Transfer engines move bytes. Processors transform finished files. `DownloadCoordinator` owns task state, queue, cancel and the final file. An extractor never downloads: it returns descriptors; a tool that can only perform an opaque download (no reusable URLs) is represented as a distinct plan step (`toolTransfer`) and is **not** adopted in the first stage (see risks).

## 4. Contracts (versioned)

`MediaSourceDescriptor` v1 is `NormalizedMediaSource` plus: `schemaVersion`, `origin` (native | provider(id) | extractor(toolID, toolVersion)), `renewal` (none | provider(id) | rerunExtractor), `authContext` (none | providerToken | needsSignIn), `processing` (per representation: none, join, remux, convert(codec)), `failure` (structured: unsupported, expired, permission, unavailable, retryable). Representation fields already carried: format id, container, codecs, width/height/fps, language, channels, bytes, expiry. `DownloadPlan` = ordered steps `[transfer(native|stream|tool), join, remux, convert, verify]`, each step naming the engine that executes it; a format is selectable only if a plan can be built for it (the existing `planProblem` rule, moved into the planner). Tool output is parsed against an explicit versioned schema per tool (`yt-dlp-json` v1 today); an unknown future shape is rejected, not guessed.

Mapping to existing code: `NormalizedMediaSource` → descriptor (add fields); `VideoOptions` + `NormalizedMediaSource.options()` → merged into one planner (removes the duplicate builder); `SourceSaveOperation` → plan executor.

## 5. Tool comparison and bundling recommendation

| Tool | Unique capability | Overlap with BrowserSetu | Runtime needs | Licence of the distributable | Recommendation |
|---|---|---|---|---|---|
| Existing engines + LAME 3.100 | HTTP, stream, torrent, AVFoundation, MP3 | n/a | none | LGPL 2.1 (LAME, dynamic) | Keep |
| yt-dlp | Broad page → media resolution | none for page extraction | standalone binary, or Python; for full YouTube a JS runtime (Deno recommended) plus its `yt-dlp-ejs` | Source: Unlicense. **PyInstaller executables include GPLv3+ code; the combined executable is GPLv3+** (upstream README). Zipimport `yt-dlp`: ISC/MIT code only | **Gate, do not approve yet** (below) |
| FFmpeg | WebM/VP9/Opus mux, remux, audio extract | AVFoundation covers MP4/M4A | none | LGPL 2.1+ only if built without `--enable-gpl` and `--enable-nonfree` (no libx264). Common prebuilt macOS builds are GPL | Bundle only a **self-built LGPL** configuration, only if a WebM requirement is confirmed |
| gallery-dl | Galleries/collections | none | Python | GPL-2.0 *(unverified here)* | DX-10, later |
| Streamlink | Live streams | none | Python | BSD *(unverified)* | DX-11, later |
| N_m3u8DL-RE | HLS/DASH | **overlaps DX-08** | .NET | MIT *(unverified)* | Not needed |
| aria2 | Multi-source transfer | **overlaps** coordinator | none | GPL-2.0 *(unverified)* | Do not bundle |
| Lux | Alternative extractor | overlaps yt-dlp | Go binary | MIT *(unverified)* | Evaluate as the alternative to yt-dlp only |

**yt-dlp packaging options** (a substantial choice; three alternatives):
- **Option 1: ship the official `yt-dlp_macos` standalone binary.** Easiest and what upstream tests. Obligations: GPLv3+ for the executable (licence text, source offer for it and its bundled components, notices), kept as a separate program invoked as a subprocess. Whether this arrangement is *aggregation* (BrowserSetu stays separate) is a legal question, not a technical one. Size and universal-vs-arm64: *unverified*; upstream calls it "Universal macOS 10.15+".
- **Option 2: ship the zipimport `yt-dlp` with a bundled Python runtime.** Avoids the GPLv3+ combined work (ISC/MIT/Unlicense code plus PSF Python), but adds a Python framework to bundle, sign and update (size and signing effort *unverified*), and every nested Mach-O needs its own signature.
- **Option 3: do not bundle; keep today's user-chosen program.** No new obligations; fails the zero-setup goal.

**Recommendation.** Do not approve bundling in Stage B until: (a) counsel reviews Option 1 versus Option 2 for GPLv3+ and for the exposure of distributing, in a commercial product, a tool whose purpose includes defeating a provider's technical access measures (a legal question separate from the licences: the 2020 youtube-dl takedown episode is the precedent to ask about); (b) the YouTube JS-runtime dependency is decided (it is not optional for full YouTube support); (c) a real run of the tool through the existing adapter passes the acceptance gates in §12. Until then the router treats "extractor" as an interface with two implementations: the user-chosen program (exists) and a bundled one (not built).

## 6. Media-processing strategy

Prefer AVFoundation passthrough (MP4/M4A/MOV, H.264/HEVC/AAC) because it is already correct and verified. Use FFmpeg only for a recorded gap: WebM/VP9/Opus join or audio extraction, and containers AVFoundation rejects. Never transcode silently: a conversion appears as a labelled "Converted" option. MP3 stays on LAME. The planner chooses by a table (container × codec × operation → engine) that tests assert; "unsupported" is a result, not a fallback to guessing.

Alternatives for FFmpeg: **A** bundled CLI built LGPL (chosen if needed; simple process model, reuses the reviewed launcher); **B** link libav* as LGPL dynamic libraries (in-process, fastest, more code and crash risk); **C** no FFmpeg (WebM stays "saved as is").

## 7. Errors, retry, cancellation

One structured failure type shared by resolvers and processors (unsupported / expired / permission / unavailable / retryable / cancelled). Retry only for `retryable`, bounded to 2, never the same request to the same host with the same arguments. Cancel flows through the coordinator and the existing process-group kill; temporary files are removed by owner-checked cleanup (exists). Task states are the existing state machine plus a `Planning` and `Processing` display state mapped onto existing ledger states (no new ledger states in Stage B).

## 8. UI integration plan

No new screens. The Download sheet keeps one flow: it asks the router, shows *Resolving…*, then the format list, then *Planning/Downloading/Processing*. Settings › Media keeps "Use my own extractor" as an advanced override; a bundled tool would appear as a read-only line ("Bundled extractor, version X") with the same consent prompt, because the tool makes its own network requests from the user's Mac. Files: `VideoDownloadSheet.swift` (use router output instead of its subject switch), `ProviderSettings.swift`.

## 9. Security and consent

Bundled tools differ from user-chosen ones only in identity: a bundled tool is verified by its code signature and a pinned digest recorded in the app (no per-user hash prompt); a user-chosen one keeps path + full SHA-256 consent. Both run through the same launcher: direct spawn in its own session, fixed environment, closed descriptors, output cap, timeout, process-group kill, never in a private tab, no cookies or tokens passed. Bundling does not make output trusted: the same parser bounds, host checks and local-address rule apply. Consent stays scoped (once / site / profile) and bound to the executable identity.

## 10. Packaging and licensing matrix

| Item | Pin | Licence | Obligation | Placement / signing |
|---|---|---|---|---|
| LAME 3.100 | tarball sha256 in `ThirdParty/lame/README.browsersetu.md` | LGPL 2.1 | notice, source offer, replaceable (dynamic) | `Contents/Frameworks/libmp3lame.dylib` (in place) |
| FFmpeg (if adopted) | exact tag + configure line + tarball digest | LGPL 2.1+ if built without GPL/nonfree | dynamic or replaceable; ship matching source and configure line; attribution (about box); no reverse-engineering ban; patent disclaimer awareness (H.264) | helper executable, signed individually |
| yt-dlp (if adopted) | exact release + `SHA2-256SUMS`/GPG signature | Unlicense source; **GPLv3+ for the PyInstaller executable** | GPLv3+ text, source offer for the binary and its bundled components (Python PSF, OpenSSL Apache-2.0, zlib, SQLite, etc. per upstream `THIRD_PARTY_LICENSES.txt`) | helper executable, signed individually; PyInstaller binaries may need extra hardened-runtime entitlements (*unverified, must be tested under notarization*) |
| SBOM | one machine-readable file per release listing every bundled tool, version, digest, licence | | | in repo + in app's About |

Apple guidance (secondary sources only; the primary Apple page was not reached): sign nested code individually, inside out, with the hardened runtime, and avoid `codesign --deep` for signing. Exact helper location (`Contents/MacOS` vs `Contents/Helpers`) and per-tool entitlements are *unverified* and are a Stage C gate.

## 11. Updates and rollback

Open conflict, needs your decision. yt-dlp's own guidance: stable releases are "prone to external breakage" and nightly is the channel for regular users; sites change faster than app releases. Your rule: no automatic executable downloads after first launch. Options: **(1)** tools update only with the app (Sparkle); simplest, but the extractor will go stale between releases. **(2)** a separate signed "extractor pack" fetched only when the person presses *Update extractor*, verified (digest + signature + Developer ID) before first run, previous version kept for rollback. **(3)** user-managed program only. Recommendation: (2), explicit-click only, but it contradicts a literal reading of the rule, so it needs your approval.

## 12. Test matrix and acceptance gates

Contract tests per resolver/processor (schema versions, error mapping). Fixture integration for each source type listed in the brief (direct, HLS, DASH, separate tracks, audio-only, video-only, WebM, MP3, M4A, qualities, expired, invalid). **Real bundled tool:** launch the actual executable, parse its real output, build the plan, enqueue, transfer bytes, publish, probe the file independently. Native UI: discovery → click → consent → format → progress → completion/cancel/failure. Adversarial: hostile JSON (exists), replaced executable, hanging children (exists), stale selections, temp leaks, private data, migration regressions. **Gate to approve bundling:** one authorised, real, non-fixture source goes page → tool → descriptor → coordinator → probed file with the bundled executable, under a Developer ID–signed, hardened-runtime build that launches the tool successfully.

## 13. Performance and reliability

Router adds no network. Extractor lookups are user-triggered and cached per navigation. Concurrency limit stays 2. A bundled Python-based tool starts slowly (cold start *unmeasured*); show *Resolving…* immediately. Binary size of candidates is *unmeasured*; app is arm64-only (`ARCHS: arm64`), so tools need only an arm64 slice.

## 14. Likely source changes (by stage)

New: `Shared/Downloads/Media/DownloadRouter.swift`, `DownloadPlan.swift`, `BundledTool.swift` (identity + launcher wrapper over `ExternalExtractor.run`), `ToolSchema.swift`. Modified: `NormalizedMedia.swift` (descriptor fields), `VideoOptions.swift` (merge into planner), `NormalizedMediaSaver.swift` (plan executor), `ExternalExtractor.swift` (extract the launcher), `VideoDownloadSheet.swift`, `ProviderSettings.swift`, `project.yml` (copy-files phase for helpers, signing phase), `docs/media-downloads.md`.

## 15. Migration and compatibility

No data migration. Consent grants stay bound to path + digest for user-chosen programs; bundled tools use a separate purpose so existing grants are untouched. The Direct and Mac targets stay unsandboxed; the share extensions stay sandboxed. iCloud key-value sync and Keychain behaviour are untouched (release gates unchanged: signed-build verification).

## 16. Stages

A (this record). B: router + descriptor + planner merge, with the existing user-chosen extractor as the only extractor (no new binaries). C: bundled-tool wrapper, identity, packaging, signing experiment (blocked on the gates in §5). D: FFmpeg gap routes, only if a WebM requirement is confirmed. E: UI integration for resolving/planning states. F: adversarial tests and dependency review. G: distribution readiness (signing, notices, SBOM, iCloud/Keychain).

## 17. Roadmap mapping

Everyday: images/galleries, cloud shares, offline pages → DX-10 (gallery-dl evaluated there); organization, preview, recovery exist (earlier phases). Power: LinkGrabber, Packages, torrents, scheduling, automation exist; FTP/SFTP/WebDAV/Metalink → DX-12; live recording → DX-11; metadata → DX-13; final UX → DX-14; recipes and remote control → after DX-10. Developer: GitHub/GitLab releases, Hugging Face, API exports, source bundles, object storage → official-API adapters, sequenced after DX-10 and routed by the same router (rule 3).

## 18. Risks and unresolved decisions

1. **Legal exposure, separate from licences:** shipping a tool built to get around providers' access measures in a distributed product. Needs counsel before Stage C.
2. GPLv3+ of the official macOS executable (Option 1 vs 2).
3. YouTube needs a JS runtime (Deno or equivalent): another bundled, signed, updated component.
4. Update policy vs "no automatic executable downloads".
5. Hardened-runtime/notarization behaviour of PyInstaller binaries and Python frameworks: unverified.
6. Staleness: a bundled extractor ages quickly.
7. Opaque-download tools (no reusable URLs) cannot be represented without a `toolTransfer` step; not planned.
8. Keychain and iCloud on the Developer ID build remain unverified release gates.

## Component table

| Component | Existing owner | Proposed modification | Reason | Risk | Test | Stage |
|---|---|---|---|---|---|---|
| Router | none | new pure `DownloadRouter` | one place for selection | low | rule table tests | B |
| Option builders | `VideoOptions`, `NormalizedMediaSource.options()` | merge into one planner | remove duplicate logic | medium (UI regressions) | existing matrix + UI tests | B |
| Descriptor | `NormalizedMediaSource` | add version/origin/renewal/auth/processing/failure | stable contract | low | contract tests | B |
| Launcher | `ExternalExtractor.run` | extract to shared launcher | reuse for bundled tools | medium | adversarial suite | C |
| Bundled tool identity | none | signature + pinned digest check | trust without per-user hash | medium | tamper tests | C |
| Sheet | `VideoDownloadSheet` | call router; states Resolving/Planning | consistent flow | medium | native UI | E |
| Settings | `ProviderSettings` | bundled-tool line, advanced override | transparency | low | UI | E |
| FFmpeg routes | none | planner entries for WebM gaps | gap fill only | medium (licence) | probe tests | D |
| Update channel | none | explicit-click signed pack | freshness | high (policy) | integrity tests | C/G |

---

## Decisions recorded after review (Nov 8)

Approved: capability-driven router and unified planner (implemented as Stage B, see `media-downloads.md`); App Sandbox stays off for the main Mac app; LAME stays as the dynamic library; legal review is required before distributing a contentious extractor; user-approved, integrity-verified tool updates are allowed, silent executable downloads or replacements are not; prefer an appropriately licensed, reproducible FFmpeg build; keep the extractor choice open (no binary chosen); avoid committing to a Python runtime until the packaging comparison is done; UI preserved; DX-10 to DX-14 deferred. Corrections noted: GPL licensing does not itself prohibit commercial distribution, it adds obligations; the youtube-dl 2020 dispute is context for the legal review, not a ruling that extraction tools are unlawful.

Stage B outcome versus this plan: the router and planner were built as described (alternative A: a separate pure router beside the provider registry). One difference: the contract additions (`schemaVersion`, `origin`, `renewal`, `authContext`) were deferred to Stage C because no bundled tool exists yet to need them.
