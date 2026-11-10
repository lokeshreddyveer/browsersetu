#!/usr/bin/env python3
"""DX-07 fixture: a small website for the media-discovery tests, written from the HTML and HLS/DASH specifications and independent of the app's code.
Two origins on one process: SITE on the first port argument (default 18840) and EMBED on the second (default 18841); the tests reach them as http://127.0.0.1:<site> and http://localhost:<embed>,
so a frame from one is cross-origin to the other. Media is a real MP4 (Tests/Fixtures/video/clip.mp4) and a short generated AAC clip; nothing is copied from any website.

Pages (SITE unless noted):  /static  /audio  /multi  /dynamic  /changing  /spa  /iframe-same  /iframe-cross  /nested  /sandbox  /removed  /expiring  /hls  /dash  /blob  /lazy
EMBED serves /player (a page with one video) and /nested-inner (a page with an iframe to /player on the same origin).
Media: /media/clip.mp4  /media/clip2.mp4 (same bytes, a different address)  /media/talk.m4a  /media/clip.vtt  /hls/master.m3u8  /hls/v720.m3u8  /dash/manifest.mpd
/expiring-media?exp=<epoch>: 200 with the clip while exp is in the future, 403 after.   /_log  /_reset
"""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "..", "apps", "apple", "Tests", "Fixtures", "video")
SITE = int(sys.argv[1]) if len(sys.argv) > 1 else 18840
EMBED = int(sys.argv[2]) if len(sys.argv) > 2 else 18841
AUDIO = os.path.join(os.environ.get("TMPDIR", "/tmp"), "bsetu-talk.m4a")
LOG = []; LOCK = threading.Lock()

def clip(): return open(os.path.join(FIX, "clip.mp4"), "rb").read()
def audio():
    if not os.path.exists(AUDIO): os.system('say -o "%s" --data-format=aac "Media discovery fixture" >/dev/null 2>&1' % AUDIO)
    return open(AUDIO, "rb").read() if os.path.exists(AUDIO) else b""

def page(body, head=""): return ("<!doctype html><html><head><meta charset=utf-8><title>fixture</title>%s</head><body>%s</body></html>" % (head, body)).encode()
V = '<video id="%s" src="%s" muted preload="auto" controls width="320"></video>'
EMBED_ORIGIN = lambda: "http://localhost:%d" % EMBED

