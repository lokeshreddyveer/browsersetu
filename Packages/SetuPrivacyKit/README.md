# SetuPrivacyKit

Ad blocking, anti-tracking and filter-list management for WebKit browsers, adapted from VayuSetu's ad-block components.
No VPN, DNS, proxy or network-extension code. No networking at all: downloading lists is the host app's job.

* `SetuPrivacyCore`: pure Swift. Configuration, validation, precedence, rule snapshots, honest protection state.
  `Sources/SetuPrivacyCore/Imported/` holds four VayuSetu files copied **unchanged** (hashes in `IMPORTED.sha256`).
* `SetuPrivacyWebKit`: compiles a snapshot into a `WKContentRuleList`, caches it by content hash, attaches it to every
  `WKUserContentController`, keeps the previous rules if an update fails. Public WebKit API only; no script injection.

Precedence, lowest to highest: filter lists, website exceptions, user rules (most specific wins). Mandatory browser security
restrictions are navigation policy in the host app and outrank all of it.

Imported files: Copyright (c) 2026 Lokesh Reddy Veerabhadra, from github.com/lokeshreddyveer/vayusetu @ b25d6cf.
Run `scripts/check-privacy-kit-drift.sh` to compare them with VayuSetu.
