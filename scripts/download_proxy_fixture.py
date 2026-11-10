#!/usr/bin/env python3
"""A local proxy for the download engine's proxy tests. Listens on 127.0.0.1 only.

Usage: download_proxy_fixture.py [--http P] [--socks P] [--ctl P] [--auth user:pass] [--map name=host:port]
Ports default to a free one. Prints one line "PORTS http=<n> socks=<n> ctl=<n>" when ready.
--map makes a name that exists nowhere else (for example originhost) lead to a local address, so a test can tell a request that went THROUGH the proxy (the name works)
from one that went around it (the name cannot be resolved). Loopback addresses are never sent through an explicit proxy by the system, so this is how that is shown.

  http   an HTTP proxy: CONNECT tunnels, and absolute-URI forwarding for plain http. With --auth it answers 407 until Proxy-Authorization (Basic) is right.
  socks  a SOCKS5 proxy (no auth, or user/pass when --auth is given).
  ctl    GET /log -> JSON list of what the proxies were asked ({"kind","target","auth_ok"}); GET /reset clears it.

Nothing here is a general-purpose proxy: it only connects to 127.0.0.1 and to addresses on the loopback interface, so a test can never use it to reach the network.
"""
import base64
import json
import select
import socket
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = []
LOCK = threading.Lock()
AUTH = None  # (user, pass)
PORTS = {"--http": 0, "--socks": 0, "--ctl": 0}
MAP = {}
for i, a in enumerate(sys.argv):
    if a == "--auth" and i + 1 < len(sys.argv):
        AUTH = tuple(sys.argv[i + 1].split(":", 1))
    if a in PORTS and i + 1 < len(sys.argv):
        PORTS[a] = int(sys.argv[i + 1])
    if a == "--map" and i + 1 < len(sys.argv):
        name, _, target = sys.argv[i + 1].partition("=")
        h, _, p = target.rpartition(":")
        MAP[name] = (h, int(p))


def log(kind, target, auth_ok=True):
    with LOCK:
        LOG.append({"kind": kind, "target": target, "auth_ok": auth_ok})


def allowed(host):
    return host in ("127.0.0.1", "localhost", "::1") or host in MAP


def target(host, port):
    """Where a request for host:port really goes."""
    return MAP.get(host, (host, port))


def pipe(a, b):
    socks = [a, b]
    try:
        while True:
            r, _, _ = select.select(socks, [], [], 30)
            if not r:
                return
            for s in r:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        return
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass


class HTTPProxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def auth_ok(self):
        if AUTH is None:
            return True
        header = self.headers.get("Proxy-Authorization", "")
        if not header.lower().startswith("basic "):
            return False
        try:
            user, _, pw = base64.b64decode(header[6:]).decode().partition(":")
        except Exception:
            return False
        return (user, pw) == AUTH

    def deny(self):
        self.send_response(407)
        self.send_header("Proxy-Authenticate", 'Basic realm="fixture"')
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_CONNECT(self):
        host, _, port = self.path.rpartition(":")
        ok = self.auth_ok()
        log("connect", self.path, ok)
        if not ok:
            return self.deny()
        if not allowed(host.strip("[]")):
            self.send_error(403)
            return
        try:
            upstream = socket.create_connection(target(host.strip("[]"), int(port)), timeout=10)
        except OSError:
            self.send_error(502)
            return
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.wfile.flush()
        pipe(self.connection, upstream)
        self.close_connection = True

    def forward(self):
        ok = self.auth_ok()
        log("forward", self.path, ok)
        if not ok:
            return self.deny()
        from urllib.parse import urlsplit
        u = urlsplit(self.path)
        if not u.hostname or not allowed(u.hostname):
            self.send_error(403)
            return
        try:
            upstream = socket.create_connection(target(u.hostname, u.port or 80), timeout=10)
        except OSError:
            self.send_error(502)
            return
        path = (u.path or "/") + ("?" + u.query if u.query else "")
        lines = [f"{self.command} {path} HTTP/1.1"]
        for k, v in self.headers.items():
            if k.lower() in ("proxy-authorization", "proxy-connection", "connection"):
                continue
            lines.append(f"{k}: {v}")
        lines.append("Connection: close")
        upstream.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        pipe(self.connection, upstream)
        self.close_connection = True

    do_GET = do_HEAD = do_POST = forward


class Socks(socketserver.BaseRequestHandler):
    def handle(self):
        c = self.request
        try:
            ver, n = c.recv(2)
            methods = c.recv(n)
            if AUTH is not None:
                if 2 not in methods:
                    c.sendall(b"\x05\xff")
                    return
                c.sendall(b"\x05\x02")
                _, ulen = c.recv(2)
                user = c.recv(ulen).decode()
                plen = c.recv(1)[0]
                pw = c.recv(plen).decode()
                ok = (user, pw) == AUTH
                c.sendall(b"\x01\x00" if ok else b"\x01\x01")
                if not ok:
                    log("socks", "-", False)
                    return
            else:
                c.sendall(b"\x05\x00")
            _, cmd, _, atyp = c.recv(4)
            if atyp == 1:
                host = socket.inet_ntoa(c.recv(4))
            elif atyp == 3:
                host = c.recv(c.recv(1)[0]).decode()
            else:
                host = socket.inet_ntop(socket.AF_INET6, c.recv(16))
            port = int.from_bytes(c.recv(2), "big")
            log("socks", f"{host}:{port}", True)
            if cmd != 1 or not allowed(host):
                c.sendall(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
                return
            up = socket.create_connection(target(host, port), timeout=10)
            c.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            pipe(c, up)
        except Exception:
            return


class Ctl(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/reset":
            with LOCK:
                LOG.clear()
            body = b"ok"
        else:
            with LOCK:
                body = json.dumps(LOG).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ThreadedTCP(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    http = ThreadingHTTPServer(("127.0.0.1", PORTS["--http"]), HTTPProxy)
    http.daemon_threads = True
    socks = ThreadedTCP(("127.0.0.1", PORTS["--socks"]), Socks)
    ctl = ThreadingHTTPServer(("127.0.0.1", PORTS["--ctl"]), Ctl)
    for s in (http, socks, ctl):
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print(f"PORTS http={http.server_address[1]} socks={socks.server_address[1]} ctl={ctl.server_address[1]}", flush=True)
    threading.Event().wait()


main()
