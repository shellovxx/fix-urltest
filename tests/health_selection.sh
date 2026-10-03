#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FORKOP_HEALTH_FIXTURE=1

ucode -L "$LIB" -e '
let p = require("singbox.health_policy");
function expect(value, label) { if (!value) die(label + "\n"); }
let a = { samples: [] }, b = { samples: [] }, nodes = { a, b };
let group = { active: "a", initialized: true, outbounds: ["a", "b"], highCycles: 0 };
for (let delay in [280, 310, 290]) p.record(a, {ok:true,delay}, 100);
p.record(b, {ok:true,delay:100}, 100);
expect(a.latency == 290 && p.decision(group,nodes,100) == null, "hold healthy median below 300");
p.record(a,{ok:false,reason:"timeout"},101);
expect(p.decision(group,nodes,101) == null, "single failure must not switch");
p.record(a,{ok:false,reason:"partial",bytes:5503},116);
expect(a.quarantineUntil == 176 && p.decision(group,nodes,116).reason == "failure", "two failures must quarantine and fail over");
p.record(b,{ok:false,reason:"http-500"},117);
expect(p.decision(group,nodes,117) == null, "no healthy candidate must not produce direct fallback");
p.record(a,{ok:true,delay:100},130);
expect(a.quarantineUntil == 176 && p.candidates(group,nodes,130)[0] == null, "early recovery must respect minimum quarantine");
p.record(a,{ok:true,delay:350},180);p.record(a,{ok:true,delay:350},180);p.record(a,{ok:true,delay:350},180);
p.record(b,{ok:true,delay:290},180); group.highCycles=2;
expect(p.decision(group,nodes,180) == null, "three high cycles required");
group.highCycles=3;
expect(p.decision(group,nodes,180) == null, "60ms gain does not meet 20 percent");
p.record(b,{ok:true,delay:270},180);p.record(b,{ok:true,delay:270},180);
expect(p.decision(group,nodes,180).reason == "latency", "50ms AND 20 percent improvement");
expect(a.status == "verified" && a.failures == 0, "recovery resets failures");
group.initialized=false;
expect(p.decision(group,nodes,180).tag == "b", "startup chooses fastest verified");
expect(p.decision(group,nodes,361) == null, "stale candidate cannot be selected");
p.record(b,{ok:true,delay:null,reason:"latency-unavailable",bytes:32768},362);
expect(b.status == "verified" && b.failures == 0, "HEAD failure must not overwrite successful payload health");
expect(p.candidates(group,nodes,362)[0] == null, "unknown RTT candidate must not be ranked as zero");

'

for data in '{"status":28,"output":"200 5503"}' '{"status":18,"output":"200 8000"}' '{"status":0,"output":"500 32768"}' '{"status":60,"output":"000 0"}' '{"status":0,"output":"204 0"}'; do
  result="$(printf '%s' "$data" | ucode -L "$LIB" "$LIB/singbox/health.uc" classify-fixture 200 32768)"
  ucode -e 'if (json(ARGV[0]).ok) die("partial, HTTP, TLS and empty responses must fail\n");' "$result"
done
printf '%s' '{"status":0,"output":"200 32768"}' | ucode -L "$LIB" "$LIB/singbox/health.uc" classify-fixture 200 32768 > "$WORK/result"
ucode -e 'if (!json(require("fs").readfile(ARGV[0])).ok) die("complete payload rejected\n");' "$WORK/result"

ucode -L "$LIB" -e '
let fs=require("fs"), h=require("singbox.health_config");
let config={inbounds:[],route:{rules:[]},outbounds:[
 {type:"vless",tag:"a",server:"a.example",server_port:443,tls:{enabled:true,reality:{enabled:true,public_key:"key"}}},
 {type:"vless",tag:"b",server:"b.example",tls:{enabled:true,reality:{enabled:true,public_key:"key",support_x25519mlkem768:false}}},
 {type:"direct",tag:"direct"},
 {type:"urltest",tag:"inner",outbounds:["a","direct"],url:"https://example/204",interval:"30s"},
 {type:"urltest",tag:"best",outbounds:["inner","b"]}
]};
let state={urltestGroups:{inner:{},best:{}}};
h.apply_reality(config,true);
if (config.outbounds[0].tls.reality.support_x25519mlkem768 !== true || config.outbounds[1].tls.reality.support_x25519mlkem768 !== false) die("ML-KEM default/explicit false\n");
h.configure(config,{".name":"proxy",health_selection_enabled:"1",health_max_latency:"300"},state,0);
if (config.outbounds[4].type != "selector" || config.outbounds[4].interrupt_exist_connections !== false || length(config.outbounds[4].outbounds)!=2) die("flattened managed selector\n");
if (index(config.outbounds[4].outbounds,"direct")>=0) die("direct candidate admitted\n");
if (config.inbounds[0].listen != "127.0.0.1" || length(config.inbounds[0].users)!=2) die("authenticated localhost probes\n");
for (let rule in config.route.rules) if (rule.outbound && !rule.auth_user) die("probe route lacks identity\n");
if (!state.urltestGroups.best.managed || !state.healthNodes.a.fingerprint) die("missing health metadata\n");
if (state.urltestGroups.best.maxLatency != 300 || length(state.urltestGroups.best.outbounds) != 2 || index(state.urltestGroups.best.outbounds,"inner") >= 0) die("managed details retained native group metadata\n");
let previous=state.healthNodes.a.fingerprint;
config.outbounds[0].server_port=444;
let changed={urltestGroups:{}};
// Recreate native group to verify changed node fingerprints.
config.outbounds[4].type="urltest";
h.configure(config,{".name":"proxy",health_selection_enabled:"1"},changed,0);
if (previous==changed.healthNodes.a.fingerprint) die("changed node retained fingerprint\n");
h.apply_reality(config,false);
if (config.outbounds[0].tls.reality.support_x25519mlkem768!=null || config.outbounds[1].tls.reality.support_x25519mlkem768!=null) die("stock core got extended fields\n");
'
printf '%s' '{"previous":{"fingerprint":"same","status":"failed","failures":2,"quarantineUntil":999},"node":{"fingerprint":"same"}}' | ucode -L "$LIB" "$LIB/singbox/health.uc" restore-fixture > "$WORK/state"
ucode -e 'let s=json(require("fs").readfile(ARGV[0]));if(s.status!="failed" || s.quarantineUntil!=999) die("subscription refresh lost quarantine\n");' "$WORK/state"
printf '%s' '{"previous":{"fingerprint":"old","status":"verified"},"node":{"fingerprint":"new"}}' | ucode -L "$LIB" "$LIB/singbox/health.uc" restore-fixture > "$WORK/state"
ucode -e 'if(json(require("fs").readfile(ARGV[0])).status!="unknown") die("changed node health not invalidated\n");' "$WORK/state"
printf 'Smart selection checks passed\n'
