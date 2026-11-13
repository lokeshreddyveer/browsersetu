#!/usr/bin/env python3
"""Keeps AI-tool attribution out of the repository: files, release text, generated metadata and NEW commit messages.

What it flags is ATTRIBUTION: a "Co-Authored-By" trailer or a "Generated with ..." / "written by ..." credit naming an AI tool, an author/contributor/credit entry naming one, or a
CONTRIBUTORS/AUTHORS/CREDITS file that does. It does NOT flag the product's own feature text (Browser Setu's connection for AI tools names the tools it works with), data files, or ordinary words.
History is never rewritten: commits up to the one named in .attribution-baseline are legacy and ignored; every commit after it is checked.

  python3 -I scripts/check-attribution.py                       tracked files + commits after the baseline
  python3 -I scripts/check-attribution.py --files PATH...       only these files (generated metadata, release notes)
  python3 -I scripts/check-attribution.py --text                text from stdin (release notes about to be published)
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = r"(claude|anthropic|chatgpt|openai|gpt-?\d*|copilot|codex|gemini|cursor|an? ai\b|\bai\b|llm)"
NAMES = r"(claude|anthropic|chatgpt|openai|gpt-?\d*|copilot|codex|gemini|cursor)"        # specific tools: used where a bare "AI" would catch ordinary technical text
PATTERNS = [
    ("attribution trailer", re.compile(r"^\s*(co-authored-by|signed-off-by|generated-by|assisted-by):.*" + TOOLS, re.I | re.M)),
    ("'generated with/by' credit", re.compile(r"^\s*(🤖\s*)?generated\s+(with|by)\s+.*" + TOOLS, re.I | re.M)),
    ("authorship credit", re.compile(r"\b(written|authored|created|developed|built|coded|designed|made|contributed)\s+(by|with|using|via)\s+(\[?)(" + NAMES + r"|an ai (assistant|tool))", re.I)),
    ("author/contributor field", re.compile(r"\"?(author|authors|contributors?|creator|credits?|co-?author)\"?\s*[:=]\s*[\[\"'{]?[^\n]{0,60}" + NAMES, re.I)),
]
CREDIT_FILES = re.compile(r"(^|/)(contributors|authors|credits|humans|thanks)(\.[a-z]+)?$", re.I)
# Files that legitimately contain the patterns (the rule itself and its tests) or are data.
SKIP = {"scripts/check-attribution.py", "scripts/tests/test_attribution_guard.py", ".githooks/commit-msg", "CLAUDE.md"}
SKIP_PREFIX = ("Packages/SetuPrivacyKit/Sources/SetuPrivacyCore/Imported/", "apps/apple/ThirdParty/", "docs/compliance/source-manifest/")
TEXT_EXT = (".md", ".txt", ".json", ".xml", ".plist", ".swift", ".py", ".sh", ".yml", ".yaml", ".html", ".rs", ".toml", ".strings")


def scan_text(text, label=""):
    found = []
    for name, rx in PATTERNS:
        for m in rx.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            found.append(f"{label}:{line}: {name}: {m.group(0).strip()[:100]}")
    return found


def tracked():
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [l for l in out.splitlines() if l]


def scan_files(paths):
    found = []
    for rel in paths:
        if rel in SKIP or rel.startswith(SKIP_PREFIX):
            continue
        if CREDIT_FILES.search(rel):
            try:
                body = open(os.path.join(ROOT, rel), encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            if re.search(TOOLS, body, re.I):
                found.append(f"{rel}: a credits/contributors file names an AI tool")
        if not rel.endswith(TEXT_EXT):
            continue
        try:
            body = open(os.path.join(ROOT, rel) if not os.path.isabs(rel) else rel, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        found.extend(scan_text(body, rel))
    return found


def baseline():
    try:
        return open(os.path.join(ROOT, ".attribution-baseline")).read().split()[0]
    except (OSError, IndexError):
        return None


def scan_commits(rev_range=None, repo=ROOT):
    base = baseline() if rev_range is None else None
    rng = rev_range or (f"{base}..HEAD" if base else "HEAD")
    out = subprocess.run(["git", "log", "--format=%H%x1f%an <%ae>%x1f%B%x1e", rng], cwd=repo, capture_output=True, text=True)
    found = []
    for rec in out.stdout.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        h, author, body = rec.split("\x1f", 2)
        if re.search(TOOLS, author, re.I) and re.search(r"claude|anthropic|chatgpt|openai|copilot|codex|gemini|cursor", author, re.I):
            found.append(f"commit {h[:10]}: author is an AI tool")
        found.extend(scan_text(body, f"commit {h[:10]}"))
    return found


def clean_message(text):
    keep = [l for l in text.split("\n") if not (PATTERNS[0][1].match(l) or PATTERNS[1][1].match(l))]
    while keep and not keep[-1].strip():
        keep.pop()
    return "\n".join(keep) + "\n"


def main(argv):
    if argv[:1] == ["--files"]:
        found = scan_files(argv[1:])
    elif argv[:1] == ["--text"]:
        found = scan_text(sys.stdin.read(), "text")
    elif argv[:1] == ["--clean-message"]:
        p = argv[1]; open(p, "w").write(clean_message(open(p).read())); return 0
    else:
        found = scan_files(tracked()) + scan_commits()
    for f in found:
        print("✘", f, file=sys.stderr)
    print("✔ no AI-tool attribution" if not found else f"{len(found)} attribution finding(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
