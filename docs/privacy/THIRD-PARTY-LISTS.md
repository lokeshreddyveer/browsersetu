# Filter lists and licences

## Shipped inside the app

Three short **first-party** lists (`BundledLists.swift`): ads, trackers, session-recording hosts (about 30 + 28 + 7 hostnames).
They are compilations of widely known public hostnames written for this project. No text from any third-party list is bundled.

## Offered for download (not bundled)

`FilterCatalog` (imported from VayuSetu) names about 90 public lists. BrowserSetu **does not redistribute** them: the user enables a
list, chooses *Update Now* (or turns on automatic updates), and the list is fetched directly from its publisher over HTTPS.

Licences have **not** been verified here. Before any list is *bundled* or the catalogue is described as cleared, each publisher's
terms must be checked and recorded below (several well-known lists are GPL or CC BY-SA, which carry attribution and share-alike duties).

| Status | Action required before bundling |
|---|---|
| Not verified | Confirm redistribution terms, record licence and attribution text, record the source URL and a content hash |

## Update behaviour

* Off by default; at most once per interval (default 7 days), at launch only, no timers.
* Requests contain nothing but the list URL: no cookies, cache, credentials, referrer or identifiers; generic User-Agent.
* HTTPS only; non-HTTPS redirects refused; 8 MB limit; must be UTF-8 text and contain at least one supported rule.
* New text is compiled by WebKit first and saved only if it installs. A failed update leaves the previous rules active.
* Cache is bounded (60 files, 96 MB) and written atomically.
