#!/usr/bin/env python3
"""A local eD2k server and two peers for the download engine's socket tests. Listens on 127.0.0.1 only.

Usage: ed2k_fixture.py <server_port> <good_peer_port> <bad_peer_port>

It speaks the subset of the eD2k TCP protocol a downloader uses, as read from the aMule protocol headers and the Kulbak & Bickson specification. It therefore shows that the app's client
agrees with THAT reading of the protocol over real sockets; it is not a real eMule/aMule/eD2k server, and cannot show interoperability with one.

Files (byte i is (i*7+3) % 253): "small" is 600000 bytes (one part), "multi" is 10500000 bytes (two parts). The server answers GETSOURCES for either with the bad peer first, then the good one.
The bad peer flips the first byte of every block it sends.
Control: the server port also accepts a plain HTTP-free line "STATS\n" and answers a JSON line (counts of logins, source requests, parts served by each peer).
"""
import json
import socketserver
import struct
import sys
import threading

SERVER, GOOD, BAD = (int(x) for x in sys.argv[1:4])
PART = 9728000
STATS = {"logins": 0, "getsources": 0, "good_blocks": 0, "bad_blocks": 0, "hello": 0}
LOCK = threading.Lock()


def md4(data):
    import hashlib
    try:
        return hashlib.new("md4", data).digest()
    except Exception:
        pass

    def rol(x, s):
        return ((x << s) | (x >> (32 - s))) & 0xFFFFFFFF
    a, b, c, d = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476
    msg = bytearray(data)
    n = len(msg) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    msg += struct.pack("<Q", n)
    for off in range(0, len(msg), 64):
        x = struct.unpack("<16I", bytes(msg[off:off + 64]))
        aa, bb, cc, dd = a, b, c, d
        for i in range(0, 16, 4):
            a = rol((a + ((b & c) | (~b & d)) + x[i]) & 0xFFFFFFFF, 3)
            d = rol((d + ((a & b) | (~a & c)) + x[i + 1]) & 0xFFFFFFFF, 7)
            c = rol((c + ((d & a) | (~d & b)) + x[i + 2]) & 0xFFFFFFFF, 11)
            b = rol((b + ((c & d) | (~c & a)) + x[i + 3]) & 0xFFFFFFFF, 19)
        for i in range(4):
            a = rol((a + ((b & c) | (b & d) | (c & d)) + x[i] + 0x5A827999) & 0xFFFFFFFF, 3)
            d = rol((d + ((a & b) | (a & c) | (b & c)) + x[i + 4] + 0x5A827999) & 0xFFFFFFFF, 5)
            c = rol((c + ((d & a) | (d & b) | (a & b)) + x[i + 8] + 0x5A827999) & 0xFFFFFFFF, 9)
            b = rol((b + ((c & d) | (c & a) | (d & a)) + x[i + 12] + 0x5A827999) & 0xFFFFFFFF, 13)
        for i in (0, 2, 1, 3):
            a = rol((a + (b ^ c ^ d) + x[i] + 0x6ED9EBA1) & 0xFFFFFFFF, 3)
            d = rol((d + (a ^ b ^ c) + x[i + 8] + 0x6ED9EBA1) & 0xFFFFFFFF, 9)
            c = rol((c + (d ^ a ^ b) + x[i + 4] + 0x6ED9EBA1) & 0xFFFFFFFF, 11)
            b = rol((b + (c ^ d ^ a) + x[i + 12] + 0x6ED9EBA1) & 0xFFFFFFFF, 15)
        a, b, c, d = (a + aa) & 0xFFFFFFFF, (b + bb) & 0xFFFFFFFF, (c + cc) & 0xFFFFFFFF, (d + dd) & 0xFFFFFFFF
    return struct.pack("<4I", a, b, c, d)


def content(n):
    return bytes((i * 7 + 3) % 253 for i in range(n))


FILES = {}      # hash -> (data, part_hashes)
READY = threading.Event()


def prepare():
    for size in (600000, 10500000):
        data = content(size)
        parts = [md4(data[o:o + PART]) for o in range(0, size, PART)]
        file_hash = parts[0] if len(parts) == 1 else md4(b"".join(parts))
        FILES[file_hash] = (data, parts)
    READY.set()


