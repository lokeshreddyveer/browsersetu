#!/usr/bin/python3 -I
"""Test-only stand-in for GitHub, Hugging Face and S3/Azure style services, plus a separate 'CDN' origin.
usage: provider_fixture_server.py SERVICE_PORT CDN_PORT      (prints 'ready'; exits when stdin says quit/closes)
GET /_log on the service port returns what every request carried (path, whether it had Authorization, Accept); /_expect/<name> gives size+sha256 of a blob."""
import hashlib, json, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SP, CP = int(sys.argv[1]), int(sys.argv[2])
SERVICE, CDN = f"http://127.0.0.1:{SP}", f"http://127.0.0.1:{CP}"
LOG, LOCK = [], threading.Lock()
RESOLVES = {"n": 0}

def blob(seed, n):
    out, h = b"", hashlib.sha256(seed.encode()).digest()
    while len(out) < n:
        out += h; h = hashlib.sha256(h).digest()
    return out[:n]
def sha(b): return hashlib.sha256(b).hexdigest()

BLOBS = {
    "App-1.0-macos-arm64.dmg": blob("arm", 200_000), "App-1.0-macos-x86_64.dmg": blob("x86", 150_000), "App-1.0-windows-x64.exe": blob("win", 90_000),
    "App-2.0-beta-macos-arm64.dmg": blob("beta", 80_000), "App-1.0-macos-arm64.dmg.sig": blob("sig", 300),
    "tool-macos-arm64.dmg": blob("t1", 60_000), "tool-macos-arm64.zip": blob("t2", 50_000), "tool-windows.exe": blob("t3", 5_000),
    "secret-macos-arm64.dmg": blob("secret", 50_000),
}
SUMS = "".join(f"{sha(BLOBS[n])}  {n}\n" for n in ["App-1.0-macos-x86_64.dmg", "App-1.0-windows-x64.exe"]).encode()
BLOBS["SHA256SUMS"] = SUMS

def gh_asset(i, name, repo, tag):
    d = {"id": i, "name": name, "size": len(BLOBS[name]), "state": "uploaded",
         "url": f"{SERVICE}/repos/{repo}/releases/assets/{i}", "browser_download_url": f"{SERVICE}/{repo}/releases/download/{tag}/{name}"}
    if name == "App-1.0-macos-arm64.dmg": d["digest"] = "sha256:" + sha(BLOBS[name])
    return d
ASSET_IDS = {11: "App-1.0-macos-arm64.dmg", 12: "App-1.0-macos-x86_64.dmg", 13: "App-1.0-windows-x64.exe", 14: "SHA256SUMS", 15: "App-1.0-macos-arm64.dmg.sig", 16: "App-2.0-beta-macos-arm64.dmg",
             31: "tool-macos-arm64.dmg", 32: "tool-macos-arm64.zip", 33: "tool-windows.exe", 21: "secret-macos-arm64.dmg"}
RELEASES = {
    "o/r": [{"id": 1, "tag_name": "v1.0", "name": "Version 1.0", "prerelease": False, "draft": False, "assets": [gh_asset(i, ASSET_IDS[i], "o/r", "v1.0") for i in (11, 12, 13, 14, 15)]},
            {"id": 2, "tag_name": "v2.0-beta", "name": "2.0 beta", "prerelease": True, "draft": False, "assets": [gh_asset(16, ASSET_IDS[16], "o/r", "v2.0-beta")]}],
    "o/two": [{"id": 3, "tag_name": "v1", "name": "v1", "prerelease": False, "draft": False, "assets": [gh_asset(i, ASSET_IDS[i], "o/two", "v1") for i in (31, 32, 33)]}],
    "o/priv": [{"id": 4, "tag_name": "v1", "name": "v1", "prerelease": False, "draft": False, "assets": [gh_asset(21, ASSET_IDS[21], "o/priv", "v1")]}],
}

