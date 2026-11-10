# Scenario coverage matrix: DX-01 (trackers), DX-02 (DHT), DX-03 (peer protocol)

Classification: COVERED (handled and tested), PARTIAL (handled, not fully tested or user-visible status is thin), MISSING (gap), BLOCKED BY PLATFORM, N/A.
"Test" names the class or test that exercises it. Items marked **fixed now** were closed in the DX-04 prerequisite review.

## DX-01 — trackers

| Scenario | Expected | Code path | Test evidence | Class | Recovery / workaround | User-visible | Change |
|---|---|---|---|---|---|---|---|
| UDP tracker offline / timeout | retransmit 15·2^n, then fail the endpoint, try the next in the tier, back off 60 s…1 h | `UDPTrackerClient.exchange`, `TrackerBook.failed` | UDPTrackerTests (loss, timeout), TrackerLifecycleTests (fallback within tier) | COVERED | next endpoint / tier; never dropped | tracker row: Error + reason + next try | no |
| Malformed or stale reply | rejected, stream not corrupted | `UDPTrackerClient.parse`, `HTTPTrackerClient.parse` | UDPTrackerTests (tid mismatch, wrong action, truncated, oversize), Phase9TorrentTests | COVERED | retry on the same schedule | error text | no |
| Connection-id expiry | never reuse an id across sockets | each exchange connects afresh | UDPTrackerTests (own connection id) | COVERED | — | — | no |
| Mixed HTTP/UDP tiers | per-tier failover, tiers independent | `TrackerBook`, `TrackerRouter` | TrackerLifecycleTests | COVERED | — | rows per tracker | no |
| Scrape unavailable | counts unknown, not zero | `scrapeNow`, `noScrape` | TrackerScrapeTests, review fix tests | COVERED | note on the row | "Counts: unknown" | no |
| DNS rebinding / redirect to LAN | resolved once, checked, pinned; each redirect re-checked | `HTTPTrackerClient.fetch/checkedAddress`, `UDPTrackerClient.resolveChecked` | HTTPTrackerDestinationTests | COVERED (direct); proxy path checks redirect names only | page requests refused through a proxy | error text | no |
| Authorized LAN tracker | destination-scoped permission, enforced in the client | `LocalTrackerPermission`, `TrackerScope` | LocalTrackerPermissionTests | COVERED | Allow Once / Remember / revoke | Settings list | no |
| Permission revoked mid-transfer | tracker grant and its peers end | `revoke`, `peerPermitted` | DX03SessionTests (revocation) | COVERED | — | — | no |
| P2P turned off during an announce | no further traffic, no stopped/completed | `stop(sendStoppedAnnounce:false)`, tasks cancelled | DX01LifecycleClosureTests | COVERED | local cleanup only | — | no |
| Proxy / metered network | UDP fails closed with Open Settings; HTTP via system client; flags applied | `withConnection`, `fetch`, `isProxyProblem` | UDPSendBoundTests, HTTPTrackerDestinationTests | COVERED | choose "No proxy" | row + Open Settings | no |
| Proxy turned on while a torrent runs | connections made before it must not continue direct | peers: none before; **fixed now** `settingsChanged` → `networkChanged` closes them | DX03SessionTests (network change) | was MISSING → COVERED | reconnect under new policy | — | yes |
| Network interface switch | new sockets per request; peers reconnect by backoff | per-request sockets | none dedicated | PARTIAL | backoff re-tries | none specific | no |
| Resume after interrupted announces | started sent again for a new session, no stale timers | book rebuilt; tiers saved in sidecar | TrackerLifecycleTests (relaunch), DX01ReviewFixTests (tiers) | COVERED | — | — | no |

## DX-02 — DHT

