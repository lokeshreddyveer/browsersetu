# Operations: rollback, hotfix, incident response and data recovery

Written 17 October 2026 from the tooling that exists in this repository. Steps marked **(untested)** have not been rehearsed end to end.

## Severity
- **S1:** data loss, a security flaw, or the app unusable for many people. Fix and release the same day.
- **S2:** a feature broken with a workaround, or wrong behaviour that is not harmful. Fix in the next release.
- **S3:** cosmetic.
BrowserSetu has no telemetry, so problems arrive only through people telling the author. Ask for the app version (Browser Setu → About), the OS version and what they saw.

## Rolling back a bad Mac release
The updater never installs an older version over a newer one, so "rolling back" means two things: stop offering the bad version, and ship a newer good one.
1. **Stop the offer.** Edit `appcast.xml` on `main`: delete the bad version's `<item>` (or move it below a fixed one), commit and push. Installed copies check the feed once a day, so it takes effect for anyone who has not updated yet.
2. **Pull the download.** In GitHub Releases, mark the bad release as a pre-release or delete its DMG asset, so a fresh download no longer finds it.
3. **Ship the fix as a higher version and build number** (see Hotfix). People already on the bad version receive it as an ordinary update.
4. For people who must go back now, the last good DMG stays on its release page; they can install it over the app by hand.
5. Record what happened in `docs/releases/`.

## Hotfix procedure
1. Branch from the tag of the released version: `git switch -c hotfix/0.2.1 v0.2.0`.
2. Make the smallest change that fixes the problem, with a test that fails without it.
3. Run the suites that matter: the new test, `FuzzTests`, `PrivacyIntegrationTests`, `HardeningTests`, and the layout tests for UI changes. Check the CI run is green.
4. Bump the version and build number. Mac: `scripts/release.sh 0.2.1 3` (signs, notarizes, staples, writes the SBOM and build metadata into `dist/`). iPhone: `scripts/testflight.sh <next build number>`.
5. Mac: `scripts/publish-release.sh 0.2.1 3 "<what changed>"` uploads the DMG with the SBOM and adds it to the update feed. Open the release and the feed, confirm both.
6. Merge the branch back to `main`; update `docs/releases/`.
7. Keep the update signing key safe: without the key in this Mac's Keychain (account `browsersetu`) no update can be offered.

## Rolling back an extension update
The previous version of each extension is kept beside it. Workbench → Extensions → "Go Back to Earlier Version" restores it and keeps the one it replaced, so the change can be undone. A failed install puts the old version back automatically. **(untested against a real extension)**

## Data recovery
- **Corrupt profile:** the app starts in recovery mode, keeps the original file untouched and works from a fresh profile; a profile written by a newer version is never modified. Covered by `HardeningTests`.
- **Repeated crashes at start:** after two launches that never finished, the next start comes up in safe start: tabs return but none is loaded.
- **Interrupted downloads:** kept on disk with a Resume button after a restart (`DownloadPersistenceTests`).
- **User backups:** Settings → Advanced → Back Up creates a passphrase-sealed file of bookmarks, settings and research collections; Restore merges and never overwrites. Passwords, cookies and history are never in it. A forgotten passphrase cannot be recovered.
- **iCloud sync conflicts:** the conflicts screen lists differences; bookmarks are only ever added by a sync, never removed.
- **Migrations:** the profile database has versioned migrations. Before shipping one, copy a profile from the previous version and open it with the new build **(untested as a routine step; do it for every schema change)**.

## Incident response (security)
1. Confirm and reproduce; classify severity.
2. If it can be exploited now (S1): pull the release (steps 1–2 above) before the fix is ready.
3. Fix with a test, release as a hotfix, and publish a short note in the release describing what was fixed, who was affected and what to do.
4. Add a case to the fuzz or privacy tests so the same class of fault is caught next time.
5. Review `docs/security/threat-model.md` and update it.
