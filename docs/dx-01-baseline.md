# DX-01 — Download Manager Expansion: baseline, architecture map and defect register

Phase DX-01 of 18. Base revision `cde881d` plus uncommitted work (about 150 modified and 217 new files at the time of writing; nothing committed).

Every path below is a real path under `apps/apple/`. Statuses are one of **COMPLETE** (implemented and observed working), **PARTIAL** (implemented, but not fully verified or with an important gap), **BROKEN** (confirmed defect), **MISSING** (not implemented), **UNSUPPORTED** (deliberately unavailable).
"Unit" means a test that passed in the Xcode test target. "Real app" means it was driven in the running Debug app against local fixtures and the outcome checked on disk.

## 1. Architecture map (what actually routes where)

```
 WebKit click / navigation / response    Add Download field     LinkGrabber / Explorer      Magnet / .torrent / eD2k
 Engines/WebKit/WebKitEngine.swift       macOS/Downloads/       Shared/Downloads/           WebKitEngine (scheme intercept)
   decidePolicyFor (navigation +          DownloadsDashboard      LinkGrabber/*, Explorer/*   -> BrowserModel.openLinkPreview
   response), decideDestination           AddDownloadForm                                      (carries addDownloadPrefillOrigin)
          |                                     |                         |                          |
          v                                     v                         v                          v
 Shared/Downloads/Browser/            LinkClassifier / LinkRouter    LinkRouter.route(link)     TorrentAddModel / ED2KAddModel
 BrowserDownloadIntegration.swift     (LinkGrabber/DetectedLink.swift,   -> LinkRoute            macOS/Downloads/TorrentAddView.swift
 BrowserDownloadRouting -> DownloadRoute   LinkGrabberStore.swift)        (download / preview /
 (webKitSession / standaloneHTTP /                                         previewLocalTorrent /
  torrentPreview / ed2kPreview /                                           mediaPreview / refused)
  informationOnly / refused)
          \____________________________________|___________________________/
                                               v
                              Shared/DownloadCoordinator.swift  (admitTicket -> begin -> update -> finish / fail / discard)
                              + DownloadCoordinator+Network.swift, +Files.swift
                                               |
        +-------------------+------------------+--------------------+---------------------+
        v                   v                  v                    v                     v
  WebKit WKDownload    HTTPDownloadRunner   MediaRunner         TorrentRunner         ED2KRunner
  (staged, see 3-B)    HTTP/HTTPDownloadRunner  Media/MediaRunner   Torrent/TorrentRunner  ED2K/ED2KRunner
                       + HTTPTransferEngine + MultipartTransferEngine + Mirrors/Mirrors.swift
                                               |
   Ledger:    Shared/Downloads/DownloadLedger.swift, DownloadTaskStore.swift, DownloadStateMachine.swift
   Scheduler: Shared/Downloads/DownloadScheduler.swift (one scheduler); connections: ConnectionBudget (HTTP/MultipartTransferEngine.swift);
              bandwidth: Network/BandwidthController.swift; retries: HTTPRetrySchedule (HTTPDownloadRunner.swift)
   Staging / finalisation / recovery: FinalizationGate.swift, DownloadRecovery.swift, DownloadCoordinator.swift (placeSaveAs, saveAsStagingRoot)
   Policy:    HTTP/HTTPRequestPolicy.swift (origin, host classification), HTTP/HTTPHostResolution.swift, DownloadTask.swift (DownloadPathPolicy)
   UI:        macOS/Downloads/* (dashboard, inspector, popover, add forms), DownloadsViewModel.swift, DownloadRowProjection.swift
```

Observations from reading the code (not changes):

* There are **three classifiers** that agree today but are separate code: `BrowserDownloadRouting` (WebKit-originated), `LinkClassifier`/`LinkRouter` (LinkGrabber and prefilled links) and the field-level checks inside `AddDownloadForm` (`isStream`, `isED2K`, `magnet`). They were not merged in DX-01; a future phase that adds a source type must touch all three or first introduce one shared entry point.
* Request provenance (`DownloadRequestOrigin`: `.user`, `.page`, `.automation`, …) is carried by HTTP and media tasks. **Torrent tasks previously did not carry it** (hard-coded `.user`); fixed in DX-01 (section 3-D).
* Private-session separation is enforced at the WebKit store level (`DownloadStoreKey`, `PrivateDownloadVisibility`, `Shared/PrivateWindow.swift`). A private window sees the profile's normal list in its popover; whether its own completed private download is listed there was **not confirmed** (see defect register).

## 2. Source-type capability matrix

