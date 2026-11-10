#!/usr/bin/env python3
"""Browser Setu media tools: the content-addressed cache of signed + notarized packages, the manifest generator, and the built-app preflight.

This is the ONE place that decides whether a package may be reused, what a shipped manifest says, and whether a built .app is releasable. The shell scripts
(release-media-tools.sh, embed-media-tools.sh, check-media-tools.sh, release.sh) only call it. Standard library only; nothing here signs or contacts Apple except
`lookup --online`, which asks notarytool about a submission that already exists.

Cache entry:  <cache>/<tool>/<version>-<arch>-<key16>/{package.zip, fragment.json, meta.json, notarization.json}
Key:          sha256 of the inputs that decide what the package contains: tool, version, arch, Team ID, the digest of the unsigned upstream tree, the packaging recipe
              (the RECIPE-BEGIN..RECIPE-END block of release-media-tools.sh) and tree_digest.py. A change in any of them is a different key, so it is rebuilt;
              nothing else (a new certificate of the same team, an edit elsewhere in a script) forces a re-sign.
Reuse:        only after the entry is re-verified from the bytes: zip digest, tree digest, every Mach-O's signature, Team ID, hardened runtime, Developer ID chain,
              exact architecture, and a notarization record that names this very zip digest. Any doubt is "invalid", never "probably fine".
"""
import argparse, hashlib, json, os, re, shutil, stat, subprocess, sys, tempfile, time, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
THIRD = os.path.join(ROOT, "apps", "apple", "ThirdParty")
DEFAULT_CACHE = os.path.expanduser("~/Library/Caches/BrowserSetu/media-tools")
TOOLS = ("yt-dlp", "ffmpeg")              # embedded in every release app: `--tool all`, the embed script and the app preflight cover exactly these
OPTIONAL_TOOLS = ("deno",)                # prepared for a possible managed JavaScript runtime; NOT embedded, NOT built by `--tool all`, NOT checked by the app preflight
ALL_TOOLS = TOOLS + OPTIONAL_TOOLS
MANIFEST_RESOURCE = {"yt-dlp": "BundledTools.json", "ffmpeg": "BundledFFmpeg.json", "deno": "BundledDeno.json"}
ENTITLEMENTS = {"deno": os.path.join(HERE, "media-tools-entitlements", "deno.entitlements")}
SCHEMA = 2
TEAM_RE = re.compile(r"^[A-Z0-9]{10}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
# The only keys a SHIPPED manifest may contain. Anything else in a source template (upstream notes, "not hosted yet" text, the upstream asset digest) is dropped, never carried.
MANIFEST_KEYS = ["schemaVersion", "name", "version", "layout", "executable", "sourceURL", "sha256", "treeSHA256", "size", "unpackedBytes", "architectures",
                 "signaturePolicy", "minimumMacOS", "license", "sourceArchive", "sourceArchiveSHA256", "sourceLicense", "binaryLicenseNote", "javascriptRuntime", "notarization", "forYtDlp"]
REQUIRED_SHIPPED = ["schemaVersion", "name", "version", "layout", "executable", "sourceURL", "sha256", "treeSHA256", "size", "unpackedBytes", "architectures", "signaturePolicy"]
STALE_MARKERS = ("not hosted yet", "until then", "placeholder", "adhoc", "ad-hoc", "re-signed with the release identity")


class Fail(Exception):
    pass


def run(args, check=True, **kw):
    p = subprocess.run(args, capture_output=True, text=True, **kw)
    if check and p.returncode != 0:
        raise Fail(f"{' '.join(map(str, args))} failed: {(p.stderr or p.stdout).strip()[:400]}")
    return p


def load_json(path):
    with open(path) as f:
        return json.load(f)


def write_json(path, obj, **kw):
    with open(path, "w") as f:
        json.dump(obj, f, **kw)
        f.write("\n")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_digest(path):
    return run([sys.executable, "-I", os.path.join(HERE, "tree_digest.py"), path]).stdout.split()[0]


def recipe_digest():
    with open(os.path.join(HERE, "release-media-tools.sh")) as f:
        text = f.read()
    m = re.search(r"# RECIPE-BEGIN.*?# RECIPE-END", text, re.S)
    if not m:
        raise Fail("release-media-tools.sh has no RECIPE-BEGIN..RECIPE-END block, so the packaging recipe cannot be fingerprinted")
    # The optional per-tool entitlements argument (empty for yt-dlp and ffmpeg) is taken out before hashing, so adding it did not change the key of packages that were already signed and notarized.
    # A tool that uses entitlements has them fingerprinted in its own inputs (input_identity).
    return hashlib.sha256(m.group(0).replace(' ${ENT:+--entitlements "$ENT"}', "").encode()).hexdigest()


def template(tool):
    return load_json(os.path.join(THIRD, tool, "MANIFEST.json"))


# ---------- Mach-O inspection (replaceable in tests) ----------

def is_macho(path):
    return "Mach-O" in run(["/usr/bin/file", "-b", path]).stdout


def macho_files(root):
    out = []
    for d, _, files in os.walk(root):
        for n in files:
            p = os.path.join(d, n)
            if os.path.islink(p):
                continue
            if is_macho(p):
                out.append(p)
    return sorted(out)


def macho_info(path):
    """Everything the checks need about one signed Mach-O: verify result, team, flags, authorities, architectures."""
    ver = run(["/usr/bin/codesign", "--verify", "--strict", path], check=False)
    d = run(["/usr/bin/codesign", "-dvv", path], check=False)
    text = (d.stdout or "") + (d.stderr or "")
    arch = run(["/usr/bin/lipo", "-archs", path], check=False).stdout.split()
    return {
        "verified": ver.returncode == 0, "verify_error": (ver.stderr or "").strip()[:200],
        "team": (re.search(r"^TeamIdentifier=(.*)$", text, re.M) or [None, ""])[1],
        "runtime": bool(re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", text)),
        "adhoc": "Signature=adhoc" in text or "flags=0x2(adhoc" in text or "(adhoc" in text,
        "authorities": re.findall(r"^Authority=(.*)$", text, re.M), "archs": arch, "timestamp": "Timestamp=" in text,
    }


def check_macho(path, rel, team, archs, problems):
    i = macho_info(path)
    if not i["verified"]:
        problems.append(f"{rel}: signature does not verify ({i['verify_error']})")
    if i["adhoc"] or not i["authorities"]:
        problems.append(f"{rel}: ad-hoc or unsigned (a Developer ID signature is required)")
    if i["team"] != team:
        problems.append(f"{rel}: Team ID is '{i['team']}', expected {team}")
    if not i["runtime"]:
        problems.append(f"{rel}: hardened runtime is missing")
    if not i["timestamp"]:
        problems.append(f"{rel}: no secure timestamp (notarization requires one)")
    auth = i["authorities"]
    if not (auth and auth[0].startswith("Developer ID Application:") and "Developer ID Certification Authority" in auth and "Apple Root CA" in auth):
        problems.append(f"{rel}: certificate chain is not Developer ID Application -> Developer ID CA -> Apple Root CA ({auth})")
    if sorted(i["archs"]) != sorted(archs):
        problems.append(f"{rel}: architectures {i['archs']} != required {archs}")


# ---------- the cache ----------

def input_identity(tool):
    """The pinned facts that decide what a package contains. They come from the committed templates and scripts, so a clean checkout (no downloaded or built tree yet)
    can still recognise and reuse a cached package. The local tree is compared with these pins only when a rebuild is needed (verify_inputs)."""
    t = template(tool)
    if tool == "yt-dlp":
        if not SHA_RE.match(str(t.get("treeSHA256", ""))):
            raise Fail("ThirdParty/yt-dlp/MANIFEST.json has no pinned treeSHA256")
        return {"pinnedUpstreamTree": t["treeSHA256"], "upstreamAssetSHA256": t["sha256"]}
    if tool == "deno":
        up = t.get("upstream") or {}
        if not SHA_RE.match(str(up.get("sha256", ""))):
            raise Fail("ThirdParty/deno/MANIFEST.json has no pinned upstream sha256")
        return {"upstreamAssetSHA256": up["sha256"], "entitlements": sha256_file(ENTITLEMENTS["deno"])}
    if not SHA_RE.match(str(t.get("sourceArchiveSHA256", ""))):
        raise Fail("ThirdParty/ffmpeg/MANIFEST.json has no sourceArchiveSHA256")
    return {"sourceArchiveSHA256": t["sourceArchiveSHA256"], "buildScript": sha256_file(os.path.join(HERE, "build-ffmpeg-minimal.sh"))}


def verify_inputs(tool):
    """Before a (re)build: the unsigned tree on disk must be exactly what the pins describe."""
    t = template(tool)
    p = os.path.join(THIRD, tool, "bin", tool)
    if not os.path.isdir(p):
        raise Fail(f"the unsigned {tool} tree is missing: {p} (scripts/fetch-bundled-tools.sh for yt-dlp, scripts/build-ffmpeg-minimal.sh {THIRD}/ffmpeg/bin/ffmpeg for ffmpeg)")
    if tool == "yt-dlp":
        got = tree_digest(p)
        if got != t["treeSHA256"]:
            raise Fail(f"the yt-dlp tree on disk ({got[:12]}…) is not the pinned upstream tree ({t['treeSHA256'][:12]}…); run scripts/fetch-bundled-tools.sh")
    elif tool == "deno":
        exe = os.path.join(p, "deno")
        if not os.path.isfile(exe):
            raise Fail(f"{exe} is missing: unpack the pinned upstream asset there (deno-aarch64-apple-darwin.zip, sha256 {t['upstream']['sha256'][:12]}…)")
        info = macho_info(exe)
        if info["team"] != t["upstream"]["teamID"] or not info["verified"]:
            raise Fail(f"the Deno on disk is not signed by upstream's team {t['upstream']['teamID']} with a valid signature (team '{info['team']}'): it is not the pinned release")
        if info["archs"] != ["arm64"]:
            raise Fail(f"the Deno on disk is {info['archs']}, expected arm64")
        out = run([exe, "--version"]).stdout.splitlines()[0] if os.access(exe, os.X_OK) else ""
        if out.split(" (")[0] != f"deno {t['version']}":
            raise Fail(f"the Deno on disk reports '{out}', expected 'deno {t['version']}'")
    else:
        bi = os.path.join(p, "BUILDINFO.txt")
        info = open(bi).read() if os.path.isfile(bi) else ""
        if t["sourceArchiveSHA256"] not in info or "--disable-gpl" not in info or "--disable-nonfree" not in info or "--disable-version3" not in info:
            raise Fail("ffmpeg BUILDINFO.txt does not show the pinned source hash and the LGPL-only configuration; rebuild with scripts/build-ffmpeg-minimal.sh")
        if f"FFmpeg {t['version']} " not in info:
            raise Fail(f"ffmpeg BUILDINFO.txt is not version {t['version']}")


def cache_key(tool, arch, team):
    t = template(tool)
    inputs = {"schema": SCHEMA, "tool": tool, "version": t["version"], "arch": arch, "team": team, "inputs": input_identity(tool),
              "recipe": recipe_digest(), "treeDigestTool": sha256_file(os.path.join(HERE, "tree_digest.py"))}
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest(), inputs


def entry_dir(cache, tool, arch, team):
    key, inputs = cache_key(tool, arch, team)
    return os.path.join(cache, tool, f"{inputs['version']}-{arch}-{key[:16]}"), key, inputs


def verify_entry(entry, tool, arch, team, key=None, online_profile=None):
    """Return a list of problems; empty means the entry may be reused."""
    p = []
    names = {n: os.path.join(entry, n) for n in ("package.zip", "fragment.json", "meta.json", "notarization.json")}
    for n, path in names.items():
        if not os.path.isfile(path):
            p.append(f"missing {n}")
    if p:
        return p
    frag, meta, notary = (load_json(names[n]) for n in ("fragment.json", "meta.json", "notarization.json"))
    if key and meta.get("key") != key:
        p.append("entry key does not match the current inputs")
    zsha = sha256_file(names["package.zip"])
    if zsha != frag.get("sha256") or zsha != meta.get("zipSHA256"):
        p.append(f"package.zip digest {zsha[:12]}… differs from its recorded digest (corrupt or replaced)")
    if os.path.getsize(names["package.zip"]) != frag.get("size"):
        p.append("package.zip size differs from the fragment")
    if frag.get("signaturePolicy") != f"teamID:{team}" or frag.get("architectures") != [arch]:
        p.append(f"fragment says {frag.get('signaturePolicy')} / {frag.get('architectures')}, expected teamID:{team} / {[arch]}")
    if notary.get("status") != "Accepted" or notary.get("zipSHA256") != zsha or not notary.get("submissionID"):
        p.append("no notarization record that says Accepted for exactly this zip")
    if p:
        return p
    try:
        with zipfile.ZipFile(names["package.zip"]) as z:
            bad = z.testzip()
            if bad:
                p.append(f"corrupt zip member {bad}")
            for n in z.namelist():
                if n.startswith("/") or ".." in n.split("/"):
                    p.append(f"unsafe path in zip: {n}")
    except zipfile.BadZipFile as e:
        return p + [f"not a valid zip: {e}"]
    if p:
        return p
    with tempfile.TemporaryDirectory() as tmp:
        run(["/usr/bin/unzip", "-q", names["package.zip"], "-d", tmp])
        if tree_digest(tmp) != frag.get("treeSHA256"):
            p.append("unpacked files do not match the recorded tree digest (tampered or different)")
        exe = template(tool).get("executable")
        exe_path = os.path.join(tmp, exe)
        if not os.path.isfile(exe_path) or not os.access(exe_path, os.X_OK):
            p.append(f"main executable '{exe}' is missing or not executable")
        files = macho_files(tmp)
        if not files:
            p.append("the package contains no Mach-O files")
        for f in files:
            check_macho(f, os.path.relpath(f, tmp), team, [arch], p)
    if online_profile and not p:
        o = run(["xcrun", "notarytool", "info", notary["submissionID"], "--keychain-profile", online_profile, "--output-format", "json"], check=False)
        try:
            ok = json.loads(o.stdout).get("status") == "Accepted"
        except ValueError:
            ok = False
        if not ok:
            p.append("Apple does not report this submission as Accepted (checked online)")
    return p


def cmd_inputs(a):
    verify_inputs(a.tool)
    print(f"{a.tool}: unsigned inputs match their pins")


def cmd_key(a):
    key, inputs = cache_key(a.tool, a.arch, a.team)
    print(json.dumps({"key": key, "inputs": inputs}, indent=2))


def cmd_lookup(a):
    entry, key, _ = entry_dir(a.cache, a.tool, a.arch, a.team)
    if not os.path.isdir(entry):
        print(f"{a.tool}: no cached package for the current inputs (key {key[:16]})", file=sys.stderr)
        return 3
    problems = verify_entry(entry, a.tool, a.arch, a.team, key, a.online)
    if problems:
        print(f"{a.tool}: cached package is NOT reusable:", file=sys.stderr)
        for x in problems:
            print(f"  - {x}", file=sys.stderr)
        return 4
    print(entry)
    return 0


def cmd_store(a):
    """Put a freshly built, signed and notarized package into the cache (atomic: complete entry or none)."""
    entry, key, inputs = entry_dir(a.cache, a.tool, a.arch, a.team)
    frag = load_json(os.path.join(a.build, "manifest-fragment.json"))
    zips = [f for f in os.listdir(a.build) if f.endswith(".zip")]
    if len(zips) != 1:
        raise Fail(f"{a.build} must hold exactly one zip")
    zsha = sha256_file(os.path.join(a.build, zips[0]))
    notary = {"status": a.status, "submissionID": a.submission, "zipSHA256": zsha, "profile": a.profile or "", "recordedBy": "release-media-tools.sh --ensure"}
    meta = {"key": key, "inputs": inputs, "zipSHA256": zsha, "zipName": zips[0], "signer": a.signer or ""}
    stage = entry + ".partial"
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    shutil.copy2(os.path.join(a.build, zips[0]), os.path.join(stage, "package.zip"))
    for n, o in (("fragment.json", frag), ("meta.json", meta), ("notarization.json", notary)):
        write_json(os.path.join(stage, n), o, indent=2, sort_keys=True)
    problems = verify_entry(stage, a.tool, a.arch, a.team, key)
    if problems:
        shutil.rmtree(stage, ignore_errors=True)
        raise Fail("refusing to cache a package that does not verify: " + "; ".join(problems))
    shutil.rmtree(entry, ignore_errors=True)
    os.rename(stage, entry)
    print(entry)


# ---------- manifests ----------

def generate_manifest(tool, entry, hosted_url=None):
    frag = load_json(os.path.join(entry, "fragment.json"))
    t = template(tool)
    m = {k: t[k] for k in MANIFEST_KEYS if k in t}
    m.update({k: frag[k] for k in ("sha256", "treeSHA256", "size", "unpackedBytes", "architectures", "signaturePolicy")})
    m["schemaVersion"] = SCHEMA
    m["sourceURL"] = hosted_url or ""            # empty until the package is really hosted and verified; the app then offers no download
    if tool == "yt-dlp":
        m["minimumMacOS"] = "11.0"
    notary = load_json(os.path.join(entry, "notarization.json"))
    m["notarization"] = {"status": notary["status"], "submissionID": notary["submissionID"], "zipSHA256": notary["zipSHA256"]}
    problems = validate_manifest(m)
    if problems:
        raise Fail(f"generated {tool} manifest is invalid: " + "; ".join(problems))
    return m


def validate_manifest(m, expect_tool=None):
    p = []
    if not isinstance(m, dict):
        return ["not a JSON object"]
    for k in REQUIRED_SHIPPED:
        if k not in m:
            p.append(f"missing '{k}'")
    for k in m:
        if k not in MANIFEST_KEYS:
            p.append(f"unexpected key '{k}' (stale template field?)")
    if p:
        return p
    if m["schemaVersion"] != SCHEMA:
        p.append(f"schemaVersion {m['schemaVersion']} != {SCHEMA}")
    if m["name"] not in ALL_TOOLS or (expect_tool and m["name"] != expect_tool):
        p.append(f"name '{m['name']}' is not the expected tool")
    for k in ("sha256", "treeSHA256"):
        if not SHA_RE.match(str(m[k])):
            p.append(f"{k} is not a SHA-256")
    if not isinstance(m["size"], int) or m["size"] <= 0 or not isinstance(m["unpackedBytes"], int) or m["unpackedBytes"] <= 0:
        p.append("size/unpackedBytes must be positive integers")
    if not re.fullmatch(r"teamID:[A-Z0-9]{10}", str(m["signaturePolicy"])):
        p.append(f"signaturePolicy '{m['signaturePolicy']}' is not teamID:<TEAM>")
    if not m["architectures"] or not all(a in ("arm64", "x86_64") for a in m["architectures"]):
        p.append("architectures must be arm64 and/or x86_64")
    url = m["sourceURL"]
    if url and not re.match(r"^https://(github\.com|[a-z0-9.-]+\.githubusercontent\.com)/", url):
        p.append(f"sourceURL host is not one the installer approves: {url}")
    blob = json.dumps(m).lower()
    for s in STALE_MARKERS:
        if s in blob:
            p.append(f"manifest text contains stale marker '{s}'")
    return p


def cmd_manifest(a):
    entry = a.entry
    m = generate_manifest(a.tool, entry, a.hosted_url)
    write_json(a.out, m, indent=2)
    print(a.out)


def cmd_validate_manifest(a):
    problems = validate_manifest(load_json(a.file), a.tool)
    for x in problems:
        print(f"  - {x}", file=sys.stderr)
    return 1 if problems else 0


# ---------- the built app ----------

def app_arch(app):
    exe = os.path.join(app, "Contents", "MacOS", os.path.splitext(os.path.basename(app))[0])
    if not os.path.isfile(exe):
        cands = os.listdir(os.path.join(app, "Contents", "MacOS"))
        exe = os.path.join(app, "Contents", "MacOS", cands[0])
    return sorted(run(["/usr/bin/lipo", "-archs", exe]).stdout.split())


# ---------- the JavaScript challenge provider (setu-jsc + its yt-dlp plugin) ----------

def entitlements(path):
    """The entitlement keys a Mach-O is signed with (replaceable in tests)."""
    import plistlib
    raw = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", path], capture_output=True).stdout
    return sorted(plistlib.loads(raw[raw.index(b"<?xml"):]).keys()) if b"<?xml" in raw else []


def plugin_compatibility(plugin_path):
    """The provider's own COMPATIBILITY record: a literal assignment in the plugin file, found with the parser (not a pattern), so the one place it is written down cannot be truncated."""
    import ast
    with open(plugin_path, encoding="utf-8") as f:
        tree = ast.parse(f.read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "COMPATIBILITY" for t in node.targets):
            return ast.literal_eval(node.value)
    raise Fail("the plugin has no COMPATIBILITY record")


def helper_handshake(path):
    """What the helper says for --version (replaceable in tests)."""
    p = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10)
    return p.stdout.strip() if p.returncode == 0 else ""


def ytdlp_debug_header(app, plugin_folder):
    """What the embedded yt-dlp itself reports with -v, offline (an address that cannot connect): its version, the yt-dlp-ejs it carries, and the plugin directories it actually found. Replaceable in tests."""
    exe = os.path.join(app, "Contents", "Resources", "Tools", "yt-dlp", "yt-dlp_macos")
    env = {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": tempfile.gettempdir(), "PYTHONDONTWRITEBYTECODE": "1"}
    p = subprocess.run([exe, "--ignore-config", "--no-cache-dir", "--no-update", "--no-plugin-dirs", "--plugin-dirs", plugin_folder, "-v", "--simulate", "--skip-download",
                        "--socket-timeout", "2", "--retries", "0", "http://127.0.0.1:9/x"], capture_output=True, text=True, timeout=60, env=env, cwd=tempfile.gettempdir())
    return p.stdout + p.stderr


def helper_selftest(path):
    """Behaviour of the FINAL signed helper in the built app (not just its handshake): returns a list of problems. Replaceable in tests."""
    problems = []
    def run(args, data, timeout=15):
        t = time.time()
        p = subprocess.run([path, *args], input=data, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), time.time() - t
    rc, out, _ = run(["-"], b"console.log(JSON.stringify([1,2,3].map(x=>x*2)))")
    if (rc, out.strip()) != (0, "[2,4,6]"):
        problems.append(f"a normal script gave exit {rc}, output {out.strip()[:40]!r}")
    rc, _, _ = run(["--deadline", "0", "-"], b"1")
    if rc != 2:
        problems.append(f"an invalid deadline was not refused (exit {rc})")
    rc, _, dt = run(["--deadline", "1", "-"], b"while(true){}")
    if rc not in (-14, 142) or dt > 8:
        problems.append(f"the wall-clock limit did not end a busy loop (exit {rc}, {dt:.1f}s)")
    rc, _, _ = run(["--deadline", "20", "-"], b"for(;;)console.error(1)")
    if rc != 4:
        problems.append(f"a stderr flood was not stopped by the output limit (exit {rc})")
    rc, _, _ = run(["--deadline", "20", "-"], b"for(;;)console.log('x'.repeat(1e6))", timeout=30)
    if rc != 4:
        problems.append(f"a stdout flood was not stopped by the output limit (exit {rc})")
    return problems


def check_js_provider(app, team, archs, ytdlp_version, problems, notes):
    """True when the helper and plugin in the built app are exactly what BundledJSProvider.json pins and are signed and confined as required."""
    res = os.path.join(app, "Contents", "Resources")
    mf = os.path.join(res, "BundledJSProvider.json")
    before = len(problems)
    if not os.path.isfile(mf):
        problems.append("js-provider: BundledJSProvider.json is missing (scripts/embed-js-provider.sh was not run)")
        return False
    try:
        m = load_json(mf)
    except ValueError as e:
        problems.append(f"js-provider: manifest is not valid JSON ({e})")
        return False
    for k in ("name", "version", "providerVersion", "helperProtocol", "helper", "helperSHA256", "pluginTreeSHA256", "plugin", "pluginSHA256", "pluginDirectory", "architectures", "signaturePolicy", "entitlements", "pinnedYtDlpVersion"):
        if k not in m:
            problems.append(f"js-provider: manifest has no '{k}'")
    if len(problems) > before:
        return False
    if m["name"] != "setu-jsc" or m["signaturePolicy"] != f"teamID:{team}" or sorted(m["architectures"]) != sorted(archs):
        problems.append(f"js-provider: manifest says {m['name']} / {m['signaturePolicy']} / {m['architectures']}, expected setu-jsc / teamID:{team} / {archs}")
    if m["entitlements"] != ["com.apple.security.app-sandbox"]:
        problems.append(f"js-provider: manifest entitlements {m['entitlements']} are not exactly the App Sandbox")
    if m["pinnedYtDlpVersion"] != ytdlp_version:
        problems.append(f"js-provider: written for yt-dlp {m['pinnedYtDlpVersion']} but the app embeds yt-dlp {ytdlp_version}; its plugin uses yt-dlp internals and must be re-checked for every yt-dlp release")
    def safe(rel):
        return isinstance(rel, str) and rel != "" and not rel.startswith("/") and ".." not in rel.split("/") and "." not in rel.split("/") and "\0" not in rel
    if not (safe(m["helper"]) and safe(m["plugin"]) and safe(m["pluginDirectory"]) and "/" not in m["pluginDirectory"]):
        problems.append("js-provider: a manifest path is absolute, escapes the app, or the plugin folder is not a single named folder")
        return False
    helper = os.path.join(app, "Contents", m["helper"])
    plugin = os.path.join(res, m["plugin"])
    folder = os.path.join(res, m["pluginDirectory"])
    if not (m["plugin"].startswith(m["pluginDirectory"] + "/") and os.path.isfile(plugin)):
        problems.append("js-provider: plugin file is missing or outside its plugin directory")
    elif sha256_file(plugin) != m["pluginSHA256"]:
        problems.append("js-provider: the plugin differs from its pinned digest")
    else:
        try:
            with open(plugin, "rb") as f:
                compile(f.read(), plugin, "exec")
        except Exception as e:
            problems.append(f"js-provider: the plugin does not compile ({e})")
    if not (os.path.isfile(helper) and os.access(helper, os.X_OK)):
        problems.append("js-provider: the helper is missing or not executable")
    else:
        if sha256_file(helper) != m["helperSHA256"]:
            problems.append("js-provider: the helper differs from its pinned digest")
        check_macho(helper, "setu-jsc", team, archs, problems)
        ents = entitlements(helper)
        if ents != ["com.apple.security.app-sandbox"]:
            problems.append(f"js-provider: the helper's entitlements are {ents}; they must be exactly com.apple.security.app-sandbox (no network, files, JIT or unsigned memory)")
    # the WHOLE plugin folder is what yt-dlp will import from: it must be exactly the pinned tree and contain exactly the one plugin file (no extra module, package, cache or link)
    if os.path.isdir(folder):
        listing = sorted([os.path.relpath(os.path.join(d, n), folder) for d, ds, fs in os.walk(folder) for n in fs]
                         + [os.path.relpath(os.path.join(d, n), folder) + "/" for d, ds, fs in os.walk(folder) for n in ds])
        expected = sorted([os.path.relpath(plugin, folder)] + ["setu/", "setu/yt_dlp_plugins/", "setu/yt_dlp_plugins/extractor/"])
        if listing != expected:
            problems.append(f"js-provider: the plugin folder holds {listing}, expected exactly {expected}")
        elif tree_digest(folder) != m["pluginTreeSHA256"]:
            problems.append("js-provider: the plugin folder differs from its pinned tree digest")
    else:
        problems.append("js-provider: the plugin folder is missing")
    # the compatibility record: this exact yt-dlp, these exact solver scripts, this helper protocol
    if os.path.isfile(plugin):
        try:
            compat = plugin_compatibility(plugin)
        except Exception as e:
            problems.append(f"js-provider: cannot read the plugin's compatibility record ({e})")
            compat = None
        if compat:
            if ytdlp_version not in compat["ytDlp"]:
                problems.append(f"js-provider: the plugin was verified for yt-dlp {compat['ytDlp']}, the app embeds {ytdlp_version}")
            solver = os.path.join(res, "Tools", "yt-dlp", "_internal", "yt_dlp_ejs", "yt", "solver")
            try:
                # hashed as TEXT, the way the plugin hashes what yt_dlp_ejs hands it (a BOM or line-ending difference must fail HERE, not silently at run time)
                def text_hash(name):
                    with open(os.path.join(solver, name), encoding="utf-8") as f:
                        return hashlib.sha256(f.read().encode("utf-8")).hexdigest()
                have = {"lib": text_hash("lib.min.js"), "core": text_hash("core.min.js")}
            except OSError:
                have = None
                problems.append("js-provider: the yt-dlp-ejs solver scripts are not in the embedded yt-dlp")
            if have and not any(pins == have for pins in compat["ejs"].values()):
                problems.append(f"js-provider: the embedded yt-dlp-ejs solver scripts ({have['lib'][:10]}…/{have['core'][:10]}…) are not a pairing the plugin was verified against ({list(compat['ejs'])})")
            if m["providerVersion"] != compat["provider"] or m["helperProtocol"] != compat["helperProtocol"]:
                problems.append("js-provider: the manifest's provider version / protocol differ from the plugin's compatibility record")
            ejs_version = next((v for v, pins in compat["ejs"].items() if have and pins == have), None)
            try:
                header = ytdlp_debug_header(app, folder)
            except Exception as e:
                header = ""
                problems.append(f"js-provider: the embedded yt-dlp could not be run to read its header ({type(e).__name__})")
            if header:
                seen = re.search(r"yt_dlp_ejs-(\S+?)(?:,|\s|$)", header)
                if not seen or (ejs_version and seen.group(1) != ejs_version):
                    problems.append(f"js-provider: yt-dlp reports yt-dlp-ejs {seen.group(1) if seen else 'none'}, the matching pins are for {ejs_version}")
                if ytdlp_version not in (re.search(r"yt-dlp version \S+@(\S+)", header) or [None, ""])[1]:
                    problems.append(f"js-provider: the embedded yt-dlp does not report version {ytdlp_version}")
                dirs = re.search(r"Plugin directories: (.*)", header)
                if not dirs or os.path.join(folder, "setu", "yt_dlp_plugins") not in dirs.group(1):
                    problems.append("js-provider: the embedded yt-dlp did not find the provider plugin folder")
            if os.path.isfile(helper):
                try:
                    problems.extend("js-provider: helper behaviour: " + x for x in helper_selftest(helper))
                except Exception as e:
                    problems.append(f"js-provider: the helper's behaviour check could not run ({type(e).__name__})")
                try:
                    said = helper_handshake(helper)
                except Exception as e:
                    said = f"({type(e).__name__})"
                if said != f"setu-jsc {m['version']} protocol {compat['helperProtocol']}":
                    problems.append(f"js-provider: the helper's handshake is '{said}', expected 'setu-jsc {m['version']} protocol {compat['helperProtocol']}'")
    if len(problems) == before:
        notes.append(f"js-provider: setu-jsc {m['version']} protocol {m['helperProtocol']} (App Sandbox only) + provider {m['providerVersion']} verified for yt-dlp {ytdlp_version} and its pinned yt-dlp-ejs scripts")
        return True
    return False


def check_no_unreviewed_runtime(app):
    """0.4.1 ships no JavaScript runtime besides the app's own helper. A Deno manifest, a Deno tool folder, or any file called deno* anywhere in the app would mean an unreviewed runtime could go live; refuse it."""
    found = []
    res = os.path.join(app, "Contents", "Resources")
    for name in ("BundledDeno.json",):
        if os.path.exists(os.path.join(res, name)):
            found.append(f"Resources/{name}")
    for d, dirs, files in os.walk(app):
        for n in dirs + files:
            if re.match(r"(?i)^(deno|denort)(\.|$)", n) or n.lower() in ("bun", "node", "qjs"):
                found.append(os.path.relpath(os.path.join(d, n), app))
    return [f"an unreviewed JavaScript runtime is in the app: {x} (0.4.1 ships none besides setu-jsc; remove it, or review and allow it deliberately)" for x in sorted(set(found))]


def cmd_check_app(a):
    """Fail-closed preflight on a BUILT .app. Returns 0 only if every claim the release would make about the tools is true of these bytes."""
    app = a.app
    res = os.path.join(app, "Contents", "Resources")
    problems, notes = [], []
    want_arch = app_arch(app)
    team = a.team
    ytdlp_version = None
    for tool in TOOLS:
        mf = os.path.join(res, MANIFEST_RESOURCE[tool])
        tdir = os.path.join(res, "Tools", tool)
        if not os.path.isfile(mf):
            problems.append(f"{tool}: {MANIFEST_RESOURCE[tool]} is missing from the app")
            continue
        try:
            m = load_json(mf)
        except ValueError as e:
            problems.append(f"{tool}: manifest is not valid JSON ({e})")
            continue
        mp = validate_manifest(m, tool)
        problems += [f"{tool}: manifest: {x}" for x in mp]
        if mp:
            continue
        if m["signaturePolicy"] != f"teamID:{team}":
            problems.append(f"{tool}: manifest signaturePolicy {m['signaturePolicy']} is not teamID:{team}")
        if sorted(m["architectures"]) != want_arch:
            problems.append(f"{tool}: manifest architectures {m['architectures']} do not match the app's {want_arch}")
        if m["notarization"]["status"] != "Accepted":
            problems.append(f"{tool}: manifest has no accepted notarization")
        if not os.path.isdir(tdir):
            problems.append(f"{tool}: not embedded (Resources/Tools/{tool} is missing)")
            continue
        got = tree_digest(tdir)
        if got != m["treeSHA256"]:
            problems.append(f"{tool}: embedded files ({got[:12]}…) differ from the manifest's tree digest ({m['treeSHA256'][:12]}…)")
        exe = os.path.join(tdir, m["executable"])
        if not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
            problems.append(f"{tool}: executable {m['executable']} is missing or not executable")
        files = macho_files(tdir)
        if not files:
            problems.append(f"{tool}: no Mach-O files embedded")
        for f in files:
            check_macho(f, f"{tool}/{os.path.relpath(f, tdir)}", team, want_arch, problems)
        # licences and source offers that travel with the tool
        lic = [n for n in os.listdir(tdir) if re.match(r"(COPYING|LICENSE|THIRD_PARTY)", n, re.I)] if os.path.isdir(tdir) else []
        if tool == "ffmpeg" and not any(n.startswith("COPYING.LGPL") for n in lic):
            problems.append("ffmpeg: LGPL licence texts are missing from the embedded package")
        offers = [n for n in os.listdir(os.path.join(res, "Notices"))] if os.path.isdir(os.path.join(res, "Notices")) else []
        needle = "FFMPEG" if tool == "ffmpeg" else "YT-DLP"
        if not any(n.upper().startswith(needle) for n in offers):
            problems.append(f"{tool}: no source offer / notice in Resources/Notices")
        if tool == "yt-dlp":
            if not m.get("javascriptRuntime"):
                problems.append("yt-dlp: manifest does not state how YouTube's JavaScript challenges are handled")
            if not os.path.isfile(os.path.join(tdir, "THIRD_PARTY_LICENSES.txt")) and not os.path.isfile(os.path.join(res, "Notices", "YT-DLP-THIRD_PARTY_LICENSES.txt")):
                notes.append("yt-dlp: THIRD_PARTY_LICENSES.txt is not inside the app (ships via Settings > Acknowledgements only)")
        if m["sourceURL"]:
            if not a.hosted_verified:
                problems.append(f"{tool}: manifest advertises a download address ({m['sourceURL']}) but --hosted-verified was not given; an unhosted address would offer an install that fails")
        if tool == "yt-dlp":
            ytdlp_version = m["version"]
        notes.append(f"{tool}: {m['version']} embedded, {len(files)} Mach-O files verified (Team {team}, runtime, {','.join(want_arch)}), notarization {m['notarization']['submissionID']}")
    problems += check_no_unreviewed_runtime(app)
    provider_ok = check_js_provider(app, team, want_arch, ytdlp_version, problems, notes) if (ytdlp_version and "yt-dlp" in TOOLS) else False
    notices = os.path.join(res, "Notices")
    promises = any("publishes the source" in open(os.path.join(notices, n), encoding="utf-8", errors="replace").read() or "published with the release" in open(os.path.join(notices, n), encoding="utf-8", errors="replace").read()
                   for n in (os.listdir(notices) if os.path.isdir(notices) else []))
    if promises and not (a.sources_published or a.allow_unpublished_sources):
        problems.append("the in-app notices promise that the corresponding source is published with this release, but --sources-published was not given. Publish the source archives (docs/compliance/media-tools-redistribution.md) and confirm with --sources-published (release.sh: MEDIA_SOURCES_PUBLISHED=1)")
    if a.allow_unpublished_sources:
        notes.append("source offer: NOT YET PUBLISHED (allowed only for a --verify-only build; a real release requires MEDIA_SOURCES_PUBLISHED=1)")
    if a.readme:
        problems += readme_claims(a.readme, app, problems, provider_ok)
    for n in notes:
        print("  " + n)
    if problems:
        print("✘ the media tools in this app are not release-ready:", file=sys.stderr)
        for x in problems:
            print(f"  - {x}", file=sys.stderr)
        print("  how to fix: scripts/release-media-tools.sh --ensure (builds, signs, notarizes and caches), then scripts/embed-media-tools.sh <app>.", file=sys.stderr)
        return 1
    print("  media tools: both embedded, signed, notarized, consistent with the manifests and the README")
    return 0


def readme_claims(readme, app, existing_problems, provider_ok=False):
    """README/release notes may say the tools are bundled only if the built app really has them verified."""
    with open(readme) as f:
        text = f.read()
    plist = os.path.join(app, "Contents", "Info.plist")
    ver = run(["/usr/bin/plutil", "-extract", "CFBundleShortVersionString", "raw", plist]).stdout.strip()
    sec = re.search(rf"### New in {re.escape(ver)}\n(.*?)(?=\n### |\n## )", text, re.S)
    p = []
    if not sec:
        return [f"README has no 'New in {ver}' section for this app version"]
    claims = re.findall(r"^.*(?:yt-dlp|ffmpeg).*(?:inside the app|bundled|come inside|embedded).*$", sec.group(1), re.M | re.I)
    tool_problems = [x for x in existing_problems if re.match(r"(yt-dlp|ffmpeg)", x)]
    if claims and tool_problems:
        p.append("README says the media tools are inside the app, but the app check above found problems with them")
    if claims and not provider_ok and "javascript" not in sec.group(1).lower() and "deno" not in sec.group(1).lower():
        p.append("README claims bundled yt-dlp but the app has no verified JavaScript provider and the README does not say that some sites (notably YouTube) may be limited without one")
    if re.search(r"no (deno|javascript|node)[^.\n]*(needed|required|install)|without (installing )?(deno|node)", sec.group(1), re.I) and not provider_ok:
        p.append("README says no Deno/Node is needed, but the app has no verified JavaScript provider")
    return p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(sp, tool=True):
        if tool:
            sp.add_argument("--tool", choices=ALL_TOOLS, required=True)
        sp.add_argument("--arch", default="arm64")
        sp.add_argument("--team", required=True)
        sp.add_argument("--cache", default=os.environ.get("MEDIA_TOOLS_CACHE", DEFAULT_CACHE))
    s = sub.add_parser("key"); common(s); s.set_defaults(f=cmd_key)
    s = sub.add_parser("inputs"); s.add_argument("--tool", choices=ALL_TOOLS, required=True); s.set_defaults(f=cmd_inputs)
    s = sub.add_parser("lookup"); common(s); s.add_argument("--online", metavar="NOTARY_PROFILE"); s.set_defaults(f=cmd_lookup)
    s = sub.add_parser("store"); common(s); s.add_argument("--build", required=True); s.add_argument("--submission", required=True)
    s.add_argument("--status", required=True); s.add_argument("--profile"); s.add_argument("--signer"); s.set_defaults(f=cmd_store)
    s = sub.add_parser("manifest"); s.add_argument("--tool", choices=ALL_TOOLS, required=True); s.add_argument("--entry", required=True)
    s.add_argument("--out", required=True); s.add_argument("--hosted-url"); s.set_defaults(f=cmd_manifest)
    s = sub.add_parser("validate-manifest"); s.add_argument("file"); s.add_argument("--tool", choices=ALL_TOOLS); s.set_defaults(f=cmd_validate_manifest)
    s = sub.add_parser("plugin-compat"); s.add_argument("file"); s.set_defaults(f=lambda a: print(json.dumps(plugin_compatibility(a.file))))
    s = sub.add_parser("check-app"); s.add_argument("app"); s.add_argument("--team", required=True); s.add_argument("--readme")
    s.add_argument("--hosted-verified", action="store_true"); s.add_argument("--sources-published", action="store_true"); s.add_argument("--allow-unpublished-sources", action="store_true"); s.set_defaults(f=cmd_check_app)
    a = ap.parse_args()
    try:
        sys.exit(a.f(a) or 0)
    except Fail as e:
        print(f"✘ {e}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
