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
