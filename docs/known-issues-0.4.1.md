# Known issues for 0.4.1 (build 24) release candidate

## Unresolved: two load-sensitive full-suite failures
In the last full macOS run (3,864 tests, machine load 107–132 from another project's simulator) two cases failed:
- `testHostileRobotsFilesAreBounded`: took 7.4 s against a 5 s bound.
- `testDiagLogWritesAndTrims`: found 34 lines where 300 were expected.

Both pass when run alone on an idle machine (3 of 3). That is evidence, not a resolution: they are recorded as **unresolved full-suite instability** until the tests are made deterministic or the cause is established. Neither was weakened.

## Open before any distribution
- Complete corresponding-source package: published and reachable at the URL the in-app notices promise (release gate `MEDIA_SOURCES_PUBLISHED=1`); unresolved provenance: curl-impersonate version, CPython patch version, GPG signature of upstream's SHA2-256SUMS.
- GUI-level workflow test (not run).
- Final Apple notarization: held by the owner until the above are settled.
