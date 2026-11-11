# Looking at and changing local media (Phase 21)

A finished download that is audio or video gets a **Media** section in the details panel: a picture, what the file is, **Preview**, and **Convert…**. Everything here is local. Nothing is fetched, nothing gets network access, and the original file is never changed: a result is always a new file beside it.

Three different things are kept apart, and the result says which one happened:

| | What it does | Called lossless? |
|---|---|---|
| **Preview** | Plays or shows the file as it is | n/a |
| **Remux** (change container) | Puts the same encoded tracks in another container. No decoding | Only after the output was read back and its codecs matched the source's |
| **Convert / exact trim / WAV** | Decodes and encodes again | Never |

A request the system cannot do is **refused with the reason**; it is never quietly done another way. No FFmpeg or other library is bundled: everything uses AVFoundation, Quick Look and the system's own encoders. (The separate, optional ffmpeg download is described in `docs/decisions/0001-media-tools-optional-downloads.md`.)

## Preview

* Audio and video: the system player (`AVPlayerView` through `VideoPlayer`), with the file's own audio and subtitle choices.
* Pictures and documents (text, PDF, office and data files): Quick Look.
* The **contents** decide, not the name. A file saved as `movie.bin` that is really an MP4 is played (the system picks its reader by extension, so it is given a link with the right extension in a private temporary folder; the file is not renamed or copied). A file called `.mp4` that is not media is refused.
* Never previewed: programs, app bundles, scripts, disk images, archives, links, and anything outside the downloads folder (links followed).
* A download that is **still arriving** is not previewed (see below).

### Partial previews (not wired to live downloads)

`PartialPreview.evaluate` says whether a half-written file could be looked at: MP4 or QuickTime only, its index (`moov`) before the picture data and wholly inside the part that is certainly written, that part a **continuous run from the start**, and the file not being put in place. What is shown would be a read-only copy of that part, never the file being written. The rule and the copy are tested (a frame decodes from a 60 % copy). But no download engine states how much of the start of a file is certainly written (multipart fills pieces out of order), so the details panel does not offer it and says why.

## What is read from a file

Container (from the first bytes), length, and per track: codec (named), language, bitrate, picture size, frame rate, turn (0 is "not stated"), colour, channels, sample rate, whether the system can decode it, plus title and creation date. A value the file does not state is shown as missing, never as 0. Reading is bounded (20 seconds, 64 tracks), cancellable, and off the main thread.

## Thumbnails

One frame (a tenth of the way in by default, or a chosen time), turned upright from the track's own transform, scaled to fit a bounded square (at most 1024), two at a time. Kept only in memory (64 pictures), keyed by path, size, modification time, time and size, so an edited file asks again. **Never kept for a private download.** Malformed, silent or unsupported files give an error, not a crash.

## Operations

| Operation | Targets | How | Notes |
|---|---|---|---|
| Change container | MP4, MOV, M4V (video); M4A (audio-only file) | passthrough export | Refused when a codec cannot live in the target (e.g. ProRes or PCM in MP4, MP3 in M4A). Subtitle and data tracks are not carried; the result says how many were left out |
| Convert video | H.264 or HEVC in MP4/MOV/M4V; same size, 1080p, 720p, 480p | system export presets | Never enlarges. HEVC only at the same size or 1080p (the system has no lower HEVC setting) and only where the system offers it. AV1 and VP9 are not offered |
| Extract audio | M4A, WAV | AAC/ALAC are **copied** into M4A; other audio is encoded to AAC; WAV is decoded to 16-bit PCM | Pick the track by language. **MP3 is not offered** (the system has no MP3 encoder) |
| Trim | MP4, MOV, M4V, M4A | **Fast**: passthrough. **Exact**: encodes again | Start and end must be valid and at least 0.1 s apart; an end past the file's end is cut to the end. Works on files whose timeline does not start at zero |
| Subtitles | WebVTT | embedded `tx3g` / QuickText tracks, or an SRT/VTT file | See below |

### Trimming accuracy

A **fast** trim copies the encoded video, so it can only start on a keyframe: it may begin **earlier** than asked (never later), by up to one keyframe interval, and is never shorter than asked. An **exact** trim decodes and encodes again and starts where asked, to within a frame. Neither is claimed frame-accurate beyond what the tests measured.

### Subtitles

* SRT and WebVTT in, WebVTT out. UTF-8 (with or without a byte-order mark) and UTF-16 with a mark; anything else is refused rather than guessed. 8 MB and 100 000 cues at most.
* Times are kept to the millisecond; an optional offset moves every cue (never before zero).
* Markup is reduced to the tags WebVTT defines (`b i u c v lang ruby rt`); every other tag (`script`, `font`), SSA overrides (`{\an8}`) and `-->` inside text are removed, and a stray `<` or `&` becomes an entity. Nothing is executed or rendered.
* Embedded: plain timed text (`tx3g`, QuickText) only. Picture-based subtitles (DVD, Blu-ray), closed captions and `wvtt` are listed and refused with the reason. No translation or transcription.
* The file is named `<video>.<language>.vtt`; an odd language tag is dropped, never used in a path.

## Jobs

A local job is not a download and has its own small list (in the details panel): **waiting → checking → ready → working → done**, or **failed**, **cancelled**, **needs a restart**. Up to two run at once; each is independent, and a failing file in a batch does not stop the others.

* An export cannot be paused or resumed, so there is no pause. **Cancel** stops it, deletes its half-written file and leaves the source alone. **Try Again** starts from the beginning.
* Each job works in `.Browser Setu Media Processing/<profile>/<job id>/` and writes a small `job.json` (operation and two paths; nothing secret). After a crash the folder is found at launch, its output is deleted, and the job is listed as **needs a restart**; it is started again only if the person asks. Private jobs work in the system's temporary folder, keep no journal, and are forgotten with the session.
* The source and the destination folder must be inside the downloads folder (links followed), checked again when the result is put in place. A symlink that leads out is refused.
* The result is **read back before it is kept**: it must have the tracks asked for, the codecs expected, a length close to the expected one, a picture that decodes and sound that decodes. A result that fails the check is deleted.
* A free name is reserved atomically and the checked file moved onto it, so two jobs never choose the same name and an existing file is never replaced (`name remuxed (1).mov`). The quarantine mark of the source is copied to the result. The `FinalizationGate` makes cancel-versus-finish a single decision.
* Disk space is checked before work starts.
* Only folders this service made are ever deleted.

## Not supported, and said so

MKV/WebM/AVI/Ogg/FLAC (the system cannot open them; nothing is converted unless asked, and it cannot be); protected media; AV1/VP9 output; MP3 output; subtitle burn-in; partial previews of live downloads; multi-file batch controls in the UI beyond submitting the same operation to several files (the engine supports it; there is no batch picker yet).

## Tests

`Tests/Phase21MediaProcessingTests.swift`: original files made with `AVAssetWriter` (H.264/HEVC video whose brightness rises with time, AAC tone, QuickText subtitles, rotated, two-language and non-zero-origin files). Outputs are checked by reading them again.
