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
  upstream-pin  the sha256 the upstream build recipe itself pins (curl-impersonate's CMakeLists.txt at the tag curl_cffi 0.17.0 names)
  publisher     a digest the publisher releases next to the file (openssl's .sha256, python.org's signed-release SPDX document)
  debian-dsc    the sha256 in Debian's source record for the same upstream tarball
  tag-commit    a GitHub tag archive whose top folder must carry the commit id the GitHub API reports for the tag
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


def lame_digest():
    """Debian's signed source record for lame 3.100 lists the sha256 of the unmodified upstream tarball (lame_3.100.orig.tar.gz): a channel independent of SourceForge."""
    dsc = get("https://deb.debian.org/debian/pool/main/l/lame/lame_3.100-6.dsc", binary=False)
    m = re.search(r"Checksums-Sha256:\n(?:\s+\w+ \d+ \S+\n)*?\s+([0-9a-f]{64}) \d+ lame_3\.100\.orig\.tar\.gz", dsc)
    return m.group(1) if m else None


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
    items.extend(runtime_items())
    items.append({"id": "lame", "name": "LAME", "version": "3.100", "license": "LGPL-2.1", "url": "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz",
                  "filename": "lame-3.100.tar.gz", "expectedSHA256": lame_digest(), "verifiedBy": "debian-dsc",
                  "builds": "Contents/Frameworks/libmp3lame.dylib (built by this project's Xcode target MP3Lame from apps/apple/ThirdParty/lame)", "recipe": "apps/apple/project.yml target MP3Lame; sources in apps/apple/ThirdParty/lame"})
    return items


CURL_IMPERSONATE = "v2.3.1"          # curl_cffi 0.17.0: scripts/build.py  __version__ = "2.3.1"  (the upstream libcurl-impersonate it downloads)


def runtime_items():
    """CPython and OpenSSL (versions read from the shipped binaries), and curl-impersonate with every dependency its build recipe pins."""
    items = []
    spdx = json.loads(get("https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tgz.spdx.json", binary=False))
    py = next(p for p in spdx["packages"] if p["name"] == "CPython")
    items.append({"id": "python", "name": "CPython", "version": "3.14.7", "license": "PSF-2.0", "url": py["downloadLocation"], "filename": "Python-3.14.7.tgz",
                  "expectedSHA256": next(c["checksumValue"] for c in py["checksums"] if c["algorithm"] == "SHA256"), "verifiedBy": "publisher",
                  "builds": "Python.framework and python3.14/lib-dynload inside yt-dlp_macos (version read from the shipped binary)", "recipe": "python.org's macOS build, as bundled by upstream's PyInstaller workflow"})
    sums = get("https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz.sha256", binary=False).split()[0]
    items.append({"id": "openssl", "name": "OpenSSL", "version": "3.5.7", "license": "Apache-2.0", "url": "https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz",
                  "filename": "openssl-3.5.7.tar.gz", "expectedSHA256": sums, "verifiedBy": "publisher", "builds": "libssl.3.dylib, libcrypto.3.dylib (version read from the shipped binary)", "recipe": "see the archive"})
    sha = json.loads(get(f"https://api.github.com/repos/lexiforest/curl-impersonate/git/ref/tags/{CURL_IMPERSONATE}", binary=False))["object"]["sha"]
    items.append({"id": "curl-impersonate", "name": "curl-impersonate (lexiforest)", "version": CURL_IMPERSONATE[1:], "license": "MIT", "url": f"https://github.com/lexiforest/curl-impersonate/archive/refs/tags/{CURL_IMPERSONATE}.tar.gz",
                  "filename": f"curl-impersonate-{CURL_IMPERSONATE[1:]}.tar.gz", "expectedSHA256": None, "expectedTagCommit": sha, "verifiedBy": "tag-commit",
                  "builds": "curl_cffi/_wrapper.abi3.so (statically; shipped libcurl reports 8.23.0-IMPERSONATE)", "recipe": "CMakeLists.txt, patches/ and docs/ in the archive"})
    cm = get(f"https://raw.githubusercontent.com/lexiforest/curl-impersonate/{CURL_IMPERSONATE}/CMakeLists.txt", binary=False)
    def var(name): return re.search(rf'set\({name} "([^"]+)"\)', cm).group(1)
    def hashed(name): return var(name + "_URL_HASH").split("=", 1)[1]
    z, zs, b, nh2, nq, nh3, ca = var("ZLIB_VERSION"), var("ZSTD_VERSION"), var("BROTLI_VERSION"), var("NGHTTP2_VERSION"), var("NGTCP2_VERSION"), var("NGHTTP3_VERSION"), var("CARES_VERSION")
    curl, bs = var("CURL_VERSION"), var("BORINGSSL_COMMIT")
    dep = lambda i, n, v, lic, url, fn, h: {"id": i, "name": n, "version": v, "license": lic, "url": url, "filename": fn, "expectedSHA256": h, "verifiedBy": "upstream-pin",
                                           "builds": "statically inside curl_cffi/_wrapper.abi3.so (via curl-impersonate " + CURL_IMPERSONATE + ")", "recipe": "curl-impersonate CMakeLists.txt"}
    items += [
        dep("curl", "curl", curl.replace("curl-", "").replace("_", "."), "curl licence (MIT-style)", f"https://github.com/curl/curl/archive/{curl}.tar.gz", f"{curl}.tar.gz", hashed("CURL")),
        dep("boringssl", "BoringSSL", bs[:12], "OpenSSL/ISC-style (see the archive's LICENSE)", f"https://github.com/google/boringssl/archive/{bs}.zip", f"boringssl-{bs[:12]}.zip", hashed("BORINGSSL")),
        dep("nghttp2", "nghttp2", nh2, "MIT", f"https://github.com/nghttp2/nghttp2/releases/download/v{nh2}/nghttp2-{nh2}.tar.bz2", f"nghttp2-{nh2}.tar.bz2", hashed("NGHTTP2")),
        dep("ngtcp2", "ngtcp2", nq, "MIT", f"https://github.com/ngtcp2/ngtcp2/releases/download/v{nq}/ngtcp2-{nq}.tar.bz2", f"ngtcp2-{nq}.tar.bz2", hashed("NGTCP2")),
        dep("nghttp3", "nghttp3", nh3, "MIT", f"https://github.com/ngtcp2/nghttp3/releases/download/v{nh3}/nghttp3-{nh3}.tar.bz2", f"nghttp3-{nh3}.tar.bz2", hashed("NGHTTP3")),
        dep("zlib", "zlib", z, "Zlib", f"https://github.com/madler/zlib/releases/download/v{z}/zlib-{z}.tar.gz", f"zlib-{z}.tar.gz", hashed("ZLIB")),
        dep("zstd", "Zstandard", zs, "BSD-3-Clause (dual BSD / GPL-2.0; BSD elected)", f"https://github.com/facebook/zstd/releases/download/v{zs}/zstd-{zs}.tar.gz", f"zstd-{zs}.tar.gz", hashed("ZSTD")),
        dep("brotli-c", "Brotli (C library)", b, "MIT", f"https://github.com/google/brotli/archive/refs/tags/v{b}.tar.gz", f"brotli-c-{b}.tar.gz", hashed("BROTLI")),
        dep("c-ares", "c-ares", ca, "MIT", f"https://github.com/c-ares/c-ares/releases/download/v{ca}/c-ares-{ca}.tar.gz", f"c-ares-{ca}.tar.gz", hashed("CARES")),
    ]
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
            if it.get("expectedTagCommit"):
                import tarfile, io
                with tarfile.open(fileobj=io.BytesIO(data)) as t:
                    t.getnames(); carried = t.pax_headers.get("comment", "")      # GitHub writes the commit it archived into the tar's global header
                if carried != it["expectedTagCommit"]:
                    row["status"] = f"REFUSED: archive carries commit {carried!r}, the tag is {it['expectedTagCommit']}"
                else:
                    open(path, "wb").write(data); row["status"] = f"verified (tag {it['version']} = commit {it['expectedTagCommit'][:12]}; sha256 recorded)"
            elif it["expectedSHA256"] and got != it["expectedSHA256"]:
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
    (r"curl_cffi/.*\.so$", "curl_cffi wrapper (statically contains curl-impersonate, curl, BoringSSL, nghttp2)", ["curl_cffi", "curl-impersonate", "curl", "boringssl", "nghttp2", "ngtcp2", "nghttp3", "zlib", "zstd", "brotli-c", "c-ares"], "MIT (and the licences of the statically contained components)"),
    (r"charset_normalizer/.*\.so$", "charset-normalizer extensions", ["charset-normalizer"], "MIT"),
    (r"Cryptodome/.*\.so$", "PyCryptodome extensions", ["pycryptodomex"], "Public domain and BSD-2-Clause"),
    (r"websockets/.*\.so$", "websockets speedups", ["websockets"], "BSD-3-Clause"),
    (r"(^|/)(ffmpeg|ffprobe)$", "FFmpeg program", ["ffmpeg"], "LGPL-2.1-or-later (configured LGPL-only)"),
    (r"libmp3lame\.dylib$", "LAME MP3 encoder library", ["lame"], "LGPL-2.1"),
]
EXTERNAL = {  # components we do not mirror: where their source lives, and why
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


YTDLP_KEY_FPR = "AC0CBBE6848D6A873464AF4E57CF65933B5A7581"      # yt-dlp signing key (Simon Sawicki), as published in yt-dlp's public.key

def cmd_verify_gpg(a):
    """Checks upstream's GPG signature on the release's SHA2-256SUMS with a throwaway keyring, and that the signing key is the pinned fingerprint. Needs gpg."""
    ver = template("yt-dlp")["version"]
    with tempfile.TemporaryDirectory() as d:
        os.chmod(d, 0o700)
        for name, url in (("SHA2-256SUMS", f"https://github.com/yt-dlp/yt-dlp/releases/download/{ver}/SHA2-256SUMS"), ("SHA2-256SUMS.sig", f"https://github.com/yt-dlp/yt-dlp/releases/download/{ver}/SHA2-256SUMS.sig"), ("public.key", "https://github.com/yt-dlp/yt-dlp/raw/master/public.key")):
            open(os.path.join(d, name), "wb").write(get(url))
        env = dict(os.environ, GNUPGHOME=d)
        run = lambda *args: subprocess.run(["gpg", "--batch", *args], env=env, cwd=d, capture_output=True, text=True)
        run("--import", "public.key")
        v = run("--status-fd", "1", "--verify", "SHA2-256SUMS.sig", "SHA2-256SUMS")
        good = "[GNUPG:] GOODSIG" in v.stdout
        valid = [l.split() for l in v.stdout.splitlines() if l.startswith("[GNUPG:] VALIDSIG")]
        fpr = valid[0][2] if valid else ""
        ok = good and fpr == YTDLP_KEY_FPR
        print(f"  yt-dlp {ver}: SHA2-256SUMS signature " + ("GOOD, key " + fpr if ok else f"NOT VERIFIED (good={good}, key={fpr!r})") + "  (the key is taken from yt-dlp's own repository: trust in it is as strong as that channel, not independently certified)")
        return 0 if ok else 1


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
    for name, fn in (("fetch", cmd_fetch), ("map", cmd_map), ("verify-lame", cmd_verify_lame), ("verify-gpg", cmd_verify_gpg)):
        s = sub.add_parser(name); s.add_argument("--out", default=os.path.join(ROOT, "build", "media-sources"))
        if name == "map": s.add_argument("--app", required=True)
        s.set_defaults(f=fn)
    a = ap.parse_args()
    sys.exit(a.f(a))


if __name__ == "__main__":
    main()