HF_SHA = "1234567890abcdef1234567890abcdef12345678"
HF_FILES = {
    "config.json": (b'{"model_type":"toy","hidden":16}\n', False), "model.safetensors": (blob("st", 300_000), True),
    "sub/tokenizer.json": (b'{"vocab":["a","b"]}\n', False), "weights-Q4.gguf": (blob("gg", 100_000), True), "pointer.bin": (blob("ptr", 5_000), True),
}
def pointer_text(content): return f"version https://git-lfs.github.com/spec/v1\noid sha256:{sha(content)}\nsize {len(content)}\n".encode()
LFS_BY_OID = {sha(c): c for c, l in HF_FILES.values() if l}
POINTER_OID = sha(HF_FILES["pointer.bin"][0])
BULK = {f"data/part-{i:05d}.parquet": f"part {i}".encode().ljust(64, b".") for i in range(1200)}
RL = {f"f{i}.bin": f"rl {i}".encode().ljust(32, b".") for i in range(10)}
S3 = {"data/a.csv": b"a," * 50, "data/b.csv": b"b," * 100, "data/sub/c.csv": b"c," * 150, "readme.txt": b"hello\n"}
AZ = {"one.txt": b"azure one\n", "dir/two.txt": b"azure two\n"}

def tree_entry(path, content, lfs):
    e = {"type": "file", "oid": "0" * 40, "size": len(pointer_text(content)) if lfs else len(content), "path": path}
    if lfs: e["lfs"] = {"oid": sha(content), "size": len(content), "pointerSize": len(pointer_text(content))}
    return e

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    @property
    def side(self): return "cdn" if self.server.server_port == CP else "service"
    def send(self, status, body=b"", headers=None, ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def js(self, obj, status=200, headers=None): self.send(status, json.dumps(obj).encode(), headers)
    def redirect(self, url): self.send(302, b"", {"Location": url})
    def serve_bytes(self, data):
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-"); a = int(a); b = int(b) if b else len(data) - 1
            part = data[a:b + 1]
            self.send(206, part, {"Content-Range": f"bytes {a}-{a + len(part) - 1}/{len(data)}", "Accept-Ranges": "bytes"}, "application/octet-stream")
        else:
            self.send(200, data, {"Accept-Ranges": "bytes", "ETag": '"' + sha(data)[:16] + '"'}, "application/octet-stream")
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); q = urllib.parse.parse_qs(u.query); path = urllib.parse.unquote(u.path)
        auth = self.headers.get("Authorization")
        with LOCK:
            if not path.startswith("/_"): LOG.append({"side": self.side, "method": self.command, "path": self.path, "auth": auth is not None, "authValue": auth, "accept": self.headers.get("Accept")})
        if path == "/_log":
            with LOCK: return self.js(LOG)
        if path.startswith("/_expect/"):
            n = path[9:]; b = BLOBS.get(n) or (HF_FILES.get(n) or (None,))[0]
            return self.js({"size": len(b), "sha256": sha(b)}) if b is not None else self.send(404)
        if path == "/_reset":
            with LOCK: LOG.clear(); RESOLVES["n"] = 0
            return self.js({"ok": True})
        if self.side == "cdn": return self.cdn(path, q)
        return self.service(path, q, auth)

    def cdn(self, path, q):
        if path.startswith("/blob/"): return self.serve_bytes(BLOBS[path[6:]]) if path[6:] in BLOBS else self.send(404)
        if path.startswith("/lfs/"):
            c = LFS_BY_OID.get(path[5:])
            if c is None: return self.send(404)
            if path[5:] == POINTER_OID: return self.serve_bytes(pointer_text(c))          # a store that hands out the pointer instead of the file
            return self.serve_bytes(c)
        return self.send(404)

    def service(self, path, q, auth):
        parts = [p for p in path.split("/") if p]
        # ---------- GitHub-shaped
        if parts[:1] == ["repos"] and len(parts) >= 3:
            repo = parts[1] + "/" + parts[2]
            if repo == "o/limited": return self.js({"message": "API rate limit exceeded"}, 403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(time.time()) + 120)})
            if repo == "o/priv" and auth != "Bearer ghp_testtoken": return self.js({"message": "Not Found"}, 404)
            if repo not in RELEASES: return self.js({"message": "Not Found"}, 404)
            rest = parts[3:]
            if not rest: return self.js({"private": repo == "o/priv", "default_branch": "main"})
            if rest == ["releases"]: return self.js(RELEASES[repo])
            if rest == ["releases", "latest"]: return self.js([r for r in RELEASES[repo] if not r["prerelease"]][0])
            if rest[:2] == ["releases", "tags"]:
                tag = "/".join(rest[2:]); m = [r for r in RELEASES[repo] if r["tag_name"] == tag]
                return self.js(m[0]) if m else self.js({"message": "Not Found"}, 404)
            if rest[:2] == ["releases", "assets"]:
                i = int(rest[2]); name = ASSET_IDS.get(i)
                if self.headers.get("Accept") != "application/octet-stream": return self.js({"id": i, "name": name})      # metadata, not the file
                return self.redirect(f"{CDN}/blob/{name}?X-Amz-Signature=sig{i}&X-Amz-Date=20990101T000000Z&X-Amz-Expires=300")
            if rest[:1] in (["zipball"], ["tarball"]): return self.redirect(f"{CDN}/blob/App-1.0-windows-x64.exe?archive=1")
        if len(parts) >= 5 and parts[2:4] == ["releases", "download"]:
            name = parts[-1]
            return self.redirect(f"{CDN}/blob/{name}?X-Amz-Signature=pub&X-Amz-Expires=300&X-Amz-Date=20990101T000000Z") if name in BLOBS else self.send(404)
        # ---------- Hugging Face-shaped
        if parts[:1] == ["api"] and len(parts) >= 4:
            kind = parts[1]; segs = parts[2:]
            if kind == "models":
                repo = segs[0] + "/" + segs[1]; rest = segs[2:]
                if repo == "org/limited": return self.send(429, b'{"error":"rate"}', {"Retry-After": "7"})
                if repo == "org/private" and auth != "Bearer hf_testtoken": return self.js({"error": "Invalid credentials"}, 401)
                if repo not in ("org/model", "org/gated", "org/private"): return self.js({"error": "Repository not found"}, 404)
                if rest[:1] == ["revision"]: return self.js({"sha": HF_SHA, "private": repo == "org/private", "gated": "manual" if repo == "org/gated" else False})
                if rest[:1] == ["tree"]:
                    sub = "/".join(rest[2:])
                    names = list(HF_FILES) if repo == "org/model" else ["config.json"]
                    ents = [tree_entry(n, *HF_FILES[n]) for n in names]
                    if sub: return self.js([e for e in ents if e["path"] == sub or e["path"].startswith(sub + "/")])
                    if repo == "org/model":
                        if q.get("cursor") == ["2"]: return self.js(ents[2:])
                        return self.js(ents[:2], 200, {"Link": f'<{SERVICE}{u_path(self)}?recursive=true&cursor=2>; rel="next"'})
                    return self.js(ents)
            if kind == "datasets":
                repo = segs[0] + "/" + segs[1]; rest = segs[2:]
                if repo not in ("org/bulk", "org/rl"): return self.js({"error": "Repository not found"}, 404)
                if rest[:1] == ["revision"]: return self.js({"sha": HF_SHA, "private": False, "gated": False})
                if rest[:1] == ["tree"]:
                    files = BULK if repo == "org/bulk" else RL
                    names = list(files); start = int(q.get("cursor", ["0"])[0]); step = 500
                    ents = [{"type": "file", "oid": "0" * 40, "size": len(files[n]), "path": n} for n in names[start:start + step]]
                    hdr = {"Link": f'<{SERVICE}{u_path(self)}?recursive=true&cursor={start + step}>; rel="next"'} if start + step < len(names) else {}
                    return self.js(ents, 200, hdr)
        if len(parts) >= 4 and "resolve" in parts:
            i = parts.index("resolve"); ds = parts[0] == "datasets"; base = parts[1:i] if ds else parts[:i]
            repo = "/".join(base); rel = "/".join(parts[i + 2:])
            if repo == "org/gated": return self.send(403, b'{"error":"Access to model org/gated is restricted. You must have access to it and be authenticated."}', {"X-Error-Code": "GatedRepo"})
            if repo == "org/private" and auth != "Bearer hf_testtoken": return self.js({"error": "Invalid credentials"}, 401)
            if ds and repo == "org/bulk" and rel in BULK: return self.serve_bytes(BULK[rel])
            if ds and repo == "org/rl" and rel in RL:
                with LOCK: RESOLVES["n"] += 1; n = RESOLVES["n"]
                return self.send(429, b"{}", {"Retry-After": "30"}) if n > 3 else self.serve_bytes(RL[rel])
            if not ds and rel in HF_FILES:
                content, lfs = HF_FILES[rel]
                return self.redirect(f"{CDN}/lfs/{sha(content)}?X-Amz-Signature=hfsig&X-Amz-Expires=3600&X-Amz-Date=20990101T000000Z") if lfs else self.serve_bytes(content)
        # ---------- S3 / Azure style
        if parts[:1] == ["locked"]: return self.send(403, b"<Error><Code>AccessDenied</Code></Error>", None, "application/xml")
        if parts[:1] == ["pub-bucket"]:
            if len(parts) == 1 and "list-type" in q:
                prefix = q.get("prefix", [""])[0]; keys = sorted(k for k in S3 if k.startswith(prefix))
                start = int(q.get("continuation-token", ["0"])[0]); page = keys[start:start + 2]; more = start + 2 < len(keys)
                x = "<?xml version='1.0'?><ListBucketResult><Name>pub-bucket</Name><IsTruncated>" + ("true" if more else "false") + "</IsTruncated>"
                if more: x += f"<NextContinuationToken>{start + 2}</NextContinuationToken>"
                x += "".join(f"<Contents><Key>{k}</Key><Size>{len(S3[k])}</Size></Contents>" for k in page) + "</ListBucketResult>"
                return self.send(200, x.encode(), None, "application/xml")
            key = "/".join(parts[1:]); return self.serve_bytes(S3[key]) if key in S3 else self.send(404)
        if parts[:2] == ["acct", "box"]:
            if q.get("sig") != ["good"]: return self.send(403, b"<Error><Code>AuthenticationFailed</Code></Error>", None, "application/xml")
            if q.get("comp") == ["list"]:
                x = "<?xml version='1.0'?><EnumerationResults><Blobs>" + "".join(f"<Blob><Name>{k}</Name><Properties><Content-Length>{len(v)}</Content-Length></Properties></Blob>" for k, v in AZ.items()) + "</Blobs><NextMarker/></EnumerationResults>"
                return self.send(200, x.encode(), None, "application/xml")
            key = "/".join(parts[2:]); return self.serve_bytes(AZ[key]) if key in AZ else self.send(404)
        return self.js({"error": "not found", "path": path}, 404)

def u_path(h): return urllib.parse.urlsplit(h.path).path

def main():
    servers = [ThreadingHTTPServer(("127.0.0.1", p), H) for p in (SP, CP)]
    for s in servers: s.daemon_threads = True; threading.Thread(target=s.serve_forever, daemon=True).start()
    print("ready", flush=True)
    if "--forever" in sys.argv:
        threading.Event().wait()
    for line in sys.stdin:
        if line.strip() == "quit": break
    for s in servers: s.shutdown()
main()
