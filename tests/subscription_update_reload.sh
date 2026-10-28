#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATES_UC="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"
REAL_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

write_stub() {
  local path="$1"
  local body="$2"

  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" >"$path"
}

stub_header='#!/usr/bin/env ucode
let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'"'"'" + replace(as_string(value), /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'";
}

function record(line) {
    if (line == (getenv("FAKE_FAIL_CALL") || "")) {
        let path = getenv("FAKE_CALL_LOG") || "";
        let log = fs.open(path, "a");
        if (log) { log.write(line + "\n"); log.close(); }
        exit(1);
    }
    let path = getenv("FAKE_CALL_LOG") || "";
    if (path != "")
        system("printf '"'"'%s\\n'"'"' " + shell_quote(line) + " >> " + shell_quote(path));
}
'

FAKE_LIB="$WORK_DIR/lib"

write_stub "$FAKE_LIB/subscription/cache.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("subscription/cache:" + mode);
if (mode == "ensure-runtime-dirs")
    exit(0);
if (mode == "update-request") {
    print(getenv("FAKE_SUBSCRIPTION_UPDATE_SUMMARY") || "1 0 0 0", "\n");
    exit(0);
}
exit(64);
'

write_stub "$FAKE_LIB/service/state.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("service/state:" + mode);
if (mode == "sing-box-service-runtime-pid") {
    print("3285\n");
    exit(0);
}
if (mode == "acquire-runtime-dir-lock" ||
    mode == "acquire-runtime-dir-lock-wait" ||
    mode == "release-runtime-dir-lock" ||
    mode == "reload-sing-box-runtime" ||
    mode == "write-current-reload-state-clean" ||
    mode == "run-pending-reload-if-requested")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/server/service.uc" "$stub_header"'
record("server/service:" + as_string(ARGV[0]));
exit(ARGV[0] == "prepare-all-defaults" ? 0 : 64);
'

write_stub "$FAKE_LIB/config/validator.uc" "$stub_header"'
record("config/validator:" + as_string(ARGV[0]));
exit(ARGV[0] == "validate-runtime" ? 0 : 64);
'

write_stub "$FAKE_LIB/singbox/runtime.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
if (mode == "init-config")
    record("singbox/runtime:init-config:" + as_string(ARGV[1]) + ":" + as_string(ARGV[2]) + ":" + as_string(ARGV[3]));
else
    record("singbox/runtime:" + mode);
if (mode == "configure-service" || mode == "init-config")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/priority.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/priority:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/dns_failover.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/dns_failover:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/health.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/health:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

run_update() {
  local summary="$1"
  local log="$2"
  local fail_call="${3:-}"

  : >"$log"
  env \
    FORKOP_LIB="$FAKE_LIB" \
    FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/subscription-update.lock" \
    FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock" \
    FORKOP_SUBSCRIPTION_UPDATE_STATE_DIR="$WORK_DIR/run/subscription-update" \
    FORKOP_SUBSCRIPTION_UPDATE_JOB_DIR="$WORK_DIR/run/subscription-update-jobs" \
    FORKOP_SUBSCRIPTION_LINKS_DIR="$WORK_DIR/run/subscription-links" \
    FORKOP_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/run/subscription-metadata" \
    FORKOP_OUTBOUND_METADATA_DIR="$WORK_DIR/run/outbound-metadata" \
    FORKOP_SECTION_CACHE_DIR="$WORK_DIR/run/section-cache" \
    FORKOP_RUNTIME_CACHE_FORMAT_FILE="$WORK_DIR/run/cache-format" \
    FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent/subscription-cache" \
    FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$WORK_DIR/persistent/subscription-cache/cache-format" \
    FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending" \
    FORKOP_RELOAD_STATE_FILE="$WORK_DIR/run/reload-state" \
    FORKOP_RULE_CONDITION_CACHE_DIR="$WORK_DIR/run/rule-condition-cache" \
    FAKE_CALL_LOG="$log" \
    FAKE_FAIL_CALL="$fail_call" \
    FAKE_SUBSCRIPTION_UPDATE_SUMMARY="$summary" \
    ucode -L "$REAL_LIB" "$UPDATES_UC" subscription-update-if-due
}

updated_log="$WORK_DIR/updated.log"
run_update "1 0 0 0" "$updated_log"

node - "$updated_log" <<'JS'
const fs = require("fs");
const calls = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n+/);
const expected = [
  "subscription/cache:update-request",
  "server/service:prepare-all-defaults",
  "config/validator:validate-runtime",
  "singbox/runtime:configure-service",
  "service/state:sing-box-service-runtime-pid",
  "singbox/dns_failover:stop-runtime",
  "singbox/health:stop-runtime",
  "singbox/runtime:init-config:0:1:1",
  "singbox/priority:stop-runtime",
  "service/state:reload-sing-box-runtime",
  "singbox/health:start-runtime",
  "singbox/priority:start-runtime",
  "singbox/dns_failover:start-runtime",
  "service/state:write-current-reload-state-clean",
  "service/state:run-pending-reload-if-requested"
];

let position = -1;
for (const item of expected) {
  const next = calls.indexOf(item, position + 1);
  if (next === -1) {
    console.error(`missing or out-of-order call: ${item}`);
    console.error(calls.join("\n"));
    process.exit(1);
  }
  position = next;
}
JS

unchanged_log="$WORK_DIR/unchanged.log"
run_update "0 0 1 0" "$unchanged_log"

if grep -Eq 'server/service|config/validator|singbox/runtime|singbox/health|singbox/priority|singbox/dns_failover|reload-sing-box-runtime|write-current-reload-state-clean' "$unchanged_log"; then
  fail "unchanged subscription update must not rebuild or reload sing-box"
fi

for failed_call in 'singbox/runtime:init-config:0:1:1' 'service/state:reload-sing-box-runtime' 'singbox/health:start-runtime'; do
  failure_log="$WORK_DIR/failure-${failed_call//[:\/]/-}.log"
  if run_update "1 0 0 0" "$failure_log" "$failed_call"; then
    fail "failed $failed_call must report subscription update failure"
  fi
  node - "$failure_log" "$failed_call" <<'JS'
const fs = require("fs");
const calls = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n+/);
const failedCall = process.argv[3];
const failure = calls.indexOf(failedCall);
const healthStop = calls.indexOf("singbox/health:stop-runtime");
if (healthStop < 0 || healthStop >= failure)
  throw new Error("Smart selection must stop before rebuilding the runtime");
for (const call of ["singbox/health:start-runtime", "singbox/dns_failover:start-runtime"])
  if (!calls.includes(call)) throw new Error(`runtime was not recovered: ${call}`);
if (failedCall !== "singbox/runtime:init-config:0:1:1" && !calls.includes("singbox/priority:start-runtime"))
  throw new Error("Priority must recover after the reload attempt");
if (calls.includes("service/state:write-current-reload-state-clean"))
  throw new Error("failed runtime must not mark reload state clean");
JS
done

printf 'subscription update reload checks passed\n'
