#!/usr/bin/env python3
"""Checks the privacy manifests (PrivacyInfo.xcprivacy) against what the source code actually uses.

Fails when a manifest is missing or unreadable, when it declares tracking, when it uses a reason code Apple does not define for a category, or when the source
uses an API of a "required reason" category that the manifest does not declare. Run from the repository root.
"""
import plistlib, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "apps" / "apple"
MANIFESTS = [APP / "macOS" / "PrivacyInfo.xcprivacy", APP / "iOS" / "PrivacyInfo.xcprivacy"]

# Apple's reason codes (TN3183 / "Describing use of required reason API").
REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
}
# What in our own Swift source uses each category.
USES = {
    "NSPrivacyAccessedAPICategoryUserDefaults": r"UserDefaults",
    "NSPrivacyAccessedAPICategoryFileTimestamp": r"contentModificationDateKey|creationDateKey|contentAccessDateKey|fileModificationDate|fileCreationDate|attributesOfItem|\.modificationDate\b|\.creationDate\b",
    "NSPrivacyAccessedAPICategoryDiskSpace": r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize|attributesOfFileSystem|statfs|statvfs",
    "NSPrivacyAccessedAPICategorySystemBootTime": r"systemUptime|mach_absolute_time",
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"activeInputModes",
}
# Used by the bundled SQLite and the Rust standard library inside the app, whatever the Swift code does.
ALWAYS = {"NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPICategoryDiskSpace"}

errors = []
def fail(message): errors.append(message)

swift_files = [p for folder in ("Shared", "Engines", "macOS", "iOS", "Direct", "LiveActivity", "SpeedWidget") for p in (APP / folder).rglob("*.swift")]
used = set(ALWAYS)
for category, pattern in USES.items():
    rx = re.compile(pattern)
    if any(rx.search(p.read_text(errors="ignore")) for p in swift_files): used.add(category)

for manifest in MANIFESTS:
    name = manifest.relative_to(ROOT)
    if not manifest.exists(): fail(f"{name} is missing"); continue
    try: data = plistlib.loads(manifest.read_bytes())
    except Exception as e: fail(f"{name} is not a readable property list: {e}"); continue
    if data.get("NSPrivacyTracking") is not False: fail(f"{name}: NSPrivacyTracking must be false")
    if data.get("NSPrivacyTrackingDomains"): fail(f"{name}: no tracking domains may be listed")
    if "NSPrivacyCollectedDataTypes" not in data: fail(f"{name}: NSPrivacyCollectedDataTypes must be present (an empty list means nothing is collected)")
    declared = {}
    for entry in data.get("NSPrivacyAccessedAPITypes", []):
        category, reasons = entry.get("NSPrivacyAccessedAPIType"), set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
        if category not in REASONS: fail(f"{name}: unknown category {category}"); continue
        if not reasons: fail(f"{name}: {category} has no reason")
        for r in reasons - REASONS[category]: fail(f"{name}: {r} is not a reason Apple defines for {category}")
        declared[category] = reasons
    for category in used - set(declared): fail(f"{name}: the source uses {category} but the manifest does not declare it")
    for category in set(declared) - used: fail(f"{name}: declares {category} but nothing in the source uses it")

# The manifests must be inside the built apps, when there are builds to look in.
for app in sorted(set(ROOT.glob("apps/apple/build/*/Build/Products/*/Browser Setu*.app"))):
    if "UITests" in app.name or "Runner" in app.name or "Tests" in app.name: continue
    if not list(app.rglob("PrivacyInfo.xcprivacy")): fail(f"{app.relative_to(ROOT)} was built without a privacy manifest")

if errors:
    print("Privacy manifest check FAILED:"); [print("  -", e) for e in errors]; sys.exit(1)
print("Privacy manifest check passed: declared", ", ".join(sorted(c.replace("NSPrivacyAccessedAPICategory", "") for c in used)))
