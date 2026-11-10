#!/usr/bin/env python3
"""A local HTTP server for the download engine's tests. Binds 127.0.0.1 on the port given as the first argument (or a free one) and prints "PORT <n>" once it is listening.
The Mac scheme starts it before the tests on port 18766 (see project.yml), as it does scripts/testserver.py on 18765.

Content is deterministic (byte i of a file is (i * 31 + 7) % 251), so a test can compute what it should have received.

Routes
  /file/<size>            ordinary file: HEAD, GET, byte ranges, strong ETag, Last-Modified, If-Range. ?cd=<Content-Disposition header value>
  /nores/<size>           no ranges, no validators (cannot be resumed)
  /nolength/<size>        chunked, no Content-Length
  /nohead/<size>          HEAD answers 405; GET works
  /slownores/<size>       slow, with no ranges or validators
  /slow/<size>            ranges and ETag, sent in 32 KB pieces with a pause between (?ms=<pause>)
  /flaky/<size>?cut=<n>   the first GET sends the full Content-Length but drops after n bytes; later ones are normal
  /wrongsize/<size>       promises <size> bytes, sends fewer, and closes
  /hang                   sends headers and then nothing
  /empty                  200 with no body and no length
  /redirect/<hops>/<size> a chain of 302s ending at /file/<size>
  /redirect-loop          a -> b -> a
  /redirect-to?url=<u>    302 to any address
  /status/<code>          that status (?ra=<Retry-After value>)
  /_log, /_reset, /_bump  the request log (JSON), clear it, change the ETag version
  PUT /_media/<path>      stores a file (the Phase 17 tests upload original media they generate)
  /media/<path>           serves a stored file with byte ranges. ?need_auth=<value>: 401 unless the Authorization header equals it (the header values seen are listed under "auth" in /_media_hits). ?fail=<n>: the first n requests for it answer 503. ?status=<code>: that status. ?redirect=<url>: 302.
  /_media_reset           forgets every stored file
  (media Range faults, for tests: ?ignore_range, ?no_content_range, ?shift=<n>, ?wrong_unit, ?truncate)
  /_media_hits            JSON: how often each stored file was asked for, and the headers of its last request
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

STATE = {"media_bytes": {}, "fault": {}, "media": {}, "media_hits": {}, "media_headers": {}, "media_auth": {}, "etag_version": 1, "log": [], "flaky_seen": set(), "active": 0, "peak": 0, "changing_hits": 0, "trunc_seen": set(), "bytes_sent": 0, "busy_hits": 0}
LOCK = threading.Lock()
MODIFIED = "Wed, 21 Oct 2015 07:28:00 GMT"


def content(start, end):
    return bytes(((i * 31 + 7) % 251) for i in range(start, end))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # -- helpers ---------------------------------------------------------
    def etag(self, size):
        return '"v%d-%d"' % (STATE["etag_version"], size)

    def record(self):
        with LOCK:
            STATE["log"].append({"method": self.command, "path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "host": self.headers.get("Host", "")})

    def send_text(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def parse_range(self, size):
        header = self.headers.get("Range")
        if not header or not header.startswith("bytes="):
            return None
        spec = header[6:].split(",")[0].strip()
        a, _, b = spec.partition("-")
        try:
            if a == "":
                n = int(b)
                return max(0, size - n), size - 1
            start = int(a)
            end = int(b) if b else size - 1
            return start, min(end, size - 1)
        except ValueError:
            return None

    def serve_file(self, size, ranges=True, validators=True, pause_ms=0, cut=None, short=None, chunked=False, bps=0, latency_ms=0, mode="", etag_override=None):
        query = parse_qs(urlparse(self.path).query)
        headers = {"Content-Type": "application/octet-stream"}
        if latency_ms:
            time.sleep(latency_ms / 1000.0)
        if ranges:
            headers["Accept-Ranges"] = "bytes"
        if validators:
            headers["ETag"] = etag_override or self.etag(size)
            headers["Last-Modified"] = MODIFIED
        if mode == "encoded" and self.headers.get("Range"):
            headers["Content-Encoding"] = "gzip"
        if "cd" in query:
            headers["Content-Disposition"] = query["cd"][0]
        start, end, status = 0, size - 1, 200
        rng = self.parse_range(size) if ranges and mode != "ignore" else None
        if_range = self.headers.get("If-Range")
        if rng and if_range and validators and if_range != (etag_override or self.etag(size)):
            rng = None
        if mode == "busy" and rng and rng[0] > 0:
            with LOCK:
                STATE["busy_hits"] += 1
                busy = STATE["busy_hits"] <= 3
            if busy:
                self.send_text(503, b"busy", {"Retry-After": "0"})
                return
        if mode == "range416" and rng and rng[0] > 0:
            self.send_text(416, b"", {"Content-Range": "bytes */%d" % size})
            return
        if rng:
            start, end = rng
            if start >= size or start > end:
                self.send_text(416, b"", {"Content-Range": "bytes */%d" % size})
                return
            status = 206
            shown_start, shown_total = start, size
            if mode == "wrongstart" and start > 0:
                shown_start = max(0, start - 1)
            if mode == "wrongtotal" and start > 0:
                shown_total = size + 1
            headers["Content-Range"] = "bytes %d-%d/%d" % (shown_start, end, shown_total)
        length = end - start + 1
        if mode == "longer" and status == 206 and start > 0:
            length += 5
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(length))
        self.end_headers()
        if self.command == "HEAD":
            return
        if mode == "trunc" and status == 206 and start > 0:
            key = (self.path, start)
            with LOCK:
                first = key not in STATE["trunc_seen"]
                STATE["trunc_seen"].add(key)
            if first:
                cut = (end - start + 1) // 2
        limit = length if cut is None else min(cut, length)
        if short is not None:
            limit = min(limit, length - short)
        sent = 0
        piece = 16384 if bps else 32768
        with LOCK:
            STATE["active"] += 1
            STATE["peak"] = max(STATE["peak"], STATE["active"])
        try:
            while sent < limit:
                n = min(piece, limit - sent)
                body = content(start + sent, start + sent + n)
                if chunked:
                    self.wfile.write(b"%x\r\n" % len(body) + body + b"\r\n")
                else:
                    self.wfile.write(body)
                self.wfile.flush()
                sent += n
                with LOCK:
                    STATE["bytes_sent"] += n
                if pause_ms:
                    time.sleep(pause_ms / 1000.0)
                if bps:
                    time.sleep(n / float(bps))
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            return
        finally:
            with LOCK:
                STATE["active"] -= 1
        if limit < length:
            self.close_connection = True

    # -- routing ---------------------------------------------------------
    def route(self):
        self.record()
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        query = parse_qs(url.query)
        if not parts:
            return self.send_text(200, b"fixture")
        # A TikTok-Data-Portability-shaped API for the DX-09 tests: POST /tt/v2/user/data/{add,check,download}/ with a bearer token. The state is set with PUT /_tt/<pending|downloading|expired|cancelled|noscope|jsonerror|badzip>.
        if parts[0] == "_tt" and len(parts) == 2:
            with LOCK:
                STATE["tt_mode"] = parts[1]
            return self.send_text(200, b"ok")
        if parts[0] == "tt":
            length = int(self.headers.get("Content-Length", "0") or 0)
            body = self.rfile.read(length) if length else b""
            with LOCK:
                mode = STATE.get("tt_mode", "pending")
                STATE.setdefault("tt_log", []).append({"path": self.path, "auth": self.headers.get("Authorization", ""), "body": body.decode("utf-8", "replace")})
            if self.command != "POST":
                return self.send_text(405, b"POST only")
            if not self.headers.get("Authorization", "").startswith("Bearer "):
                return self.send_text(401, json.dumps({"error": {"code": "access_token_invalid"}}).encode(), {"Content-Type": "application/json"})
            if mode == "noscope":
                return self.send_text(403, json.dumps({"error": {"code": "scope_not_authorized"}}).encode(), {"Content-Type": "application/json"})
            kind = parts[-1]
            if kind == "add":
                return self.send_text(200, json.dumps({"data": {"request_id": 123451234512345}, "error": {"code": "ok", "message": "", "log_id": "x"}}).encode(), {"Content-Type": "application/json"})
            if kind == "check":
                status = mode if mode in ("pending", "downloading", "expired", "cancelled") else "downloading"
                return self.send_text(200, json.dumps({"data": {"request_id": 123451234512345, "status": status, "data_format": "json", "category_selection_list": ["profile"]}, "error": {"code": "ok"}}).encode(), {"Content-Type": "application/json"})
            if kind == "download":
                if mode == "jsonerror":
                    return self.send_text(400, json.dumps({"data": {}, "error": {"code": "invalid_params", "message": "Incorrect request_id"}}).encode(), {"Content-Type": "application/json"})
                if mode == "jsonok":
                    return self.send_text(200, json.dumps({"data": {}, "error": {"code": "ok"}}).encode(), {"Content-Type": "application/json"})
                if mode == "badzip":
                    return self.send_text(200, b"this is not a zip archive at all" * 50, {"Content-Type": "application/octet-stream"})
                import io, zipfile
                buf = io.BytesIO()
                with zipfile.ZipFile(buf, "w") as z:
                    z.writestr("Activity/Video Browsing History.txt", "one\ntwo\n")
                    z.writestr("Profile And Settings/Profile Info.txt", "name: test\n")
                return self.send_text(200, buf.getvalue(), {"Content-Type": "application/octet-stream"})
            return self.send_text(404, b"nothing")
        if parts[0] == "_media" and self.command in ("PUT", "POST"):
            length = int(self.headers.get("Content-Length", "0") or 0)
            body = self.rfile.read(length) if length else b""
            with LOCK:
                STATE["media"]["/".join(parts[1:])] = body
            return self.send_text(200, b"stored")
        if parts[0] == "_media_fault" and len(parts) == 3:
            with LOCK:
                STATE["fault"][parts[1]] = int(parts[2])
            return self.send_text(200, b"ok")
        if parts[0] == "_media_reset":
            with LOCK:
                STATE["fault"].clear()
                STATE["media"].clear(); STATE["media_hits"].clear(); STATE["media_headers"].clear(); STATE["media_auth"].clear(); STATE["media_bytes"].clear()
            return self.send_text(200, b"ok")
        if parts[0] == "_media_hits":
            with LOCK:
                return self.send_text(200, json.dumps({"hits": STATE["media_hits"], "headers": STATE["media_headers"], "auth": STATE["media_auth"], "bytes": STATE["media_bytes"]}).encode(), {"Content-Type": "application/json"})
        if parts == ["robots.txt"]:
            with LOCK:
                robots = STATE["media"].get("robots.txt")
                STATE["media_hits"]["robots.txt"] = STATE["media_hits"].get("robots.txt", 0) + 1
            if "robots" in STATE.get("fault", {}):
                return self.send_text(STATE["fault"]["robots"], b"x")
            if robots is None:
                return self.send_text(404, b"nothing")
            return self.send_text(200, robots, {"Content-Type": "text/plain"})
        if parts[0] == "media":
            key = "/".join(parts[1:])
            with LOCK:
                STATE["media_headers"][key] = {k.lower(): v for k, v in self.headers.items()}
                STATE["media_auth"].setdefault(key, []).append(self.headers.get("Authorization", ""))
                data = STATE["media"].get(key)
                hits = STATE["media_hits"].get(key, 0)
                STATE["media_hits"][key] = hits + 1
            if "need_auth" in query and self.headers.get("Authorization", "") != query["need_auth"][0]:
                return self.send_text(401, b"sign in", {"WWW-Authenticate": 'Bearer realm="fixture"'})
            if "status" in query:
                return self.send_text(int(query["status"][0]), b"status")
            if "redirect" in query:
                return self.send_text(302, b"", {"Location": query["redirect"][0]})
            if data is None:
                return self.send_text(404, b"nothing")
            if "fail" in query and hits < int(query["fail"][0]):
                return self.send_text(503, b"later")
            if "ok_first" in query and hits >= int(query["ok_first"][0]):
                return self.send_text(503, b"later")
            import hashlib
            validators = {}
            if "no_validators" not in query:
                etag = '"%s"' % hashlib.md5(data).hexdigest()[:16]
                if "etag" in query: etag = query["etag"][0]
                if "flip" in query: etag = '"flip-%d"' % hits
                if "weak" in query: etag = "W/" + etag
                validators = {"ETag": etag, "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"}
                if "weak" in query or "flip" in query: validators["Last-Modified"] = "Wed, 21 Oct 2015 07:28:%02d GMT" % (hits % 60) if "flip" in query else validators["Last-Modified"]
            def counted(body):
                if self.command == "HEAD":
                    return body          # a HEAD answer sends no body: nothing is served
                with LOCK:
                    STATE["media_bytes"][key] = STATE["media_bytes"].get(key, 0) + len(body)
                return body
            ctype = {"m3u8": "application/vnd.apple.mpegurl", "mpd": "application/dash+xml", "mp4": "video/mp4", "m4s": "video/iso.segment", "ts": "video/mp2t", "vtt": "text/vtt", "html": "text/html", "htm": "text/html", "txt": "text/plain", "pdf": "application/pdf", "zip": "application/zip"}.get(key.rsplit(".", 1)[-1], "application/octet-stream")
            # A conditional GET (RFC 9110 13.1): the same validator as last time gets "304 Not Modified" and no body.
            inm = self.headers.get("If-None-Match"); ims = self.headers.get("If-Modified-Since")
            if validators and not self.headers.get("Range") and "no_304" not in query and ((inm and inm.replace("W/", "") == validators["ETag"].replace("W/", "")) or (not inm and ims and ims == validators["Last-Modified"])):
                return self.send_text(304, b"", validators)
            rng = self.headers.get("Range")
            if "ignore_range" in query:
                rng = None
            if rng and rng.startswith("bytes="):
                a, _, b = rng[6:].partition("-")
                start = int(a) if a else 0
                end = int(b) if b else len(data) - 1
                end = min(end, len(data) - 1)
                if start > end or start >= len(data):
                    return self.send_text(416, b"", {"Content-Range": "bytes */%d" % len(data)})
                body = data[start:end + 1]
                headers = {"Content-Type": ctype, "Content-Range": "bytes %d-%d/%d" % (start, end, len(data)), "Accept-Ranges": "bytes"}
                headers.update(validators)
                if "no_content_range" in query:
                    del headers["Content-Range"]
                if "shift" in query:
                    n = int(query["shift"][0])
                    headers["Content-Range"] = "bytes %d-%d/%d" % (start + n, end + n, len(data) + abs(n))
                if "wrong_unit" in query:
                    headers["Content-Range"] = "items %d-%d/%d" % (start, end, len(data))
                if "truncate" in query:
                    body = body[:-1]
                return self.send_text(206, counted(body), headers)
            return self.send_text(200, counted(data), dict({"Content-Type": ctype, "Accept-Ranges": "bytes"}, **validators))
        head = parts[0]
        if head == "_log":
            with LOCK:
                return self.send_text(200, json.dumps(STATE["log"]).encode(), {"Content-Type": "application/json"})
        if head == "_reset":
            with LOCK:
                STATE["log"].clear()
                STATE["flaky_seen"].clear()
                STATE["trunc_seen"].clear()
                STATE["changing_hits"] = 0
                STATE["busy_hits"] = 0
                STATE["peak"] = 0
                STATE["bytes_sent"] = 0
            return self.send_text(200, b"ok")
        if head == "_bump":
            with LOCK:
                STATE["etag_version"] += 1
            return self.send_text(200, b"ok")
        if head == "file":
            return self.serve_file(int(parts[1]))
        if head == "nores":
            return self.serve_file(int(parts[1]), ranges=False, validators=False)
        if head == "nolength":
            return self.serve_file(int(parts[1]), ranges=False, validators=False, chunked=True)
        if head == "nohead-norange":
            if self.command == "HEAD":
                return self.send_text(405, b"", {"Allow": "GET"})
            return self.serve_file(int(parts[1]), ranges=False, validators=False, pause_ms=20)
        if head == "nohead":
            if self.command == "HEAD":
                return self.send_text(405, b"", {"Allow": "GET"})
            return self.serve_file(int(parts[1]))
        if head in ("throttle", "ignorerange", "wrongstart", "wrongtotal", "longer", "encoded", "trunc", "range416", "latency", "changing", "busy"):
            size = int(parts[1])
            kw = {}
            if head == "throttle":
                kw["bps"] = int(query.get("bps", ["1000000"])[0])
            elif head == "latency":
                kw["latency_ms"] = int(query.get("ms", ["100"])[0])
                kw["bps"] = int(query.get("bps", ["0"])[0])
            elif head == "ignorerange":
                kw["mode"] = "ignore"
            elif head == "changing":
                # the version tag changes after the first N ranged requests: the file "changes" part-way through a download
                after = int(query.get("after", ["3"])[0])
                with LOCK:
                    STATE["changing_hits"] += 1
                    hits = STATE["changing_hits"]
                kw["etag_override"] = '"changing-%d"' % (0 if hits <= after else 1)
                kw["pause_ms"] = 5
            else:
                kw["mode"] = head
            if "bps" in query and head != "throttle":
                kw["bps"] = int(query["bps"][0])
            return self.serve_file(size, **kw)
        if head == "_peak":
            with LOCK:
                return self.send_text(200, json.dumps({"peak": STATE["peak"], "active": STATE["active"], "bytes_sent": STATE["bytes_sent"]}).encode(), {"Content-Type": "application/json"})
        if head == "slownores":
            return self.serve_file(int(parts[1]), ranges=False, validators=False, pause_ms=int(query.get("ms", ["20"])[0]))
        if head == "slow":
            return self.serve_file(int(parts[1]), pause_ms=int(query.get("ms", ["20"])[0]))
        if head == "flaky":
            size = int(parts[1])
            key = url.path
            with LOCK:
                first = key not in STATE["flaky_seen"] and self.command == "GET" and "range" not in {k.lower() for k in self.headers.keys()}
                if first:
                    STATE["flaky_seen"].add(key)
            cut = int(query.get("cut", ["10000"])[0]) if first else None
            return self.serve_file(size, cut=cut)
        if head == "wrongsize":
            return self.serve_file(int(parts[1]), short=10, ranges=False, validators=False)
        if head == "hang":
            self.send_response(200)
            self.send_header("Content-Length", "1000000")
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            self.wfile.flush()
            time.sleep(30)
            return
        if head == "empty":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"0\r\n\r\n")
            return
        if head == "redirect":
            hops, size = int(parts[1]), int(parts[2])
            target = "/file/%d" % size if hops <= 1 else "/redirect/%d/%d" % (hops - 1, size)
            return self.send_text(302, b"", {"Location": target})
        if head == "redirect-loop":
            other = "/redirect-loop-b" if parts[0] == "redirect-loop" else "/redirect-loop"
            return self.send_text(302, b"", {"Location": other})
        if head == "redirect-loop-b":
            return self.send_text(302, b"", {"Location": "/redirect-loop"})
        if head == "redirect-to":
            return self.send_text(302, b"", {"Location": query["url"][0]})
        if head == "status":
            code = int(parts[1])
            extra = {"Retry-After": query["ra"][0]} if "ra" in query else {}
            return self.send_text(code, b"status %d" % code, extra)
        return self.send_text(404, b"nothing")

    do_GET = route
    do_HEAD = route
    do_PUT = route
    do_POST = route


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    print("PORT %d" % server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
