# Packages, batch downloads and the Website Explorer (Phase 19)

## Where an address came from (the Phase 18 correction)

An address the person **typed** is theirs (`origin: user`): it may name a page on their own network, may use their proxy, and may be fetched in several parts. An address that came from a **web page, the clipboard, a crawl, a collection or an automation proposal** is `page`: the person's approval starts the download, but it keeps the untrusted network rules however it was approved: no local-network destinations (checked by name, by what the name resolves to, at every redirect, and at the connection that was actually made), no proxy that hides where the connection goes, no multipart, no credential headers, and the file is set aside until the destination was verified.

* The origin is saved with the task and read back on restart, resume and retry. Nothing promotes it.
* `scheduleDownload(origin:)` accepts only `user` or `page`; any other value is made `page`. Automation proposals the person approves are `page`.
* In Add Download, an address a page or collection supplied keeps `page` until the person changes the text. Editing it makes it their own typing.
* Media previews, the playlist fetch, planning and the segment downloads all carry the origin.

Known limit: as for every untrusted fetch, a name that resolves to a public address when checked and to a private one when connected is detected at the connection, not prevented before it.

## Packages

A package is a **named, ordered grouping of tasks that already exist in the ledger**. It has no transfer, state machine or queue of its own. Progress and status are worked out from the members each time; every action is the coordinator's own action on a member.

* A task is in at most one package. Only this profile's ordinary (non-private) tasks can be members. Packages are saved per profile (`packages.json` beside the task database); tasks that no longer exist drop out on load and on every change.
* Removing a package, or members, removes the *grouping*. Cancelling is a separate action. Pause / Resume / Retry Failed / Cancel Unfinished report each member (done, left as it was, could not be done); nothing is atomic.
* Aggregate progress is shown as a percentage only when every non-cancelled member's size is known. Status is *completed* only when every member completed; paused, cancelled or failed members never count as finished. A package that completes or needs attention is announced once, through the same event feed as task events (`package.completed`, `package.attention`).
* Folder: a package may name a folder (inside Downloads). It is applied to members that have not started. The folder is cleaned (no `..`, no separators, no hidden names, bounded) and checked, before anything is created, to be inside Downloads after symbolic links are followed; otherwise the file is saved in the usual place. Existing files are never overwritten; the existing duplicate policy and safe finalization apply.

## Batch creation

LinkGrabber ▸ **Add as Package…** reviews the selection (files to be made, already downloading, needing their own approval, unsupported), then makes one ordinary scheduled task per file. The shared scheduler starts them in turn within the "downloads at once" limit. At most 200 per batch; links already downloading are skipped; the same batch asked for twice makes nothing new. Streams, magnet and eD2k links and web pages are never made here (each needs its own preview and approval). A private collection makes nothing. Folder templates: `{package}`, `{host}`, `{directory}`, `{date}`. Grouping: one package, by website, or by type.

## Website Explorer

Library ▸ **Explore This Website…** reads a few pages of one website and **proposes** the files it finds. It downloads nothing and does not check availability unless asked ("Check Sizes", up to 50, on the selected).

* Scope: this website only (unless more hosts are listed), stay in the starting folder, depth 0–3 (default 1), pages 1–100 (default 25), at most 2 000 results, 1–2 MB per page, 10 MB total, 2 minutes. Every request counts toward the page limit, whatever came back.
* Polite: **robots.txt (RFC 9309)** is read once per website and obeyed (longest match, allow wins ties, `*` and `$`; 4xx means no rules; 5xx or no answer means nothing is read), requests to one website are at least 0.5 s apart (more if `Crawl-delay`).
* Links found on pages are untrusted: a page on the internet cannot send it to the local network; a redirect is only followed to another address inside the scope on the same website (the new address is not requested otherwise); the starting page itself may move (http→https, www) and the scope follows it after robots.txt is checked for the new place.
* Only addresses are read from markup (`a`, `area`, `img`, `video`, `audio`, `source`, `iframe`, `embed`); scripts, styles, forms and text are skipped. Results are in memory only, never saved, and are for the profile that asked.
* A private tab is refused.

## Not done, or not verified

* The new sheets (Packages, Explorer, the LinkGrabber package form) were never seen running.
* Real-website behaviour of the Explorer is untested; only local fixtures were used.
* A package's folder cannot move a download that has already started.
* No cross-profile package sharing, no package scheduling presets (deferred to later phases).