| Source | Entry point | Engine | Status | Unit | Real app | Known limits | Phase |
|---|---|---|---|---|---|---|---|
| HTTP/HTTPS file click | `WebKitEngine` | WKDownload / `takeOverInPieces` (https, ranges) | COMPLETE | yes | yes (7 link kinds, hashes match) | pieces path only for https | — |
| Content-Disposition / redirects | `WebKitEngine` | same | COMPLETE | yes | yes | | — |
| Typed URL | `AddDownloadForm` | `HTTPDownloadRunner` (+ `MultipartTransferEngine`) | COMPLETE | yes | yes (Retry, no-Range, resume) | | — |
| Authenticated download | `Accounts/Accounts.swift` | HTTP runner | PARTIAL | yes | no (no real site) | | DX-14/17 |
| Pause / resume / cancel | dashboard | HTTP + WebKit | COMPLETE | yes | yes | | — |
| Multi-source (mirrors) | inspector "Add Source…" | `Mirrors/Mirrors.swift` + runner | COMPLETE | yes | yes (failover); corrupt source: see 3-A | failover is sequential unless checksum + range | DX-15 |
| Remote ZIP | Library menu "Open Archive from Address…" | `RemoteZip/RemoteZip.swift`, `ZipFormat.swift` | COMPLETE (after fix 3-E) | yes | yes (4 entries, checksums) | ZIP64 not seen in app | — |
| Archives (zip, tar, tar.gz) | inspector | `Archives/ArchiveManager.swift` | COMPLETE | yes | yes (list, extract, `../` and symlink refused) | 7z, RAR, encrypted zip unsupported | — |
| Magnet (HTTP/HTTPS trackers) | Add Download / page click | `Torrent/*` | PARTIAL | yes | yes (local tracker + independent peer: metadata, 10 pieces, hash match) | no UDP tracker, DHT, PEX, µTP, web seeds, seeding | DX-02…07 |
| `.torrent` file | file picker | `TorrentRunner.inspect` | PARTIAL | yes | no (file dialog not driven) | | DX-06 |
| eD2k | Add Download | `ED2K/*` | PARTIAL | yes | no | own fixture only | DX-18 |
| HLS (TS segments) | Add Download | `Media/*` | COMPLETE | yes | yes (quality chosen, output decodes) | audio labelled "Video" and host-named output fixed in DX-01 | DX-09 |
| DASH (fMP4) | Add Download | `Media/*` | PARTIAL | yes | default quality only | alternative-quality choice not confirmed in app | DX-09 |
| Direct MP4 / audio | HTTP runner | HTTP | COMPLETE | yes | yes | | — |
| Media found on pages | `Media/MediaDiscovery.swift` | media + HTTP | PARTIAL | yes | no | HTML5 and embeds only as the discovery supports | DX-08 |
| Separate audio/video, subtitles | `Media/MediaManifest.swift`, `MediaProcessing/SubtitleSupport.swift` | media | PARTIAL | yes | not in app (no fixture) | | DX-13 |
| Convert / remux / extract audio / trim | `MediaProcessing/*` | processor | COMPLETE | yes | yes (WAV, M4A, trim 3.00 s decode) | subtitles untested | DX-13 |
| Playlists, collections, live streams | — | — | MISSING | | | live streams refused | DX-11, DX-12 |
| LinkGrabber | `LinkGrabber/*` | HTTP | PARTIAL | yes | detection yes; Add Selected correctly refused for loopback (page origin) | the paste route not driven | DX-18 |
| Website Explorer, Packages | `Explorer/*`, `Packages/*` | HTTP | PARTIAL | yes | no | | DX-11 |
| FTP / SFTP | — | — | MISSING | | | | DX-14 |
| DRM-protected media | — | — | UNSUPPORTED | | | by design | — |
| Website-specific extractors | — | — | MISSING / policy | | | only with source authorisation | DX-10 |
| Automation, notifications, diagnostics | `Automation/*`, `Notifications/*` | — | PARTIAL | yes | no | | DX-17 |
| Remote Companion | `Remote/*` | — | PARTIAL | yes | transport unsupported here | | DX-17 |

## 3. Confirmed issues and what DX-01 did

### A. Corrupt mirror recovery — BROKEN → FIXED
Root cause (`Shared/Downloads/HTTP/HTTPDownloadRunner.swift`): a whole-file checksum mismatch on a **single-source** transfer ended in `coordinator.fail(... retryable: false)` without going through `tryNextSource`, so a good source added afterwards was never tried, and **Try Again re-fetched the same corrupt source** (the source was never marked). Fix: the mismatch now deletes the file, records the address in the task's `corruptSources` list (only while the task still asks for a checksum), and calls the existing `tryNextSource`; at launch, a source already on that list is skipped (`http:known-corrupt`) and, with no other source, the task fails with "already gave a file that did not match … Add another source". The checksum still decides for every source. No change to the mirror engine itself.
Evidence: unit `CorruptSourceFailoverTests` (4, against a real local HTTP fixture server: wrong source refused, good source finishes the file with the right hash, the wrong source is not asked again, no connections left open); existing `MirrorTests` pass. Real app: the checksum mismatch is detected and the file discarded (earlier build); with the fix, Try Again with no other source shows "already gave a file that did not match … not used again" and sends no request to the corrupt source. **Not confirmed in the real app: the good-mirror fallback itself** (the UI driver lost the Downloads card during that run) — PARTIAL.

