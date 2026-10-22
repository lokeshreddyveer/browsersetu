#!/bin/bash
# Starts the AI-tool server (apps/apple/macOS/AgentServer.swift) on a spare port in a small test program and checks it over a real socket with curl:
# who is let in, a new token ending the old one at once, Stop cutting a request that is still being handled, the limit on open connections, and
# the drop of a client that never finishes a request.
#
#   scripts/test-agent-server.sh        (needs Xcode's Swift compiler; takes about 40 seconds)
#
# The unit tests cannot do this: they run inside the sandboxed App Store build, which may not open a port.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
W="$(mktemp -d)"; trap 'kill $SERVER 2>/dev/null; rm -rf "$W"' EXIT
PORT=47999; URL="http://127.0.0.1:$PORT/mcp"; TOKEN_FILE="$W/token"; STOP_FILE="$W/stop"
echo -n "token-one-token-one-token-one-token-one" > "$TOKEN_FILE"
BODY='{"jsonrpc":"2.0","id":1,"method":"ping"}'

cat > "$W/main.swift" <<'SWIFT'
import Foundation
let tokenFile = CommandLine.arguments[1], stopFile = CommandLine.arguments[2]
let server = AgentServer()
server.start(port: 47999, tokenProvider: { try? String(contentsOfFile: tokenFile, encoding: .utf8) },
             onPort: { print("READY \($0)"); fflush(stdout) }, onFailure: { print("FAIL \($0)"); exit(1) },
             handle: { body in
    let text = String(data: body, encoding: .utf8) ?? ""
    if text.contains("notifications/") { return nil }
    if text.contains("slow") { try? await Task.sleep(nanoseconds: 4_000_000_000) }
    return Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
})
let started = Date()
while Date().timeIntervalSince(started) < 90 {
    if FileManager.default.fileExists(atPath: stopFile) { server.stop(); print("STOPPED"); fflush(stdout); try? FileManager.default.removeItem(atPath: stopFile) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
SWIFT
echo "▸ Compiling the server..."
swiftc -D DIRECT_BUILD -o "$W/server" "$W/main.swift" apps/apple/macOS/AgentServer.swift apps/apple/Shared/AgentHTTP.swift 2>&1 | grep -E "error" && { echo "✘ did not compile"; exit 1; }
"$W/server" "$TOKEN_FILE" "$STOP_FILE" > "$W/server.log" 2>&1 & SERVER=$!
for _ in $(seq 1 50); do grep -q READY "$W/server.log" && break; sleep 0.1; done
grep -q READY "$W/server.log" || { echo "✘ the server did not start"; cat "$W/server.log"; exit 1; }

FAILS=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then printf "  ✔ %-46s %s\n" "$1" "$3"; else printf "  ✘ %-46s wanted %s, got %s\n" "$1" "$2" "$3"; FAILS=$((FAILS+1)); fi
}
code() { curl -s -m 8 -o /dev/null -w "%{http_code}" "$@"; }
T1=$(cat "$TOKEN_FILE")

echo "▸ Who is let in"
check "valid request"                    200 "$(code -X POST $URL -H "Authorization: Bearer $T1" -d "$BODY")"
check "no token"                         401 "$(code -X POST $URL -d "$BODY")"
check "wrong token"                      401 "$(code -X POST $URL -H "Authorization: Bearer nope" -d "$BODY")"
check "empty bearer"                     401 "$(code -X POST $URL -H "Authorization: Bearer " -d "$BODY")"
check "a web page (Origin header)"       403 "$(code -X POST $URL -H "Authorization: Bearer $T1" -H "Origin: https://evil.example" -d "$BODY")"
check "wrong Host header"                403 "$(code -X POST $URL -H "Authorization: Bearer $T1" -H "Host: evil.example:$PORT" -d "$BODY")"
check "localhost name"                   200 "$(code -X POST http://localhost:$PORT/mcp -H "Authorization: Bearer $T1" -d "$BODY")"
check "GET"                              405 "$(code $URL -H "Authorization: Bearer $T1")"
check "other path"                       404 "$(code -X POST http://127.0.0.1:$PORT/x -H "Authorization: Bearer $T1" -d "$BODY")"
check "notification gets 202, no body"   202 "$(code -X POST $URL -H "Authorization: Bearer $T1" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')"
check "huge declared body"               400 "$(code -X POST $URL -H "Authorization: Bearer $T1" -H "Content-Length: 99999999" -d x)"
echo "▸ Only this Mac's loopback address"
LISTEN=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | sort -u | tr '\n' ' ')
check "listening address"                "127.0.0.1:$PORT " "$LISTEN"

echo "▸ A new token ends the old one at once"
echo -n "token-two-token-two-token-two-token-two" > "$TOKEN_FILE"; T2=$(cat "$TOKEN_FILE")
check "old token after renewal"          401 "$(code -X POST $URL -H "Authorization: Bearer $T1" -d "$BODY")"
check "new token"                        200 "$(code -X POST $URL -H "Authorization: Bearer $T2" -d "$BODY")"

echo "▸ Stop cuts a request that is still being handled"
( code -X POST $URL -H "Authorization: Bearer $T2" -d '{"jsonrpc":"2.0","id":2,"method":"slow"}' > "$W/inflight" ) &
sleep 1; touch "$STOP_FILE"; wait $! 2>/dev/null
for _ in $(seq 1 30); do grep -q STOPPED "$W/server.log" && break; sleep 0.1; done
check "request in progress when stopped"  000 "$(cat "$W/inflight")"
check "new request after stopping"        000 "$(code -X POST $URL -H "Authorization: Bearer $T2" -d "$BODY")"

# The server cannot restart in this small program, so the last two checks use a second copy.
kill $SERVER 2>/dev/null; sleep 0.5
"$W/server" "$TOKEN_FILE" "$STOP_FILE" > "$W/server2.log" 2>&1 & SERVER=$!
for _ in $(seq 1 50); do grep -q READY "$W/server2.log" && break; sleep 0.1; done

echo "▸ Limits on open connections"
for i in $(seq 1 10); do ( exec 3<>/dev/tcp/127.0.0.1/$PORT; sleep 14 ) 2>/dev/null & done
sleep 1.5
CROWDED=$(code -X POST $URL -H "Authorization: Bearer $T2" -d "$BODY")
check "10 idle connections crowd out a 9th"  000 "$CROWDED"
sleep 12
check "idle connections dropped after ~10s" 200 "$(code -X POST $URL -H "Authorization: Bearer $T2" -d "$BODY")"
wait 2>/dev/null

echo
if [ "$FAILS" = 0 ]; then echo "✔ All checks passed"; else echo "✘ $FAILS check(s) failed"; exit 1; fi
