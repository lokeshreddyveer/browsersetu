#!/usr/bin/env python3
"""Corresponding-source preparation and the exact binary-to-source map for Browser Setu's redistributed third-party programs.

  scripts/prepare-media-sources.py fetch [--out DIR]                 download each source archive from its official place and VERIFY it (see below); writes SOURCES.json
  scripts/prepare-media-sources.py map --app "<Browser Setu.app>" [--out DIR]
                                                                      map EVERY Mach-O file in the built app's media tools (and the app's own LAME library) to the source it was built from; writes BINARY-TO-SOURCE.json
  scripts/prepare-media-sources.py verify-lame [--out DIR]           compare the LAME sources in this repository with the upstream tarball, file by file

Default OUT is build/media-sources. Nothing here uploads or publishes anything; the output is a staging folder for a release's source assets.

How each archive is verified (the strongest independent digest available, stated in SOURCES.json as "verifiedBy"):
  pypi          the sha256 PyPI publishes for that exact release file (metadata fetched separately from the file)
  release-sums  the SHA2-256SUMS file published in the same GitHub release
  repo-pin      the sha256 already pinned in this repository (ffmpeg's in apps/apple/ThirdParty/ffmpeg/MANIFEST.json)
  none          no independent digest exists: the sha256 is only RECORDED (what we downloaded), not verified; marked clearly
This script prepares material. It is not a legal opinion and does not close any legal review.
"""
import argparse, hashlib, json, os, re, subprocess, sys, tarfile, tempfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
UA = {"User-Agent": "BrowserSetu-source-prep"}


def get(url, binary=True, timeout=120):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        data = r.read()
    return data if binary else data.decode()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def pypi(project, version):
    meta = json.loads(get(f"https://pypi.org/pypi/{project}/{version}/json", binary=False))
    sdist = next(u for u in meta["urls"] if u["packagetype"] == "sdist")
    return sdist["url"], sdist["digests"]["sha256"], sdist["filename"]


def template(tool):
    with open(os.path.join(ROOT, "apps", "apple", "ThirdParty", tool, "MANIFEST.json")) as f:
        return json.load(f)


def parse_requirements(text):
    """name==version pins from a hash-locked requirements file; entries whose marker excludes CPython are skipped."""
    pins, block = [], ""
    for raw in text.splitlines():
        if raw and not raw.startswith((" ", "#")):
            m = re.match(r"^([A-Za-z0-9_.-]+)==([^\s;\\]+)(.*)$", raw)
            if m and "implementation_name != 'cpython'" not in m.group(3) and "sys_platform == 'win32'" not in m.group(3):
                pins.append((m.group(1).lower().replace("_", "-"), m.group(2)))
    return pins


def requirement_items(ytdlp_version, have):
    """Every package pinned by upstream's macOS build (bundle/requirements/*.txt in the git tag), fetched from PyPI with PyPI's own sha256. Also the git-tag archive itself: it holds the build recipe."""
    tag_url = f"https://github.com/yt-dlp/yt-dlp/archive/refs/tags/{ytdlp_version}.tar.gz"
    tag = get(tag_url)
    items = [{"id": "yt-dlp-git-tag", "name": "yt-dlp (git tag archive: build recipe and pinned requirements)", "version": ytdlp_version, "license": "Unlicense",
              "url": tag_url, "filename": f"yt-dlp-{ytdlp_version}-git-tag.tar.gz", "expectedSHA256": None, "verifiedBy": "none", "builds": "the recipe for yt-dlp_macos: .github/workflows/build.yml (job macos), bundle/pyinstaller.py, bundle/requirements/",
              "recipe": "runs-on macos-14; pinned wheels from bundle/requirements/macos.txt; universal2 cffi and curl_cffi fused with delocate; python3 -m bundle.pyinstaller --target-architecture universal2 --onedir"}]
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "tag.tar.gz")
        open(path, "wb").write(tag)
        with tarfile.open(path) as t:
            members = {os.path.basename(m.name): m for m in t.getmembers() if "/bundle/requirements/" in m.name and m.name.endswith(".txt")}
            texts = {n: t.extractfile(m).read().decode() for n, m in members.items() if n in ("macos.txt", "macos-curl_cffi.txt", "pyinstaller.txt", "delocate.txt")}
    seen = set(have)
    for fname in ("macos.txt", "macos-curl_cffi.txt", "pyinstaller.txt"):
        for name, version in parse_requirements(texts.get(fname, "")):
            key = {"pycryptodome": "pycryptodomex"}.get(name, name)
            if key in seen or key in ("mutagen", "yt-dlp-ejs", "curl-cffi"):
                continue
            seen.add(key)
            lic = "see upstream's THIRD_PARTY_LICENSES.txt" + ("; PyInstaller's bootloader (GPL-2.0-or-later with the PyInstaller exception) is inside the yt-dlp_macos executable" if name == "pyinstaller" else "")
            try:
                url, digest, filename = pypi(name, version)
                items.append({"id": key, "name": name, "version": version, "license": lic, "url": url, "filename": filename, "expectedSHA256": digest, "verifiedBy": "pypi", "builds": f"pinned in bundle/requirements/{fname}", "recipe": "see the archive"})
            except Exception as e:
                items.append({"id": key, "name": name, "version": version, "license": lic, "url": None, "filename": None, "expectedSHA256": None, "verifiedBy": "none", "builds": f"pinned in bundle/requirements/{fname}", "error": f"no source distribution on PyPI ({type(e).__name__})"})
    return items


