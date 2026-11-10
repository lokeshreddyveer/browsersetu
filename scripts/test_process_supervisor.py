#!/usr/bin/env python3
"""Test-only supervisor for the helper servers that unit tests need (the FTP/FTPS fixture and a real sshd).

A sandboxed test host cannot start those programs itself, so the test scheme starts this one (outside the sandbox) before the tests, and each test asks it over
loopback HTTP to start or stop one helper. Nothing else can be started: the programs are fixed, and every path argument must lie inside a sandboxed app's own
temporary folder (or this user's TMPDIR), where the test already put the files. Helpers run in their own process group and are stopped on request, after
20 minutes, or when this supervisor exits.

  test_process_supervisor.py [PORT]        (default 18821, loopback only)
  POST /start  {"kind": "ftp", "args": [ROOT, PORT, ...ftp_fixture_server.py options]}   -> {"id": "..."}
  POST /start  {"kind": "sshd", "args": [SSHD_CONFIG], "port": N}                          -> {"id": "..."}
  POST /stop   {"id": "..."}                                                                -> {"ok": true}
  GET  /health                                                                              -> {"ok": true, "running": N}
"""
import atexit, json, os, select, signal, socket, subprocess, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18821
HOME = os.path.expanduser("~")
MAX_AGE = 20 * 60
LOCK = threading.Lock()
RUNNING = {}   # id -> (Popen, started)


def allowed_path(p):
    """Inside a sandbox container's own temporary folder, or this user's TMPDIR: the places a test puts its throwaway files."""
    real = os.path.realpath(p)
    containers = os.path.realpath(os.path.join(HOME, "Library", "Containers")) + os.sep
    if real.startswith(containers) and (os.sep + "Data" + os.sep + "tmp" + os.sep) in real:
        return True
    tmp = os.path.realpath(os.environ.get("TMPDIR", "/nonexistent")) + os.sep
    return real.startswith(tmp)


def listening(port):
    s = socket.socket()
    s.settimeout(0.3)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def start(kind, args, port):
    if kind == "ftp":
        if len(args) < 2 or not all(isinstance(a, str) for a in args):
            raise ValueError("ftp needs ROOT and PORT")
        for a in args:
            if a.startswith("/") and not allowed_path(a):
                raise ValueError("path outside the allowed folders: " + a)
        argv = ["/usr/bin/python3", "-I", os.path.join(HERE, "ftp_fixture_server.py")] + args
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        ready, _, _ = select.select([p.stdout], [], [], 15)
        line = p.stdout.readline() if ready else b""
        if b"ready" not in line:
            kill(p)
            raise RuntimeError("the FTP fixture did not become ready")
        return p
    if kind == "sshd":
        if len(args) != 1 or not allowed_path(args[0]):
            raise ValueError("sshd needs one config path inside the allowed folders")
        p = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", args[0]], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        end = time.time() + 15
        while time.time() < end:
            if p.poll() is not None:
                raise RuntimeError("sshd exited at start")
            if port and listening(port):
                return p
            time.sleep(0.1)
        kill(p)
        raise RuntimeError("sshd did not listen")
    raise ValueError("unknown kind")


def kill(p):
    try:
        if p.stdin and not p.stdin.closed:
            try:
                p.stdin.write(b"quit\n"); p.stdin.flush()
            except OSError:
                pass
        os.killpg(p.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        pass
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass


def stop_all():
    with LOCK:
        items = list(RUNNING.values()); RUNNING.clear()
    for p, _ in items:
        kill(p)


def janitor():
    while True:
        time.sleep(30)
        with LOCK:
            old = [i for i, (p, t) in RUNNING.items() if time.time() - t > MAX_AGE or p.poll() is not None]
            gone = [RUNNING.pop(i)[0] for i in old]
        for p in gone:
            kill(p)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            with LOCK:
                self.reply(200, {"ok": True, "running": len(RUNNING)})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(min(n, 65536)) or b"{}")
            if self.path == "/start":
                p = start(req.get("kind"), req.get("args", []), int(req.get("port", 0) or 0))
                i = uuid.uuid4().hex
                with LOCK:
                    RUNNING[i] = (p, time.time())
                self.reply(200, {"id": i})
            elif self.path == "/stop":
                with LOCK:
                    item = RUNNING.pop(req.get("id", ""), None)
                if item:
                    kill(item[0])
                self.reply(200, {"ok": True})
            else:
                self.reply(404, {"error": "not found"})
        except (ValueError, RuntimeError) as e:
            self.reply(400, {"error": str(e)})
        except Exception as e:
            self.reply(500, {"error": repr(e)})


def main():
    atexit.register(stop_all)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: (stop_all(), os._exit(0)))
    threading.Thread(target=janitor, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("READY", flush=True)
    srv.serve_forever()


main()
