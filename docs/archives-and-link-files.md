# Archives and link files (Phase 25)

## Archives

**Downloads details ▸ Browse Archive…** for a finished ZIP, TAR, TGZ or TAR.GZ.

| Format | Listing | Extraction | Notes |
|---|---|---|---|
| ZIP, ZIP64 | yes (table of contents only) | yes (stored, deflate; size and CRC-32 checked) | comments up to 65 535 bytes; entries ≤ 10 000 |
| TAR (ustar, GNU long names, pax paths) | yes | yes | regular files and folders only |
| TAR.GZ / TGZ | yes (read through, nothing written) | yes (gzip CRC and length checked at the end) | a lone `.gz` is not an archive |
| 7z, RAR, bzip2, xz | named, refused with the reason | no | no vetted, licensed decoder is bundled and none was written |
| Password-protected ZIP entries | shown, marked | no | there is no decoder to give a password to; no password is ever asked for or tried |
| Archives in several parts | no | no | |

Format is decided from the first bytes, never from the name.

### Safety

Listing writes nothing. Extraction writes into a hidden folder of its own inside the destination; the finished folder is put in place under a free name (`name`, `name 2`, …) with an exclusive rename, so nothing is merged into or replaced, and the archive is never changed or deleted. Refused or skipped, with the reason shown: absolute paths, `..`, backslashes, drive letters, control characters, deeper than 16 levels, names that the file system treats as one (case and Unicode spelling), a file that shares a name with a folder, symbolic and hard links, device and pipe files, overlapping or inconsistent ZIP entries, entries over 2 GiB, totals over 4 GiB, a tar.gz that expands more than 1000× past 64 MiB. An archive with an unsafe name is not opened whole; its safe entries can still be chosen. Everything is checked before the folder appears; any failure or cancel removes the working folder and nothing else. The destination must be inside the downloads folder (links followed). The quarantine mark is copied to what is taken out. Disk space is checked first.

Several archives can be opened at once (`ArchiveBatch`): each succeeds or fails on its own with its own message. There is no separate package scheduler; a package's completed archives are passed to the same function.

## Link files

**LinkGrabber ▸ Import Link File…** reads a plain text list, an M3U list of ordinary links, or a Metalink 4 document (the first address of each file; other sources are noted, and *Open Metalink* is how its checksum and sources are used). The addresses are **collected for review** like links found on a page (classified, de-duplicated, checked when added); nothing starts and they are never treated as links you typed. Limits: 2 MB, 5 000 links, text only. A stream playlist is not a list of links and is said so.

**DLC, RSDF and CCF are not supported.** They are encrypted or obfuscated with keys and services owned by the tool that makes them, and no authorised specification is used here. A file ending in one of those names is reported unsupported without being read; nothing is guessed from the extension.

## Not verified

The archive sheet and the import button have never been seen running. Interoperability is with archives made by the tests' own writers, not with archives from other tools (Info-ZIP, 7-Zip, GNU tar, bsdtar).
