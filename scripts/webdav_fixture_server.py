#!/usr/bin/env python3
"""A small WebDAV test server (standard library only) for BrowserSetu's tests: OPTIONS, PROPFIND (Depth 0/1), GET/HEAD with byte ranges, optional Basic authentication.

  webdav_fixture_server.py ROOT PORT [--user alice --password s3cret] [--hostile]

--hostile: PROPFIND answers also list a resource outside the folder, one on another host, one named '..' and one with a slash in its name: a client must ignore all four.
Stops when stdin says 'quit' or closes.
"""
import argparse, base64, email.utils, os, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser(); ap.add_argument("root"); ap.add_argument("port", type=int)
ap.add_argument("--user"); ap.add_argument("--password"); ap.add_argument("--hostile", action="store_true")
args = ap.parse_args(); ROOT = os.path.realpath(args.root)

def esc(s): return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def authed(self):
        if not args.user: return True
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic ") and base64.b64decode(h[6:]).decode() == "%s:%s" % (args.user, args.password): return True
        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="fixture"'); self.send_header("Content-Length", "0"); self.end_headers(); return False
    def real(self):
        p = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        r = os.path.realpath(os.path.join(ROOT, p.lstrip("/")))
        return (p, r) if r == ROOT or r.startswith(ROOT + os.sep) else (p, None)
    def reply(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def do_OPTIONS(self):
        if not self.authed(): return
        self.reply(200, b"", {"DAV": "1, 2", "Allow": "OPTIONS, GET, HEAD, PROPFIND, PUT, DELETE"})
    def prop(self, href, path, isdir):
        st = os.stat(path); lm = email.utils.formatdate(st.st_mtime, usegmt=True)
        rt = "<D:resourcetype><D:collection/></D:resourcetype>" if isdir else "<D:resourcetype/>"
        ln = "" if isdir else "<D:getcontentlength>%d</D:getcontentlength>" % st.st_size
        return "<D:response><D:href>%s</D:href><D:propstat><D:prop>%s%s<D:getlastmodified>%s</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>" % (esc(href), rt, ln, lm)
    def do_PROPFIND(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)          # (read first: a refused request must not leave its body on the connection)
        if not self.authed(): return
        p, r = self.real()
        if r is None or not os.path.exists(r): return self.reply(404)
        depth = self.headers.get("Depth", "1")
        base = urllib.parse.quote(p if p.endswith("/") or not os.path.isdir(r) else p + "/")
        out = [self.prop(base, r, os.path.isdir(r))]
        if os.path.isdir(r) and depth != "0":
            try: names = sorted(os.listdir(r))
            except PermissionError: return self.reply(403)
            for nme in names:
                c = os.path.join(r, nme); d = os.path.isdir(c)
                out.append(self.prop(base + urllib.parse.quote(nme) + ("/" if d else ""), c, d))
            if args.hostile:
                f = os.path.join(r, names[0]) if names else r
                out.append(self.prop("/outside/secret.txt", f, False))
                out.append(self.prop("http://evil.example/x.txt", f, False))
                out.append(self.prop(base + "..", f, False))
                out.append(self.prop(base + "a%2Fb", f, False))
        body = ('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">%s</D:multistatus>' % "".join(out)).encode()
        self.reply(207, body, {"Content-Type": "application/xml; charset=utf-8"})
    def do_GET(self):
        if not self.authed(): return
        p, r = self.real()
        if r is None or not os.path.isfile(r): return self.reply(404)
        size = os.path.getsize(r); rng = self.headers.get("Range"); start, end, code = 0, size - 1, 200
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-"); start = int(a or 0); end = int(b) if b else size - 1; code = 206
        with open(r, "rb") as fh: fh.seek(start); data = fh.read(end - start + 1)
        h = {"Accept-Ranges": "bytes", "Content-Type": "application/octet-stream", "ETag": '"%x-%x"' % (int(os.path.getmtime(r)), size)}
        if code == 206: h["Content-Range"] = "bytes %d-%d/%d" % (start, end, size)
        self.reply(code, data, h)
    def do_PUT(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        if not self.authed(): return
        p, r = self.real()
        if r is None or os.path.isdir(r): return self.reply(403)
        if self.headers.get("If-None-Match") == "*" and os.path.exists(r): return self.reply(412)
        existed = os.path.exists(r)
        with open(r, "wb") as fh: fh.write(body)
        self.reply(204 if existed else 201)
    def do_DELETE(self):
        if not self.authed(): return
        p, r = self.real()
        if r is None or r == ROOT or not os.path.exists(r): return self.reply(404)
        import shutil
        if os.path.isdir(r) and not os.path.islink(r): shutil.rmtree(r)
        else: os.remove(r)
        self.reply(204)
    do_HEAD = do_GET

srv = ThreadingHTTPServer(("127.0.0.1", args.port), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
print("ready", flush=True)
for line in sys.stdin:
    if line.strip() == "quit": break
