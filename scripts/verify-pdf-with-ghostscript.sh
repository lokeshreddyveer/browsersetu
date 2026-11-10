#!/bin/sh
# Opens the PDFs the editor wrote with Ghostscript, a PDF engine that shares no code with Apple's PDFKit, and checks page counts, text and rendering.
# Usage: verify-pdf-with-ghostscript.sh <folder written by PDFOperationsTests.testWriteFilesForAnIndependentReader>
set -u
DIR="${1:?folder of PDFs}"
GS="$(command -v gs)" || { echo "Ghostscript (gs) is not installed"; exit 2; }
status=0
pages() { "$GS" -q -dNODISPLAY -dNOSAFER -dBATCH -dNOPAUSE -c "($1) (r) file runpdfbegin pdfpagecount = quit" 2>/dev/null; }
text() { "$GS" -q -dNOPAUSE -dBATCH -sDEVICE=txtwrite -sOutputFile=- "$1" 2>/dev/null | tr -s '[:space:]' ' '; }
for f in "$DIR"/*.pdf; do
  n="$(pages "$f")"; t="$(text "$f")"
  "$GS" -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=png16m -r48 -sOutputFile="/tmp/gs-check-$$-%d.png" "$f" >/dev/null 2>&1 || { echo "FAIL render: $f"; status=1; }
  rendered=$(ls /tmp/gs-check-$$-*.png 2>/dev/null | wc -l | tr -d ' '); rm -f /tmp/gs-check-$$-*.png
  echo "$(basename "$f"): $n page(s), $rendered rendered, text: ${t:0:60}"
  [ -n "$n" ] && [ "$n" = "$rendered" ] || { echo "FAIL pages/render mismatch: $f"; status=1; }
done
exit $status
