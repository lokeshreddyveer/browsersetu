#!/bin/sh
# Reads the exported pictures with Tesseract (an OCR engine that shares nothing with the app): the plain picture's card number must be readable (so the check can work at all),
# and neither the blacked-out nor the hidden one may give any of its digits back.
# Usage: verify-screenshot-redaction.sh <folder written by ScreenshotEditorTests.testWriteFilesForAnIndependentOCRCheck>
set -u
DIR="${1:?folder of pictures}"
T="$(command -v tesseract)" || { echo "tesseract is not installed"; exit 2; }
read_text() { "$T" "$1" - --psm 6 2>/dev/null | tr -d ' \n'; }
plain="$(read_text "$DIR/unredacted.png")"
black="$(read_text "$DIR/blacked-out.png")"
hidden="$(read_text "$DIR/hidden.png")"
echo "unredacted: $plain"; echo "blacked-out: $black"; echo "hidden: $hidden"
status=0
case "$plain" in *4111111111111111*|*4111*1111*) ;; *) echo "FAIL: the control picture's digits were not readable, so the check proves nothing"; status=1;; esac
for name in black hidden; do
  eval "text=\$$name"
  case "$text" in *4111*|*1111*) echo "FAIL: digits are still readable in the $name picture"; status=1;; esac
done
[ $status -eq 0 ] && echo "OK: the digits are readable only in the unredacted picture"
exit $status