SITE_PAGES = {
 "/static": lambda q: page('<video id=v src="/media/clip.mp4" muted preload="auto" controls width="320"><track kind=subtitles src="/media/clip.vtt" srclang=te label=Telugu></video>'),
 "/audio": lambda q: page('<audio id=a src="/media/talk.m4a" preload=auto controls></audio>'),
 "/multi": lambda q: page(V % ("v1", "/media/clip.mp4") + V % ("v2", "/media/clip.mp4") + V % ("v3", "/media/clip2.mp4") + '<audio id=a src="/media/talk.m4a" preload=auto></audio>'),
 "/dynamic": lambda q: page('<div id=host></div><script>setTimeout(function(){var v=document.createElement("video");v.id="late";v.muted=true;v.preload="auto";v.src="/media/clip.mp4";document.getElementById("host").appendChild(v);},300);</script>'),
 "/changing": lambda q: page(V % ("v", "/media/clip.mp4") + '<script>setTimeout(function(){document.getElementById("v").src="/media/clip2.mp4";},900);</script>'),
 "/spa": lambda q: page('<div id=host>' + V % ("v", "/media/clip.mp4") + '</div><script>setTimeout(function(){history.pushState({}, "", "/spa/next");var h=document.getElementById("host");h.innerHTML="";var v=document.createElement("video");v.id="v";v.muted=true;v.preload="auto";v.src="/media/clip2.mp4";h.appendChild(v);},900);</script>'),
 "/iframe-same": lambda q: page('<iframe src="/static" width=400 height=300></iframe>'),
 "/iframe-cross": lambda q: page('<iframe src="%s/player" width=400 height=300></iframe>' % EMBED_ORIGIN()),
 "/nested": lambda q: page('<iframe src="%s/nested-inner" width=400 height=300></iframe>' % EMBED_ORIGIN()),
 "/sandbox": lambda q: page('<iframe sandbox src="%s/player" width=400 height=300></iframe>' % EMBED_ORIGIN()),
 "/removed": lambda q: page('<div id=host>' + V % ("v", "/media/clip.mp4") + '</div><script>setTimeout(function(){document.getElementById("host").innerHTML="";},3500);</script>'),
 "/expiring": lambda q: page(V % ("v", "/expiring-media?exp=%s&sig=SECRETSIG" % q.get("exp", ["4000000000"])[0])),
 "/hls": lambda q: page('<video id=v src="/hls/master.m3u8" muted controls></video><script>var x=new XMLHttpRequest();x.open("GET","/hls/v720.m3u8");x.send();fetch("/dash/manifest.mpd");</script>'),
 "/dash": lambda q: page('<video id=v muted></video><script>fetch("/dash/manifest.mpd").then(function(r){return r.text();});</script>'),
 "/blob": lambda q: page('<video id=v muted preload=auto></video><script>fetch("/media/clip.mp4").then(function(r){return r.blob();}).then(function(b){document.getElementById("v").src=URL.createObjectURL(b);});</script>'),
 "/lazy": lambda q: page('<video id=v muted preload=none controls><source src="/media/clip.mp4" type="video/mp4"><source src="/media/clip.webm" type="video/webm"></video>'),
}
EMBED_PAGES = {
 "/player": lambda q: page(V % ("ev", "/media/clip.mp4")),
 "/nested-inner": lambda q: page('<iframe src="/player" width=360 height=260></iframe>'),
}
HLS_MASTER = b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nv360.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720\nv720.m3u8\n"
HLS_MEDIA = b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
MPD = b'<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S" minBufferTime="PT2S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="800000" width="640" height="360" codecs="avc1.42c01e"><BaseURL>/media/clip.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>'

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, body, ctype, extra=None):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def ranged(self, data, ctype):
        r = self.headers.get("Range")
        if r and r.startswith("bytes="):
            a, _, b = r[6:].partition("-"); a = int(a or 0); b = int(b) if b else len(data) - 1; b = min(b, len(data) - 1)
            if a > b: return self.send(416, b"", ctype, {"Content-Range": "bytes */%d" % len(data)})
            return self.send(206, data[a:b + 1], ctype, {"Content-Range": "bytes %d-%d/%d" % (a, b, len(data)), "Accept-Ranges": "bytes"})
        self.send(200, data, ctype, {"Accept-Ranges": "bytes"})
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query); port = self.server.server_address[1]
        with LOCK: LOG.append({"port": port, "path": u.path, "t": time.time()})
        if u.path == "/_log": return self.send(200, json.dumps(LOG).encode(), "application/json")
        if u.path == "/_reset": LOG.clear(); return self.send(200, b"ok", "text/plain")
        pages = SITE_PAGES if port == SITE else EMBED_PAGES
        if u.path in pages: return self.send(200, pages[u.path](q), "text/html; charset=utf-8")
        if u.path.startswith("/spa/"): return self.send(200, SITE_PAGES["/spa"](q), "text/html; charset=utf-8")
        if u.path in ("/media/clip.mp4", "/media/clip2.mp4"): return self.ranged(clip(), "video/mp4")
        if u.path == "/media/talk.m4a": return self.ranged(audio(), "audio/mp4")
        if u.path == "/media/clip.vtt": return self.send(200, open(os.path.join(FIX, "clip.vtt"), "rb").read(), "text/vtt")
        if u.path == "/expiring-media":
            if int(q.get("exp", ["0"])[0]) <= time.time(): return self.send(403, b"expired", "text/plain")
            return self.ranged(clip(), "video/mp4")
        if u.path == "/hls/master.m3u8": return self.send(200, HLS_MASTER, "application/vnd.apple.mpegurl")
        if u.path.startswith("/hls/") and u.path.endswith(".m3u8"): return self.send(200, HLS_MEDIA, "application/vnd.apple.mpegurl")
        if u.path == "/dash/manifest.mpd": return self.send(200, MPD, "application/dash+xml")
        self.send(404, b"not found", "text/plain")

def serve(port):
    s = ThreadingHTTPServer(("127.0.0.1", port), H); s.daemon_threads = True; s.serve_forever()

if __name__ == "__main__":
    for p in (EMBED,): threading.Thread(target=serve, args=(p,), daemon=True).start()
    print("ready site=%d embed=%d" % (SITE, EMBED), flush=True)
    serve(SITE)
