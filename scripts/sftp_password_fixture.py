#!/usr/bin/env python3
"""An SFTP server that CHECKS PASSWORDS (a normal user cannot make the system's sshd do that), for BrowserSetu's tests. Uses asyncssh from the hash-pinned folder made by
scripts/prepare-sftp-test-deps.sh (given in BS_PWSERVER_LIB); it never installs anything.

  sftp_password_fixture.py ROOT PORT HOSTKEY [--user alice --password s3cret]

ROOT is the whole visible tree (a chroot). Stops when stdin says 'quit' or closes."""
import asyncio, os, sys, threading
sys.path.insert(0, os.environ["BS_PWSERVER_LIB"])
import asyncssh

root, port, hostkey = sys.argv[1], int(sys.argv[2]), sys.argv[3]
user, password = "alice", "s3cret"
if "--user" in sys.argv: user = sys.argv[sys.argv.index("--user") + 1]
if "--password" in sys.argv: password = sys.argv[sys.argv.index("--password") + 1]

class Server(asyncssh.SSHServer):
    def password_auth_supported(self): return True
    def validate_password(self, username, pw): return username == user and pw == password
    def public_key_auth_supported(self): return False

async def main():
    await asyncssh.listen("127.0.0.1", port, server_host_keys=[hostkey], server_factory=Server,
                          sftp_factory=lambda chan: asyncssh.SFTPServer(chan, chroot=root.encode()))
    print("ready", flush=True)
    loop = asyncio.get_running_loop(); done = asyncio.Event()
    def watch():
        for line in sys.stdin:
            if line.strip() == "quit": break
        loop.call_soon_threadsafe(done.set)
    threading.Thread(target=watch, daemon=True).start()
    await done.wait()

asyncio.run(main())
