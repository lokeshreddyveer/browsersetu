# Remote companion (Phase 23)

**Status: foundation delivered; encrypted network connectivity is NOT available on the system this was built on.** Pairing, device identity, per-device authorization, revocation, the gate in front of the command service, events and the settings screen are implemented and tested. No device can connect over a network yet, and the app says so ("Not available") instead of listening.

## What exists

* **Settings ▸ Downloads ▸ Remote devices.** Off by default. Turning it on first checks what the Mac can really do (`RemoteTransportSupport.detect`): the app must be allowed to accept connections, and a pre-shared-key TLS handshake must succeed against itself (right key in, wrong key out). If either fails the switch stays off and the reason is shown.
* **Devices are automation clients.** A paired device is an `AutomationClient` (one profile, scopes, token stored only as a hash, durable revocation, expiry, event streams closed on withdrawal) plus a `RemoteDevice` record (name, kind, when paired, last connected, credential version) and a channel key in the Keychain. Nothing about authorization is duplicated.
* **Same command service.** `RemoteGateway` accepts a request only from a connection whose proven identity is a paired, active device of this profile with a key on file, whose bearer token belongs to *that same device*, then passes it to `AutomationService.handle` unchanged (scopes, profile checks, rate limits, approval-only creation, private downloads invisible, SSE with `Last-Event-ID` and `stream.gap`). Browser-origin headers and tokens in addresses are refused as for the socket.
* **Proposals still need the Mac.** A device can only *propose*. There is no route that approves; a direct "approved" request, internal addresses, magnet/eD2k links and unsupported schemes are refused as before.

## Pairing

1. **Add Device** makes an invitation: 6 random bytes of id and a 128-bit random secret, valid for two minutes, one device. The QR code and the typed code carry id and secret (and the Mac's address when a transport exists). They are not an access token.
2. The companion asks to pair over the channel the secret sets up, giving its name and a 16-byte random number; the Mac answers with its own. A second use of the invitation is refused (replay); one device may wait at a time; a new invitation withdraws the old one; five unknown invitation ids in a minute lock further guesses for a minute.
3. Both sides derive **six digits** (HMAC-SHA256 over both numbers, keyed from the secret). The companion shows them; **the person types them into the Mac**. Three wrong tries end the pairing. A stranger who only photographed the QR code cannot see the companion's screen.
4. Only then are the credentials made (a client with the chosen scopes, a 256-bit channel key) and handed over **once**, to whoever proves it holds the secret (HMAC over the pairing id). The Mac keeps only the token's hash. Nothing is kept in memory afterwards.
* Default scopes: see downloads, pause/resume/cancel/retry, propose downloads, see the queue. **Never the file permission** unless the person adds it.
* Revoke ends the device at once (key removed, client revoked through the durable deny records, event streams closed). Remove deletes the record. Rotation (new key *and* new token, both or neither) exists in the controller; the screen does not offer it because there is no channel to deliver new credentials over yet.

## Why remote connectivity is unavailable here

* The sandboxed app has the client network entitlement only; accepting incoming connections needs `com.apple.security.network.server` (the downloadable build has it). A TCP listener in the test host fails with "Operation not permitted".
* Network.framework's pre-shared-key TLS did not complete a handshake on this system (TLS 1.2 or 1.3, over a Unix socket), so the app cannot offer an encrypted channel. **No home-made encryption was substituted.** If a future system or approach (certificate-based mutual TLS with a per-Mac identity, or a vetted Noise/QUIC library) passes the same self-test, the transport can be added behind the existing gateway without changing anything above it.

## Alternatives considered

| Option | Security | App Store fit | Cost / upkeep | Verdict |
|---|---|---|---|---|
| Mutual TLS on the LAN, per-Mac self-signed identity and per-device client certificates | Strong, standard | Needs server entitlement | None | Preferred next step (needs certificate creation without openssl) |
| TLS pre-shared key (built) | Strong if it works | Same | None | Does not complete here |
| User's own private network (Tailscale, WireGuard) in front of the same listener | Strong, user-managed | Same | None | Works with the above; no code in this app |
| Outbound-only relay with end-to-end encryption | Strong if E2E | No listener | Hosting, maintenance | Deferred; not built, nothing deployed |
| Public HTTP listener | Weak | Poor | — | Rejected |

Nothing here is reachable from the internet, and worldwide remote access is **not** claimed.

## Not done / unverified

No transport, so no real-device test, connection limits, slow-client or network-change behaviour; no companion app (the API is the documented automation API); Bonjour advertisement not added (needs local-network usage declarations); the settings screen has never been seen running.
