# Mirrors, Metalink and partial ZIP retrieval (Phase 20)

## Other sources for one download (mirrors)

A download can have up to 8 other addresses where the same file can be had (Inspector ▸ Sources ▸ *Add Source…*, or *Open Metalink…* in Add Download). They belong to the one task: one task id, one finalization, one entry in the list and in any package.

**A matching name or length proves nothing about the bytes**, and an ETag only vouches for the server that issued it. So there are two modes, chosen by what can be proved:

| Mode | When | What happens |
|---|---|---|
| **Together** | The task is the person's own (an address they typed), it carries a **whole-file SHA-256**, and the mirror passed checks | Pieces of the file are fetched from the first source and the mirrors at once, within the shared connection limits. Every answer is checked (status, exact `Content-Range`, length, that source's own version tag) before a byte is written. The finished file is hashed; if it does not match, the mirrors are dropped and the file is fetched again from the first source alone |
| **One at a time** | Anything else: no hash, an address that came from a page or a Metalink file, a proxy in use | Only the first source is used. If it fails for good, the next is tried **from the start**; bytes from different sources are never mixed |

Before a mirror is used together with another source it is asked (with the task's own origin and the same address, redirect and connection checks) whether it answers byte ranges correctly and is **exactly the same size**; one that is not is marked unusable. During a run, a source that gives something wrong (a wrong range, a changed file, a refusal) or fails three times in a row is dropped and its piece comes from another; only the last source left ends the run.

Not done: piece-level hashes (Metalink `<pieces>`) are ignored, so a bad mirror is found only by the final whole-file hash and costs a refetch; there is no probing for the fastest mirror (each source takes an equal share of the workers); mirrors are not found automatically.

### Request origin

The origin of the task is the origin of every one of its sources. A mirror added to a page-derived task is held to the page rules (no local network, no credentials in the address, no ftp). Failover, retry, resume and restart read the origin from the task. A task from a page never fetches in pieces at all (the piece engine accepts only the person's own requests).

## Metalink (RFC 5854)

*Open Metalink…* reads a Metalink 4 file: at most 1 MB, UTF-8, no document type declaration or entities, namespace `urn:ietf:params:xml:ns:metalink`, file names refused if they start with `/`, `./`, `../` or contain `/../`, a trailing `/..` or a backslash (and only the last part is used), only `http(s)` addresses (no name or password), at most 8 sources by `priority`, only `sha-256` hashes (others are noted and ignored), `size` enforced on the finished file. Because it is a stranger's document, each file becomes a **page-derived** download (so its sources are tried one at a time) that starts like any scheduled download. Torrent links in it are ignored.

## Partial ZIP

Library ▸ **Open Archive from Address…** reads a ZIP archive's table of contents from a few small range requests (the last kilobyte, normally; the ZIP64 record and the table if present), shows the entries, and takes only the chosen ones.

* Never the whole archive: if the server ignores ranges (answers `200`), or gives no strong version tag or modification date, it says so and offers nothing; downloading the whole archive is a separate action in Add Download.
* Every request after the first carries `If-Range` and must come back with the same version tag/date; a different one stops the read (`changed`).
* Supported: ZIP and ZIP64, stored and deflated entries, UTF-8 and legacy names, folders, data descriptors. Shown but refused, each with its reason: encryption, other methods, links and special files, unsafe names (`..`, absolute, backslash, drive letters, hidden, too deep), duplicate names (also by case), a file and a folder with one name, overlapping data, positions outside the archive, entries that expand more than 200:1, entries over 8 GiB. Not supported: archives in several parts.
* Bounds: 10 000 entries, a 16 MB table, 16 levels, 1 KiB names.
* Taking is an ordinary task (`remoteZip` in the ledger): scheduled, paused, resumed (finished entries are kept and skipped), cancelled, retried; a member of a package like any other. Each entry's data is fetched with its exact range, inflated as a stream into the task's private folder with the size and CRC-32 enforced (decompression stops at the size the table declared), and only then is the whole folder moved into Downloads under the archive's name (another name if taken; an existing folder is never merged into). A failure leaves nothing visible. Path components are re-checked when written, including that no link in the staging folder leads out of it.

## Not verified

* The new sheet and inspector section were never seen running.
* Local fixtures only: no real mirror network, CDN or Metalink publisher.
* Single-source versus multi-source speed was not measured; combining is not promised to be faster.
