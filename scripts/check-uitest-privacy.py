#!/usr/bin/env python3
"""Fails if a UI test could take a picture of the whole screen.

A screen picture shows whatever else is on the person's displays (other apps, conversations, documents). UI tests may only picture a window of Browser Setu, through the helpers in
apps/apple/UITests/SafeScreenshot.swift (`safeScreenshot()`, `safeAttachment()`), which never fall back to the screen.

Run: python3 -I scripts/check-uitest-privacy.py
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent / "apps" / "apple" / "UITests"
helper = root / "SafeScreenshot.swift"
problems = []
for path in sorted(root.glob("*.swift")):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split("//")[0]
        if re.search(r"\bXCUIScreen\b", code):
            problems.append(f"{path.name}:{number}: XCUIScreen (a whole-screen capture): {line.strip()}")
        elif path != helper and re.search(r"(?<!safe)\.screenshot\(\)", code):
            problems.append(f"{path.name}:{number}: .screenshot() called directly (use safeScreenshot()/safeAttachment()): {line.strip()}")
if problems:
    print("UI-test privacy check FAILED:"); print("\n".join(problems)); sys.exit(1)
print("UI-test privacy check passed: no whole-screen capture in", len(list(root.glob('*.swift'))), "test files.")