| Scenario | Expected | Code path | Test evidence | Class | Recovery | Visible | Change |
|---|---|---|---|---|---|---|---|
| Bootstrap unavailable / all silent | state "No nodes reachable", keep retrying while needed | `bootstrapResolved`, `tick` re-bootstrap | **added now** testAllBootstrapNodesSilentIsReportedAndRetried | was PARTIAL → COVERED | retry every 60 s | inspector DHT row + error | test only |
| Stale / malicious nodes | bounded table, one per address, id bound to address, hearsay never evicts | `DHTRoutingTable.insert` | DHTCoreTests | COVERED | markFailed → replacement | node count | no |
| Malicious replies | tid + source + id checks, size caps | `receive`, `KRPC.parse` | DHTNodeTests (spoofed, malformed) | COVERED | dropped, counted | — | no |
| Routing persistence corrupt | ignored, size bound | `DefaultsDHTNodeStore` | DHTNodeTests | COVERED | cold bootstrap | — | no |
| Trackerless magnet, zero peers | lookup ends, repeats every 60 s while few peers; details time out | `dhtTick`, probe timeout | DHTSessionTests | PARTIAL | the 60 s timeout message names details, not DHT | generic message | no |
| Duplicate peers DHT + tracker | one connection | `addCandidates` canonical | DHTSessionTests, DX03SessionTests | COVERED | — | — | no |
| Private flag found after metadata | DHT/PEX/LAN peers dropped, tracker peers kept | `forgetSource`, `stopDHT` | DX03SessionTests (private), reviewed | PARTIAL (not a dedicated end-to-end test) | — | — | no |
| P2P / DHT disabled mid-lookup | lookups end, socket closed, nothing sent | `stopNow`, policy tick | DHTNodeTests | COVERED | — | status Blocked | no |
| Proxy changes mid-task | DHT stops within a second; direct connections end | policy tick; **fixed now** `networkChanged` | DHTNodeTests, DX03SessionTests | COVERED | choose No proxy | Open Settings | fixed |
| IPv4-only / IPv6-only | no IPv6 socket → no `want`; IPv6-only network needs an IPv6 bootstrap | `supportsIPv6` | DHTNodeTests (IPv4-only) | PARTIAL (IPv6-only untested) | public bootstrap list is hostnames | — | no |
| Sandbox: unconnected sockets cannot receive | per-node connected sockets | `NWDHTTransport` | DHTLiveTests (independent node) | BLOCKED BY PLATFORM for inbound | outbound works | — | DX-04 |
| Network interface change | sockets replaced, bootstrap again | **fixed now** `tick` path generation | **added now** testANetworkChange… | was MISSING → COVERED | — | — | yes |

## DX-03 — peer protocol

| Scenario | Expected | Code path | Test evidence | Class | Visible | Change |
|---|---|---|---|---|---|---|
| Invalid / unsolicited Fast messages | not agreed → drop; bad index → drop; no details yet → ignore | `handle(message)` | DX03SessionTests | COVERED | — | no |
| Rejected allowed-fast request | block freed, other peer asked, same peer avoided 30 s | `picker.rejected`, `rejectedPieces` | DX03SessionTests | COVERED | — | no |
| Single-seed starvation after reject | avoid is time-limited | `rejectedPieces[index] = now+30` | DX03SessionTests | COVERED | — | fixed earlier |
| PEX duplicates / dropped provenance | per-sender vouchers; goes only after the last | `pexVouchers` | **added now** three provenance tests | was MISSING → COVERED | — | fixed |
| Candidate flooding | 500 cap, per-message 50, per-address LAN cap | `addCandidates`, LPD limits | DX03Tests (LAN flood) | COVERED | — | no |
| Unauthorized LAN peers | need a still-valid source | `peerPermitted` | DX03SessionTests | COVERED | — | no |
| Mapped-address duplication | one candidate | `PeerAddress.canonical` | DX03WireTests, DX03SessionTests | COVERED | — | no |
| IPv6 block list | ranges, mapped entries | `PeerFilter` | DX03WireTests | COVERED | — | no |
| Backoff after failure | 15 s doubling, policy refusals not counted | `PeerRecord`, `connectMore` | DX03SessionTests | COVERED | counts in inspector | no |
| Live change: PEX / LAN / block list | immediate | **fixed now** `settingsChanged` → `applyLive` | **added now** DX03SessionTests (live) | was MISSING → COVERED | — | fixed |
| Revocation during active connections | dependent connections closed, others kept | `revalidateLocalPeers` | DX03SessionTests | COVERED | — | no |
| Multicast receive failure / Local Network denied | status Unavailable / nothing delivered, explained | `MulticastTransport`, `LocalPeerDiscovery` | DX03LiveTests (skip with reason) | BLOCKED BY PLATFORM | status text | DX-04 re-investigates |
| Private torrent discovery | no PEX/DHT/LAN | `pexAllowed`, `dhtWanted`, `lanTick` | DX03SessionTests, DHTSessionTests | COVERED | — | no |
| Simultaneous torrents | fair share of the pool | `PeerBudget` | DX03SessionTests (fairness) | PARTIAL (enforced at acquisition only; stale `waiting` can inflate sharers) | — | noted |
