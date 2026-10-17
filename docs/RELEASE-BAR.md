# Release bar

BrowserSetu is called **production grade** only when every gate below has passed and its evidence is recorded in `docs/releases/`. Until then it is a
**release candidate in the production-hardening phase**. A gate is open until its evidence exists; "built" or "compiled" is not evidence.

Updated 17 October 2026.

## 1. The App Store build (Build 3 and later) - DEFERRED: App Store submission is not being done now; TestFlight builds for the owner's own devices continue
- [ ] Apple / TestFlight validation passes (record Apple's processing result).
- [ ] App Store privacy answers match the real search, iCloud and sync data flows (`docs/privacy/DATA-FLOW.md`); the empty collected-data list is confirmed against Apple's current definitions.
- [ ] Encryption export-compliance code recorded (`ITSEncryptionExportComplianceCode`) with the submitted documentation.
- [x] Privacy manifests present in every app bundle and checked in CI (`scripts/check-privacy-manifest.py`).

## 2. Security and reliability
- [ ] Real-device proxy test passes.
- [ ] Real-device profile-sync test passes (two devices).
- [x] Fuzz tests for ZIPs, extension manifests, backups, sync inputs and device messages (`FuzzTests`, 6 tests, passing on 17 Oct 2026).
- [x] Interrupted downloads resume after a restart (`DownloadPersistenceTests`).
- [ ] Crash recovery, extension rollback and profile migration verified end to end, not only in logic tests.

## 3. UI and accessibility
- [ ] macOS layout UI tests run (`LayoutRegressionUITests`).
- [ ] iPad split view tested.
- [x] iPhone landscape and largest text size: controls stay reachable (two UI tests pass in the simulator).
- [ ] VoiceOver, keyboard navigation, Dynamic Type across screens, reduced motion and high contrast checked.
- [ ] External displays and multi-window validated, or explicitly deferred (currently **deferred**: the browser has one model for one window).

## 4. Release engineering
- [ ] CI runs all required unit, integration, security and UI tests, and is green.
- [x] SBOM and reproducible-build metadata generated for each release (`scripts/generate-sbom.py`, run by `scripts/release.sh`): the application version comes from `MARKETING_VERSION`, and the run fails if the Rust, Cargo, Xcode or Swift version cannot be read.
- [ ] Written rollback, hotfix, incident-response and data-recovery procedures.
- [x] Mac release signed, notarized, stapled and Gatekeeper-checked (0.2.0 and 0.3.0 through 0.3.3; see `docs/releases/`).
- [ ] All evidence for the build kept together (`docs/releases/`).
