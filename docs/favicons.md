# Favicons: architecture, schema, policy

One subsystem owns every site icon in Browser Setu. Source: `apps/apple/Shared/Favicons/`. Tests: `apps/apple/Tests/Favicons/`.

## 1. Decision record

| Question | Decision | Why |
|---|---|---|
| Who owns icons? | `FaviconService` (an actor, one per profile). `FaviconStore` is the main-actor face the UI uses. | The audit found one fetcher and one cache, but each UI surface decided for itself when to read the disk. One owner, one contract. |
| Where do icons live? | `<root>/profiles/<profile>/favicons/` | Per profile, so another profile cannot read them and deleting a profile deletes them. The old cache was `Caches/SiteIcons/<host>.png`, shared by every profile, and listed every host ever visited. |
| New database? | No SQLite table. A versioned `index.json` plus content-addressed PNG files. | The Rust core has no icon schema, and adding one means an FFI change and a rebuilt xcframework for a cache that never needs queries. The index is small (bounded, see budget), loaded once, written atomically. If icons ever need joins with history, move the index to the core then. |
| Network rules | The downloads' `HTTPRequestPolicy` (origin `.page`), including `decideRedirectResolving`. No second policy. | Same reach rules for every request a web page can cause. |
| Existing callers | `FaviconStore.shared.image(forURL:)`, `learn`, `clear`, `key(forHost:)` keep working. | About 40 call sites, no churn. The change is behind the API. |
| SVG | Accepted only after `SVGSanitizer` finds nothing active or external; drawn on macOS only. | An SVG is code. "Nothing in the file asks for anything" is a rule a different renderer cannot weaken. |

## 2. Layers and dependency direction

```
WebKitEngine ──(typed IconCandidate + page URL)──▶ TabController ──▶ FaviconStore (main actor) ──▶ FaviconService (actor)
                                                                           ▲                          │        │         │
                                                              FaviconView / SiteTile          IconFetching  IconDecoder  FaviconDiskStore
                                                                                          (HTTPRequestPolicy)
```

| Folder | Holds | Knows about |
|---|---|---|
| `Domain/` | `IconKey`, `IconCandidate`, `IconRecord`, `IconResourceID`, `IconFailure`, `FaviconIndex`, `FaviconBudget`, `IconResolution` | nothing else |
| `Discovery/` | `IconCandidateRanker` (pure) | Domain |
| `Network/` | `IconFetching`, `NetworkIconFetcher`, `IconRedirectGuard` | Domain, `HTTPRequestPolicy` |
| `Decoding/` | `IconDecoder`, `SVGSanitizer` (pure functions) | ImageIO |
| `Persistence/` | `FaviconDiskStore` | Domain, Decoding (legacy import only) |
| `Service/` | `FaviconService` | all of the above |
| `Diagnostics/` | `FaviconDiagnosticsLog` | Domain |
| `Presentation/` | `FaviconStore`, `FaviconView` | Service, SwiftUI |

Nothing below `Presentation/` imports SwiftUI. Nothing outside `Network/` creates a `URLSession` for icons.

## 3. Schema (`index.json`, `schemaVersion` 1)

```
FaviconIndex
  schemaVersion: Int
  legacyImported: Bool                       the old shared cache has been read in (once, default profile only)
  records:   { host -> IconRecord }          the page-to-icon association
  resources: { sha256 -> IconResourceMeta }  the bytes' facts
  failures:  { host -> IconFailure }         bounded negative cache

IconRecord      key, resource, darkResource?, sourceHost, sourceDigest, kind, fetchedAt, validatedAt, expiresAt, etag?, lastModified?, lastUsed
IconResourceMeta bytes, pixelWidth, pixelHeight, mimeType ("image/png"), createdAt
IconFailure     key, failedAt, retryAfter, count, reason
```

Blobs: `blobs/<sha256>.png`, always 64 x 64 PNG. Two sites with the same icon share one blob; a blob is deleted when the last record referring to it goes.

An icon address is never stored (it can carry a token): only the host it came from and a SHA-256 of the address, used to decide whether a conditional request may be sent.

Compatibility: an index newer than the build, or unreadable, is moved to `index.corrupt-<time>.json` (the last three are kept) and the profile starts empty. It is never overwritten in place. Blobs the new, empty index does not name are swept, so the set-aside file is evidence, not a restorable backup.

Clearing writes an empty index marked `legacyImported`, so a relaunch does not read the old shared cache back in.

## 4. Candidate selection (`IconCandidateRanker`)

1. The page's own icons always come before the site's `/favicon.ico`.
2. Icons for the other appearance are not a first choice; they are the dark variant.
3. Scalable (SVG, `sizes="any"`) first. Then the smallest icon at least 64 px. Then icons with no declared size. Then the largest of the ones that are too small.
4. Equal fit: `icon` before `shortcut icon` before Apple touch icon, then page order.
5. At most four page icons are tried, then `/favicon.ico`. (The old code cut the list after adding the default, so with four links it was never tried.)
6. `https` icons always; `http` only for an `http` page. Up to two dark-appearance icons are also fetched after a light one succeeds.
7. A dark-appearance icon is drawn on a dark plate; every other icon keeps a light plate (icons are drawn for a light page).

## 5. Security and privacy policy