def sources():
    """The components whose source this project redistributes or must offer, with how each is fetched and verified."""
    ff = template("ffmpeg")
    yt = template("yt-dlp")
    items = [
        {"id": "ffmpeg", "name": "FFmpeg", "version": ff["version"], "license": "LGPL-2.1-or-later (this build: --disable-gpl --disable-nonfree --disable-version3)",
         "url": ff["sourceArchive"], "filename": os.path.basename(ff["sourceArchive"]), "expectedSHA256": ff["sourceArchiveSHA256"], "verifiedBy": "repo-pin",
         "builds": "apps/apple/ThirdParty/ffmpeg/bin/ffmpeg/{ffmpeg,ffprobe}", "recipe": "scripts/build-ffmpeg-minimal.sh (exact configure line is in BUILDINFO.txt inside the package)"},
    ]
    ver = yt["version"]
    sums = get(f"https://github.com/yt-dlp/yt-dlp/releases/download/{ver}/SHA2-256SUMS", binary=False)
    line = next((l for l in sums.splitlines() if l.strip().endswith("yt-dlp.tar.gz")), None)
    items.append({"id": "yt-dlp", "name": "yt-dlp", "version": ver, "license": "Unlicense (the PyInstaller executable that bundles it is GPL-3.0-or-later per upstream)",
                  "url": f"https://github.com/yt-dlp/yt-dlp/releases/download/{ver}/yt-dlp.tar.gz", "filename": f"yt-dlp-{ver}.tar.gz", "expectedSHA256": line.split()[0] if line else None,
                  "verifiedBy": "release-sums" if line else "none", "builds": "Tools/yt-dlp/ (yt-dlp_macos and the Python code inside its archive)",
                  "recipe": "upstream's release workflow .github/workflows/build.yml in this tarball; we only thin to arm64, restore the Python.framework layout and re-sign (scripts/release-media-tools.sh)"})
    for pid, project, version, note, builds in (
        ("mutagen", "mutagen", "1.48.1", "GPL-2.0-or-later: the one GPL component upstream's licence file lists for the macOS build", "Python code inside yt-dlp_macos's archive"),
        ("yt-dlp-ejs", "yt-dlp-ejs", "0.8.0", "Unlicense (bundles Meriyah ISC and Astring MIT in its solver scripts)", "Tools/yt-dlp/_internal/yt_dlp_ejs/yt/solver/{lib,core}.min.js"),
        ("curl_cffi", "curl_cffi", "0.17.0", "MIT; its _wrapper.abi3.so statically contains curl-impersonate, curl, BoringSSL and nghttp2 (see SOURCES notes)", "Tools/yt-dlp/_internal/curl_cffi/_wrapper.abi3.so"),
    ):
        try:
            url, digest, filename = pypi(project, version)
            items.append({"id": pid, "name": project, "version": version, "license": note, "url": url, "filename": filename, "expectedSHA256": digest, "verifiedBy": "pypi", "builds": builds, "recipe": "see the archive"})
        except Exception as e:
            items.append({"id": pid, "name": project, "version": version, "license": note, "url": None, "filename": None, "expectedSHA256": None, "verifiedBy": "none", "builds": builds, "error": str(e)})
    items.extend(requirement_items(ver, {i["id"] for i in items}))
    items.append({"id": "lame", "name": "LAME", "version": "3.100", "license": "LGPL-2.1", "url": "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz",
                  "filename": "lame-3.100.tar.gz", "expectedSHA256": None, "verifiedBy": "none",
                  "builds": "Contents/Frameworks/libmp3lame.dylib (built by this project's Xcode target MP3Lame from apps/apple/ThirdParty/lame)", "recipe": "apps/apple/project.yml target MP3Lame; sources in apps/apple/ThirdParty/lame"})
    return items


