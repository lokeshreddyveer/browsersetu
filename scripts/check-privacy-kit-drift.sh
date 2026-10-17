#!/bin/sh
# SetuPrivacyKit imports four files from VayuSetu unchanged. This reports whether either side has changed since the import.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAYU="${VAYUSETU_DIR:-$HOME/Documents/VayuSetu}/Packages/VayuSetuCore/Sources/VayuSetuCore"
KIT="$ROOT/Packages/SetuPrivacyKit"
[ -d "$VAYU" ] || { echo "VayuSetu not found at $VAYU (set VAYUSETU_DIR)"; exit 2; }
status=0
while read -r hash name; do
  mine="$(shasum -a 256 "$KIT/Sources/SetuPrivacyCore/Imported/$name" | cut -d' ' -f1)"
  theirs="$(shasum -a 256 "$VAYU/$name" | cut -d' ' -f1)"
  [ "$mine" = "$hash" ] || { echo "CHANGED HERE: $name (edited after import)"; status=1; }
  [ "$theirs" = "$hash" ] || { echo "CHANGED IN VAYUSETU: $name (review and re-import)"; status=1; }
done < "$KIT/IMPORTED.sha256"
[ $status -eq 0 ] && echo "imported files match VayuSetu and the recorded hashes"
exit $status