### B. Partial files under final names — BROKEN → FIXED
Browser-click downloads wrote straight to the final name (observed 7 MB of a 12 MB file sitting in `~/Downloads`). Fix: `DownloadCoordinator.begin(... staged:)` stages WebKit and piece downloads in the existing hidden Save-As staging folder and publishes by rename after finish (collisions become `name (1).ext`, never overwritten). Only when staging and target are on one volume. Evidence: unit `StagedBrowserDownloadTests` (8); real app: nothing visible during the transfer, whole file after, staging empty.

### C. Source prompt — BROKEN → FIXED
`Dialogs.promptText` filled the field with its hint, so OK submitted `https://mirror.example.com/file.zip`. Fix: `prefill: false` for the three hint-style prompts (mirror source, Save Session, Tag This File). Unit: `DownloadsBatchTests.testThePromptHintIsNeverSubmittedAsAnswer` (source check). Real app: an empty OK adds nothing.

### D. Local BitTorrent tracker policy — FIXED, and a further gap closed
* `fetchDetails` lacked the "local peers allowed when the torrent's own tracker is local" rule that the download step had; now shared through `TorrentRunner.allowsLocalPeers`.
* **New in DX-01:** torrent requests ignored provenance, and the tracker client does no address classification, so a **magnet from a web page** naming `http://192.168.x.x/...` as tracker would cause a GET to that address once the person pressed Get Details with P2P enabled. Now `TorrentRunner.usableTrackers(_:origin:)` drops internal-address trackers for any origin other than `.user`, and local peers are only ever allowed for `.user`. The origin (`addDownloadPrefillOrigin`, already set for page links) is passed through `TorrentAddModel` and stored with the task so a relaunch applies the same limits.
* P2P stays off by default (`DownloadsBatchTests.testPeerToPeerIsOffByDefault…`); nothing turns it on.
Residual: tracker URLs of a **typed** magnet may still name the local network (the person's own request, by design).

### E. Remote ZIP path safety — BROKEN → FIXED
`DownloadPathPolicy.isAuthorized` judged a not-yet-existing path under the sandbox's symlinked `Downloads` folder as outside it, so every Remote ZIP finish failed in the real app. Now `DownloadPathPolicy.realPath` resolves the longest existing ancestor and follows links (including dangling ones) before comparing. Unit: `PathPolicyLinkTests` (6, including an escaping link, a dangling link and `..`). Real app: Remote ZIP extraction matches checksums.

## 4. BitTorrent readiness for DX-02 (UDP trackers, BEP 15)

Existing pieces DX-02 can reuse, in `Shared/Downloads/Torrent/`:

| Piece | Where | Note |
|---|---|---|
| Magnet parser (BEP 9/53) | `TorrentMetainfo.swift` `MagnetLink` | keeps `http`, `https`, `udp` trackers |
| Tracker list (tiers flattened) | `TorrentMetainfo.swift` `trackers` | tiers are not kept (DX-04) |
| Tracker interface | `TorrentSession.swift` `protocol TrackerAnnouncing` (`announce(...) async throws -> TrackerReply`) | **the DX-02 extension point** |
| HTTP/HTTPS implementation | `TorrentNetwork.swift` `HTTPTrackerClient` | the only implementation today |
| Reply and peer model | `TorrentSession.swift` `TrackerReply`, `PeerAddress` (IPv4 host + port) | IPv6 not modelled (DX-04) |
| Announce lifecycle | `TorrentSession.swift` `announceIfDue` | per-tracker state in `Snapshot.trackers` |
| Peer dedupe and local-address filter | `TorrentSession.swift` `addCandidates` | cap 500; internal addresses ignored unless `allowLocalPeers` |
| Metadata, TCP peers, pieces, SHA-1 | `TorrentSession.swift`, `PeerWire.swift`, `TorrentPicker.swift`, `TorrentStorage.swift` | |
| Policy and ownership | `TorrentRunner.swift` (`usableTrackers`, `allowsLocalPeers`, `sessionSettings`), `TorrentSlots`, `PeerBudget` | origin stored in the task |
| Proxy handling | `TorrentNetwork.swift` (peer connections refuse an unusable proxy setting) | UDP must follow the same rule: no direct fallback |

What DX-02 must change: `TorrentRunner` filters `udp` trackers out in two places (`fetchDetails` and `run`) before the session sees them; the session is given a single `TrackerAnnouncing`, so DX-02 needs a thin dispatcher choosing by URL scheme (HTTP client vs a new UDP client) behind the same protocol. **No code was changed for this in DX-01** (no abstraction without a demonstrated need).
Recommended fixtures: extend `scripts/` with a loopback UDP tracker (connect/announce/scrape, transaction-id and connection-id expiry, malformed and oversized replies) and reuse the independent seeder pattern used in DX-01 testing (tracker + peer on 127.0.0.1, 10 pieces).
Prerequisites: P2P on in a throwaway profile only; a UDP socket path that honours the proxy setting and the local-network rule above.

## 5. Media path readiness

WebKit → `Media/MediaDiscovery.swift` → `LinkRoute.mediaPreview` / `AddDownloadForm.isStream` → `MediaAddView` (quality) → `MediaRunner` (`Media/MediaFetcher.swift`, `MediaAssembler.swift`) → `MediaProcessing/*` → finalisation.

Works (real app): HLS master → quality pick → TS segments → decodable output; DASH default quality → decodable MP4; convert, extract audio, WAV, trim. Present in code, not driven in the app: separate audio/video tracks, subtitles, thumbnails, metadata. Missing: general HTML5/embed association beyond discovery, playlists, collections, live recording, site adapters. Intentionally excluded: DRM, live, encrypted streams. DX-01 fixed two media presentation defects: the audio-only picker label ("Video" → "Quality") and the output name of a bare manifest (`127.0.0.ts` → named from the address or `Stream from <host>`, and a dot typed in a name is no longer cut off as an extension).
Future website adapters should be declarative and enter through `MediaAddModel`/`MediaManifest` so the existing fetch and assemble engines are reused.

## 6. Downloads settings audit

`DownloadsSettingsSection` (`Shared/SharedViews.swift`) already bundles: concurrency, folder sorting, multipart, collisions, `DownloadNetworkSettingsSection` (speed, retries, proxy, adaptive), `TorrentSettingsSection`, `ED2KSettingsSection`, extensions, link detection, notifications, automation, remote devices, accounts. It sat in **General**. DX-01 gave it its own **Settings → Downloads** panel (`macOS/Settings/SettingsWindow.swift`, `SettingsPanel.downloads`), updated the settings search (`Shared/SettingsSearch.swift`), and pointed the torrent/eD2k warnings at it (with an Open Settings button). Same state, nothing duplicated or reset. A fuller redesign stays with DX-16.

## 7. Defect register

| # | Item | State |
|---|---|---|
| 1 | Corrupt mirror not failed over, retried | FIXED |
| 2 | Partial files under final name | FIXED |
| 3 | Prompt hint submitted | FIXED |
| 4 | Magnet details ignored local-tracker rule | FIXED |
| 5 | Page magnet could name a LAN tracker | FIXED |
| 6 | Remote ZIP path check (symlinked sandbox) | FIXED |
| 7 | "Open Downloads" toggled the card closed for sheet requests | FIXED (`BrowserModel.ensureDownloadsShown`) |
| 8 | Audio-only picker labelled "Video" | FIXED |
| 9 | Manifest output named after the host | FIXED |
| 10 | Size blank for older completed downloads | FIXED for new downloads; older rows show on-disk size |
| 11 | Private window's own completed download not seen in its popover | UNVERIFIED |
| 12 | DASH alternative-quality selection | UNVERIFIED (driver) |
| 13 | ZIP64 listing/extraction in app | UNVERIFIED (unit-tested) |
| 14 | Card drag and bounds | UNVERIFIED (needs pointer input) |
| 15 | Torrent cancel / resume in app | UNVERIFIED |
| 16 | Subtitle processing in app | UNVERIFIED (no fixture) |
| 17 | Three source classifiers | NOTED, not merged |
| 18 | UDP trackers, DHT, PEX, µTP, web seeds, v2, seeding | MISSING (DX-02…07) |
| 19 | FTP/SFTP, playlists, live streams, site adapters | MISSING (DX-10…14) |

## 8. DX-01 result: UDP trackers and tracker management

Sources consulted: BEP 3 (announce events), BEP 12 (tiers), BEP 15 (UDP tracker protocol), BEP 23 (compact peers).

- `UDPTracker.swift`: BEP 15 connect (16 B), announce (98 B), scrape (action 2); transaction-id and action checks, retransmit 15·2^n (n ≤ 2), connection id cached ≤ 55 s, stray-datagram cap, 8-socket cap, IPv4 only, advertised port 0, peers ≤ 200.
- Policy: explicit proxy → UDP trackers fail closed; hostnames resolved once, public-looking name resolving to a local address is blocked; page-origin magnets drop internal trackers; nothing is sent until peer-to-peer is authorized.
- `TrackerBook.swift`: BEP 12 tiers, per-tier announce, success moves to front, backoff 60 s → 1 h, started/completed/stopped each sent once, scrape rate-limited to once a minute. Inspector shows host:port only.
- Independent interop: Python UDP tracker + TCP peer drove the real Debug app through connect, announce, metadata, download (SHA-256 matched), then completed and stopped.

### DX-02 handoff
Reusable: `UDPDatagramTransport` / `NWUDPTransport`, `TrackerAnnouncing` / `TrackerRouter`, `TorrentSession.addCandidates`, `TrackerBook`. DHT needs: bootstrap node list (user-supplied or from magnet `x.pe`/`tr`, no hard-coded public contact without approval), routing table, token handling, and a local fixture node modelled on `swarm.py`.

## 9. DX-02 result: DHT and trackerless magnets

Sources: BEP 5 (DHT), 32 (IPv6), 42 (node-ID security), 27 (private torrents), 9 (metadata), 43 (read-only nodes).

- `Torrent/DHT/DHTCore.swift`: NodeID/XOR metric, endpoints and compact formats (v4/v6), KRPC parse/encode, tokens (HMAC bound to address, 5-minute rotation, current+previous), BEP 42 check (a preference, never a requirement), Kademlia routing table (K=8, splits only on our own range, replacement cache, one entry per address, bounded).
- `Torrent/DHT/DHTNode.swift`: `DHTNode` (ping, find_node, get_peers, announce_peer handling; iterative lookups; bootstrap; refresh; saved nodes), `NWDHTTransport` (pool of per-node connected UDP sockets, 64 max, idle-closed), `DHTNetworkPolicy`, `NetworkPathGate`, `DefaultsDHTNodeStore`.
- Sandbox finding: with only `network.client`, an unconnected UDP socket can send but never receives replies, and cannot bind. The transport therefore keeps one connected socket per node. Queries from nodes we have not asked cannot arrive; `network.server` would be a product decision (DX-04).
- Policy: off until P2P and "Find peers on the public DHT" are on; explicit proxy or a Mac proxy keeps it off with an Open Settings action; metered/Low Data Mode applied; no public bootstrap contact before authorization; local bootstrap only via the person's own `downloads.dhtBootstrap` list.
- Private torrents: never looked up, never answered; a magnet that names trackers is not looked up before its metadata is known; trackerless magnets need the DHT consent; DHT-sourced peers are dropped when metadata shows `private=1`.
- Peers: provenance per address (`peerSources`), local peers need a still-valid source, checked before connecting and every second; TCP peers fail closed when the Mac uses a proxy.

### DX-03 handoff
Reusable: `peerSources`/`addCandidates(source:)` for PEX and LPD provenance, `forgetSource` for private torrents, `DHTEndpoint`/compact peer codecs (IPv6 peers are counted today but not handed to the peer transport), `NetworkPathGate`, `DHTNetworkPolicy` pattern, `LocalTrackerPermission` for LAN scope, `e2e/dhtnode.py` as the model for an independent fixture.

## 10. DX-03 result: PEX, Fast Extension, local discovery, IPv6 TCP, peer management

Sources: BEP 6 (Fast Extension), 10 (extension protocol), 11 (PEX), 14 (Local Service Discovery), 27 (private torrents).

- `PeerWire.swift`: fast bit (reserved[7] 0x04), messages 0x0D–0x11, `allowedFastSet` (matches the BEP 6 example), `ut_pex` build/parse (50 peers per kind, IPv4+IPv6, flags). `TorrentSession`: fast negotiation (HAVE_ALL/HAVE_NONE/ALLOWED_FAST sent, choked peers asked only for allowed-fast pieces, REJECT releases the block, choked requests for allowed-fast pieces served, others REJECTed), PEX in and out through `addCandidates(source: "pex")`, never for a private torrent or before metadata is known, never giving a LAN address to a peer.
- `LocalPeerDiscovery.swift`: BEP 14 codec, service, multicast transport. Receive-only today (no listening port to announce); opt-in; never for private torrents; policy-gated (off under a proxy); sources must be on the local network and not this computer; per-address limits.
- IPv6: DHT and PEX peers of both families go to the TCP engine; `PeerAddress.canonical` (mapped IPv4, compressed IPv6, scope kept); an IPv6 transfer was verified against an independent peer.
- Peer management: `PeerRecord` (backoff 15 s doubling to 15 min, score by bytes and verified pieces; our own policy refusals never count), `PeerFilter` (user ranges), fair share of the global peer pool, per-source provenance for revocation.
- Debug-only experiment: `macOS/BrowserSetuDebug.entitlements` adds `network.server` to Debug builds only; the multicast socket then binds and joins, but no datagram was delivered to the test process (macOS Local Network privacy suspected, unconfirmed). Release entitlements are unchanged.

### DX-04 handoff
Needs: an inbound TCP listener (and its entitlement decision), which also enables announcing in BEP 14 and BEP 5 announce_peer; µTP and MSE/PE as peer transports behind `PeerTransport`; reuse `peerSources`, `PeerRecord`, `NetworkPathGate`, `LocalTrackerPermission` scopes, and `e2e/peerx.py` as the independent peer fixture.

## 11. DX-04 result: advanced peer networking

Sources: BEP 29 (µTP, LEDBAT), MSE/PE (Message Stream Encryption), RFC 6886 (NAT-PMP). Status words below: **implemented**, **unit-tested** (in-process, simulated), **runtime-verified** (against an independent implementation or a real component on this Mac). Nothing here was tested against a public swarm, a public tracker or an unknown peer.

### What exists

- `PeerTransport` abstraction with TCP (`NWPeerTransport`), µTP (`UTPPeerTransport`), MSE (`MSEPeerTransport` for dialled, `CipherPeerTransport` for accepted), `FallbackPeerTransport` and `FailingPeerTransport`. Modes: automatic, prefer TCP, prefer µTP, TCP only, µTP only; fallback is bounded (one attempt per kind), never crosses a proxy (µTP cannot), and never falls back from required encryption.
- `UTP.swift`: connection state machine over a datagram channel, BEP 29 header and SACK, LEDBAT (target 100 ms), RTT/RTO, fast retransmit (once per 2 RTT), zero-window probing, graceful close with linger. Unit-tested on a simulated network with loss, reordering, duplication and delay (21 tests).
- `MSE.swift`: 768-bit DH (checked against Python big integers), RC4 with the 1024-byte discard (known vectors), req1/req2/req3 hashes, VC, crypto_provide/select, padding limits. Policies: prefer / require / allow plain / disable. This is obfuscation only; the Settings text says so and does not claim anonymity or secure encryption.
- `PeerListener.swift`: one TCP and one UDP listener for the app, off until the person allows incoming connections (native consent dialog) and a torrent is running; closed with the last torrent; limits (20 handshaking, 3 per address, 5 accepts per second, 15 s handshake); a plain peer is refused when encryption is required; µTP SYNs and DHT queries are told apart by the first datagram; DHT questions have their own limits (60 per second, 64 connections, 10 s idle) so they cannot use up the room for peers. The person's metered-network and Low Data Mode choices stop accepting and answering. A failed listener is retried every 30 s while torrents want it; `.waiting` is not treated as failure.
- Trackers are told the listening port (the router's external port when NAT-PMP opened one) instead of 0.
- `PortMapping.swift`: PCP, NAT-PMP and UPnP, opt-in with its own consent dialog, only while the listener has a port, renewed at half the lifetime, released (lifetime 0) when incoming connections stop, bounded attempts, status shown in the inspector. PCP (RFC 6887) is tried first, then NAT-PMP, then UPnP (`UPnP.swift`: unicast SSDP to the router, description and control addresses must be http on exactly the router's IPv4, size-capped, no redirects, no proxy, only AddPortMapping/DeletePortMapping, lease 0 only when the router answers error 725). A router that does not answer or refuses is reported as such; nothing is claimed reachable until a peer actually connects in. All three were tested against fake routers only.
- Settings → Downloads: peer connections, encryption, incoming connections + port, router port (NAT-PMP). Inspector: Incoming and Router rows, per-peer transport/encryption.

### Review findings (independent adversarial review) and what was done

Fixed: M1 (µTP send queue full no longer drops bytes; the connection ends), M2 (data race on the incoming buffer), M3 (per-host cap for established incoming peers, 3), M4 (a repeated SYN is answered again), M5 (listener retry, `.waiting`), M6 (session handshake budget is three attempts' worth for dialled peers), M7 (an incoming peer that drops is not queued for dialling), M8 (metered/constrained gate on accept and DHT answers), M9 (own DHT limits), M10 (handshake timeout closes the transport), M11 (MSE buffer cap allows a large first message), M12 (stale Settings text, tracker port), M13 (DHT restart failure is retried), M14 (the µTP timer runs while lingering). Not changed on purpose: half-close handling (closing once our FIN is acknowledged is accepted for BitTorrent).

### Entitlement decision (not changed)

Distribution is the notarized DMG only (target `BrowserSetuMacDirect`), never the App Store. That target's entitlements already carry `com.apple.security.network.server`, so the listener works in the shipped build. The App Store target (`BrowserSetuMac`, Release) does not have it and is not shipped; its Debug configuration has it through `macOS/BrowserSetuDebug.entitlements` so tests can bind a listener.

### Evidence

- Unit tests: µTP 21, MSE 9, transport, fallback, factory and µTP-transport classes 11, NAT-PMP codec 2 + mapper 4, µTP review fixes 2, per-host inbound cap 1; session/DHT/PEX regression classes from earlier phases pass.
- Runtime-verified (Debug app and independent Python peers on loopback): MSE required / preferred / require-refused, plain fallback, listener accept and refuse, µTP plain, lossy and encrypted-with-fallback against an independent µTP implementation.
- Re-run after the review fixes (focused): 87 tests across DHT node/session, DX-03 session, MSE, µTP connection and the µTP/MSE transport classes passed; the live checks against the Python peers passed again (MSE required/preferred/never-fallback, µTP plain/lossy/encrypted, listener 2 accepted + 2 refused). Every connection that ends without being handed to a torrent now counts as refused.
- **Not verified:** LPD announcements are sent but no multicast datagram is delivered to a sandboxed process here (an unsandboxed Python receiver does hear the announcer; Local Network privacy is suspected, not confirmed). Inbound DHT queries from third parties were not seen on a real network. NAT-PMP was tested against a fake router only: no real router was asked. Nothing in the listener (M5, M8, M9, M10) or in the DHT restart (M13) has an automated test; they were compiled and exercised only through the unchanged regression classes.
 The rewritten inbound UDP path of the listener (µTP SYN versus DHT query, M9) has no live check: the Python µTP fixture can only seed, and no live DHT query was sent to the listener. The metered-network gate (M8) has no automated test.


## 12. Downloads retrospective audit (Phases 1-25 and DX-01-04)

Method: an independent read-only audit of Phases 1-25 (code, tests, docs), then a read of every claim against the code before any change, then fixes with focused tests, then an independent adversarial review of the changes and fixes for what it confirmed. No full regression was run.

### Outstanding issues, reconciled with the latest code
| Issue | Result |
|---|---|
| Corrupt-mirror recovery | Already handled (a mismatch after combining mirrors deletes the file, marks them bad and refetches from one source; a single bad source is marked corrupt and another is tried). Hole fixed: D1 below. |
| Partial-file staging | Already handled for HTTP (staged, part and multi files, atomic non-overwriting rename), torrent (`.bsetu-torrent`) and ED2K. Gaps fixed: D4, D5. |
| Remote ZIP64 UI | Parsed and labelled (" · ZIP64" when a ZIP64 end record is used). Unit-tested; not seen running. |
| Downloads-card drag | Drag-out of a finished download to Finder/other apps did not exist; implemented with a `TableRow` item provider (managed-root files only). Not hand-tested. |
| Torrent resume/cancel | Pause/resume/cancel tested; cancel and dismissal now also clean a dismissed failure (D4). No relaunch test of a running torrent. |
| .torrent import | The Open panel, browser download and link-grabber routes worked. Finder open and window drop did not reach the preview; fixed (document type declared at Alternate rank, `openDocument`/`openIncoming` route `.torrent` to the preview). Not hand-tested. |
| HLS/DASH selection | Already handled (video/audio pickers, DRM and encrypted streams refused). DASH alternative quality is unverified. |
| Private-session isolation | Already handled in the ledger and listings; diagnostics leak fixed (D6, review #11). |
| PEX provenance | Fixed earlier in DX-04; tested. |
| Local discovery multicast | Still unverified. Apple's local-network rules say receiving multicast needs the Local Network permission; a test host with an unstable signing identity cannot show the prompt. Needs one run of the signed app with the permission granted. |
| DX-04 inbound µTP/DHT | Implemented; the UDP accept path was rewritten after review (separate pending table and limits, DHT limits and reply-size cap); no live test (the Python µTP fixture only seeds). |
| NAT-PMP / PCP / UPnP | All three implemented and tested against fake routers; not tried on a real router. |
| M14 half-close | Deliberately omitted; closing after our FIN is acknowledged is accepted. |
| TorrentSession compiler warning | There was none: an earlier report misread a source line. The build log has only Swift 6 language-mode notices (self capture, async locking). |
| Debug vs Release inbound entitlement | Settled by DMG-only distribution; see section 11. |

### Defects found and fixed (all with focused tests unless noted)
- D1 recovery trusted a size-matching file as verified without its checksum: now hashed first (the typed checksum is normalized like the engine does; an unreadable file is left alone; a mismatch is deleted).
- D2/D3 finalisation guards checked only the default Downloads folder, so downloads routed to a folder the person granted were thrown away or not deleted: now use the managed roots (HTTP, torrent, ED2K, media, remote ZIP).
- D4 dismissing a failed torrent/ED2K/HTTP download left its hidden working data on disk: now discarded.
- D5 `.bsetu-staged` was never swept: now swept.
- D6 private download names in diagnostics: every note now redacts them.
- Review of the fixes: recovery delete on typed-prefix checksums; PCP address timing; PCP renewal nonce; mapping granted during cancel; UDP channel retain cycle and starvation of peer slots by unclassified UDP; DHT reply size; stale exchange timer; URLSession lifetime and overall deadline; port 0 from a router; duplicate YAML entitlement key (my own mistake: the target already had the entitlement).

### Not changed on purpose
- Granted destination folders stay in the managed roots for the session (review #13): by design for now.
- Drag-out, Finder open, router protocols, multicast: no hand or hardware test yet.

## 13. DX-05 result: selective files, priorities, web seeds, piece intelligence

Status words: **implemented**, **unit-tested**, **independently verified** (against an independent implementation written from the specification), **not hand-tested** (UI compiled, never clicked).

### What exists
- `TorrentSelection.swift`: file priorities (Skip, Low, Normal, High, Maximum), the order (rarest first, in order, streaming), the plan (needed pieces and a weight for each piece), per-file progress, and BEP 53 `so=` parsing (`0,2,4,6-8`, zero-based, inclusive; open-ended ranges are not in the BEP and are refused; malformed or impossible choices are reported and never mean "everything"; merging into a known torrent adds only files not downloading, at Normal).
- Cross-file pieces: a piece is needed when any chosen file has a byte in it (its hash needs the whole piece); its urgency comes only from the chosen files; the bytes it holds for files not chosen live in the scratch file and are never published.
- `TorrentStorage.reselect`: changing the choice while running moves the bytes of verified pieces between a chosen file and the scratch file, so nothing is downloaded twice; a file chosen later is filled from what is held; a file dropped is removed (with its empty folders) and never published; empty files follow the choice; a failed change removes what it created; `finish` publishes only chosen files.
- `TorrentPicker`: priority first, then a peer's suggestion, then the order (rarest, in order, or a window from the playback position), then availability; live `configure` (returns requests to cancel); endgame (nothing left unbegun and at most 48 blocks missing: a block may also be asked of up to 2 other peers; the first valid answer wins and the others are told to cancel; a block owned by a web seed is never duplicated); whole-piece claims for web seeds; per-file verified bytes.
- Web seeds (`WebSeed.swift`): BEP 19 `url-list` (trailing slash adds the name; multi-file adds name and path; one range request per file a piece touches; padding files are zeros; a server that ignores Range is used only for files up to 8 MiB) and BEP 17 `httpseeds` (`?info_hash=&piece=`; 503's body is the wait in seconds). They go through the tracker client's HTTP path: pinned address, redirects checked one by one, the person's proxy and metered-network choices, no credentials, and an address on the local network only when approved. Up to 4 requests at once; a seed that sends data failing the check is dropped; 404 and the like drop it; 503 and timeouts back off (30 s doubling to 10 min; six failures drop it).
- Persistence: the sidecar (`.state.json`, version 2) keeps priorities, order, stream position and seed addresses, written to a temporary file and renamed over the old one; sidecars from before DX-05 load with every chosen file at Normal.
- UI: the Add sheet has a tree (folders with mixed state, search, All/None, priority menu, order menu, web-seed notice, BEP 53 notes) in place of the old flat list that silently included everything after the 200th file; the inspector has "Choose files" with progress, priorities and order for a running torrent, plus web-seed and last-stretch rows.

### Evidence
- Unit and session tests (DX-05 classes, plus the existing picker, storage, metainfo, magnet and session classes): all pass.
- Independent: a Python web seed written from BEP 19 and BEP 17 (`e2e/webseed.py`): only the chosen file's pieces were requested, including exactly the neighbouring ranges a shared piece needs, with no whole-file requests; files exact; with a Maximum-priority file the HTTP seed was asked for its pieces first (order 3, 4, 0, 1, 2). Two independent peers with the transfer slowed to 80 KB/s: the last stretch was reached (11 duplicate requests), every piece verified once, file exact.
- The independent review found 10 issues; the confirmed ones are fixed (a choice that grows during the final check could have published holes; stale seed claims; large pieces on slow links; concurrent changes; leftover unchosen files; a stale tree when the inspector changes torrent; a truncated body counted as wrong data; and, found by a test it broke, a seed that sent bad data could claim another piece before the first was checked).

### Not verified, not done
- The new screens were compiled, not clicked through (the tree with thousands of files, priority menus, the inspector panel, the order picker).
- Streaming order is implemented in the picker and the session (`setStreamPosition`), but nothing feeds a playback position to it yet: preview playback from partial files is DX-13/14 work.
- The magnet `so=` choice is applied after the details arrive; the whole Add sheet flow was not exercised by hand.
- Web seeds on the local network need the existing approval, and no dialog asks from a background download, so such a seed is simply not used.
- FTP web seeds are not used (DX-12). Without peer-to-peer enabled a torrent does not run, so web seeds alone are not used then.
- A pause that lands in the middle of a change of files keeps the on-disk change but not the saved choice; a resume rebuilds the files and the final check fetches again what is missing.
- Filenames are matched as the app normalizes them (NFC, trimmed); a server holding the raw names may answer 404 and the seed is then dropped.
- `TrackerScrapeTests.testTheTorrentKeepsItsTiersInOrderWithoutRepeats` (DX-01) fails: it expects a lone `announce` URL to be a tier of its own even when an `announce-list` exists; the parser ignores it, as BEP 12 says. Not touched here; needs a decision.

### DX-06 dependencies
Extension points: `TorrentMetainfo.segments` and `TorrentStorage` (file layout and piece-to-file mapping, v1 SHA-1 checks in `matches`), `TorrentPicker.pieceVerified/invalidate/verifiedBytesByFile`, `TorrentPlan` (needed pieces and weights), `TorrentSession.verify` (the one place a piece is accepted), the sidecar `version` field. v2 Merkle trees will need per-file hash trees alongside the piece hashes, seeding will need a read path that serves only verified pieces, and creating a torrent can reuse `TorrentFileTree` and the piece geometry.
