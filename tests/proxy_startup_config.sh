#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings",
    "dns_type": "doh", "dns_server": "https://dns.example.com/dns-query",
    "bootstrap_dns_server": "1.1.1.1",
    "dns_detour_enabled": "1", "dns_detour_section": "verdian",
    "list_update_enabled": "1",
    "download_lists_via_proxy": "1", "download_lists_via_proxy_section": "verdian",
    "download_components_via_proxy": "1", "download_components_via_proxy_section": "verdian"
  },
  "section": [{
    ".name": "verdian", ".type": "section", "enabled": "1", "action": "outbound",
    "outbound_json": "{\"type\":\"socks\",\"server\":\"proxy.example.com\",\"server_port\":1080}",
    "community_lists": ["discord"],
    "rule_set": ["https://example.com/domains.json"]
  }]
}
JSON

for version in 1.12.25 1.13.0-extended 1.14.0-alpha.1 1.14.0-extended 1.16.0; do
  ucode -L "$LIB_DIR" "$LIB_DIR/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/$version.json" 127.0.0.1 0 1 '' 0 "$version"
done

ucode -e '
let fs = require("fs");
function assert(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }
for (let version in ["1.12.25", "1.13.0-extended", "1.14.0-alpha.1", "1.14.0-extended", "1.16.0"]) {
    let config = json(fs.readfile(ARGV[0] + "/" + version + ".json"));
    let modern = index(version, "1.12.") != 0 && index(version, "1.13.") != 0;
    assert(config.route.default_domain_resolver == "bootstrap-dns-server", version + ": proxy hostname must bootstrap directly");
    let main = filter(config.dns.servers, s => s.tag == "dns-server")[0];
    assert(main.detour == "verdian-out", version + ": main DNS must keep its proxy section");
    assert(main.domain_resolver == "bootstrap-dns-server", version + ": DoH hostname must bootstrap directly");
    for (let tag in ["service-mixed-in", "service-components-in"])
        assert(length(filter(config.route.rules, r => r.inbound == tag && r.outbound == "verdian-out")) == 1,
            version + ": lists/components must keep their proxy section");
    assert(length(config.route.rule_set) == 2, version + ": community and custom rule-sets must be present");
    for (let ruleset in config.route.rule_set) {
        if (modern) {
            assert(ruleset.download_detour == null && ruleset.http_client.detour == "verdian-out",
                version + ": remote lists must use the new HTTP client through the selected section");
            assert(ruleset.http_client.domain_resolver == "bootstrap-dns-server", version + ": list hostnames must bootstrap directly");
        }
        else {
            assert(ruleset.download_detour == "verdian-out" && ruleset.http_client == null,
                version + ": older cores must keep compatible download options");
        }
    }
    assert(modern ? config.dns.independent_cache == null : config.dns.independent_cache === true,
        version + ": DNS cache option must match the core version");
}
' "$WORK_DIR"

printf 'Proxy startup configuration checks passed\n'
