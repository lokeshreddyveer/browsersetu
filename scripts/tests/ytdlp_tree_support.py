"""Where the live/chain tests get yt-dlp from. The app carries NO yt-dlp (it is an optional download), so the tests run the VERIFIED signed + notarized package: BS_YTDLP_TREE if given (an unpacked
package folder), otherwise the package in the media-tools cache, re-verified and unpacked into a temporary folder that is deleted when the test run ends."""
import atexit, os, shutil, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_tree = None


def ytdlp_tree():
    """The unpacked yt-dlp package folder, or None when there is no verified package (the caller skips)."""
    global _tree
    if _tree and os.path.isdir(_tree):
        return _tree
    env = os.environ.get("BS_YTDLP_TREE")
    if env:
        _tree = env if os.path.isfile(os.path.join(env, "yt-dlp_macos")) else None
        return _tree
    team = os.environ.get("BS_TEAM", "X4MH29QNRS")
    cache = os.environ.get("MEDIA_TOOLS_CACHE", os.path.expanduser("~/Library/Caches/BrowserSetu/media-tools"))
    p = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts", "media_tools_cache.py"), "lookup", "--tool", "yt-dlp", "--arch", "arm64", "--team", team, "--cache", cache],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    entry = p.stdout.strip().splitlines()[-1]
    dest = tempfile.mkdtemp(prefix="ytdlp-tree-")
    atexit.register(shutil.rmtree, dest, ignore_errors=True)
    if subprocess.run(["/usr/bin/unzip", "-q", os.path.join(entry, "package.zip"), "-d", dest]).returncode != 0:
        return None
    _tree = dest
    return _tree
