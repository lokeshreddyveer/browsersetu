#!/bin/bash
# Server for the native Repositories & Models UI tests: the GitHub/Hugging Face/S3-style stand-in on loopback port 18791 and its separate "CDN" origin on 18792. `stop` ends it. Nothing else on this Mac is touched.
D=/private/tmp/bs-provider-ui-fixture
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$1" in
  start)
    [ -f "$D/pid" ] && /bin/kill "$(cat "$D/pid")" >/dev/null 2>&1
    /bin/rm -rf "$D"; /bin/mkdir -p "$D" && /bin/chmod 700 "$D" || exit 1
    /usr/bin/nohup /usr/bin/python3 -I "$HERE/provider_fixture_server.py" 18791 18792 --forever >"$D/server.log" 2>&1 </dev/null &
    echo $! > "$D/pid"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      /usr/bin/nc -z 127.0.0.1 18791 >/dev/null 2>&1 && /usr/bin/nc -z 127.0.0.1 18792 >/dev/null 2>&1 && exit 0; /bin/sleep 0.5
    done
    echo "The provider fixture did not start" >&2; exit 1 ;;
  stop)
    [ -f "$D/pid" ] && /bin/kill "$(cat "$D/pid")" >/dev/null 2>&1
    /bin/rm -rf "$D" ;;
esac
