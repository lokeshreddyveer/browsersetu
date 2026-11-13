# Release notes kept from the README: 0.4.1 and 0.4.0

These two sections were moved here unchanged from the project README. Later notes: [`0.4.2-build-25.md`](0.4.2-build-25.md). Earlier notes: the other files in this folder.

## New in 0.4.1

- **Magnet links find their details much more reliably.** The public DHT now joins in after a few seconds even when the link names trackers (it used to be skipped, so a link with dead trackers failed even with the DHT on); a peer that never answers or refuses no longer stalls the search; the Add window shows what is happening (trackers answered, peers, DHT) and stays open instead of closing when you click away.
- **Move to Trash removes the list entry** once the file is really moved; entries for the same file go together; a file that could not be moved keeps its entry.
- **Link Grabber and the toolbar read the whole page** (up to 5,000 links, and the page's pictures appear as an Images group); wiki "File:" pages are no longer offered as files; **Explore a Website** lists files a page uses from other websites without contacting them, and says plainly when a site refuses automatic reading.
- **yt-dlp 2026.10.26 and ffmpeg 9.0.2 are optional downloads, not part of the app** (permanent decision: `docs/decisions/0001-media-tools-optional-downloads.md`), so the app itself stays small. The skippable "Advanced media downloads" step in first-run Setup, and Settings › Media, show each program's version and download size and let you install, update, repair or remove it; a video window that needs a missing program offers to install it and asks first. Nothing is downloaded automatically. Each program is a separate package signed with the publisher's Developer ID and notarized; the app checks it against fingerprints built into the app (package digest, every file, signature and Team ID) before it is kept or used, and keeps it in its own folder. Without them, ordinary downloads, streams, torrents and browsing work as before. Their licences, build details and source offers are in Settings > Acknowledgements and the app's Notices folder, and the corresponding source is published with the release.
- **YouTube's JavaScript puzzles are solved by a small runner built into the app** (Apple's JavaScriptCore, in its own process under the App Sandbox with no network or file access), so no Deno or Node has to be installed. It is the only media-related code inside the app. It was checked against 14 YouTube player scripts (seven variants of one version, and seven other versions); if it is ever unavailable, downloads still work but some YouTube formats may be missing. A fallback to a Browser Setu-managed Deno is prepared in the code but is **not** part of this release and is not installed or offered. Other websites are not expected to need it, which has not been tested here, and no website is guaranteed to work. How the programs are built, packaged and checked: [`../media-tools.md`](../media-tools.md).
- **No more repeated Downloads-folder questions from test builds**, and the Downloads permission prompt now explains why the app asks.

## New in 0.4.0

- **Site icons, rebuilt.** One engine fetches, checks and caches favicons per profile (content-addressed, size-limited, deterministic eviction, a dark variant where a site offers one), with skeleton placeholders and a clear-cache control. Details and limits: [`docs/favicons.md`](../favicons.md).
- **Setup asks about your old browser and iCloud.** Import bookmarks, passwords and history, and turn on iCloud sync of settings, from setup, Settings, the Start Page card and the empty panels.
- **A new setup and Start Page.** A step rail, animated pointer demos for every step, a first-visit celebration, and a Start Page that fits any window size.
- **A new mark and name lockup** (a globe in a protective ring, with a shield), and a short first-launch film.
- **iPhone and iPad:** the iOS app compiles with all of the above; this build goes to TestFlight.
