#!/bin/bash
# Prepares the hash-pinned, wheel-only Python packages the password-SFTP test server needs, into build/test-deps/sftp (git-ignored). The tests never install anything themselves;
# without this folder (or BS_PWSERVER_LIB pointing at one) that single test is SKIPPED, not run. Run this once, on purpose, then run the tests.
set -euo pipefail
cd "$(dirname "$0")/.."
dest="build/test-deps/sftp"; rm -rf "$dest"; mkdir -p "$dest"
/usr/bin/python3 -m pip install --quiet --disable-pip-version-check --require-hashes --only-binary=:all: --no-deps --target "$dest" -r scripts/tests/sftp-fixture-requirements.txt
# wheels carry no quarantine flag; make sure none appears, so Gatekeeper has nothing to stop on
xattr -rd com.apple.quarantine "$dest" 2>/dev/null || true
echo "✔ $dest ready ($(find "$dest" -name '*.so' | wc -l | tr -d ' ') native modules). Run the tests with BS_PWSERVER_LIB=$PWD/$dest or let them find it."
