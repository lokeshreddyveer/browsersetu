#!/usr/bin/env python3
"""The digest of a tool folder, identical to BundledExtractor.treeDigest in the app: SHA-256 over sorted lines, one per file ("F<TAB>path<TAB>sha256<TAB>x|-") or symbolic link ("L<TAB>path<TAB>target"), directories ignored."""
import hashlib, os, sys
def digest(root):
    lines = []
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(d, n); rel = os.path.relpath(p, root)
            if os.path.islink(p): lines.append("L\t%s\t%s" % (rel, os.readlink(p)))
            elif os.path.isfile(p):
                h = hashlib.sha256()
                with open(p, "rb") as f:
                    for c in iter(lambda: f.read(1 << 20), b""): h.update(c)
                lines.append("F\t%s\t%s\t%s" % (rel, h.hexdigest(), "x" if os.access(p, os.X_OK) else "-"))
    lines.sort(key=lambda s: s.split("\t")[1].encode("utf-8"))
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest(), len(lines)
if __name__ == "__main__":
    d, n = digest(sys.argv[1]); print(d, n)
