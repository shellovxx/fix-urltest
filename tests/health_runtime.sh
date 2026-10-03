#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FORKOP_LIB="$ROOT/forkop/files/usr/lib"
WORK="$(mktemp -d)"
export FORKOP_RUNTIME_STATE_DIR="$WORK/runtime"
export FORKOP_HEALTH_CONFIG_PATH="$WORK/config.json"
export HEALTH_MOCK_DIR="$WORK"
cleanup() {
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/health.uc" stop-runtime || true
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/bin" "$WORK/runtime/section-cache"
cat > "$WORK/config.json" <<'JSON'
{"experimental":{"clash_api":{"external_controller":"192.168.99.1:9090"}},"inbounds":[{"tag":"forkop-health-in","listen":"127.0.0.1","listen_port":4536,"users":[{"username":"a","password":"test"},{"username":"b","password":"test"}]}],"outbounds":[{"type":"selector","tag":"best","outbounds":["a","b"]}],"route":{"rules":[{"inbound":"forkop-health-in","auth_user":"a","outbound":"a"},{"inbound":"forkop-health-in","auth_user":"b","outbound":"b"}]}}
JSON
cat > "$WORK/runtime/section-cache/main.json" <<'JSON'
{"healthGroups":{"best":{"tag":"best","section":"main","outbounds":["a","b"],"maxLatency":300}},"healthNodes":{"a":{"fingerprint":"a"},"b":{"fingerprint":"b"}}}
JSON
cat > "$WORK/bin/curl" <<'PY'
#!/usr/bin/env python3
import sys,json,os,fcntl
from pathlib import Path
root=Path(os.environ['HEALTH_MOCK_DIR']);args=sys.argv[1:];url=args[-1]
with (root/'lock').open('a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 path=root/'mock.json';state=json.loads(path.read_text()) if path.exists() else {'active':'a','payload':{},'deletes':[],'switches':[]}
 if '/delay?' in url:
  print(json.dumps({'delay':10 if '/a/' in url else 100}))
 elif url.endswith('/proxies'):
  print(json.dumps({'proxies':{'best':{'now':state['active']}}}))
 elif url.endswith('/proxies/best'):
  state['active']=json.loads(args[args.index('--data-binary')+1])['name'];state['switches'].append(state['active'])
 elif url.endswith('/connections'):
  print(json.dumps({'connections':[{'id':'own-old','chains':['a','best','main-out']},{'id':'other-group','chains':['a','other']},{'id':'new-node','chains':['b','best']},{'id':'direct','chains':['direct']}]}))
 elif '/connections/' in url:
  state['deletes'].append(url.rsplit('/',1)[1])
 elif 'generate_204' in url:
  print('204 0')
 elif '__down' in url:
  user=args[args.index('--proxy-user')+1].split(':')[0];state['payload'][user]=state['payload'].get(user,0)+1
  # Short HEAD succeeds, but old active leaf stalls after a few KB on cycles two and three.
  print('200 5503' if user=='a' and state['payload'][user]>=2 else '200 32768')
 else: sys.exit(1)
 path.write_text(json.dumps(state))
PY
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/health.uc" start-runtime
sleep 19
python3 - "$WORK" <<'PY'
import json,sys
from pathlib import Path
w=Path(sys.argv[1]);s=json.loads((w/'runtime/health-state.json').read_text());m=json.loads((w/'mock.json').read_text())
assert s['nodes']['a']['failures']==1 and s['nodes']['a']['latency']==10,s
assert m['active']=='a' and not m['deletes'],m
PY
sleep 19
python3 - "$WORK" <<'PY'
import json,sys,time
from pathlib import Path
w=Path(sys.argv[1]);s=json.loads((w/'runtime/health-state.json').read_text());m=json.loads((w/'mock.json').read_text())
assert s['groups']['best']['active']=='b' and m['active']=='b',s
assert s['nodes']['a']['failures']>=2 and s['nodes']['a']['quarantineUntil']>time.time(),s
assert m['payload']['b']>=2,'backup was not checked again'
assert m['deletes']==['own-old'],m
assert m['switches']==['b'],m
PY
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/health.uc" stop-runtime
test ! -e "$WORK/runtime/health.pid"
test -z "$(find "$WORK/runtime/health-jobs" -name '*.pid' -print)"
printf 'Smart selection runtime and targeted connection recovery checks passed\n'