def packet(proto, opcode, payload=b""):
    return bytes([proto]) + struct.pack("<I", len(payload) + 1) + bytes([opcode]) + payload


def packets(sock):
    buf = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return
        buf += chunk
        while len(buf) >= 6:
            length = struct.unpack("<I", buf[1:5])[0]
            if length < 1 or length > 1 << 20:
                return
            if len(buf) < 5 + length:
                break
            yield buf[0], buf[5], buf[6:5 + length]
            buf = buf[5 + length:]


class ServerHandler(socketserver.BaseRequestHandler):
    def handle(self):
        s = self.request
        s.settimeout(30)
        try:
            for proto, op, payload in packets(s):
                if op == 0x01:
                    with LOCK:
                        STATS["logins"] += 1
                    msg = b"fixture server"
                    s.sendall(packet(0xE3, 0x38, struct.pack("<H", len(msg)) + msg))
                    s.sendall(packet(0xE3, 0x40, bytes([127, 0, 0, 1])))      # a high ID: the address read as the id
                    s.sendall(packet(0xE3, 0x34, struct.pack("<II", 1, len(FILES))))
                elif op == 0x19:
                    READY.wait(60)
                    with LOCK:
                        STATS["getsources"] += 1
                    h = payload[:16]
                    sources = [BAD, GOOD] if h in FILES else []
                    body = h + bytes([len(sources)]) + b"".join(bytes([127, 0, 0, 1]) + struct.pack("<H", p) for p in sources)
                    s.sendall(packet(0xE3, 0x42, body))
        except OSError:
            pass


class PeerHandler(socketserver.BaseRequestHandler):
    bad = False

    def handle(self):
        s = self.request
        s.settimeout(30)
        current = None
        try:
            READY.wait(60)
            for proto, op, payload in packets(s):
                if op == 0x01:
                    with LOCK:
                        STATS["hello"] += 1
                    s.sendall(packet(0xE3, 0x4C, bytes(range(16)) + struct.pack("<IHI", 0, 4662, 0) + struct.pack("<IH", 0, 0)))
                elif op in (0x58, 0x4F, 0x51, 0x54, 0x47):
                    h = payload[:16]
                    if h not in FILES:
                        s.sendall(packet(0xE3, 0x48, h))
                        continue
                    data, parts = FILES[h]
                    if op == 0x58:
                        s.sendall(packet(0xE3, 0x59, h + struct.pack("<H", 3) + b"abc"))
                    elif op == 0x4F and len(parts) > 1:
                        s.sendall(packet(0xE3, 0x50, h + struct.pack("<H", len(parts)) + bytes([(1 << len(parts)) - 1])))
                    elif op == 0x51:
                        s.sendall(packet(0xE3, 0x52, h + struct.pack("<H", len(parts)) + b"".join(parts)))
                    elif op == 0x54:
                        s.sendall(packet(0xE3, 0x55))
                    elif op == 0x47:
                        starts = struct.unpack("<3I", payload[16:28])
                        ends = struct.unpack("<3I", payload[28:40])
                        for a, b in zip(starts, ends):
                            if b > a and b <= len(data):
                                block = bytearray(data[a:b])
                                if self.bad:
                                    block[0] ^= 0xFF
                                with LOCK:
                                    STATS["bad_blocks" if self.bad else "good_blocks"] += 1
                                s.sendall(packet(0xE3, 0x46, h + struct.pack("<II", a, b) + bytes(block)))
        except OSError:
            pass


class BadPeer(PeerHandler):
    bad = True


class Stats(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.recv(16)
        with LOCK:
            self.request.sendall((json.dumps(STATS) + "\n").encode())


class TCP(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    threading.Thread(target=prepare, daemon=True).start()
    servers = [TCP(("127.0.0.1", SERVER), ServerHandler), TCP(("127.0.0.1", GOOD), PeerHandler), TCP(("127.0.0.1", BAD), BadPeer), TCP(("127.0.0.1", SERVER + 10), Stats)]
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print("READY", flush=True)
    threading.Event().wait()


main()
