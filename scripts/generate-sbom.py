#!/usr/bin/env python3
"""Writes a CycloneDX 1.5 software bill of materials and the build metadata for a release.

Components: every Rust crate in core/Cargo.lock (with the crate's registry checksum) and every Swift package in the app's resolved package list (with its
pinned revision). Metadata: the source commit, the hash of the Rust sources the XCFramework was built from, the toolchains, and the time.
Usage: scripts/generate-sbom.py [output-folder]     (default: dist)
"""
import json, re, subprocess, sys, pathlib, datetime, platform

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist"
OUT.mkdir(parents=True, exist_ok=True)

def run(*cmd):
    try: return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except Exception: return "unknown"

components = []
lock = (ROOT / "core" / "Cargo.lock").read_text()
for block in lock.split("[[package]]")[1:]:
    name = re.search(r'^name = "(.*)"', block, re.M); version = re.search(r'^version = "(.*)"', block, re.M)
    if not name or not version: continue
    source = re.search(r'^source = "(.*)"', block, re.M); checksum = re.search(r'^checksum = "(.*)"', block, re.M)
    c = {"type": "library", "bom-ref": f"cargo:{name[1]}@{version[1]}", "name": name[1], "version": version[1], "purl": f"pkg:cargo/{name[1]}@{version[1]}"}
    if checksum: c["hashes"] = [{"alg": "SHA-256", "content": checksum[1]}]
    if source and "registry" not in source[1]: c["externalReferences"] = [{"type": "vcs", "url": source[1]}]
    if not source: c["scope"] = "required"; c["description"] = "this project's own crate"
    components.append(c)

for resolved in sorted(ROOT.glob("apps/apple/**/Package.resolved")):
    if "/build/" in str(resolved): continue
    data = json.loads(resolved.read_text())
    for pin in data.get("pins", data.get("object", {}).get("pins", [])):
        loc = pin.get("location") or pin.get("repositoryURL", ""); state = pin.get("state", {})
        name = pin.get("identity") or pin.get("package", "")
        version = state.get("version") or state.get("revision", "")[:12]
        c = {"type": "library", "bom-ref": f"swift:{name}@{version}", "name": name, "version": version, "purl": f"pkg:swift/{loc.replace('https://', '').removesuffix('.git')}@{version}"}
        if state.get("revision"): c["properties"] = [{"name": "git-revision", "value": state["revision"]}]
        if not any(x["bom-ref"] == c["bom-ref"] for x in components): components.append(c)

core_hash = (ROOT / "apps/apple/Generated/CORE_SOURCE_HASH").read_text().strip() if (ROOT / "apps/apple/Generated/CORE_SOURCE_HASH").exists() else "unknown"
meta = {
    "source_commit": run("git", "rev-parse", "HEAD"), "source_dirty": run("git", "status", "--porcelain") != "",
    "core_source_hash": core_hash, "rustc": run("rustc", "--version"), "cargo": run("cargo", "--version"),
    "xcode": run("xcodebuild", "-version").replace("\n", " "), "swift": run("swift", "--version").split("\n")[0],
    "macos": platform.mac_ver()[0], "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
sbom = {
    "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
    "metadata": {"timestamp": meta["generated"], "component": {"type": "application", "name": "Browser Setu", "version": "0.2.0", "bom-ref": "browser-setu"},
                 "properties": [{"name": f"build:{k}", "value": str(v)} for k, v in meta.items()]},
    "components": sorted(components, key=lambda c: c["bom-ref"]),
}
(OUT / "sbom.cdx.json").write_text(json.dumps(sbom, indent=2) + "\n")
(OUT / "build-metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
print(f"SBOM written: {len(components)} components, commit {meta['source_commit'][:10]}, core source hash {core_hash[:12]} -> {OUT}")
