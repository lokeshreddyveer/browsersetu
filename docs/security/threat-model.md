# Threat model (v1)

| Boundary | Trust | Rule enforced |
|---|---|---|
| Native shell + Rust core | trusted | typed calls only; no localhost server |
| Webpage / subframes | untrusted | no bridge to the core; navigations evaluated by `evaluate_navigation` (http/https only; mailto/tel need confirmation; file, javascript, data denied) |
| Downloads | untrusted | filenames stripped to a leaf name, unique path, never opened automatically |
| Profile names | untrusted input | `[A-Za-z0-9_-]{1,32}` before touching the filesystem |
| Permissions | sensitive | insecure origins always denied; private tabs always prompt and never persist |
| Private tabs | | non-persistent data store; core never writes their history or session |
| SQL | | parameterized statements only, LIKE patterns escaped |

Known gaps (16 Oct 2026): WKWebView site isolation is the system's. Extensions run in WebKit's own extension sandbox, are reviewed before they run, install only from an immutable staged copy, and are off in private tabs; no store signature is verified. HTTP sign-ins are saved per full protection space (scheme, host, port, realm, method), only filled over HTTPS and never from a private tab. Local sharing uses a 100-bit one-time code, expires after five minutes and stops after five failed attempts. See `docs/capabilities.md`.

Startup stop (documented on purpose): `BrowserModel.init` ends in `fatalError` only when the profile database, an in-memory database and a scratch folder all fail to open. Nothing can run without the storage engine and a half-started browser could write to the wrong place, so it stops with a message that names the reason. Every earlier failure falls back to a recovery profile first and tells the person.

Web content and plain HTTP: the Info.plist sets `NSAllowsArbitraryLoadsInWebContent` so the browser can open pages a person types as `http://`. It applies to web views only, not to the app's own requests (updates, rule lists, sync), which stay HTTPS. The browser still shows the lock state, refuses to fill saved sign-ins over plain HTTP except on localhost, and keeps insecure origins from permissions.
