# Browser downloads and the download manager (Phase 12)

One ledger (`DownloadLedger`) and one coordinator (`DownloadCoordinator`) own every download. The browser adds no manager of its own.

## Routing policy (`BrowserDownloadRouting`)

| Input | Path | Why |
|---|---|---|
| WebKit turns a navigation or response into a download | WebKit session (`WebKitDownloads`) | Depends on cookies, sign-in, a POST body or a blob. Only the page's web view may fetch it. |
| Save Link As / Save Image As (http/https only) | WebKit session | The page's session applies; the file is never fetched as an anonymous address. |
| Address typed or pasted into Add Download | Standalone HTTP engine | Only where the request policy allows it. |
| `magnet:` / `.torrent` | BitTorrent preview | Nothing connects until the person approves. |
| `ed2k:` | eD2k preview | Same. |
| Extension suggestion | Information only | Phase 11 gate; never a task by itself. |
| A page merely containing a link | Refused | Browsing a page starts nothing. |

## Lifecycle of a WebKit download

1. WebKit hands over a `WKDownload` (navigation action or response). `WebKitDownloads.adopt` sets the delegate once and records a `BrowserDownloadContext`: the data store, method, whether it had a body or credential headers, and any destination the person chose. Nothing about the download is read from the web view afterwards, because the web view is gone when its tab closes.
2. `decideDestinationUsing` asks the coordinator for a place in line (`admitTicket`), applies the duplicate policy (skipped when the person chose the place in a save panel), may hand a large plain GET to the piece engine, then `begin` creates the destination. Same task id from ticket to completion.
3. Progress comes from `WKDownload.progress`; completion, failure, cancellation and interruption go to `finish`, `fail`, `discard` and `interrupt`. Each is idempotent in the ledger.
4. A download that WebKit ends while it is still waiting for a place gives the place back (`abandonAdmitted`).

## What is not repeated

A retry, a scheduled start or a resume from an address is only done for a plain GET with no body and no credential headers. A POST-generated download that fails is reported with no retry button. WebKit resume data is conditional: resume is offered only when WebKit supplied it.

## Profile and privacy

Retries and resumes go out through a page that uses the same website data store as the download. A private download is only ever restarted through a private page; an ordinary one never through a private page. A download restored after a restart (no recorded store) uses only an ordinary page.

## Save As

Choosing a place in the save panel changes nothing on disk. WebKit writes to a hidden, task-owned staging folder inside the app's Downloads folder (always authorized, so a resume works). After the transfer finishes and is checked, the file is moved to the chosen place: a free place gets the file; an existing file the person agreed to replace goes to the Trash first and is put back if the move fails; a file that appeared after the panel closed is never replaced (both are kept). Two tasks never claim one place. If the chosen place can no longer be written (usual after a relaunch, because the permission ended with the app), the file is moved to the visible Downloads folder, the task records `saveAsPlacement=failed`, and the failure list says so. Across volumes the move is copy-then-delete and not atomic. The chosen path and the replace flag are kept in the ledger so a relaunch can still finish the job.

## Which session a task belongs to

Each task is tied to its data store by task identity, never by address. A profile's store is recorded in the ledger as a plain name (`wkStore`); a private session is never written down, and every private store is a separate session. A start, retry or resume goes only through a page of exactly that store. If the store is unknown or no such page is open, nothing is borrowed: the task is marked recovery-required (resume data kept) or closed with the reason.

## Not done on purpose: automatic link detection

No page scanning and no automatic magnet/eD2k interception. The place to add it later is a new `BrowserDownloadRouting.Input` case produced by the user's explicit action (for example a context-menu item on a magnet link), which already maps to the preview routes. Nothing in the engine should call the torrent or eD2k runners directly.

## Limits

- The bandwidth limiter does not limit a WKDownload; only the app's own engines are limited.
- Transfer speed and ETA are not shown for WebKit downloads unless WebKit reports byte counts.
