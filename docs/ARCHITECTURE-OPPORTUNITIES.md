# Larger opportunities noticed while building build 22

Written 3 November 2026, updated the same day after five of them were worked on. Status of each is stated plainly.

## 1. One answer to "which tabs are listed" — DONE
Nine places each repeated `workspace == active && not essential && not a panel`. They now use `isHiddenTab`, `belongsInLists` and `listedTabs(inWorkspace:)` in `Shared/TabScope.swift`: `visibleTabs`, the Sidebar layout, workspace and group counts, tab grouping by website, saved sessions, restore points, Clear Tabs, tab search and the address bar's open-tab results. A new kind of hidden tab is now excluded by changing one function. Not yet done: some views still filter `model.tabs` directly for their own reasons (the tab-search pool keeps Essentials on purpose).

## 2. Groups belong to workspaces — DONE in the string form; the table was NOT built
Groups are still paths (`Work/Project A`), but each workspace now has its own list (`groupLists`), so the same name in two workspaces is two groups, deleting or renaming one touches only that workspace's tabs, and a deleted workspace's grouped tabs land in Personal with their groups listed. Old saved data (one global list) is placed by a one-time migration: a group goes to the workspaces whose tabs use it, and an unused one goes to Personal.
Not done, on purpose: the `tab_folders` SQL table. It would need a Rust-core change and a migration of every saved tab's group, to gain ordering by id and renames that do not rewrite tabs. That is worth doing together with drag-to-reorder of groups. Group colours and folded state are still keyed by the path, so two same-named groups in different workspaces share a colour.

## 3. Workspace identity — DONE for renames; the full switch to ids was NOT done
Each workspace now has a hidden `uid` (given to older workspaces at the next start, kept through renames). A rename now follows everything that remembered the name, in every window: tabs, the workspace in front, Recently Closed, restore points, site rules, extension choices, focus schedules, saved sessions, the start-up workspace and the workspace's groups. Before, only tabs and the workspace in front were updated, so rules, sessions and schedules silently stopped finding it. `--space` and Shortcuts look a workspace up by `uid` first.
Not done: tabs, rules and sessions still store the workspace's name, not its `uid`. Moving them to the id would be the cleaner design but touches sync and every saved format. The `gradient` of a workspace is not synced between devices.

## 4. Scroll tracking — REVIEWED, NO CHANGE
The tab locator tracks only the selected row with a preference (cheap, and works on macOS 14 and iOS 17). I looked at `onScrollGeometryChange` and `onScrollVisibilityChange` (macOS 15, iOS 18): the second says only whether a row is visible, not on which side; the first reports the list's scroll offset, not where a row is. The locator needs "above or below", so either would still need the row's frame. Using them behind an availability check would add a second code path for no gain. Revisit only if the minimum systems are raised and the cost of the preference shows up in a profile.

## 5. Content blocking is split between two installers
The privacy kit's `ContentRuleInstaller` and the app's `ExtraRuleInstaller` each compile, cache, attach and prune rule lists. They differ only in what builds the rules. Kept apart for now because the kit has its own drift check (`scripts/check-privacy-kit-drift.sh`). Fold the second into the first (an extra named list) when the kit is next changed.

## 6. Settings are one flat key/value table with several parallel lists
Adding a setting means the model, the loader, the portable-export list and, for synced ones, `SyncRules`. A small `SettingKey<T>` (key, default, scope: window, profile or synced) would make it one declaration and let a test check every synced key.

## 7. The address bar's retrieval is synchronous on the main thread
Candidates come from SQLite on the main thread and are ranked there (microseconds for 500 candidates, measured by a test). Fine at today's limits. If history search grows, move retrieval to a cancellable background task; the ranker already takes plain values.

## 8. Essentials across windows
Each window has its own live page for an Essential, which keeps windows independent but can hold two copies of a signed-in app. Sharing one needs the `TabRecord` / per-window presentation split described in `ROADMAP-NEXT.md`.

## 9. Fixture server for tests — DONE
About forty Mac tests load pages from `scripts/testserver.py`. The `BrowserSetuMac` scheme now starts it before the tests (unless something already listens on port 18765) and stops only the copy it started, through scheme pre- and post-actions, which run outside the app sandbox. Verified by a test run with no server started by hand (see the release notes for the result).
