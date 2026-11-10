# Media tools: redistribution and source readiness

Status date: 2026-11-10. **The legal review is not complete and nothing here is a statement that redistribution is compliant.** This file records what has been verified, what is prepared, and what is still open. Nothing has been uploaded, published or made installable. The machine-readable evidence is in `docs/compliance/source-manifest/` (`SOURCES.json`, `BINARY-TO-SOURCE.json`, `LAME-COMPARISON.json`); `scripts/prepare-media-sources.py` regenerates all of it and re-verifies every archive.

## What is distributed (Direct build, Apple silicon)

| Program | Package / file | Size | SHA-256 | Notarization |
|---|---|---|---|---|
| yt-dlp 2026.10.26 | `yt-dlp-2026.10.26-arm64.zip` | 27,310,492 B | `b82fec9f012524ac…a818c3d9` | Apple submission `6f4291e4-012c-43b8-ba4f-140a98bb59c2`, Accepted, for exactly this zip |
| ffmpeg + ffprobe 9.0.2 | `ffmpeg-9.0.2-arm64.zip` | 3,446,550 B | `dcd62a353d3dd957…3ed9c1` | Apple submission `e51f49e6-1d2e-4e8b-bc31-baae5f7b37f9`, Accepted, for exactly this zip |
| LAME 3.100 | `Contents/Frameworks/libmp3lame.dylib` (built by this project) | | | covered by the app's notarization |
| setu-jsc 1.0.0 (our own code) | `Contents/Helpers/setu-jsc` | 103,728 B | in `BundledJSProvider.json` | covered by the app's notarization |

Both zips were re-checked online with `notarytool info` and are cached with their records; the release pipeline reuses them only while every signature and record re-verifies.

## What is actually inside yt-dlp (measured from the shipped files, not from upstream's text)

Upstream's `THIRD_PARTY_LICENSES.txt` is written for **all** of yt-dlp's platform builds. For this macOS arm64 build the shipped files show:

