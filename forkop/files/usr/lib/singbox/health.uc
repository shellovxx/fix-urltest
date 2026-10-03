#!/usr/bin/env ucode
// One controller owns managed URLTest selectors; child probes never change selection.
let fs = require("fs");
let common = require("core.common");
let policy = require("singbox.health_policy");
const LIB = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const STATE = DIR + "/health-state.json";
const JOBS = DIR + "/health-jobs";
const PID = DIR + "/health.pid";
const SELF = LIB + "/singbox/health.uc";
const GOOGLE = "https://www.gstatic.com/generate_204";
const PAYLOAD = "https://speed.cloudflare.com/__down?bytes=32768";

function quote(value) {
    return "'" + replace(common.as_string(value), /'/g, "'\\''") + "'";
}
function command(args) { return join(" ", map(args, quote)); }
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: 1, output: "" };
    let output = pipe.read("all") || "";
    let status = int(pipe.close());
    return { output, status: status > 255 ? int(status / 256) : status };
}
function atomic(path, value) {
    if (common.write_json_file(path + ".tmp", value) == null)
        return false;
    return fs.rename(path + ".tmp", path);
}
function encode(value) {
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let c = substr(value, i, 1);
        result += match(c, /^[a-zA-Z0-9_.~-]$/) ? c : sprintf("%%%02X", ord(c));
    }
    return result;
}
function current_config() {
    if (getenv("FORKOP_HEALTH_CONFIG_PATH"))
        return common.read_json_file(getenv("FORKOP_HEALTH_CONFIG_PATH")) || {};
    let path = trim(capture([ "uci", "-q", "get", "forkop.settings.config_path" ]).output);
    return common.read_json_file(path || "/etc/sing-box/config.json") || {};
}
function api(config, method, path, body) {
    let clash = config.experimental?.clash_api || {};
    let controller = clash.external_controller || "";
    if (!match(controller, /:[0-9]+$/)) return null;
    // Forkop may bind Clash API to the LAN address instead of loopback.
    if (index(controller, "0.0.0.0:") == 0) controller = "127.0.0.1" + substr(controller, 7);
    if (index(controller, "[::]:") == 0) controller = "127.0.0.1" + substr(controller, 4);
    if (substr(controller, 0, 1) == ":") controller = "127.0.0.1" + controller;
    let args = [ "curl", "-q", "--noproxy", "*", "-fsS", "--max-time", "4", "-X", method ];
    if (clash.secret) push(args, "-H", "Authorization: Bearer " + clash.secret);
    if (body != null) push(args, "-H", "Content-Type: application/json", "--data-binary", sprintf("%J", body));
    push(args, "http://" + controller + path);
    let result = capture(args);
    if (result.status != 0) return null;
    if (!length(trim(result.output))) return {};
    try { return json(result.output); } catch (e) { return null; }
}