- Icon addresses and bytes are untrusted. Origin `.page`: no loopback, private, link-local or `.local` addresses, judged by name **and** by what the name resolves to; every redirect is judged again; an `https` page cannot be redirected to `http`.
- Exception, narrow: a site the person opened on their own network may supply its own icon from **exactly the same origin** (scheme, host and port). Redirects from such an icon are confined to that origin too, so a page on `localhost:3000` cannot reach `localhost:6379` or `169.254.169.254`.
- A direct request is made to the numeric address that was checked: the name is resolved once, every answer is judged, and the connection goes to that address with TLS still verifying the certificate against the site's own name (`NWPinnedHTTP`, the same client the tracker code uses). A name that answers differently a second time (DNS rebinding) cannot redirect it. Redirects are read, judged and resolved before they are followed, at most five.
- Only when a system proxy is in use is the connection left to `URLSession` (it cannot be pinned); there the address the connection really used is checked afterwards, when the system reports one. That path is detection, not prevention.
- No cookies, no cache, no credentials. Login challenges (basic, digest, NTLM, client certificate) are cancelled; the certificate check of https is the system's own.
- Body read as a stream, abandoned at 300 KB; announced length checked first; only image-like content types.
- Decoding: only PNG, JPEG, GIF, ICO, BMP, WebP and HEIC (the type is read from the bytes, not from the name or header); at most 32 frames, 4096 px a side, 4.19 million pixels; decoded as a 128 px thumbnail.
- SVG: parsed as XML with external entities off, then checked against an element allowlist (shapes, gradients, clip paths, masks, symbols, `use`, `style`, `title`, `desc`), whatever the prefix. No `script`, `image`, `foreignObject`, text or animation; no event attributes; every `href` and `url()` stays inside the file; only the standard public SVG doctype; at most 100 KB, 400 elements, 24 levels. A `<style>` element or `style` attribute is parsed (`SVGStyle`): plain `selector { property: value }` rules, 18 painting properties, no at-rules, no escapes, no attribute selectors or pseudo-classes, `url()` only as `url(#id)`; anything else makes the whole SVG unsafe. Drawn on macOS only; the declared size is clamped before use.
- Protection: the domain block rules of the browser's own lists (read back from the compiled content rules whenever they are rebuilt) apply to icon hosts: a third-party icon host on the list is not contacted. See `IconBlocklist`.
- Private tabs never learn an icon. A proxy being on means nothing is fetched. "Fetch site icons" off means nothing is fetched and the cache is cleared.
- Clear browsing data clears icons, including the old shared cache; removing a site's data removes that site's icon; deleting a profile deletes its folder. A service whose profile was left is closed and can write nothing, so it cannot recreate a deleted folder.
- Work that began before a clear, a removal or a profile switch stores nothing and draws nothing (epoch checks in the service and in the facade).
- Diagnostics (in memory, 200 events): host and a fixed reason only, never an address.

### Known limits (not defects of the rules above)

- The fetch is made by the app, not by WebKit. The browser's domain block rules are applied to it (above), but rules that depend on a path, a page, a resource type or a context cannot be evaluated outside WebKit and are not applied; nor are the in-app DNS settings or a VPN-style proxy (while a proxy is on, nothing is fetched). A page can still cause one request to a public host of its choosing, as any image on a page can.
- Icons are keyed by host and, when it is not the default, port (`localhost:3000`, `localhost:8080`). Removing a site's data removes every port of the host.
- The index is written half a second after a change (a burst of icons is one write). A use of an icon is only noted in memory and written with the next change, when the app stops being the active one or goes to the background, and at quit (which waits up to 1.5 seconds for it). A crash can lose uses, never icons older than half a second.
- An SVG that needs more than painting styles (text, filters, animation, an outside image) is refused by design; the site's `/favicon.ico` is tried instead.

## 6. Cache and lifetime

- Fresh: 14 days by default, or `max-age` clamped to 1 hour to 30 days; `no-store` and `no-cache` mean 1 hour.
- Expired: a conditional request (ETag, Last-Modified); a 304 costs no body.
- A good icon whose refresh fails keeps being served and is retried in an hour.
- No icon: not asked again for 10 minutes, then 20, 40, ... up to 24 hours. Offline, slow or cancelled never counts against a site.
- Budget per profile: 2,000 records and 32 MB. Eviction is least recently used, ties by key: the same history always evicts the same icons.
- Memory: 150 decoded images (trimmed to 0 under memory pressure); a miss is remembered so a redraw does not ask again.

## 7. Concurrency

`FaviconService` is an actor. One fetch per site at a time (later callers share the first answer). At most three fetches at once. Decoding runs on a detached task, not on the actor and not on the main thread. Reading an icon in a view never waits: a miss returns nil and the view is redrawn when the icon arrives. Index writes are debounced (3 s) and atomic.

## 8. Integration matrix

| Surface | Reads through |
|---|---|
| Tab strip, sidebar, tab drag card, overview | `SiteTile` ▸ `FaviconView` |
| Address-bar suggestions, bookmarks, history, favorites, start page, essentials | `SiteTile` ▸ `FaviconView` |
| iPhone and iPad tab rails and bars, glance view, search-engine menu, web-app draft | `FaviconStore.image(forURL:)` |
| Page icon links | `WebKitEngine.readIconLinks` ▸ `engineIconsFound(_:page:)` ▸ `FaviconStore.learn` |
| Downloads UI, command palette | no site icons (by design, unchanged) |