* 108 Mach-O files in the media tools and LAME library, **all mapped to a source component, none unmapped** (`BINARY-TO-SOURCE.json`): CPython 3.14 runtime and 55 extension modules, OpenSSL 3, Zstandard, Brotli, cffi, PyCryptodome (40 extensions), websockets, charset-normalizer, `curl_cffi`'s `_wrapper.abi3.so`, the `yt-dlp_macos` PyInstaller executable, ffmpeg and ffprobe, and the LAME library.
* `curl_cffi`'s `_wrapper.abi3.so` statically contains curl, curl-impersonate, **BoringSSL** and **nghttp2** (string and symbol evidence). No libidn2, libunistring or GNU Readline is in it.
* The Python `readline` module links the **macOS system library `libedit`**, not GNU Readline.
* No binary in the media tools or the LAME library **links** libintl, libidn2, libunistring, libstdc++ or libgcc (`otool -L` on every Mach-O), and string searches of the Python library, the curl-impersonate wrapper and the main executable found no identifying strings for them (the executable's archive is compressed, so a static copy inside it cannot be excluded by this test). Earlier documents of ours named them as bundled; that came from upstream's all-platform list and has been corrected in the notices, the manifest note and the in-app Acknowledgements. They are still *mentioned*, as not found, because the legal review is not finished.
* The one GPL component upstream lists for this build is **mutagen (GPL-2.0-or-later)**. The **PyInstaller bootloader** inside `yt-dlp_macos` is GPL-2.0-or-later with the PyInstaller bootloader exception, and upstream's licence list has no entry for it; its licence text (`PYINSTALLER-6.22.0-LICENSE.txt`) is now shipped in the Notices folder. Upstream's README states that the PyInstaller executables include GPLv3+ code and that the combined work is licensed under GPLv3+. Browser Setu follows upstream's statement.
* Versions of the Python layer match, one for one, what the shipped program reports with `-v` and what upstream's hash-pinned `bundle/requirements/macos.txt` lists.

## Corresponding source: what is prepared (25 archives, 43 MB, staged in `build/media-sources`, not hosted)

| | Verified how |
|---|---|
| FFmpeg 9.0.2 | the sha256 pinned in this repository (`8c385028…96e002e`) |
| yt-dlp 2026.10.26 release tarball | upstream's published `SHA2-256SUMS` for that release |
| 20 Python packages (mutagen, PyInstaller 6.22.0, yt-dlp-ejs 0.8.0, curl_cffi 0.17.0, cffi, brotli, certifi, charset-normalizer, idna, pycryptodomex, requests, urllib3, websockets, and the build tools) | the sha256 PyPI publishes for each file |
| yt-dlp git-tag archive (holds the build recipe: the release tarball does not) | recorded only; no independent digest exists |
| LAME 3.100 | recorded only (`ddfe36ca…b1da1e`); but **45 repository files are byte-identical to the upstream tarball, 0 differ**, and the 2 extra files are ours (`README.browsersetu.md`, `module.modulemap`) |

Not mirrored, on purpose: CPython, OpenSSL, zstd, curl, curl-impersonate, BoringSSL, nghttp2, libffi, SQLite, zlib, bzip2, liblzma, Expat, mpdecimal. Their licences need attribution only (see the licence file); the notices point to their projects. **The exact curl-impersonate version inside `curl_cffi` 0.17.0 has not been verified.** The CPython patch version, and the exact versions of the C libraries statically inside it, have not been extracted either.

Upstream's build recipe, from the tag archive: `.github/workflows/build.yml` job `macos` (runs-on `macos-14`; hash-pinned wheels from `bundle/requirements/macos.txt`; universal2 `cffi` and `curl_cffi` fused with `delocate`; `python3 -m bundle.pyinstaller --target-architecture universal2 --onedir`). Our changes to that output, and only those: thin to arm64 with `lipo`, restore the `Python.framework` links, re-sign every Mach-O (`scripts/release-media-tools.sh`).

FFmpeg: unmodified source, LGPL-only configure line (`--disable-gpl --disable-nonfree --disable-version3 --disable-autodetect`, no external libraries), built by `scripts/build-ffmpeg-minimal.sh` (the exact configure line is in `BUILDINFO.txt` inside the package and in the source offer). Statically linked: relinking is by rebuilding from the source and using one's own ffmpeg, which Browser Setu can be pointed at.

LAME: LGPL-2.1, built as a **separate dynamic library** (`libmp3lame.dylib`) that the app loads, so it can be replaced by rebuilding from the repository sources (re-signing is needed for the signed app).

## Reproduce

```
python3 scripts/prepare-media-sources.py fetch                       # download + verify the 25 archives into build/media-sources
python3 scripts/prepare-media-sources.py verify-lame                 # LAME: this repository against the upstream tarball
python3 scripts/prepare-media-sources.py map --app "<Browser Setu.app>"   # every Mach-O in the built app -> its source; fails if any file is unmapped
```

The map is regenerated per built app; a future yt-dlp bump that adds a native file with no rule makes `map` fail instead of shipping an unmapped binary.

## Open before any public distribution

1. **Legal review.** Someone qualified must confirm the GPL-3.0-or-later combined-work position for yt-dlp, including the PyInstaller bootloader and mutagen, and that distributing it from our release is acceptable. This file does not do that.
2. **Hosting.** The source archives, `SOURCES.json`, `BINARY-TO-SOURCE.json`, the source offers and `build-ffmpeg-minimal.sh` must be published next to the release (GPL-3.0 section 6) and the release notes must link them. The notices already say the publisher publishes them "with the release that contains this package"; that must be made true.
3. **Written-offer contact.** The offers say "the address in the release notes"; the release notes must carry a working address.
4. **Unverified items:** the curl-impersonate version, the CPython patch version, the C library versions statically inside it; the GPG signature of upstream's `SHA2-256SUMS` was not checked (no gpg here); the LAME archive digest is recorded, not independently verified.
5. Intel Macs are unsupported until the app and the tools are built for x86_64.

## Hosting plan (not done)

Versioned, immutable GitHub release assets on `lokeshreddyveer/browsersetu`, one tag per tool, created without becoming "Latest" so the update feed is unaffected: `media-tools-yt-dlp-2026.10.26` and `media-tools-ffmpeg-9.0.2`, each with the zip, its notice/offer, and the source files above; the app's allow-list (`github.com`, `*.githubusercontent.com`, https, port 443) accepts the redirect. Manifests are generated from the verified package (`scripts/media_tools_cache.py manifest --hosted-url`), never edited by hand, and a download address is only enabled after the hosted file's digest is checked (`check-media-tools.sh --hosted-verified`).
