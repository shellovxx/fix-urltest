let fs = require("fs");
let common = require("core.common");
let rulesets = require("singbox.rulesets");

const PROBE_TAG = "forkop-health-in";
const PROBE_PORT = 4536;

function apply_reality(config, supported) {
    for (let outbound in config.outbounds) {
        let reality = outbound.tls?.reality;
        if (type(reality) != "object" || reality.enabled === false)
            continue;
        if (supported) {
            if (reality.support_x25519mlkem768 == null)
                reality.support_x25519mlkem768 = true;
        }
        else {
            delete reality.support_x25519mlkem768;
        }
    }
}

function leaf_tags(tag, outbounds, seen) {
    if (seen[tag])
        return [];
    seen = { ...seen, [tag]: true };
    let outbound = outbounds[tag];
    if (!outbound)
        return [];
    if (outbound.type == "selector" || outbound.type == "urltest") {
        let result = [];
        for (let member in common.array_or_empty(outbound.outbounds))
            for (let leaf in leaf_tags(member, outbounds, seen))
                if (index(result, leaf) < 0)
                    push(result, leaf);
        return result;
    }
    // No direct/bypass candidates: the probe must exercise a proxy tunnel.
    return outbound.server != null && outbound.type != "direct" ? [ tag ] : [];
}

function fingerprint(tag, outbounds, seen) {
    if (seen[tag])
        return "";
    seen = { ...seen, [tag]: true };
    let outbound = outbounds[tag];
    let value = sprintf("%J", outbound);
    if (outbound?.detour)
        value += fingerprint(outbound.detour, outbounds, seen);
    for (let child in common.array_or_empty(outbound?.outbounds))
        value += fingerprint(child, outbounds, seen);
    return rulesets.hash12(value);
}

function configure(config, section, state, start_index) {
    if (!common.bool_option(section, "health_selection_enabled", false))
        return;
    let outbounds = {};
    for (let outbound in config.outbounds)
        outbounds[outbound.tag] = outbound;
    let groups = {};
    // Resolve members before transforming nested groups.
    for (let i = start_index; i < length(config.outbounds); i++) {
        let outbound = config.outbounds[i];
        if (outbound.type == "urltest") {
            let members = leaf_tags(outbound.tag, outbounds, {});
            if (!length(members))
                die("Smart selection group has no proxy candidates: " + outbound.tag);
            groups[outbound.tag] = {
                tag: outbound.tag,
                section: section[".name"],
                outbounds: members,
                maxLatency: int(section.health_max_latency || 300)
            };
        }
    }
    if (!length(groups))
        return;
    let probe = null;
    for (let inbound in config.inbounds)
        if (inbound.tag == PROBE_TAG)
            probe = inbound;
    if (probe && (probe.type != "socks" || probe.listen != "127.0.0.1" || type(probe.users) != "array"))
        die("Smart selection probe tag is already used by another inbound");
    if (!probe) {
        probe = { type: "socks", tag: PROBE_TAG, listen: "127.0.0.1", listen_port: PROBE_PORT, users: [] };
        push(config.inbounds, probe);
        // Last probe rule rejects requests without a mapped identity.
        unshift(config.route.rules, { inbound: PROBE_TAG, action: "reject" });
    }
    let password = trim(fs.readfile("/proc/sys/kernel/random/uuid") || "");
    if (length(password) < 32)
        die("Cannot generate smart selection probe credentials");
    // Keep credentials stable across reloads to avoid gratuitous core restarts.
    let saved = getenv("FORKOP_HEALTH_PASSWORD_FILE") || "/var/run/forkop/health-password";
    let previous = trim(fs.readfile(saved) || "");
    if (length(previous) >= 32)
        password = previous;
    else if (!getenv("FORKOP_HEALTH_FIXTURE")) {
        fs.writefile(saved, password + "\n");
        fs.chmod(saved, 0600);
    }
    state.healthGroups = groups;
    state.healthNodes = {};
    for (let tag, group in groups) {
        let outbound = outbounds[tag];
        outbound.type = "selector";
        outbound.outbounds = group.outbounds;
        outbound.default = group.outbounds[0];
        outbound.interrupt_exist_connections = false;
        for (let key in [ "url", "interval", "tolerance", "idle_timeout" ])
            delete outbound[key];
        if (state.urltestGroups[tag]) {
            state.urltestGroups[tag].managed = true;
            state.urltestGroups[tag].maxLatency = group.maxLatency;
            state.urltestGroups[tag].outbounds = group.outbounds;
        }
        for (let member in group.outbounds) {
            state.healthNodes[member] = { fingerprint: fingerprint(member, outbounds, {}) };
            let username = "hp-" + rulesets.hash12(member);
            if (length(filter(probe.users, (user) => user.username == username)))
                continue;
            push(probe.users, { username, password });
            unshift(config.route.rules, { inbound: PROBE_TAG, auth_user: username, action: "route", outbound: member });
        }
    }
}

function refresh_fingerprints(config, state) {
    let outbounds = {};
    for (let outbound in config.outbounds) outbounds[outbound.tag] = outbound;
    for (let tag, node in state.healthNodes || {}) node.fingerprint = fingerprint(tag, outbounds, {});
}

function finalize_probe(config) {
    let probe = null, occupied = {};
    for (let inbound in config.inbounds) {
        if (inbound.tag == PROBE_TAG) probe = inbound;
        else if (inbound.listen_port) occupied[inbound.listen_port] = true;
    }
    if (!probe) return;
    let port = PROBE_PORT;
    while (occupied[port] && port < 65535) port++;
    if (occupied[port]) die("Cannot allocate localhost smart selection probe port");
    probe.listen_port = port;
}

return { apply_reality, configure, refresh_fingerprints, finalize_probe, PROBE_TAG, PROBE_PORT };
