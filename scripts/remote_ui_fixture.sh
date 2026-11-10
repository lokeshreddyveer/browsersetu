#!/bin/bash
# Servers for the native Remote Files UI tests: the system's OpenSSH server (SFTP, loopback port 18781, throwaway keys) and the FTP fixture (18782), with a small tree of files.
# `start` builds everything under /private/tmp/bs-remote-ui-fixture and leaves both running; `stop` ends them and removes the folder. Nothing else on this Mac is touched.
D=/private/tmp/bs-remote-ui-fixture
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$1" in
  start)
    # (a previous run's servers are stopped first, so none are left behind when the folder is replaced)
    for f in sshd ftp; do [ -f "$D/$f.pid" ] && /bin/kill "$(cat "$D/$f.pid")" >/dev/null 2>&1; done
    /bin/rm -rf "$D"; /bin/mkdir -p "$D/tree/reports" "$D/ftp" && /bin/chmod 700 "$D" || exit 1
    /usr/bin/python3 -I - "$D" <<'PY'
import sys
d = sys.argv[1]
def pattern(n, k): return bytes((i * k + (i >> 8)) & 255 for i in range(n))
open(d + "/tree/dataset.bin", "wb").write(pattern(1_500_000, 29))
open(d + "/tree/notes.txt", "wb").write(b"notes")
open(d + "/tree/reports/a.txt", "wb").write(b"a"); open(d + "/tree/reports/b.txt", "wb").write(b"b")
open(d + "/ftp/release.zip", "wb").write(pattern(400_000, 7))
PY
    /usr/bin/ssh-keygen -q -t ed25519 -N "" -f "$D/host" && /usr/bin/ssh-keygen -q -t ed25519 -N "" -f "$D/client" || exit 1
    /bin/cp "$D/client.pub" "$D/authorized_keys" && /bin/chmod 600 "$D/authorized_keys"
    printf 'Port 18781\nListenAddress 127.0.0.1\nHostKey %s/host\nPidFile %s/pid\nAuthorizedKeysFile %s/authorized_keys\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\nLogLevel ERROR\nSubsystem sftp /usr/libexec/sftp-server\n' "$D" "$D" "$D" > "$D/sshd_config"
    /usr/bin/nohup /usr/sbin/sshd -D -e -f "$D/sshd_config" >"$D/sshd.log" 2>&1 &
    echo $! > "$D/sshd.pid"
    /usr/bin/nohup /usr/bin/python3 -I "$HERE/ftp_fixture_server.py" "$D/ftp" 18782 --forever >"$D/ftp.log" 2>&1 &
    echo $! > "$D/ftp.pid"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      /usr/bin/nc -z 127.0.0.1 18781 >/dev/null 2>&1 && /usr/bin/nc -z 127.0.0.1 18782 >/dev/null 2>&1 && exit 0; /bin/sleep 0.5
    done
    echo "The remote-file fixtures did not start" >&2; exit 1 ;;
  stop)
    for f in sshd ftp; do [ -f "$D/$f.pid" ] && /bin/kill "$(cat "$D/$f.pid")" >/dev/null 2>&1; done
    /bin/rm -rf "$D" ;;
esac
