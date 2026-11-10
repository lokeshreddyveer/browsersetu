#!/usr/bin/env python3
"""A small, independent ISO-BMFF (MP4) reader for checking what a download really produced. It shares no code with the app: it walks the boxes of the file itself and prints JSON.

usage: mp4_probe.py <file.mp4>

{ "brands": [...], "fragmented": bool, "duration": seconds, "tracks": [
    { "id": n, "handler": "vide"|"soun"|..., "codec": "avc1", "language": "eng", "timescale": n, "duration": seconds,
      "samples": n, "start": seconds (first presentation time after the edit list), "channels": n, "width": n, "height": n } ] }
Exit status 1 and {"error": ...} if the file is not readable as MP4.
"""
import json
import struct
import sys

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"edts", b"dinf", b"mvex", b"moof", b"traf"}


def boxes(data, start, end):
    pos = start
    while pos + 8 <= end:
        size, kind = struct.unpack(">I4s", data[pos:pos + 8])
        header = 8
        if size == 1:
            if pos + 16 > end:
                return
            size = struct.unpack(">Q", data[pos + 8:pos + 16])[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header or pos + size > end:
            return
        yield kind, pos + header, pos + size
        pos += size


def find(data, start, end, path):
    kind0 = path[0].encode()
    for kind, a, b in boxes(data, start, end):
        if kind == kind0:
            if len(path) == 1:
                yield a, b
            else:
                yield from find(data, a, b, path[1:])


def lang(code):
    if code == 0:
        return None
    return "".join(chr(((code >> s) & 0x1F) + 0x60) for s in (10, 5, 0))


def probe(path):
    data = open(path, "rb").read()
    out = {"brands": [], "fragmented": False, "duration": None, "tracks": []}
    for kind, a, b in boxes(data, 0, len(data)):
        if kind == b"ftyp":
            out["brands"] = [data[a:a + 4].decode("latin1")] + [data[i:i + 4].decode("latin1") for i in range(a + 8, b, 4)]
        if kind == b"moof":
            out["fragmented"] = True
    moov = list(find(data, 0, len(data), ["moov"]))
    if not moov:
        raise ValueError("no moov box")
    ma, mb = moov[0]
    for a, b in find(data, ma, mb, ["mvhd"]):
        version = data[a]
        if version == 1:
            ts, dur = struct.unpack(">IQ", data[a + 20:a + 32])
        else:
            ts, dur = struct.unpack(">II", data[a + 12:a + 20])
        out["duration"] = dur / ts if ts else None
    if any(find(data, ma, mb, ["mvex"])):
        out["fragmented"] = True
    for ta, tb in find(data, ma, mb, ["trak"]):
        t = {}
        for a, b in find(data, ta, tb, ["tkhd"]):
            version = data[a]
            t["id"] = struct.unpack(">I", data[a + (20 if version == 1 else 12):a + (24 if version == 1 else 16)])[0]
            w, h = struct.unpack(">II", data[b - 8:b])
            t["width"], t["height"] = w >> 16, h >> 16
        media_start = 0
        for a, b in find(data, ta, tb, ["edts", "elst"]):
            version = data[a]
            count = struct.unpack(">I", data[a + 4:a + 8])[0]
            step = 20 if version == 1 else 12
            offset = a + 8
            for i in range(count):
                if version == 1:
                    seg_dur, mtime = struct.unpack(">Qq", data[offset:offset + 16])
                else:
                    seg_dur, mtime = struct.unpack(">Ii", data[offset:offset + 8])
                if mtime >= 0:
                    media_start = mtime
                    break
                offset += step
        for a, b in find(data, ta, tb, ["mdia", "mdhd"]):
            version = data[a]
            if version == 1:
                ts, dur, code = struct.unpack(">IQH", data[a + 20:a + 34])
            else:
                ts, dur, code = struct.unpack(">IIH", data[a + 12:a + 22])
            t["timescale"] = ts
            t["duration"] = dur / ts if ts else None
            t["language"] = lang(code)
            t["start"] = media_start / ts if ts else None
        for a, b in find(data, ta, tb, ["mdia", "elng"]):
            t["extended_language"] = data[a + 4:b].split(b"\0")[0].decode("latin1")
        for a, b in find(data, ta, tb, ["mdia", "hdlr"]):
            t["handler"] = data[a + 8:a + 12].decode("latin1")
        for a, b in find(data, ta, tb, ["mdia", "minf", "stbl", "stsd"]):
            t["codec"] = data[a + 12:a + 16].decode("latin1")
            if t.get("handler") == "soun":
                t["channels"] = struct.unpack(">H", data[a + 8 + 8 + 8 + 8:a + 8 + 8 + 8 + 8 + 2])[0] if b - a >= 36 else None
        for a, b in find(data, ta, tb, ["mdia", "minf", "stbl", "stts"]):
            count = struct.unpack(">I", data[a + 4:a + 8])[0]
            t["samples"] = sum(struct.unpack(">I", data[a + 8 + i * 8:a + 12 + i * 8])[0] for i in range(count))
        out["tracks"].append(t)
    return out


if __name__ == "__main__":
    try:
        print(json.dumps(probe(sys.argv[1])))
    except Exception as e:  # noqa: BLE001 - a probe reports any failure as data
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
