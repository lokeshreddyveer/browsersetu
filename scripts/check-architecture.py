#!/usr/bin/env python3
"""Consistency check for docs/decisions/0001-media-tools-optional-downloads.md.

Fails when documentation, manifests, build files or release scripts contradict the decision (media tools are optional downloads, never bundled; updates keep data; the appcast comes last).
Run: python3 -I scripts/check-architecture.py   (also run by scripts/tests/test_architecture_record.py and by scripts/release.sh)
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADR = "docs/decisions/0001-media-tools-optional-downloads.md"
TOOLS = re.compile(r"yt-dlp|ffmpeg|ffprobe|\bdeno\b|\bnode\b", re.I)
# an affirmative claim that a tool is inside the app / DMG
CLAIM = re.compile(r"(bundled (in|inside|with)|ships? (in|inside|with) the (app|dmg)|inside the (app|dmg)|embedded (in|into) the (app|dmg)|part of the (app|dmg))", re.I)
NEGATION = re.compile(r"\b(plugin|solver scripts|setu-jsc|runner|helper|not|never|no|nor|without|isn't|aren't|neither|refuses?|refused|instead of|false|fail|fails|superseded|historical)\b", re.I)
HISTORICAL = ("docs/downloads-architecture-stage-a.md",)       # carries a SUPERSEDED banner (checked below)
TOOL_NAMES = {"ffmpeg", "ffprobe", "yt-dlp", "yt-dlp_macos", "deno", "node"}


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def tracked():
    try:
        out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        return [l for l in out.splitlines() if l]
    except Exception:
        return []


def check(root_files=None):
    problems = []
    # 1. the record exists, is final, and is discoverable
    if not os.path.isfile(os.path.join(ROOT, ADR)):
        return [f"{ADR} is missing"]
    adr = read(ADR)
    if "ACCEPTED AND FINAL" not in adr:
        problems.append(f"{ADR} is not marked ACCEPTED AND FINAL")
    for rel in ("CLAUDE.md", "docs/media-tools.md", "README.md"):
        if not os.path.isfile(os.path.join(ROOT, rel)) or ADR not in read(rel):
            problems.append(f"{rel} does not reference {ADR}")
    if "SUPERSEDED" not in read("docs/downloads-architecture-stage-a.md")[:600]:
        problems.append("docs/downloads-architecture-stage-a.md lacks its SUPERSEDED banner")
    # 2. documents never claim a tool is bundled
    files = tracked()
    for rel in files:
        if not rel.endswith((".md", ".txt")) or rel in HISTORICAL or rel.startswith(("docs/releases/", "docs/compliance/source-manifest/")) or rel == ADR or not rel.startswith(("README", "docs/", "CLAUDE")):
            continue
        for n, line in enumerate(read(rel).splitlines(), 1):
            if TOOLS.search(line) and CLAIM.search(line) and not NEGATION.search(line):
                problems.append(f"{rel}:{n}: claims a media tool is bundled: {line.strip()[:110]}")
    # 3. no tool binary is tracked, and the project does not embed one
    for rel in files:
        if os.path.basename(rel) in TOOL_NAMES and os.path.isfile(os.path.join(ROOT, rel)):
            problems.append(f"{rel}: a media tool binary is tracked in the repository")
    proj = read("apps/apple/project.yml")
    if re.search(r"embed-media-tools\.sh", proj) or re.search(r"(?m)^\s*-\s*(path|framework):.*(ffmpeg|ffprobe|yt-dlp|deno)", proj, re.I):
        problems.append("apps/apple/project.yml refers to embedding a media tool")
    if os.path.exists(os.path.join(ROOT, "scripts", "embed-media-tools.sh")):
        problems.append("scripts/embed-media-tools.sh (a binary embedder) exists")
    # 4. shipped manifest templates keep the optional-download shape
    for rel in files:
        if re.match(r"apps/apple/ThirdParty/(yt-dlp|ffmpeg|deno)/MANIFEST\.json$", rel):
            try:
                m = json.loads(read(rel))
            except ValueError:
                problems.append(f"{rel} is not valid JSON"); continue
            if m.get("bundled") is True:
                problems.append(f"{rel} says bundled: true")
    # 5. the release scripts keep the guarantees
    rel_sh = read("scripts/release.sh")
    for needle in ("embed-media-manifests.sh", "check-media-tools.sh", "MEDIA_PACKAGES_HOSTED"):
        if needle not in rel_sh:
            problems.append(f"scripts/release.sh no longer uses {needle}")
    cache_py = read("scripts/media_tools_cache.py")
    if "the app carries NO tool" not in cache_py or "def cmd_check_app" not in cache_py:
        problems.append("scripts/media_tools_cache.py no longer states and enforces that the app carries no tool")
    pub = read("scripts/publish-release.sh")
    i_rel, i_app = pub.find("gh release"), pub.find("appcast")
    if i_rel < 0 or i_app < 0 or not any(pub.find(k) > i_rel for k in ("appcast.xml", "generate_appcast", "git push")):
        problems.append("scripts/publish-release.sh must publish and verify the GitHub release before updating the appcast")
    return problems


if __name__ == "__main__":
    found = check()
    for p in found:
        print("✘", p, file=sys.stderr)
    print("✔ architecture record consistent" if not found else f"{len(found)} contradiction(s) with {ADR}")
    sys.exit(1 if found else 0)
