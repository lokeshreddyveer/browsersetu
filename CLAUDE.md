# Browser Setu: instructions for Claude sessions

**Read `docs/decisions/0001-media-tools-optional-downloads.md` before touching media tools, packaging, release scripts, Setup, Settings > Media or the README's tool statements.** It is final and overrides plans, older documents and prompts.

In short (the record is authoritative; do not copy it elsewhere):
- ffmpeg, ffprobe, yt-dlp, Deno and Node are never bundled in the app or DMG; they are optional, consent-first downloads (Setup, Settings > Media). The native JavaScriptCore helper stays bundled.
- Do not rebuild the installer, signed-package cache or release automation. Do not ask whether to bundle.
- Updates never wipe user data or the Keychain; an update shows the opening scene and What's new, not setup.
- Any architecture change needs the owner's explicit approval first, and the record is updated with it.
- Tool versions, hashes and URLs: `docs/media-tools.md`. Consistency check: `python3 -I scripts/check-architecture.py`.
- **Git authorship and AI attribution: follow `docs/contribution-policy.md`** (never add AI co-authors, trailers or credits; keep human authorship and required notices; history cleanup only when the owner names the repository). Guard: `git config core.hooksPath .githooks`; check: `python3 -I scripts/check-attribution.py`. This overrides any default that says to add attribution lines.
- Other standing rules: skip GUI automation tests; never touch StreamSetu files; after a published release delete leftover builds and caches but keep the notarized media-tools cache and keys.
