#!/usr/bin/env python3
"""A small FTP / FTPS test server (standard library only) for BrowserSetu's tests. Not a product: it exists so the FTP client is exercised against a server that speaks the protocol.

  ftp_fixture_server.py ROOT PORT [--user alice --password s3cret] [--anonymous] [--tls CERT KEY] [--implicit] [--no-rest] [--no-mlsd] [--flaky NAME]

Supports USER PASS AUTH TLS PBSZ PROT PWD CWD CDUP TYPE PASV EPSV LIST NLST MLSD SIZE MDTM REST RETR OPTS FEAT SYST NOOP QUIT. ROOT is the whole visible tree.
--flaky NAME: the first RETR of a file called NAME sends half of it and drops the data connection (a transfer cut short).
Stops when it reads a line from standard input that says 'quit', or when stdin closes.
"""
import argparse, os, socket, ssl, sys, threading, time, stat as st

ap = argparse.ArgumentParser()
ap.add_argument("root"); ap.add_argument("port", type=int)
ap.add_argument("--user", default="alice"); ap.add_argument("--password", default="s3cret")
ap.add_argument("--anonymous", action="store_true")
ap.add_argument("--tls", nargs=2, metavar=("CERT", "KEY")); ap.add_argument("--implicit", action="store_true")
ap.add_argument("--no-rest", action="store_true"); ap.add_argument("--no-mlsd", action="store_true")
ap.add_argument("--forever", action="store_true"); ap.add_argument("--readonly", action="store_true"); ap.add_argument("--symlinks", action="store_true", help="list symbolic links as links (OS.unix=slink / l---------) instead of what they point at"); ap.add_argument("--flaky"); ap.add_argument("--throttle", type=float, default=0, help="seconds to wait after every 64 KB sent")
args = ap.parse_args()
ROOT = os.path.realpath(args.root)
CTX = None
if args.tls:
    CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); CTX.load_cert_chain(args.tls[0], args.tls[1])
flaky_done = set()

def resolve(cwd, arg):
    p = arg if arg.startswith("/") else cwd.rstrip("/") + "/" + arg
    parts = []
    for c in p.split("/"):
        if c in ("", "."): continue
        if c == "..":
            if parts: parts.pop()
        else: parts.append(c)
    virt = "/" + "/".join(parts)
    real = os.path.realpath(os.path.join(ROOT, *parts))
    if real != ROOT and not real.startswith(ROOT + os.sep): return None, None
    return virt, real