def cmd_fetch(a):
    os.makedirs(a.out, exist_ok=True)
    result = []
    for it in sources():
        row = dict(it)
        if not it.get("url"):
            row["status"] = "NOT FETCHED: " + it.get("error", "no URL"); result.append(row); print(f"  {it['id']:12} {row['status']}"); continue
        path = os.path.join(a.out, it["filename"])
        try:
            data = open(path, "rb").read() if os.path.exists(path) else get(it["url"])
            got = sha256(data)
            row.update(sha256=got, size=len(data))
            if it["expectedSHA256"] and got != it["expectedSHA256"]:
                row["status"] = f"REFUSED: sha256 {got} != expected {it['expectedSHA256']} ({it['verifiedBy']})"
            else:
                open(path, "wb").write(data)
                row["status"] = "verified" if it["expectedSHA256"] else "downloaded, digest RECORDED ONLY (no independent digest exists)"
        except Exception as e:
            row["status"] = f"NOT FETCHED: {type(e).__name__}: {e}"
        result.append(row); print(f"  {it['id']:12} {it['version']:10} {row['status']}")
    json.dump({"generated": "see file time", "note": "staging folder for a release's source assets; not a legal opinion", "archives": result}, open(os.path.join(a.out, "SOURCES.json"), "w"), indent=2)
    bad = [r["id"] for r in result if not r["status"].startswith(("verified", "downloaded"))]
    print(f"  {len(result)} archives; not fetched or refused: {bad or 'none'}")
    return 0 if not bad else 1


# ---------------- the map ----------------

RULES = [  # (path regex, component, source ids, licence)
    (r"(^|/)yt-dlp_macos$", "yt-dlp executable (PyInstaller bootloader + archive of yt-dlp and its Python dependencies)", ["yt-dlp", "yt-dlp-git-tag", "mutagen", "yt-dlp-ejs", "pyinstaller"], "GPL-3.0-or-later (combined, per upstream)"),
    (r"(^|/)Python\.framework/|(^|/)python3\.\d+/lib-dynload/|(^|/)Python$", "CPython runtime and its extension modules", ["python"], "PSF-2.0"),
    (r"libssl\.3\.dylib$|libcrypto\.3\.dylib$", "OpenSSL 3", ["openssl"], "Apache-2.0"),
    (r"libzstd\.1\.dylib$", "Zstandard", ["zstd"], "BSD-3-Clause (dual BSD / GPL-2.0; BSD elected)"),
    (r"_brotli\..*\.so$", "Brotli Python binding", ["brotli"], "MIT"),
    (r"_cffi_backend\..*\.so$", "cffi", ["cffi"], "MIT"),
    (r"curl_cffi/.*\.so$", "curl_cffi wrapper (statically contains curl-impersonate, curl, BoringSSL, nghttp2)", ["curl_cffi", "curl-impersonate"], "MIT (and the licences of the statically contained components)"),
    (r"charset_normalizer/.*\.so$", "charset-normalizer extensions", ["charset-normalizer"], "MIT"),
    (r"Cryptodome/.*\.so$", "PyCryptodome extensions", ["pycryptodomex"], "Public domain and BSD-2-Clause"),
    (r"websockets/.*\.so$", "websockets speedups", ["websockets"], "BSD-3-Clause"),
    (r"(^|/)(ffmpeg|ffprobe)$", "FFmpeg program", ["ffmpeg"], "LGPL-2.1-or-later (configured LGPL-only)"),
    (r"libmp3lame\.dylib$", "LAME MP3 encoder library", ["lame"], "LGPL-2.1"),
]
EXTERNAL = {  # components we do not mirror: where their source lives, and why
    "python": {"url": "https://www.python.org/downloads/source/", "note": "permissive licence (PSF-2.0); attribution only"},
    "openssl": {"url": "https://www.openssl.org/source/", "note": "Apache-2.0; attribution only"},
    "zstd": {"url": "https://github.com/facebook/zstd", "note": "BSD-3-Clause elected"},
    "curl-impersonate": {"url": "https://github.com/lexiforest/curl-impersonate", "note": "MIT; the exact version bundled by curl_cffi 0.17.0 is NOT verified here"},
}


