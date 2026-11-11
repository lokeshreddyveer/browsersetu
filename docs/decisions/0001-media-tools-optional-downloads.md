# ADR 0001: Media tools are optional downloads, never bundled

Status: **ACCEPTED AND FINAL.** Decided by the owner, 2026-11-10. This record takes precedence over version-specific documentation, historical plans and older prompts. Changing anything below needs the owner's explicit approval first; when that is given, edit this file in the same change and say so in its history.

## Decisions
1. Browser Setu ships as a lightweight macOS DMG (about 33 MB). **ffmpeg, ffprobe, yt-dlp, Deno and Node are NOT bundled** in the app or the DMG.
2. ffmpeg/ffprobe and yt-dlp are **optional, user-authorized downloads** through First-Run Setup (a skippable step) and Settings > Media (Install, Update, Repair, Remove, progress, errors, versions). The person sees the size, purpose and licence note first. **Nothing is ever installed without consent**, including when a feature needs a missing tool (it offers, never installs silently).
3. Each tool is a separate, signed and notarized package hosted as an **immutable, versioned GitHub release asset** named `media-tools-<tool>-<version>`, with its manifest, SHA-256, size and URL generated from the verified package (never hand-written). The current versions and URLs are in `docs/media-tools.md`; they change with tool upgrades, this architecture does not.
4. The small **native JavaScriptCore helper (`setu-jsc`) and its yt-dlp plugin stay bundled**. It is the default YouTube challenge provider when yt-dlp is installed; no Node or Deno is required. A managed Deno is not part of the product.
5. The **existing secure machinery is kept, not rebuilt**: the installer (approved hosts, SHA-256, tree digest, Developer ID and Team ID, notarization, architecture, launch check, atomic activation, rollback), the content-addressed signed-package cache, manifest generation, and the release automation (`scripts/release.sh`, `release-media-tools.sh`, `check-media-tools.sh`, `publish-release.sh`).
6. **Corresponding source and licence notices are published separately** (release `sources-<version>-build<n>` and the notices in the app and next to each package). Compliance records live in `docs/compliance/`. A tool package is hosted only after its source is published.
7. The **browser works fully without the optional tools**.
8. **Updates preserve user data**: profiles, downloads, settings, Keychain and browser data. No clean uninstall or reset unless the owner explicitly asks. A new install plays the opening scene and then setup; an update plays the opening scene and shows What's new, never setup.
9. **Release order**: build, sign, notarize, staple, verify, publish the GitHub release, verify it by downloading it back, and only then update the live Sparkle appcast.
10. **Bundled-versus-optional is not to be revisited** unless the owner explicitly requests a change.
11. **The programs' own names are never shown in Setup, Settings or Downloads.** The app calls them "Video download tool" and "Media processing tool" (`MediaToolLabel`). Only the licence notices, Acknowledgements and the hosted release pages name them, because the licences require it. `scripts/check-architecture.py` fails if a sentence in those screens names them.

## Rules that follow
- A tool-version upgrade replaces package details (version, hashes, URLs) only. It never moves a tool into the app.
- The release preflight refuses an app that contains any of the five binaries (`scripts/check-media-tools.sh`), and `scripts/check-architecture.py` refuses documents, manifests or scripts that contradict this record.
- Do not ask the owner again whether to bundle; do not re-plan it.

## What this record is not
It is not the place for version numbers, hashes or procedures. Those are in `docs/media-tools.md`. Earlier plans that assumed bundling (`docs/downloads-architecture-stage-a.md`) are historical and superseded where they disagree.

## History
- 2026-11-10: accepted (optional downloads; native JavaScriptCore helper bundled).
- 2026-11-11: decision 11 added at the owner's explicit request (no tool names in Setup, Settings or Downloads).
