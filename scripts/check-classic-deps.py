#!/usr/bin/env python3
"""Read-only: which of Classic's shared source files changed since an accepted baseline, and which Classic tests that change calls for.

    python3 -I scripts/check-classic-deps.py                       list every protected file with its current SHA-256
    python3 -I scripts/check-classic-deps.py --record FILE         write the current hashes to FILE (do this only for a baseline the owner has accepted)
    python3 -I scripts/check-classic-deps.py --baseline FILE       compare with that baseline; exit 1 when a protected file differs, naming the tests to run

It reads the repository and, for --record, writes only the one file named. There is no baseline in the repository: none exists until Classic is accepted.
"""
import hashlib, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
A = "apps/apple/"
UI = "BrowserSetuMacUITests/"
UNIT = "BrowserSetuMacTests/"
# protected file -> the Classic test classes its change calls for (kept to the smallest meaningful selection)
PROTECTED = {
    A + "macOS/Chrome/TabViews.swift": [UI + "D1aClassicUITests", UI + "D1cOneRowUITests"],
    A + "macOS/Chrome/ChromeComponents.swift": [UI + "D1aClassicUITests"],
    A + "macOS/Chrome/InlineBar.swift": [UI + "D1cOneRowUITests", UI + "D1aClassicUITests"],
    A + "macOS/Chrome/ClassicGroupChip.swift": [UI + "D1aClassicUITests", UI + "D1aClassicOrganizationUITests"],
    A + "macOS/Chrome/SidebarViews.swift": [UI + "D1aClassicLibraryUITests", UI + "D1aClassicQualityUITests"],
    A + "macOS/Chrome/LibrarySections.swift": [UI + "D1aClassicHistorySessionsUITests"],
    A + "macOS/MacRootView.swift": [UI + "D1aClassicUITests", UI + "D1aClassicPanelsUITests"],
    A + "Shared/SharedViews.swift": [UI + "D1aClassicBookmarksUITests", UI + "D1aClassicLibraryUITests", UI + "D1aClassicHistorySessionsUITests"],
    A + "Shared/LibraryKeyboard.swift": [UI + "D1aClassicBookmarksUITests"],
    A + "Shared/DockedPanels.swift": [UI + "D1aClassicPanelsUITests"],
    A + "Shared/BrowserModel.swift": [UNIT + "D1aClassicOrganizationTests", UNIT + "D1aClassicPersistenceTests", UI + "D1aClassicSettingsUITests"],
    A + "Shared/LayoutState.swift": [UNIT + "LayoutStateTests", UNIT + "ChromeLayoutTests"],
    A + "Shared/AppSettings.swift": [UNIT + "D1aClassicPersistenceTests", UI + "D1aClassicSettingsUITests"],
    A + "Shared/Windows.swift": [UI + "D1aClassicSettingsUITests"],
    A + "Shared/Favicons/Presentation/FaviconStore.swift": [UNIT + "D1aClassicFaviconTests"],
    A + "macOS/Settings/BrowserExtrasSettings.swift": [UI + "D1aClassicSettingsUITests"],
}

def digest(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path): return None
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

def current(): return {rel: digest(rel) for rel in PROTECTED}

def main(argv):
    now = current()
    if "--record" in argv:
        target = argv[argv.index("--record") + 1]
        json.dump(now, open(target, "w"), indent=2, sort_keys=True); print(f"recorded {len(now)} hashes to {target}"); return 0
    if "--baseline" in argv:
        base = json.load(open(argv[argv.index("--baseline") + 1]))
        changed = [rel for rel in PROTECTED if base.get(rel) != now[rel]]
        if not changed: print("No protected Classic dependency changed since the baseline."); return 0
        tests = sorted({t for rel in changed for t in PROTECTED[rel]})
        print("Changed since the baseline:"); [print("  " + rel) for rel in changed]
        print("Run (through scripts/test-isolated.sh, after the owner authorizes tests):"); [print("  -only-testing:" + t) for t in tests]
        return 1
    for rel, h in now.items(): print(f"{h or 'MISSING'}  {rel}")
    return 0

sys.exit(main(sys.argv[1:]))
