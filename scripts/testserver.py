#!/usr/bin/env python3
"""Local fixture server for browser integration tests (127.0.0.1 only)."""
import http.server
import json
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18765
requests = []
lock = threading.Lock()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="text/html", headers=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        with lock:
            requests.append((self.headers.get("Host") or "") + self.path)
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        with lock:
            # host + path, so tests can tell first-party from third-party hostnames that all resolve to 127.0.0.1
            requests.append((self.headers.get("Host") or "") + self.path)
        if path == "/_requests":
            with lock:
                return self.send(200, json.dumps(requests), "application/json")
        if path == "/_reset":
            with lock:
                requests.clear()
            return self.send(200, "ok", "text/plain")
        if path.startswith("/cookie/"):
            token = path.split("/")[2]
            return self.send(200, "<title>Cookie</title>set", headers=[("Set-Cookie", f"marker={token}; Path=/")])
        if path.startswith("/p/"):
            return self.send(200, f"<title>Page {path[3:]}</title>hello")
        if path == "/tall":
            rows = "".join(f"<p style='font:18px sans-serif;margin:24px'>Paragraph {i}. A long page, so there is something to scroll.</p>" for i in range(200))
            return self.send(200, f"<title>Tall</title><body style='margin:0'>{rows}</body>")
        if path == "/amp-page":
            return self.send(200, f'<html amp><head><title>AMP copy</title><link rel="canonical" href="http://127.0.0.1:{PORT}/full-page"></head><body>amp</body></html>')
        if path == "/full-page":
            return self.send(200, "<title>Full page</title>the real one")
        if path == "/script-page":
            return self.send(200, "<title>before</title><script>document.title='ran'</script>text")
        if path == "/page":
            return self.send(200, "<title>Page</title>hello")
        if path == "/page2":
            return self.send(200, "<title>Page Two</title>hello two")
        if path == "/withtracker":
            return self.send(200, f'<title>Tracker</title><script src="http://localhost:{PORT}/tracker.js"></script>ok')
        if path == "/tracker.js":
            return self.send(200, "document.title='tracker-ran'", "application/javascript")
        if path == "/slow.bin":
            import time
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "2000000")
            self.send_header("Content-Disposition", 'attachment; filename="slow.bin"')
            self.end_headers()
            try:
                for _ in range(2000):
                    self.wfile.write(b"x" * 1000)
                    self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == "/redirect-file":
            self.send_response(302)
            self.send_header("Location", "file:///etc/hosts")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/redirect-page":
            self.send_response(302)
            self.send_header("Location", "/page2")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/privacy-page":
            p = PORT
            return self.send(200, f"""<title>Privacy</title>
<img src="http://ads.localhost:{p}/ad.gif">
<script src="http://tracker.localhost:{p}/t.js"></script>
<img src="/normal.gif">
<img src="http://other.localhost:{p}/cookie-img/THIRDPARTY">
<script>navigator.sendBeacon("http://other.localhost:{p}/beacon", "x")</script>
<body>privacy fixture</body>""")
        if path in ("/ad.gif", "/normal.gif"):
            return self.send(200, b"GIF89a", "image/gif")
        if path == "/t.js":
            return self.send(200, "window.__tracker=1", "application/javascript")
        if path.startswith("/cookie-img/"):
            token = path.split("/")[2]
            return self.send(200, b"GIF89a", "image/gif", [("Set-Cookie", f"tp={token}; Path=/")])
        if path == "/download.bin":
            return self.send(200, b"hello-download", "application/octet-stream",
                             [("Content-Disposition", 'attachment; filename="../../evil name.bin"')])
        self.send(404, "<title>Not Found</title>nope")


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
