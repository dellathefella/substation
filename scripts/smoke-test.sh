#!/usr/bin/env bash
# Substation smoke test against the release daemon (fake engines).
# Usage: ./scripts/smoke-test.sh   (run from repo root)
set -u
cd "$(dirname "$0")/.."
BIN=daemon/.build/debug/substationd
[ -x daemon/.build/release/substationd ] && BIN=daemon/.build/release/substationd
pkill -f substationd 2>/dev/null; pkill -f fake-engine 2>/dev/null; sleep 1
rm -rf state-smoke state-smoke-node

"$BIN" --config daemon/config/substation.smoke.toml --data state-smoke > /tmp/subd.log 2>&1 &
CTRL=$!
sleep 6

echo "== 1. non-stream {model:auto} — response.model must echo 'auto'"
curl -s localhost:8800/v1/chat/completions -d '{"model":"auto","messages":[{"role":"user","content":"What is 2+2? Reply briefly."}]}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('model =', d['model'], '| content =', d['choices'][0]['message']['content'])"

echo "== 2. stream {model:auto,stream:true} — every chunk model == auto"
curl -sN localhost:8800/v1/chat/completions -d '{"model":"auto","stream":true,"messages":[{"role":"user","content":"write a sorting function in code"}]}' \
  | python3 -c "
import sys, json
models = []
done = False
for line in sys.stdin:
    line = line.strip()
    if line.startswith('data: ') and line != 'data: [DONE]':
        models.append(json.loads(line[6:])['model'])
    elif line == 'data: [DONE]':
        done = True
print('chunk models =', set(models), '| [DONE] seen =', done)"

echo "== 3. transparency headers"
curl -s -D- -o /dev/null localhost:8800/v1/chat/completions -d '{"model":"auto-fast","messages":[{"role":"user","content":"hi"}]}' \
  | tr -d '\r' | grep -i '^x-substation'

echo "== 4. cache: repeat identical request, then /api/cache"
for i in 1 2 3; do curl -s localhost:8800/v1/chat/completions -d '{"model":"auto","messages":[{"role":"user","content":"What is 2+2? Reply briefly."}]}' > /dev/null; done
curl -s localhost:8800/api/cache | python3 -c "import json,sys; d=json.load(sys.stdin); print('enabled=%s entries=%s hit_ratio=%s' % (d['enabled'], d['entries'], d['hit_ratio']))"

echo "== 5. triage endpoint 404 -> heuristic fallback (triage fake-engine returns 404 on response_format)"
curl -s "localhost:8800/api/events?limit=120" | python3 -c "
import json,sys
evs = json.load(sys.stdin)
tri = [e for e in evs if e['type']=='triage.decision']
print('triage.decision methods =', {e['data']['method'] for e in tri}, 'tiers =', {e['data']['tier'] for e in tri})"

echo "== 6. event ring contains triage.decision + route.selected + stream.done"
curl -s "localhost:8800/api/events?limit=200" | python3 -c "
import json,sys
types = {e['type'] for e in json.load(sys.stdin)}
need = {'triage.decision','route.selected','stream.done'}
print('present:', sorted(need & types), '| missing:', sorted(need - types))"

echo "== 7. /api/metrics non-empty"
curl -s localhost:8800/api/metrics | python3 -c "import json,sys; d=json.load(sys.stdin); print('counters =', json.dumps(d['counters']), '| ttft p50/p95/p99 =', d['percentiles']['ttft_ms'])"

echo "== 8. WS /ws receives events (raw-socket python client)"
python3 - <<'EOF'
import socket, base64, os, struct, json, threading, urllib.request, time
s = socket.create_connection(("127.0.0.1", 8800), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf: buf += s.recv(4096)
head, rest = buf.split(b"\r\n\r\n", 1)
assert b"101" in head, head[:40]
def fire():
    time.sleep(1)
    req = urllib.request.Request("http://127.0.0.1:8800/v1/chat/completions",
        data=b'{"model":"auto","messages":[{"role":"user","content":"summarize the treaty of versailles"}]}',
        headers={"Content-Type":"application/json"})
    urllib.request.urlopen(req).read()
threading.Thread(target=fire).start()
def one_frame(d):
    if len(d) < 2: return None, 0
    ln = d[1] & 0x7F; i = 2
    if ln == 126: ln = struct.unpack("!H", d[i:i+2])[0]; i += 2
    elif ln == 127: ln = struct.unpack("!Q", d[i:i+8])[0]; i += 8
    return (d[i:i+ln].decode(), i+ln) if len(d) >= i+ln else (None, 0)
types, data = [], rest
s.settimeout(6)
try:
    while True:
        fr, n = one_frame(data)
        if fr is None:
            chunk = s.recv(65535)
            if not chunk: break
            data = data[n:] + chunk; continue
        data = data[n:]
        types.append(json.loads(fr)["type"])
except socket.timeout: pass
print("WS frames:", types)
EOF

echo "== 9. pause -> 503 code 'paused', resume -> 200"
curl -s -X POST localhost:8800/api/admin/pause > /dev/null
curl -s -o /dev/null -w "paused http=%{http_code} " localhost:8800/v1/chat/completions -d '{"model":"auto","messages":[{"role":"user","content":"hi"}]}'
curl -s localhost:8800/v1/chat/completions -d '{"model":"auto","messages":[{"role":"user","content":"hi"}]}'
echo
curl -s -X POST localhost:8800/api/admin/resume > /dev/null
curl -s -o /dev/null -w "resumed http=%{http_code}\n" localhost:8800/v1/chat/completions -d '{"model":"auto","messages":[{"role":"user","content":"hi"}]}'

echo "== 10. join-code + CLI join (node agent on :8801)"
SUBSTATION_BIND=0.0.0.0 "$BIN" --role node --config daemon/config/substation.smoke.toml --data state-smoke-node > /tmp/subd-node.log 2>&1 &
NODE=$!
sleep 2
CODE=$(curl -s -X POST localhost:8800/api/admin/join-code | python3 -c "import json,sys; print(json.load(sys.stdin)['code'])")
"$BIN" join --controller 127.0.0.1 --code "$CODE" | python3 -c "import json,sys; print('join ->', json.load(sys.stdin))"
sleep 6
curl -s localhost:8800/api/nodes | python3 -c "
import json,sys
for n in json.load(sys.stdin):
    print('node', n['id'][:8], 'healthy =', n['healthy'], '| link =', n['link'])"
curl -s "localhost:8800/api/events?limit=120" | python3 -c "
import json,sys
t = [e['type'] for e in json.load(sys.stdin)]
print('cluster events:', [x for x in set(t) if x in ('cluster.warning','node.health','config.changed')])"

kill $CTRL $NODE 2>/dev/null
pkill -f fake-engine 2>/dev/null
echo "== done"
