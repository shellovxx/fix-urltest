// Pure selection policy: a latency sample never proves payload health.
function median(samples) {
    let values = sort([ ...samples ], (a, b) => a - b);
    return length(values) ? values[int(length(values) / 2)] : null;
}

function record(node, result, now) {
    node.checkedAt = now;
    node.checking = false;
    node.reason = result.reason || "";
    node.bytes = result.bytes || 0;
    let measured = type(result.delay) == "int" && result.delay >= 0;
    node.latencyUnavailable = !measured;
    if (measured) {
        node.samples ||= [];
        push(node.samples, result.delay);
        if (length(node.samples) > 3)
            shift(node.samples);
        node.latency = median(node.samples);
    }
    if (result.ok) {
        node.failures = 0;
        if ((node.quarantineUntil || 0) <= now)
            node.quarantineUntil = 0;
        node.status = "verified";
    }
    else {
        node.failures = (node.failures || 0) + 1;
        node.status = "failed";
        if (node.failures >= 2)
            node.quarantineUntil = now + 60;
    }
    return node;
}

function candidates(group, nodes, now) {
    return sort(filter(group.outbounds, (tag) => {
        let node = nodes[tag];
        return node && node.status == "verified" &&
            type(node.latency) == "int" && !node.latencyUnavailable &&
            (node.quarantineUntil || 0) <= now && now - node.checkedAt <= 180;
    }), (a, b) => nodes[a].latency - nodes[b].latency);
}

function decision(group, nodes, now) {
    let active = nodes[group.active];
    let available = candidates(group, nodes, now);
    let best = available[0];
    if (active && (active.failures || 0) >= 2)
        return best && best != group.active ? { tag: best, reason: "failure" } : null;
    if (!active || !group.initialized)
        return best ? { tag: best, reason: "startup" } : null;
    if (group.startup && best && nodes[best].latency < active.latency)
        return { tag: best, reason: "startup" };
    if ((group.highCycles || 0) < 3 || active.status != "verified")
        return null;
    for (let tag in available) {
        if (tag == group.active)
            continue;
        let gain = active.latency - nodes[tag].latency;
        if (gain >= 50 && gain >= active.latency * 0.2)
            return { tag, reason: "latency" };
    }
    return null;
}

return { median, record, candidates, decision };
