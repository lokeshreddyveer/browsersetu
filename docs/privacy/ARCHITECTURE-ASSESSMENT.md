# Privacy integration: architecture assessment

Audit date 2026-10-15. VayuSetu was audited at `~/Documents/VayuSetu` (the path in the brief,
`~/Downloads/vayusetu`, does not exist). That checkout has the same origin as
`https://github.com/lokeshreddyveer/vayusetu`, commit `b25d6cf`.

## What was found

**VayuSetu** (VPN client, encrypted DNS and Safari ad blocker). Its ad-block code is already a separate Swift package
(`Packages/VayuSetuCore`):

| File | Purpose | Reusable here |
|---|---|---|
| `Filtering.swift` | domain normalisation, `FilterRule`, `RuleEngine` precedence, hosts/ABP domain parser, `SafariRuleCompiler` | Yes, verbatim |
| `ABPContentParser.swift` | URL-pattern and element-hiding rules; counts unsupported syntax | Yes, verbatim |
| `PublicSuffixData.swift` | public-suffix list used to reject bad domains | Yes, verbatim |
| `FilterCatalog.swift` | metadata for ~90 public lists | Yes, verbatim |
| `SafariPlanner.swift` | splits rules across six Safari extensions delivered through an App Group | No: specific to that delivery model |
| `Protection.swift` (`PrivacyIntegrityEngine`) | "a preference never manufactures an observation" | Pattern reused (`ProtectionEvaluator`) |
| VPN, DNS, tunnel, network-filter code | | Excluded by the brief; not touched |

**BrowserSetu before this work.** One 30-host list in Rust (`domain/blocking.rs`) emitted by an FFI function and compiled
by a Swift helper. No exceptions, no precedence, no lists, no status. The app made no network requests of its own.

## Answers to the audit questions

1. **Reusable directly:** the four files above (copied unchanged, hashes recorded in `Packages/SetuPrivacyKit/IMPORTED.sha256`).
2. **Needs a WebKit adapter:** compile/cache/attach (`SetuPrivacyWebKit.ContentRuleInstaller`). VayuSetu has no `WKContentRuleListStore` code.
3. **Already in BrowserSetu:** a minimal tracker list. It overlapped with the new engine and was **deleted** so there is one authority.
4. **Overlap / one authority:** `SetuPrivacyKit` owns rule models, validation, precedence and compilation. The Rust core owns *storage only*
   (the configuration is a validated JSON value in the per-profile SQLite `settings` table). Rust keeps navigation security policy,
   which sits above any content rule.
5. **Unsupported syntax:** scriptlets, regex rules, redirects, `removeparam`, `csp`, extended selectors, `$important`, `$badfilter`,
   `$denyallow`, document-level and subdocument options. Counted and reported, never approximated.
6. **Not possible with public WebKit API:** per-request blocked counts, rewriting responses, redirects, blocking in other apps.
   The UI shows no counts for that reason.
7. **Risks introduced:** downloaded text is untrusted (bounded to 8 MB, UTF-8, parsed by a strict parser, compiled before it is
   saved, never executed). Two copies of the imported files can drift (see below). ATS exemption for web content (see below).
8. **Circular dependency:** none. `SetuPrivacyKit` depends on nothing in either app. BrowserSetu depends on it. VayuSetu is untouched.

## Decisions that differ from the brief or from VayuSetu

* **Location and VayuSetu adoption.** The package lives in this repository and VayuSetu does **not** yet consume it (the brief said
  to preserve VayuSetu and not to modify its VPN/DNS code, and its full app cannot be rebuilt and validated here). The files are
  therefore *copies*. `scripts/check-privacy-kit-drift.sh` fails if they diverge from VayuSetu's. Migrating VayuSetu to depend on the
  package is the follow-up that removes the duplication.
* **Precedence.** Implemented as specified: mandatory security (navigation policy in Rust) > user rules > website exceptions >
  list rules > default. VayuSetu's Safari planner instead appends site exceptions *last*, so there an exception overrides a user
  block. In BrowserSetu a user block still applies on an exception site. Verified in `PrivacyIntegrationTests`.
* **WebKit ordering.** A later rule overrides an earlier one, so the output is laid out lists, then exceptions, then user rules
  (most specific last). This was tested against real WebKit, not assumed.
* **Strict mode.** Adds session-recording hosts, third-party tracking-endpoint requests (verified) and third-party cookie blocking
  (installs; effect not separately measurable because WebKit already refuses third-party cookies). An earlier "beacon" rule was
  removed because WebKit classifies `sendBeacon` as `raw`, not `ping`, so it did nothing.
* **ATS.** `NSAllowsArbitraryLoadsInWebContent` was added. Without it a WKWebView browser cannot open `http://` pages for any
  hostname (only IP literals worked). It affects web content only; the filter updater's own `URLSession` stays under ATS and refuses HTTP.
* **Branding.** "Protected by VayuSetu" is shown only when the state is `active`: rules compiled, attached, matching the current
  settings, no failed lists, nothing dropped. Otherwise an accurate status word is shown.
