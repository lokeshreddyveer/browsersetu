# Adaptive speed and connections (Phase 22)

**Settings ▸ Downloads ▸ Speed and network ▸ Adapt to** chooses how the downloader reacts to what it can measure. It never goes past your own limits, it can only slow things down, and it does not (and cannot) see what other apps are doing.

| Mode | What it does |
|---|---|
| **Unlimited** (default) | Nothing of its own. Your speed limit, connection counts and network rules are all that apply |
| **Balanced** | Fewer connections per download after repeated errors; downloads held to about 70 % of their measured speed while the browser is busy |
| **Browser Priority** | Same, but held to about 40 % while the browser is busy |
| **Download Priority** | Same, but held to about 85 % while the browser is busy |
| **Custom** | Only the numbers you set. Nothing changes by itself |

"Reset Speed and Connection Settings" puts speed, connections, waiting, retries and this choice back to the defaults. It keeps your proxy and your offline / metered / Low Data Mode rules.

## What is measured, and what is not

* **Measured:** the bytes this app's own downloads receive (averaged over a six-second window, because a throttled transfer arrives in bursts), the connections they hold, how many transfers failed in a way that may be tried again, whether a page is loading, the network path, and Low Power Mode / the Mac's heat.
* **Not measured, and never claimed:** how much of the network other apps use, or the network's real capacity. No packet capture, no Accessibility, no helper. Nothing here says *which* app is busy; it reacts to this app's own measurements and to its own browser being busy.
* One short transfer is not a capacity: nothing is estimated until there are three samples with data in them, and a ceiling is a share of the rate measured *before* it began (so it cannot spiral downward on its own effect).

## Browser activity

Only "a navigation began / ended" is recorded (a count and two times): no address, title, tab, or whether it was private. The browser counts as busy while a load is under way and for a grace period after it (2 to 60 seconds; default 8), and a load that never reports its end is ignored after a minute. Playing video is not used as a signal: no supported API is wired in.

## Rules

* The **manual limit is a hard bound.** The speed a profile's downloads share is the lower of the manual limit and the adaptive ceiling.
* **Connections:** after two or more failures in 30 seconds the per-download connection count drops by a quarter (at least one fewer, never below one, at most once every 10 seconds); after 30 quiet seconds it comes back one at a time. Low Power Mode or a hot Mac (adaptive modes only): at most two connections per download.
* A download **held by the network rule** (offline, metered or Low Data Mode as you chose) stays held, and adaptive limits are cleared while it is. Better speed never resumes it.
* No timer runs unless an adaptive mode is on; it stops after a few looks with nothing moving.
* One line is added to the activity log per significant change (for example "The browser is busy: downloads held to about 2.4 MB/s"); never per small adjustment, never with an address.

## Verified mirrors

Mirrors are still used only with a trusted whole-file SHA-256 and the earlier vetting. The engine now measures what each source has delivered; a source that has delivered under a quarter of the best one keeps one worker (it may recover) and the workers it leaves unused go to the others. No extra connections are opened for this, nothing extra is fetched to benchmark, and a source dropped for failing the checksum is never brought back by adaptive control.

## Profiles

Each profile (coordinator) has its own overall speed limit, per-website connection cap, request timeout and retry count. The shared parts are physical: 16 connections in all, and 8 to one website for everyone together. A profile's setting can no longer change another profile's (before Phase 22 the last one to apply won).

## Which transports are limited

| Transport | Speed limit |
|---|---|
| The app's own downloads fetched in pieces or one piece through the data-task path | **Enforced** (reading stops while it waits) |
| Streams (HLS/DASH) | Held **between** segments only, not inside one |
| Downloads the system or WebKit fetches (including authenticated browser downloads) | **Not limited**; they are never taken over to be limited |
| BitTorrent / eD2k | Their own separate limits; adaptive control does not touch them, and peer networking stays off unless you turn it on |

Adaptive connection counts apply to the app's own multipart downloads.