def macho_files(root):
    out = []
    for d, _, files in os.walk(root):
        for n in files:
            p = os.path.join(d, n)
            if os.path.islink(p):
                continue
            if "Mach-O" in subprocess.run(["/usr/bin/file", "-b", p], capture_output=True, text=True).stdout:
                out.append(p)
    return sorted(out)


def cmd_map(a):
    app = a.app
    roots = [os.path.join(app, "Contents", "Resources", "Tools"), os.path.join(app, "Contents", "Frameworks")]
    rows, unmapped = [], []
    for root in roots:
        for p in macho_files(root) if os.path.isdir(root) else []:
            rel = os.path.relpath(p, os.path.join(app, "Contents"))
            if "Sparkle.framework" in rel or "Autoupdate" in rel or "Updater.app" in rel or "XPCServices" in rel or "SetuPrivacy" in rel:
                continue                       # not media tools; the app's own and Sparkle's notices are separate
            rule = next((r for r in RULES if re.search(r[0], rel)), None)
            if not rule:
                unmapped.append(rel); continue
            with open(p, "rb") as f:
                digest = sha256(f.read())
            rows.append({"path": rel, "sha256": digest, "size": os.path.getsize(p), "component": rule[1], "sources": rule[2], "license": rule[3]})
    ids = {r["id"] for r in json.load(open(os.path.join(a.out, "SOURCES.json")))["archives"]} if os.path.exists(os.path.join(a.out, "SOURCES.json")) else set()
    used = sorted({s for r in rows for s in r["sources"]})
    missing = [s for s in used if s not in ids and s not in EXTERNAL]
    by_comp = {}
    for r in rows:
        by_comp.setdefault(r["component"], 0); by_comp[r["component"]] += 1
    out = {"app": os.path.basename(app), "files": len(rows), "unmapped": unmapped, "sourcesWithoutAnyRecord": missing, "externalSources": {k: EXTERNAL[k] for k in used if k in EXTERNAL}, "components": by_comp, "map": rows}
    os.makedirs(a.out, exist_ok=True)
    json.dump(out, open(os.path.join(a.out, "BINARY-TO-SOURCE.json"), "w"), indent=2)
    print(f"  {len(rows)} Mach-O files mapped to {len(used)} source components; unmapped: {len(unmapped)}; sources with no record: {missing or 'none'}")
    for c, n in sorted(by_comp.items()):
        print(f"    {n:4d}  {c}")
    return 1 if unmapped or missing else 0


def cmd_verify_lame(a):
    path = os.path.join(a.out, "lame-3.100.tar.gz")
    if not os.path.exists(path):
        print("  fetch the LAME archive first"); return 2
    mine = os.path.join(ROOT, "apps", "apple", "ThirdParty", "lame")
    same, differ, only_mine = [], [], []
    with tarfile.open(path) as t, tempfile.TemporaryDirectory() as tmp:
        t.extractall(tmp, filter="data") if sys.version_info >= (3, 12) else t.extractall(tmp)
        up = os.path.join(tmp, "lame-3.100")
        for d, _, files in os.walk(mine):
            for n in files:
                p = os.path.join(d, n); rel = os.path.relpath(p, mine)
                cand = [os.path.join(up, rel), os.path.join(up, "libmp3lame", os.path.relpath(rel, "libmp3lame")) if not rel.startswith("libmp3lame") else None, os.path.join(up, "include", n)]
                q = next((c for c in cand if c and os.path.isfile(c)), None)
                if not q:
                    only_mine.append(rel)
                elif open(p, "rb").read() == open(q, "rb").read():
                    same.append(rel)
                else:
                    differ.append(rel)
    print(f"  LAME: {len(same)} files identical to the upstream 3.100 tarball, {len(differ)} differ, {len(only_mine)} only in this repository")
    for x in differ: print("    DIFFERS:", x)
    for x in only_mine: print("    ONLY HERE:", x)
    json.dump({"identical": same, "differ": differ, "onlyInRepository": only_mine}, open(os.path.join(a.out, "LAME-COMPARISON.json"), "w"), indent=2)
    return 0 if not differ else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("fetch", cmd_fetch), ("map", cmd_map), ("verify-lame", cmd_verify_lame)):
        s = sub.add_parser(name); s.add_argument("--out", default=os.path.join(ROOT, "build", "media-sources"))
        if name == "map": s.add_argument("--app", required=True)
        s.set_defaults(f=fn)
    a = ap.parse_args()
    sys.exit(a.f(a))


if __name__ == "__main__":
    main()
