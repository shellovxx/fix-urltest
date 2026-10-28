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
cat > "$WORK/bin/curl" <<'PY'
#!/usr/bin/env python3
import fcntl,json,os,sys,time
from pathlib import Path
from urllib.parse import unquote,urlsplit
root=Path(os.environ['HEALTH_MOCK_DIR']);args=sys.argv[1:];url=args[-1]
with (root/'lock').open('a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 path=root/'mock.json';state=json.loads(path.read_text());route=unquote(urlsplit(url).path);status=0
 if route=='/proxies':
  print(json.dumps({'proxies':{tag:{'now':group['active']} for tag,group in state['groups'].items()}}))
 elif route.startswith('/proxies/') and route.endswith('/delay'):
  tag=route[len('/proxies/'):-len('/delay')]
  if tag not in state['nodes']: status=22
  else: print(json.dumps({'delay':state['nodes'][tag]['delay']}))
 elif route.startswith('/proxies/'):
  tag=route[len('/proxies/'):];candidate=json.loads(args[args.index('--data-binary')+1])['name']
  if tag not in state['groups'] or candidate not in state['groups'][tag]['members']: status=22
  else:
   state['groups'][tag]['active']=candidate;state['switches'].append([tag,candidate])
 elif route=='/connections': print('{"connections":[]}')
 elif 'generate_204' in url or '__down' in url:
  tag=args[args.index('--proxy-user')+1].split(':')[0]
  if tag not in state['nodes']: status=22
  elif 'generate_204' in url: print('204 0')
  else:
   state['payload'][tag]=state['payload'].get(tag,0)+1
   state['events'].append([tag,time.time()])
   print('200 32768' if state['nodes'][tag]['ok'] else '200 5503')
 else: status=22
 if status: state['missing'].append(route)
 temp=path.with_suffix('.tmp');temp.write_text(json.dumps(state));temp.replace(path)
 sys.exit(status)
PY
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
cat > "$WORK/scenario.py" <<'PY'
import fcntl,json,os,sys,time
from pathlib import Path
w=Path(sys.argv[1]);old='🇺🇸 best'
def read(path):
 return json.loads(path.read_text())
def atomic(path,value):
 temp=path.with_suffix('.fixture.tmp');temp.write_text(json.dumps(value));temp.replace(path)
def mock_update(update):
 with (w/'lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  state=read(w/'mock.json');update(state);atomic(w/'mock.json',state)
def fixture(group,members):
 groups={group:{'active':members[0],'members':members}} if group else {}
 nodes={tag:{'ok':tag=='good','delay':90 if tag=='good' else 20} for tag in members}
 if (w/'mock.json').exists(): mock_update(lambda state:state.update(groups=groups,nodes=nodes))
 else: atomic(w/'mock.json',dict(groups=groups,nodes=nodes,payload={},events=[],switches=[],missing=[]))
 config={'experimental':{'clash_api':{'external_controller':'192.168.99.1:9090'}},
  'inbounds':[{'tag':'forkop-health-in','listen':'127.0.0.1','listen_port':4536,
   'users':[{'username':tag,'password':'test'} for tag in members]}],
  'outbounds':[{'type':'selector','tag':group,'outbounds':members}] if group else [],
  'route':{'rules':[{'inbound':'forkop-health-in','auth_user':tag,'outbound':tag} for tag in members]}}
 cache={'healthGroups':{group:{'tag':group,'section':'main','outbounds':members,'maxLatency':300}} if group else {},
  'healthNodes':{tag:{'fingerprint':tag} for tag in members}}
 atomic(w/'config.json',config);atomic(w/'runtime/section-cache/main.json',cache)
def wait_for(label,predicate,timeout=12):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  try:
   state=read(w/'runtime/health-state.json');mock=read(w/'mock.json')
   if predicate(state,mock): return state,mock
  except (FileNotFoundError,json.JSONDecodeError,KeyError): pass
  time.sleep(.05)
 raise AssertionError(f'{label} timed out; state={state}; mock={mock}')
def alive(pid):
 assert (w/'runtime/health.pid').read_text().strip()==pid,'worker PID changed'
 os.kill(int(pid),0)
if sys.argv[2]=='init':
 fixture(old,['gone','bad']);now=int(time.time())
 atomic(w/'runtime/health-state.json',{'groups':{},'nodes':{
  tag:{'fingerprint':tag,'status':'failed','failures':2,'quarantineUntil':now+60,'checkedAt':now,'samples':[]}
  for tag in ['gone','bad']}})
 sys.exit()
pid=(w/'runtime/health.pid').read_text().strip()
wait_for('initial obsolete plan',lambda state,mock:old in state['groups'])
fixture('best',['bad','good'])
state,mock=wait_for('renamed selector failover',lambda state,mock:
 set(state['groups'])=={'best'} and set(state['nodes'])=={'bad','good'} and
 state['groups']['best']['active']=='good' and mock['groups']['best']['active']=='good')
assert state['nodes']['bad']['failures']>=2,state
assert state['nodes']['good']['status']=='verified',state
assert mock['payload']['good']>=2,'replacement must be verified again before switching'
assert ['best','good'] in mock['switches'],mock
alive(pid)
# A Clash selection made outside this worker must become visible and be checked.
before=state['nodes']['bad']['checkedAt'];bad_checks=mock['payload'].get('bad',0)
mock_update(lambda state:state['groups']['best'].update(active='bad'))
wait_for('external selection synchronization',lambda state,mock:state['groups']['best']['active']=='bad')
wait_for('external selection immediate probe',lambda state,mock:
 state['nodes']['bad']['checkedAt']>before and mock['payload'].get('bad',0)>bad_checks)
wait_for('external failed selection recovery',lambda state,mock:
 state['groups']['best']['active']=='good' and mock['groups']['best']['active']=='good')
# Config generation can briefly contain no managed selectors. Keep the same watcher.
fixture(None,[])
wait_for('empty plan reconciliation',lambda state,mock:not state['groups'] and not state['nodes'])
alive(pid)
fixture('best',['bad','good'])
state,mock=wait_for('selector reappears',lambda state,mock:
 set(state['nodes'])=={'bad','good'} and state['groups']['best']['active']=='good' and
 mock['groups']['best']['active']=='good')
alive(pid)
assert not any(tag=='gone' for tag,at in mock['events'] if at>state['updatedAt']-3),mock
print('Smart selection configuration reconciliation and external selection checks passed')
PY
python3 "$WORK/scenario.py" "$WORK" init
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/health.uc" start-runtime
python3 "$WORK/scenario.py" "$WORK" verify
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/health.uc" stop-runtime
test ! -e "$WORK/runtime/health.pid"
test -z "$(find "$WORK/runtime/health-jobs" -name '*.pid' -print)"
