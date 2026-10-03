#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PARSER="$LIB/subscription/parser.uc"
for value in 0 1; do
  ucode -L "$LIB" "$PARSER" share-link-outbound "vless://00000000-0000-4000-8000-000000000001@a.example:443?security=reality&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&fp=chrome&support-x25519mlkem768=$value#Reality" reality > "$WORK/node.json"
  ucode -L "$LIB" -e '
    let node=json(require("fs").readfile(ARGV[0]));
    let expected=ARGV[1]=="1";
    if (node.tls.reality.support_x25519mlkem768 !== expected) die("link import lost explicit ML-KEM value\n");
    let link=require("subscription.share_link").serialize_outbound_link(node);
    if (index(link,"support-x25519mlkem768="+ARGV[1])<0) die("link export lost explicit ML-KEM value\n");
    print(link);
  ' "$WORK/node.json" "$value" > "$WORK/link"
  ucode -L "$LIB" "$PARSER" share-link-outbound "$(cat "$WORK/link")" reality > "$WORK/roundtrip.json"
  ucode -e 'let n=json(require("fs").readfile(ARGV[0]));if(n.tls.reality.support_x25519mlkem768 !== (ARGV[1]=="1")) die("link round trip\n");' "$WORK/roundtrip.json" "$value"
done
cat > "$WORK/clash.yaml" <<'YAML'
proxies:
  - name: Reality
    type: vless
    server: a.example
    port: 443
    uuid: 00000000-0000-4000-8000-000000000001
    tls: true
    client-fingerprint: chrome
    reality-opts:
      public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      short-id: abcd
      support-x25519mlkem768: false
YAML
ucode -L "$LIB" "$PARSER" normalize-content "$WORK/clash.yaml" "$WORK/clash.json"
ucode -e 'let n=json(require("fs").readfile(ARGV[0]));if(n.outbounds[0].tls.reality.support_x25519mlkem768 !== false) die("Clash explicit false lost\n");' "$WORK/clash.json"
cat > "$WORK/sing-box.json" <<'JSON'
{"outbounds":[{"type":"vless","tag":"Reality","server":"a.example","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","support_x25519mlkem768":true}}}]}
JSON
ucode -L "$LIB" "$PARSER" normalize-content "$WORK/sing-box.json" "$WORK/normalized.json"
ucode -e 'let n=json(require("fs").readfile(ARGV[0]));if(n.outbounds[0].tls.reality.support_x25519mlkem768 !== true) die("JSON ML-KEM option lost\n");' "$WORK/normalized.json"
printf 'REALITY ML-KEM import and export checks passed\n'
ucode -L "$LIB" -e '
  let module=require("subscription.share_link");
  let node={tls:{reality:{support_x25519mlkem768:true}}};
  let original="vless://id@a.example:443?security=reality&vendor=value#Original%20Name";
  let updated=module.with_reality_mlkem(original,node,"Other name");
  if(updated!="vless://id@a.example:443?security=reality&vendor=value&support-x25519mlkem768=1#Original%20Name") die("export changed original URI metadata\n");
  let explicit="vless://id@a.example:443?security=reality&support_x25519mlkem768=0#Name";
  if(module.with_reality_mlkem(explicit,node,"Other name")!=explicit) die("export replaced explicit false\n");
'