// A successful short HEAD alone is never sufficient, including HTTP 204.
function classify(result, expected_status, expected_bytes) {
    let fields = split(trim(result.output), /\s+/);
    let status = int(fields[0] || 0);
    let bytes = int(fields[1] || 0);
    if (result.status != 0) {
        let reason = result.status == 28 ? "timeout" :
            index([ 35, 51, 58, 60, 77, 80, 83, 90, 91 ], result.status) >= 0 ? "tls" :
            result.status == 18 ? "partial" : "connection";
        return { ok: false, reason, bytes };
    }
    if (status != expected_status) return { ok: false, reason: "http-" + status, bytes };
    if (bytes != expected_bytes) return { ok: false, reason: "partial", bytes };
    return { ok: true, reason: "", bytes };
}
function transfer(inbound, user, url, status, bytes, timeout) {
    // Explicit proxy and empty no_proxy prevent environment settings from bypassing the tunnel.
    return classify(capture([
        "curl", "-q", "--noproxy", "", "--proxy", "socks5h://127.0.0.1:" + inbound.listen_port,
        "--proxy-user", user.username + ":" + user.password,
        "--proto", "=https", "--connect-timeout", "3", "--max-time", "" + timeout,
        "--max-filesize", "32768", "-sS", "-o", "/dev/null", "-w", "%{http_code} %{size_download}", url
    ]), status, bytes);
}
function probe(tag, path) {
    let config = current_config();
    let inbound = filter(config.inbounds || [], (item) => item.tag == "forkop-health-in")[0];
    let rule = filter(config.route?.rules || [], (item) => item.inbound == "forkop-health-in" && item.outbound == tag)[0];
    let user = filter(inbound?.users || [], (item) => item.username == rule?.auth_user)[0];
    let result = { ok: false, reason: "probe-unavailable", bytes: 0, delay: null };
    if (inbound?.listen == "127.0.0.1" && user && rule) {
        let delay = api(config, "GET", "/proxies/" + encode(tag) + "/delay?timeout=3000&url=" + encode(GOOGLE));
        if (delay?.delay != null) result.delay = int(delay.delay);
        let check = transfer(inbound, user, GOOGLE, 204, 0, 4);
        if (check.ok) check = transfer(inbound, user, PAYLOAD, 200, 32768, 6);
        result = { ...check, delay: result.delay };
        if (result.ok && result.delay == null) {
            result.reason = "latency-unavailable";
        }
    }
    atomic(path, result);
}
function plan() {
    let groups = {}, nodes = {};
    let configured = {};
    for (let outbound in current_config().outbounds || []) configured[outbound.tag] = outbound;
    for (let path in fs.glob((getenv("FORKOP_SECTION_CACHE_DIR") || DIR + "/section-cache") + "/*.json")) {
        let cache = common.read_json_file(path) || {};
        for (let tag, group in cache.healthGroups || {})
            if (configured[tag]?.type == "selector") groups[tag] = group;
        for (let tag, node in cache.healthNodes || {}) nodes[tag] = node;
    }
    let used = {};
    for (let tag, group in groups)
        for (let member in group.outbounds) used[member] = true;
    for (let tag in nodes) if (!used[tag]) delete nodes[tag];
    return { groups, nodes };
}
function close_failed(config, group, old) {
    // Never use DELETE /connections: only connections through this group AND old leaf.
    let connections = api(config, "GET", "/connections")?.connections || [];
    for (let connection in connections)
        if (index(connection.chains || [], group) >= 0 && index(connection.chains || [], old) >= 0)
            api(config, "DELETE", "/connections/" + encode(connection.id));
}
function log_switch(group, tag, reason) {
    capture([ "logger", "-t", "forkop", "health: " + group + " -> " + tag + " (" + reason + ")" ]);
}
function restore_node(previous, node) {
    if (previous?.fingerprint != node.fingerprint)
        return { ...node, samples: [], status: "unknown", failures: 0, checkedAt: 0 };
    return { ...previous, ...node, checking: false };
}
function running(pid) {
    return pid && match("" + pid, /^[0-9]+$/) && capture([ "kill", "-0", "" + pid ]).status == 0;
}
function worker() {
    let desired = plan();
    if (!length(desired.groups)) return 0;
    let config = current_config(), previous = common.read_json_file(STATE) || {};
    let state = { version: 1, nodes: {}, groups: {}, updatedAt: time() };
    for (let tag, node in desired.nodes) state.nodes[tag] = restore_node(previous.nodes?.[tag], node);
    let proxies = api(config, "GET", "/proxies")?.proxies || {};
    for (let tag, group in desired.groups) {
        let saved = previous.groups?.[tag] || {};
        let active = proxies[tag]?.now || "";
        let initialized = saved.active == active && saved.initialized &&
            previous.nodes?.[active]?.fingerprint == state.nodes[active]?.fingerprint;
        state.groups[tag] = { ...group, active, initialized, startup: !initialized,
            highCycles: saved.active == active ? saved.highCycles || 0 : 0, nextActiveCheck: time(), pending: null };
    }
    let jobs = {}, next = {}, sequence = 0;
    for (let tag in state.nodes) next[tag] = (state.nodes[tag].checkedAt || 0) + 180;
    while (true) {
        let now = time();
        for (let tag, job in jobs) {
            let result = common.read_json_file(job.path);
            if (!result && now - job.started <= 18 && running(job.pid)) continue;
            if (!result) {
                if (running(job.pid)) capture([ "/bin/kill", "-TERM", "-" + job.pid ]);
                result = { ok: false, reason: "probe-timeout" };
            }
            policy.record(state.nodes[tag], result, now);
            fs.unlink(job.path);
            fs.unlink(job.path + ".pid");
            delete jobs[tag];
            next[tag] = job.started + 180;
            for (let group_tag, group in state.groups) {
                if (group.active == tag) {
                    group.highCycles = result.ok && !state.nodes[tag].latencyUnavailable &&
                        state.nodes[tag].latency > group.maxLatency ? group.highCycles + 1 : 0;
                    // Measure start-to-start, not completion-to-start.
                    group.nextActiveCheck = job.started + 15;
                }
                if (group.pending?.tag == tag) {
                    let selected = policy.decision(group, state.nodes, now);
                    if (result.ok && selected?.tag == tag) {
                        let old = group.active;
                        if (api(config, "PUT", "/proxies/" + encode(group_tag), { name: tag }) != null) {
                            group.active = tag;
                            group.initialized = true;
                            group.highCycles = 0;
                            group.nextActiveCheck = now + 15;
                            group.switchedAt = now;
                            group.switchReason = selected.reason;
                            log_switch(group_tag, tag, selected.reason);
                            if (selected.reason == "failure") close_failed(config, group_tag, old);
                        }
                    }
                    group.pending = null;
                }
            }
        }
        let urgent = [];
        for (let group_tag, group in state.groups) {
            let selected = policy.decision(group, state.nodes, now);
            if (selected && selected.tag == group.active) group.initialized = true;
            else if (selected && !group.pending) {
                // Always repeat the backup's payload test before changing selection.
                group.pending = selected;
            }
            if (group.startup && !group.pending && group.initialized &&
                !length(filter(group.outbounds, (tag) => !state.nodes[tag]?.checkedAt))) group.startup = false;
            if (group.active && now >= group.nextActiveCheck) push(urgent, group.active);
            if (group.pending) push(urgent, group.pending.tag);
            group.status = state.nodes[group.active]?.status == "verified" && group.initialized ? "verified" :
                policy.candidates(group, state.nodes, now)[0] ? "checking" : "unavailable";
        }
        let queue = [ ...urgent, ...sort(keys(state.nodes), (a, b) => next[a] - next[b]) ];
        for (let tag in queue) {
            if (length(jobs) >= 2) break;
            if (jobs[tag]) continue;
            let urgent_node = index(urgent, tag) >= 0;
            if (!urgent_node && (now < next[tag] || now < (state.nodes[tag].quarantineUntil || 0))) continue;
            let path = JOBS + "/" + (++sequence) + ".json";
            let status = system(command([ "setsid", "ucode", "-L", LIB, SELF, "probe", tag, path ]) +
                " >/dev/null 2>&1 1000>&- & echo $! >" + quote(path + ".pid"));
            let pid = int(trim(fs.readfile(path + ".pid") || "0"));
            if (status == 0 && pid > 0) {
                jobs[tag] = { path, pid, started: now };
                state.nodes[tag].checking = true;
            }
        }
        state.updatedAt = now;
        atomic(STATE, state);
        system("sleep 1");
    }
}
function stop() {
    let pid = trim(fs.readfile(PID) || "");
    // Check command identity before acting on persistent PID files.
    if (running(pid) && index(fs.readfile("/proc/" + pid + "/cmdline") || "", SELF) >= 0)
        capture([ "/bin/kill", "-TERM", "-" + pid ]);
    fs.unlink(PID);
    for (let path in fs.glob(JOBS + "/*.pid")) {
        pid = trim(fs.readfile(path) || "");
        if (running(pid) && index(fs.readfile("/proc/" + pid + "/cmdline") || "", SELF) >= 0)
            capture([ "/bin/kill", "-TERM", "-" + pid ]);
        fs.unlink(path);
    }
    for (let path in fs.glob(JOBS + "/*.json*")) fs.unlink(path);
    return 0;
}
function start() {
    stop();
    if (!length(plan().groups)) { fs.unlink(STATE); return 0; }
    capture([ "mkdir", "-p", JOBS ]);
    fs.chmod(JOBS, 0700);
    let status = system(command([ "setsid", "ucode", "-L", LIB, SELF, "worker" ]) +
        " >" + quote(DIR + "/health.log") + " 2>&1 1000>&- & echo $! >" + quote(PID));
    if (status != 0) return 1;
    system("sleep 1");
    return running(trim(fs.readfile(PID) || "")) ? 0 : 1;
}
let mode = ARGV[0] || "";
if (mode == "start-runtime") exit(start());
else if (mode == "stop-runtime") exit(stop());
else if (mode == "worker") exit(worker());
else if (mode == "probe") probe(ARGV[1], ARGV[2]);
else if (mode == "classify-fixture") common.write_json(classify(common.read_stdin_json(), int(ARGV[1]), int(ARGV[2])));
else if (mode == "restore-fixture") { let input = common.read_stdin_json(); common.write_json(restore_node(input.previous, input.node)); }
else { warn("Usage: health.uc <start-runtime|stop-runtime|worker|probe>\n"); exit(1); }
