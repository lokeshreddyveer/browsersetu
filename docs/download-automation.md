# Download automation (Phase 13)

A local, authenticated way for scripts and tools on this Mac to list and control downloads. Off until the person turns it on (Settings › Downloads › Automation). It translates requests into calls on the existing `DownloadCoordinator`; it owns no transfer state.

## Transport

| Option | Decision |
|---|---|
| Unix domain socket carrying HTTP/1.1 | **Shipped.** Mode 0600 in a 0700 folder; no web page can open it; needs no network entitlement, so it fits the sandboxed App Store build. |
| Loopback TCP (`127.0.0.1`) | Written (`AutomationTransport.Endpoint.loopback`) with Host/Origin checks, but **not switched on** by the app and not exercised here: the sandboxed build has no server entitlement. |
| Native XPC | Rejected: the CLI would need a bundled helper and a Mach service. |
| JSON-RPC (aria2 style) | Rejected: a second vocabulary for the same operations. |
| Public/LAN listener | Not in this phase. |

## Authentication and scopes

`Authorization: Bearer bsat_<id>_<secret>` on every request, including `/v1/health`. Only a SHA-256 of the secret is stored; the secret is shown once at *Add Client* or *New Token*. Tokens are never accepted in the address. Ten failed attempts a minute, then 429. A client belongs to one profile, fixed at enrolment.

Scopes: `downloads.read`, `downloads.create`, `downloads.control`, `downloads.files` (moves a finished file in Downloads to the Trash; never implied), `queues.read`, `queues.control`, `settings.read`.

Requests carrying `Origin` or `Sec-Fetch-*` are refused. On loopback the `Host` must be the loopback address with the exact port (DNS rebinding). POST bodies must be `application/json`, at most 64 KB. 60 requests per 10 seconds per client; 16 in flight.

## Endpoints (`/v1`)

| Method and path | Scope | Notes |
|---|---|---|
| `GET /health`, `/capabilities`, `/stats` | read | |
| `GET /downloads[?state=&limit=]`, `GET /downloads/{id}` | read | Sanitized: no query string, user name, cookie, header or path. Private tasks do not exist here. |
| `POST /downloads` | create | **A proposal**, `202`. `"approved": true` is refused. magnet/ed2k are refused. Internal addresses are refused. |
| `GET /proposals` | read | This client's proposals. Approval is only possible in the app. |
| `POST /downloads/{id}/pause\|resume\|cancel\|retry\|priority\|schedule` | control | `409` with a code when the engine cannot. |
| `POST /downloads:batch` | control | pause/resume/cancel up to 50. |
| `POST /downloads/{id}/trash-file` | files | |
| `GET /queues`, `POST /queues/default/hold\|release` | queues.read / queues.control | |
| `GET /settings` | settings.read | |
| `GET /events` | read | Server-Sent Events. `Last-Event-ID` replays. |

`Idempotency-Key` (8–64 chars) on POSTs: same key and body returns the first answer; same key, different body is `422`.

## Why creation is a proposal

`HTTPRequestPolicy.untrustedRequestsEnabled` is false: the system gives no way to refuse a connection to a private address before it is made, so only the person's own requests may start a standalone download. A program is not the person. A client therefore *proposes*, the person approves in the app, and that approval (a real user action) starts an ordinary user download. The API cannot approve, cannot reclassify its request, and cannot start BitTorrent or eD2k. Phase 4 and Phase 11 gates are untouched.

## Events and webhooks

Server-Sent Events were chosen over WebSockets: one-way, plain HTTP, resumable with `Last-Event-ID`. Each subscriber has a 64-event buffer; progress is coalesced; a client that falls far behind is cut off. Eight streams in all, four per client. Event types: `task.created`, `task.started`, `task.progress`, `task.paused`, `task.resumed`, `task.completed`, `task.failed`, `task.cancelled`, `task.recovery_required`.

Webhooks are off until an endpoint is added. Destinations: https to a public website, or http to `127.0.0.1`; never a private-network address, never one that resolves to one (re-checked at every delivery; a name can still change between check and connect). Redirects are not followed. Payloads carry task id, state, byte counts and host only. Signed `X-BrowserSetu-Signature: t=<unix>,v1=<HMAC-SHA256(t.body)>`; secrets live in the Keychain. Three attempts, a 100-item queue.

## MCP

Deferred. The existing MCP adapter (`AgentMCP`) serves browser tabs under a different permission model; adding download tools would mean a second set of scopes there. The streamable-HTTP transport also requires Origin validation and a TCP listener, which this build does not have. When added it should call this service, not the coordinator.

## Future remote control

`AutomationService.handle` takes an `AutomationRequest` and returns an `AutomationReply`; any later transport (an authenticated companion in Phase 23) can feed it. Nothing is exposed beyond this Mac now.

## Sources consulted

OWASP API Security Top 10 (2023); MCP specification revision 2026-07-28 (transports, authorization); aria2 manual (RPC options); Stripe webhook signing guidance; WHATWG Server-Sent Events. Apple's Network framework page could not be read (script-only page), so listener behaviour was verified by running it. AB Download Manager's repository page was read but documents no API details.