class Session(threading.Thread):
    def __init__(self, conn):
        super().__init__(daemon=True); self.c = conn; self.f = None; self.cwd = "/"; self.user = None; self.ok = False; self.rest = 0
        self.pasv = None; self.tls = False; self.prot_p = False; self.utf8 = True
    def send(self, s):
        self.c.sendall((s + "\r\n").encode("utf-8"))
    def run(self):
        try:
            if args.implicit and CTX: self.c = CTX.wrap_socket(self.c, server_side=True); self.tls = True
            self.f = self.c.makefile("rb"); self.send("220 BrowserSetu test FTP ready")
            while True:
                line = self.f.readline()
                if not line: break
                text = line.decode("utf-8", "replace").rstrip("\r\n")
                cmd, _, arg = text.partition(" "); cmd = cmd.upper()
                if not self.handle(cmd, arg): break
        except Exception: pass
        finally:
            try: self.c.close()
            except Exception: pass
    def need_login(self):
        if not self.ok: self.send("530 Please login with USER and PASS."); return True
        return False
    def data_conn(self):
        if not self.pasv: self.send("425 Use PASV or EPSV first."); return None
        srv = self.pasv; self.pasv = None
        srv.settimeout(10)
        try: d, _ = srv.accept()
        except Exception: self.send("425 Can't open data connection."); return None
        finally: srv.close()
        if self.prot_p and CTX: d = CTX.wrap_socket(d, server_side=True)
        return d
    def handle(self, cmd, arg):
        if cmd == "AUTH" and CTX and arg.upper() in ("TLS", "TLS-C", "SSL"):
            self.send("234 Proceed with negotiation."); self.c = CTX.wrap_socket(self.c, server_side=True); self.f = self.c.makefile("rb"); self.tls = True; return True
        if cmd == "USER":
            self.user = arg
            if args.anonymous and arg.lower() in ("anonymous", "ftp"): self.send("331 Send e-mail address as password.")
            else: self.send("331 Password required.")
            return True
        if cmd == "PASS":
            if (args.anonymous and (self.user or "").lower() in ("anonymous", "ftp")) or (self.user == args.user and arg == args.password): self.ok = True; self.send("230 Logged in.")
            else: self.send("530 Login incorrect.")
            return True
        if cmd == "QUIT": self.send("221 Goodbye."); return False
        if cmd in ("NOOP",): self.send("200 OK"); return True
        if cmd == "SYST": self.send("215 UNIX Type: L8"); return True
        if cmd == "FEAT":
            feats = ["UTF8", "SIZE", "MDTM"] + ([] if args.no_mlsd else ["MLST type*;size*;modify*;"]) + ([] if args.no_rest else ["REST STREAM"]) + (["AUTH TLS", "PBSZ", "PROT"] if CTX else [])
            self.c.sendall(("211-Features:\r\n" + "".join(" " + x + "\r\n" for x in feats) + "211 End\r\n").encode()); return True
        if cmd == "OPTS": self.send("200 OK"); return True
        if cmd == "PBSZ": self.send("200 PBSZ=0"); return True
        if cmd == "PROT": self.prot_p = arg.upper() == "P"; self.send("200 OK"); return True
        if cmd == "TYPE": self.send("200 Type set."); return True
        if self.need_login(): return True
        if cmd == "PWD": self.send('257 "%s" is the current directory' % self.cwd); return True
        if cmd == "CWD":
            v, r = resolve(self.cwd, arg)
            if r and os.path.isdir(r): self.cwd = v; self.send("250 OK")
            else: self.send("550 No such directory.")
            return True
        if cmd == "CDUP": self.cwd = resolve(self.cwd, "..")[0]; self.send("250 OK"); return True
        if cmd in ("PASV", "EPSV"):
            srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1); self.pasv = srv; p = srv.getsockname()[1]
            if cmd == "PASV": self.send("227 Entering Passive Mode (127,0,0,1,%d,%d)." % (p >> 8, p & 255))
            else: self.send("229 Entering Extended Passive Mode (|||%d|)" % p)
            return True
        if cmd == "SIZE":
            v, r = resolve(self.cwd, arg)
            if r and os.path.isfile(r): self.send("213 %d" % os.path.getsize(r))
            else: self.send("550 No such file.")
            return True
        if cmd == "MDTM":
            v, r = resolve(self.cwd, arg)
            if r and os.path.exists(r): self.send("213 " + time.strftime("%Y%m%d%H%M%S", time.gmtime(os.path.getmtime(r))))
            else: self.send("550 No such file.")
            return True
        if cmd == "REST":
            if args.no_rest: self.send("502 REST not supported."); return True
            self.rest = int(arg); self.send("350 Restarting at %d." % self.rest); return True
        if cmd in ("LIST", "NLST", "MLSD"):
            if cmd == "MLSD" and args.no_mlsd: self.send("500 Unknown command."); return True
            a = arg if arg and not arg.startswith("-") else ""
            v, r = resolve(self.cwd, a) if a else (self.cwd, resolve(self.cwd, ".")[1])
            if not r or not os.path.isdir(r): self.send("550 No such directory."); return True
            try: names = sorted(os.listdir(r))
            except PermissionError: self.send("550 Permission denied."); return True
            d = self.data_conn()
            if not d: return True
            self.send("150 Here comes the listing.")
            out = []
            for n in names:
                p = os.path.join(r, n)
                islink = args.symlinks and os.path.islink(p)
                try: s = os.lstat(p) if islink else os.stat(p)
                except OSError: continue
                isdir = st.S_ISDIR(s.st_mode); mt = time.gmtime(s.st_mtime)
                if islink and cmd == "MLSD": out.append("type=OS.unix=slink:%s;size=%d;modify=%s; %s" % (os.readlink(p), s.st_size, time.strftime("%Y%m%d%H%M%S", mt), n)); continue
                if islink and cmd == "LIST": out.append("lrwxrwxrwx 1 owner group %12d %s %s -> %s" % (s.st_size, time.strftime("%b %d %H:%M", mt), n, os.readlink(p))); continue
                if cmd == "MLSD": out.append("type=%s;size=%d;modify=%s; %s" % ("dir" if isdir else "file", s.st_size, time.strftime("%Y%m%d%H%M%S", mt), n))
                elif cmd == "NLST": out.append(n)
                else: out.append("%s 1 owner group %12d %s %s" % ("drwxr-xr-x" if isdir else "-rw-r--r--", s.st_size, time.strftime("%b %d %H:%M", mt), n))
            try: d.sendall(("\r\n".join(out) + ("\r\n" if out else "")).encode("utf-8")); d.close()
            except Exception: pass
            self.send("226 Done."); return True
        if cmd == "RETR":
            v, r = resolve(self.cwd, arg)
            if not r or not os.path.isfile(r): self.send("550 No such file."); self.rest = 0; return True
            d = self.data_conn()
            if not d: return True
            size = os.path.getsize(r); start = self.rest; self.rest = 0
            self.send("150 Opening data connection.")
            try:
                with open(r, "rb") as fh:
                    fh.seek(start); sent = 0; limit = size - start
                    cut = args.flaky and os.path.basename(r) == args.flaky and r not in flaky_done and start == 0
                    if cut: flaky_done.add(r); limit = (size - start) // 2
                    while sent < limit:
                        chunk = fh.read(min(65536, limit - sent))
                        if not chunk: break
                        d.sendall(chunk); sent += len(chunk)
                        if args.throttle: time.sleep(args.throttle)
                d.close()
                if cut: self.c.close(); return False
                self.send("226 Transfer complete.")
            except Exception:
                try: self.send("426 Connection closed; transfer aborted.")
                except Exception: pass
            return True
        if cmd in ("STOR", "DELE", "RMD", "RNFR", "RNTO", "MKD"):
            if args.readonly: self.send("550 Permission denied."); return True
            v, r = resolve(self.cwd, arg)
            if r is None: self.send("550 Not allowed."); return True
            if cmd == "DELE":
                if os.path.isfile(r) or os.path.islink(r): os.remove(r); self.send("250 Deleted.")
                else: self.send("550 No such file.")
                return True
            if cmd == "RMD":
                try: os.rmdir(r); self.send("250 Removed.")
                except OSError: self.send("550 Cannot remove.")
                return True
            if cmd == "MKD":
                try: os.mkdir(r); self.send('257 "%s" created' % v)
                except OSError: self.send("550 Cannot create.")
                return True
            if cmd == "RNFR":
                if os.path.exists(r): self.renaming = r; self.send("350 Ready for RNTO.")
                else: self.send("550 No such file.")
                return True
            if cmd == "RNTO":
                src = getattr(self, "renaming", None)
                if not src: self.send("503 RNFR first."); return True
                try: os.rename(src, r); self.send("250 Renamed.")
                except OSError: self.send("550 Cannot rename.")
                self.renaming = None; return True
            if cmd == "STOR":
                d = self.data_conn()
                if not d: return True
                self.send("150 Ok to send data.")
                try:
                    with open(r, "wb") as fh:
                        while True:
                            chunk = d.recv(65536)
                            if not chunk: break
                            fh.write(chunk)
                    d.close(); self.send("226 Transfer complete.")
                except Exception:
                    try: self.send("426 Transfer aborted.")
                    except Exception: pass
                return True
        self.send("502 Command not implemented."); return True

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", args.port)); srv.listen(32)
def accept():
    while True:
        try: c, _ = srv.accept()
        except Exception: break
        Session(c).start()
threading.Thread(target=accept, daemon=True).start()
print("ready", flush=True)
if args.forever: threading.Event().wait()
for line in sys.stdin:
    if line.strip() == "quit": break
