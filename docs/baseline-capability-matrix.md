# Downloads baseline — capability matrix (end of Phase 15)

Evidence legend: **E2E** working end to end in the running app · **FIX** works against controlled local fixtures (real sockets/servers on this Mac) · **MOCK** tested through fakes only · **CODE** code exists, runtime unverified · **NO** not implemented.
Nothing below is marked E2E: the sandbox here cannot launch the app, so no screen, menu, notification or Dock badge has been seen running.

| Area | Intended | Evidence | Known limits | Open risk | Later phase |
|---|---|---|---|---|---|
| Ledger, state machine, store | One authority for every task, survives relaunch | FIX (real SQLite store, relaunch tests) | Private tasks never stored by design | – | – |
| HTTP/HTTPS engine | Range/resume, validators, redirects, retry | FIX (local fixture server, 36 tests) | System networking cannot throttle precisely; speed limits pause/resume | P2 | 22 |
| Multipart | Assemble parts, fall back when server lies | FIX | – | – | 20 |
| Pause/resume/cancel/recovery | Never lose data, never restart silently | FIX | WebKit resume is conditional on resume data | – | – |
| Scheduler, priorities, pools | Limits honoured, leases released once | FIX | Pools are process-wide, so profiles in one process share them (P1, see below) | **P1** | 22 |
| Dashboard / inspector | Native list, details, actions | CODE + view-model FIX | Never seen running | P1 (verification) | final |
| File management | Names, duplicates, integrity, ZIP | FIX | Replace now swaps with a kept backup; Trash may be unavailable on some volumes (backup then kept visibly) | P2 | 25 |
| Bandwidth / proxy | Per-profile proxy, shared speed limit | FIX (local proxy fixtures) | Overall speed limit, timeout, retry count, per-host cap are process-wide; WKDownload is not limited | **P1** | 22 |
| BitTorrent | .torrent/magnet, pieces, peers | FIX (loopback peers/tracker written in the test code) | No DHT, UDP trackers, PEX, uTP, web seeds, v2-only, seeding; public-swarm interop **unverified** | P1 (interop) | later |
| eD2k | Links, hashes, parts, peers | FIX (independent Python fixture server) | No Kad, obfuscation, compression, uploads, low-ID; real network interop **unverified** | P1 (interop) | later |
| HLS / DASH streams | Preview, choose tracks, fetch, join to one file | FIX (original H.264/AAC media made in the test, local HTTP fixture) | VOD only; no live, no encryption/DRM, DASH single period with templates; MPEG-TS joined to `.ts` (playability **unverified**); limit held between segments; preview UI never seen running | P1 (verification) | final |
| Packages / batch / Website Explorer | Group tasks, make many from a reviewed selection, propose files from a bounded, robots-respecting site read | FIX (local fixture sites and server) | Sheets never seen running; no real websites tried; a package folder cannot move a started download; explorer ignores JavaScript-built pages | P1 (verification) | final |
| Mirrors / Metalink / partial ZIP | Several sources for one file when proven the same; entries from a remote ZIP by range | FIX (local fixture server, original archives) | Together-mode needs the person's own address plus a SHA-256; piece hashes ignored; no mirror discovery; sheets never seen running; no real CDN/mirror interop | P1 (verification) | final |
| Download extensions | Declarative suggestions only | FIX | No scripts, no network, suggestions never start tasks | – | – |
| WebKit integration | Browser downloads in the one ledger | FIX (real WKWebView + fixture) | Menus/save panel/drag-drop never seen; blob/POST at runtime untested | **P1** (verification) | final |
| Save As / Replace | Never lose the old file | FIX (real files, interruption hooks) | Sandbox behaviour of the swap for folders outside Downloads unverified | P1 (verification) | final |
| Automation API / CLI / SSE | Local, scoped, per-profile, proposals only | FIX (real Unix socket) | CLI run against a live app not done; loopback TCP unshipped | P2 | 23 |
| Authorization durability | Revoked stays revoked | FIX (real files + simulated failures) | If no storage at all accepts a write the service locks down; a restart could not help | P2 | – |
| Webhooks | Signed local notices | FIX (fake transport) | Loopback only; websites unsupported (DNS rebinding) | P2 | 23 |
| Notifications | Opt-in, actions, per-event | MOCK (fake centre) | Real macOS delivery, permission prompt, actions **unseen** | **P1** (verification) | final |
| Diagnostics / export | Redacted, bounded | FIX | Redaction patterns are broad, not provably complete | P2 | – |
| Dock / toolbar indicators | Honest counts | MOCK/CODE | Toolbar button unchanged; Dock unseen | P2 | final |

## Process-wide state (fixed in Phase 22, final-stage corrected)
Speed limits, per-host caps, timeout and retry count are now per profile (per coordinator): `TransferOwnership` maps every task to its owner and `BandwidthController` / `ConnectionBudget` keep per-owner limits. The final stage found the torrent and eD2k limits were still set on the default owner (so silently ignored); they are now set on the profile's owner and covered by a test. A cancelled queued task used to be admitted later and keep a connection lease (`DownloadCoordinator.forget` did not remove it from the scheduler line); fixed, and the Phase 8 tests assert no lease is left over.

## Phases 21–25 (added after the baseline)
| Area | Status | Verified how | Limits |
|---|---|---|---|
| Media preview / remux / convert (21) | FIX | Original media made in the tests; exact trim measured | Partial preview of a live download not wired; UI never launched |
| Adaptive bandwidth (22) | FIX | Fixture server; Browser Priority 20 MiB at 6 MiB/s limit: 5.2–5.6 s vs 3.24 s fixed | UI never launched; no real-network numbers |
| Remote companion (23) | **PARTIAL** | Pairing, device list, revocation, rotation, gateway authorization by tests | **No working encrypted transport on this system** (TLS-PSK handshake fails over a Unix socket; a sandboxed TCP listener is refused). Off by default, listens on nothing. The transport must derive the gateway's `Peer` only from the TLS identity that matched |
| Website accounts (24) | **PARTIAL** | Local fixture with `?need_auth=`: exact host+port, https, user origin only, redirects drop the header, no resume data, wiped with the profile | **No real-site or real-provider testing.** Basic/token only |
| Archives and link files (25) | PASS (local scope) | Own writers plus Info-ZIP and bsdtar archives; hostile archives | ZIP/ZIP64/TAR/TAR.GZ only. 7z, RAR, xz, bzip2, encrypted ZIP entries, DLC/RSDF/CCF unsupported. Quarantine propagation unverified in the sandboxed app. 5,000 small ZIP entries extract in ~4.9 s |

## Missing capabilities for later planning (not implemented)
Live stream recording, DASH SegmentList/multi-period, magnet/eD2k auto-interception, script-capable extensions, DHT/PEX/uTP/seeding, Kad, a working remote transport, 7z/RAR/encrypted archives, real-provider account sign-in.
