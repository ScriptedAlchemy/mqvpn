#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 mp0rta and mqvpn contributors
# run_reinjection_test.sh — E2E netns coverage for [Multipath] Reinjection.
#
# Reinjection (speculative multipath duplication of unacked data,
# MQVPN_REINJ_* in include/libmqvpn.h) has no CLI flag — config file/JSON
# only (see src/main.c:483-497) — so every non-"off" scenario here drives
# both endpoints via --config.
#
# Traffic direction is server -> client in every scenario, so the SERVER
# (the sender of the data that can go unacked / get duplicated) is where
# the control API's per-path "reinject_tx_bytes" (control_socket.c
# ctrl_cmd_get_status) accrues.
#
# Scenarios (all 2-path netns):
#   1. off       — default config (no [Multipath] Reinjection key). Asserts
#                  every "reinject_tx_bytes" in the server's get_status stays
#                  0, and that the "reinjection enabled: mode=" log marker
#                  never appears on either end.
#   2. deadline  — [Multipath] Reinjection = deadline on BOTH sides, with
#                  [Hybrid] Enabled=true / Tcp=stream so the stream lane is
#                  live (mqvpn_client.c:2631 / mqvpn_server.c:1855 both warn
#                  that deadline mode "protects only stream traffic" without
#                  the hybrid lane enabled). A file is downloaded from the
#                  server's egress target over the hybrid TCP lane (the HTTP
#                  response body — i.e. the bulk bytes — flows server ->
#                  client by construction of a GET). Midway through the
#                  transfer, the ACTIVE path (the lower-RTT one under the
#                  MinRTT fallback the stream lane uses — see AGENTS.md's
#                  "hybrid TCP lane is scheduled by MinRTT" note) is
#                  degraded with netem so its in-flight data goes late,
#                  arming the deadline reinjection path. Asserts the
#                  transfer still completes byte-identical and that at
#                  least one server-side path shows reinject_tx_bytes > 0,
#                  sampled while the client is still connected (closed
#                  paths drop out of the get_status snapshot).
#   3. dgram     — [Multipath] Reinjection = dgram on BOTH sides, [Hybrid]
#                  left disabled (default) so the connect-ip datagram lane
#                  carries inner traffic, and [Reorder] left at its default
#                  OFF (MQVPN_REORDER_OFF, src/reorder.h:570) — the reorder
#                  shim would dedup the duplicate datagrams dgram-mode
#                  produces at the tun, and this scenario is meant to
#                  exercise the documented un-deduped tun semantics.
#                  MQVPN_REINJ_DGRAM duplicates every DATAGRAM
#                  unconditionally (include/libmqvpn.h:110), so no netem
#                  degradation is needed to arm it — a sustained inner UDP
#                  flow (iperf3 -u), server -> client, is enough. Asserts
#                  the workload completes, inner reachability survives it,
#                  and reinject_tx_bytes > 0 on at least one server-side
#                  path.
#
# REQUIRES: root, GNU/OpenBSD netcat (`nc -q`), python3, iperf3, curl.
#
# Run manually:
#   sudo bash scripts/ci_e2e/run_reinjection_test.sh [path/to/mqvpn]
#
# Exit code: 0 if all scenarios pass, 1 if any fails.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../benchmarks/bench_env_setup.sh"

MQVPN="${1:-${MQVPN:-${SCRIPT_DIR}/../../build/mqvpn}}"
LOG_DIR="$(mktemp -d)"
CTRL_PORT=9099

# Track scratch dirs created per-scenario (HTTP docroots) for cleanup —
# separate from bench_cleanup, which only knows about netns/veth/procs.
SCENARIO_TMP_DIRS=()

trap '_rc=$?; bench_cleanup; for d in "${SCENARIO_TMP_DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; \
    if (( _rc != 0 )); then echo "Logs preserved at: $LOG_DIR" >&2; else rm -rf "$LOG_DIR"; fi' EXIT
echo "Logs: $LOG_DIR"

# --- Preflight ---

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)" >&2
    exit 2
fi
if ! command -v nc >/dev/null 2>&1; then
    echo "ERROR: nc (netcat) not on PATH" >&2
    exit 2
fi
if ! nc -h 2>&1 | grep -q '\-q'; then
    echo "ERROR: nc lacks the '-q' flag — install GNU netcat (apt: netcat-openbsd works too if it ships -q)" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not on PATH" >&2
    exit 2
fi
if ! command -v iperf3 >/dev/null 2>&1; then
    echo "ERROR: iperf3 not on PATH" >&2
    exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl not on PATH" >&2
    exit 2
fi
if [[ -z "$MQVPN" || ! -x "$MQVPN" ]]; then
    echo "ERROR: mqvpn binary not found (pass path as argv[1] or set MQVPN env)" >&2
    exit 2
fi

bench_check_deps

PASS=0
FAIL=0

# --- Control-API helpers (copied from run_control_api_test.sh — same
# socat/nc idiom, same JSON grep style; no jq / new deps added). ---

ctrl_send() {
    local ns="$1" addr="$2" port="$3" json="$4"
    if [[ -n "$ns" ]]; then
        printf '%s' "$json" | ip netns exec "$ns" nc -q1 "$addr" "$port" 2>/dev/null \
            | head -c 16384
    else
        printf '%s' "$json" | nc -q1 "$addr" "$port" 2>/dev/null | head -c 16384
    fi
}

assert_json_field() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
try:
    expected = json.loads(sys.argv[3])
except Exception:
    sys.exit(1)
sys.exit(0 if d.get(sys.argv[2]) == expected else 1)
PY
}

# wait_for <secs> <bash-cmd>  → polls every 0.2s up to <secs>
wait_for() {
    local secs="$1"; shift
    local deadline=$(( $(date +%s) + secs ))
    while (( $(date +%s) < deadline )); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

ctrl_local() {
    local r
    r=$(ctrl_send "$NS_SERVER" 127.0.0.1 "$CTRL_PORT" "$1")
    if [[ -z "$r" ]]; then
        echo "  ctrl_local: empty response (server may be dead)" >&2
        return 1
    fi
    printf '%s' "$r"
}

# --- Server / client launchers (copied from run_control_api_test.sh) ---

start_server_with_flags() {
    local server_log="$1"
    shift
    if ! bench_start_vpn_server >"${server_log}.bringup" 2>&1; then
        echo "  bench_start_vpn_server failed; tail of bringup log:" >&2
        tail -20 "${server_log}.bringup" >&2
        return 1
    fi
    kill "$_BENCH_SERVER_PID" 2>/dev/null || true
    wait "$_BENCH_SERVER_PID" 2>/dev/null || true

    ip netns exec "$NS_SERVER" "$MQVPN" --mode server \
        --listen "0.0.0.0:${VPN_LISTEN_PORT}" \
        --subnet 10.0.0.0/24 \
        --cert "$_BENCH_WORK_DIR/server.crt" \
        --key "$_BENCH_WORK_DIR/server.key" \
        --log-level "$BENCH_LOG_LEVEL" \
        "$@" \
        >"$server_log" 2>&1 &
    _BENCH_SERVER_PID=$!
    sleep 1

    if ! kill -0 "$_BENCH_SERVER_PID" 2>/dev/null; then
        echo "  ERROR: server failed to start; tail of $server_log:" >&2
        tail -20 "$server_log" >&2
        return 1
    fi
    return 0
}

start_client_with_auth_key() {
    local auth_key="$1"
    local client_log="$2"
    local extra_flags="$3"

    if [[ -n "$_BENCH_CLIENT_PID" ]]; then
        kill "$_BENCH_CLIENT_PID" 2>/dev/null || true
        wait "$_BENCH_CLIENT_PID" 2>/dev/null || true
        _BENCH_CLIENT_PID=""
    fi

    # shellcheck disable=SC2086
    ip netns exec "$NS_CLIENT" "$MQVPN" --mode client \
        --server "${IP_A_SERVER_ADDR}:${VPN_LISTEN_PORT}" \
        --auth-key "$auth_key" \
        --insecure \
        --path "$VETH_A0" --path "$VETH_B0" \
        --log-level "$BENCH_LOG_LEVEL" \
        $extra_flags \
        >"$client_log" 2>&1 &
    _BENCH_CLIENT_PID=$!
    sleep 2
    return 0
}

# --- run_test wrapper (copied from run_control_api_test.sh) ---

run_test() {
    local name="$1"
    shift
    echo ""
    echo "--- Test: $name ---"
    if "$@"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# --- Shared helpers ---

# Apply netem to a single path slot's veth pair only (both ends), leaving
# the other path slot untouched. Copied verbatim from
# tests/test_e2e_hybrid_h2.sh's apply_path_netem.
apply_path_netem() {
    local idx="$1" netem="$2"
    local vc vs
    vc="$(bench_path_veth_client "$idx")"
    vs="$(bench_path_veth_server "$idx")"
    ip netns exec "$NS_CLIENT" tc qdisc del dev "$vc" root 2>/dev/null || true
    ip netns exec "$NS_SERVER" tc qdisc del dev "$vs" root 2>/dev/null || true
    ip netns exec "$NS_CLIENT" tc qdisc add dev "$vc" root netem ${netem}
    ip netns exec "$NS_SERVER" tc qdisc add dev "$vs" root netem ${netem}
}

# Parse the first client's assigned tunnel IP out of the server log's
# "ADDRESS_ASSIGN: client=<ip>/32" marker (mqvpn_server.c:810 — same
# convention scripts/ci_e2e/run_ipv6_dataplane_test.sh greps for). Falls
# back to the well-known first-client address (10.0.0.2) if the marker
# hasn't landed yet.
get_client_tunnel_ip() {
    local slog="$1"
    local ip
    ip=$(grep -oE 'ADDRESS_ASSIGN: client=[0-9.]+' "$slog" 2>/dev/null \
        | head -1 | cut -d= -f2)
    if [[ -z "$ip" ]]; then
        ip="10.0.0.2"
    fi
    echo "$ip"
}

# Echoes the max "reinject_tx_bytes" across every client/path in a
# get_status response, or -1 if no paths are present.
max_reinject_tx_bytes() {
    python3 - "$1" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
vals = []
for c in d.get("clients", []):
    for p in c.get("paths", []):
        vals.append(p.get("reinject_tx_bytes", 0))
print(max(vals) if vals else -1)
PY
}

# --- Scenario 1: off ---

test_scenario_off() {
    local server_log="${LOG_DIR}/off_server.log"
    local client_log="${LOG_DIR}/off_client.log"

    bench_cleanup
    bench_setup_netns

    start_server_with_flags "$server_log" \
        --auth-key "$_BENCH_PSK" \
        --control-port "$CTRL_PORT" \
        || return 1

    start_client_with_auth_key "$_BENCH_PSK" "$client_log" "" || return 1

    if ! wait_for 10 ip netns exec "$NS_CLIENT" ping -c 1 -W 1 "$TUNNEL_SERVER_IP"; then
        echo "  tunnel never came up"; tail -20 "$client_log"; return 1
    fi
    echo "  off: tunnel up"

    # Traffic, server -> client (same direction convention as the other
    # scenarios, even though the assertion below holds regardless of
    # direction when reinjection is off).
    local tunnel_client_ip
    tunnel_client_ip=$(get_client_tunnel_ip "$server_log")
    ip netns exec "$NS_SERVER" ping -c 5 -W 2 "$tunnel_client_ip" >/dev/null 2>&1 || true
    sleep 1

    # 1) marker absence in BOTH logs — the byte-frozen observable this
    #    scenario pins per Task 7's brief.
    if grep -q "reinjection enabled: mode=" "$server_log" "$client_log" 2>/dev/null; then
        echo "  FAIL: 'reinjection enabled: mode=' marker present with Reinjection unset"
        return 1
    fi
    echo "  off: marker absent on both ends: OK"

    # 2) every reinject_tx_bytes in get_status is 0.
    local resp
    resp=$(ctrl_local '{"cmd":"get_status"}') || return 1
    if ! assert_json_field "$resp" ok true; then
        echo "  get_status failed: $resp"; return 1
    fi

    local occ zero
    occ=$(grep -o '"reinject_tx_bytes"' <<<"$resp" | wc -l)
    zero=$(grep -o '"reinject_tx_bytes":0' <<<"$resp" | wc -l)
    if (( occ == 0 )); then
        echo "  FAIL: no reinject_tx_bytes fields in get_status (no paths?): $resp"
        return 1
    fi
    if (( occ != zero )); then
        echo "  FAIL: reinject_tx_bytes nonzero while Reinjection=off ($zero/$occ zero): $resp"
        return 1
    fi
    echo "  off: reinject_tx_bytes all zero across $occ path(s): OK"

    return 0
}

# --- Scenario 2: deadline ---

test_scenario_deadline() {
    local server_log="${LOG_DIR}/deadline_server.log"
    local client_log="${LOG_DIR}/deadline_client.log"
    local ini="${LOG_DIR}/deadline.ini"
    local http_target_ip="10.223.0.1"
    local http_target_port=8090
    local http_docroot http_pid=""

    http_docroot="$(mktemp -d)"
    SCENARIO_TMP_DIRS+=("$http_docroot")

    bench_cleanup
    bench_setup_netns

    # Keys cross-checked against src/config.c cfg_keys[] (SEC_MULTIPATH,
    # SEC_HYBRID) and src/mqvpn_sched_names.h's MQVPN_REINJ_LIST (exact
    # accepted string is "deadline"). Both sides share one INI, mirroring
    # tests/test_e2e_hybrid_h2.sh's INI_STREAM (server-only EgressAllow is
    # harmless to also load on the client).
    cat >"$ini" <<EOF
[Multipath]
Reinjection = deadline

[Hybrid]
Enabled = true
Tcp = stream
EgressAllow = ${http_target_ip}/32
EOF

    # HTTP egress target: a /32 loopback alias inside NS_SERVER (same
    # addressing pattern as test_e2e_hybrid_h2.sh's HTTP_TARGET_IP note).
    ip netns exec "$NS_SERVER" ip addr add "${http_target_ip}/32" dev lo
    head -c $((16 * 1024 * 1024)) /dev/urandom >"${http_docroot}/payload.bin"

    ip netns exec "$NS_SERVER" python3 -m http.server "$http_target_port" \
        --bind "$http_target_ip" --directory "$http_docroot" >/dev/null 2>&1 &
    http_pid=$!

    local http_ready=0 _i
    for _i in $(seq 1 20); do
        if ip netns exec "$NS_SERVER" curl -s --max-time 1 -o /dev/null \
                "http://${http_target_ip}:${http_target_port}/payload.bin" 2>/dev/null; then
            http_ready=1
            break
        fi
        sleep 0.5
    done
    if (( http_ready != 1 )); then
        echo "  FAIL: HTTP test server never became ready"
        kill "$http_pid" 2>/dev/null || true
        return 1
    fi

    # Baseline shaping BEFORE the tunnel comes up: path 0 (idx 0) is the
    # lower-RTT leg, so the stream lane's MinRTT fallback (AGENTS.md:
    # "hybrid TCP lane is scheduled by MinRTT, not by WLB — by
    # construction") prefers it. Rate-limited so a 16 MiB download takes
    # long enough to degrade mid-transfer, not so fast it finishes first.
    apply_path_netem 0 "delay 5ms rate 12mbit"
    apply_path_netem 1 "delay 8ms rate 12mbit"

    start_server_with_flags "$server_log" \
        --auth-key "$_BENCH_PSK" \
        --control-port "$CTRL_PORT" \
        --config "$ini" \
        || { kill "$http_pid" 2>/dev/null || true; return 1; }

    start_client_with_auth_key "$_BENCH_PSK" "$client_log" "--config $ini" \
        || { kill "$http_pid" 2>/dev/null || true; return 1; }

    if ! wait_for 15 ip netns exec "$NS_CLIENT" ping -c 1 -W 1 "$TUNNEL_SERVER_IP"; then
        echo "  tunnel never came up"; tail -30 "$client_log"
        kill "$http_pid" 2>/dev/null || true
        return 1
    fi
    echo "  deadline: tunnel up"

    # Both ends log the deadline marker at connection-setup time
    # (mqvpn_server.c:1849 / mqvpn_client.c:2624) — must be present by now.
    if ! grep -q "reinjection enabled: mode=deadline" "$server_log"; then
        echo "  FAIL: server log missing 'reinjection enabled: mode=deadline'"
        kill "$http_pid" 2>/dev/null || true
        return 1
    fi
    if ! grep -q "reinjection enabled: mode=deadline" "$client_log"; then
        echo "  FAIL: client log missing 'reinjection enabled: mode=deadline'"
        kill "$http_pid" 2>/dev/null || true
        return 1
    fi
    echo "  deadline: marker present on both ends: OK"

    # Download in the background (server -> client bytes, by construction
    # of an HTTP GET response body), then degrade the ACTIVE path (idx 0)
    # mid-transfer so its in-flight stream data goes late and arms
    # deadline reinjection onto path 1.
    local dl_out="${LOG_DIR}/deadline_download.bin"
    ip netns exec "$NS_CLIENT" curl -s --max-time 90 -o "$dl_out" \
        "http://${http_target_ip}:${http_target_port}/payload.bin" &
    local curl_pid=$!

    sleep 3
    apply_path_netem 0 "delay 400ms loss 30%"

    local curl_rc=0
    wait "$curl_pid" || curl_rc=$?
    kill "$http_pid" 2>/dev/null || true

    if (( curl_rc != 0 )); then
        echo "  FAIL: download did not complete (curl rc=$curl_rc)"
        return 1
    fi
    if ! cmp -s "${http_docroot}/payload.bin" "$dl_out"; then
        echo "  FAIL: downloaded content mismatch"
        return 1
    fi
    echo "  deadline: download completed byte-identical under path-A degradation: OK"

    # Sample reinject_tx_bytes WHILE paths are still live — the client is
    # still connected at this point, so no path has dropped out of the
    # get_status snapshot yet.
    local resp max_bytes
    resp=$(ctrl_local '{"cmd":"get_status"}') || return 1
    max_bytes=$(max_reinject_tx_bytes "$resp")
    if (( max_bytes <= 0 )); then
        echo "  FAIL: no path shows reinject_tx_bytes > 0: $resp"
        return 1
    fi
    echo "  deadline: reinject_tx_bytes=$max_bytes on at least one path: OK"

    return 0
}

# --- Scenario 3: dgram ---

test_scenario_dgram() {
    local server_log="${LOG_DIR}/dgram_server.log"
    local client_log="${LOG_DIR}/dgram_client.log"
    local ini="${LOG_DIR}/dgram.ini"
    local udp_port=5303

    bench_cleanup
    bench_setup_netns

    # [Hybrid] and [Reorder] intentionally omitted: default Hybrid is
    # disabled (so inner traffic rides the connect-ip DATAGRAM lane —
    # dgram-mode reinjection's target, per include/libmqvpn.h:110), and
    # default Reorder is OFF (src/reorder.h:570) — the shim would dedup
    # dgram-mode's duplicate datagrams at the tun, and this scenario
    # exercises the documented un-deduped semantics with it off.
    cat >"$ini" <<EOF
[Multipath]
Reinjection = dgram
EOF

    start_server_with_flags "$server_log" \
        --auth-key "$_BENCH_PSK" \
        --control-port "$CTRL_PORT" \
        --config "$ini" \
        || return 1

    start_client_with_auth_key "$_BENCH_PSK" "$client_log" "--config $ini" || return 1

    if ! wait_for 10 ip netns exec "$NS_CLIENT" ping -c 1 -W 1 "$TUNNEL_SERVER_IP"; then
        echo "  tunnel never came up"; tail -30 "$client_log"; return 1
    fi
    echo "  dgram: tunnel up"

    if ! grep -q "reinjection enabled: mode=dgram" "$server_log"; then
        echo "  FAIL: server log missing 'reinjection enabled: mode=dgram'"; return 1
    fi
    if ! grep -q "reinjection enabled: mode=dgram" "$client_log"; then
        echo "  FAIL: client log missing 'reinjection enabled: mode=dgram'"; return 1
    fi
    echo "  dgram: marker present on both ends: OK"

    local tunnel_client_ip
    tunnel_client_ip=$(get_client_tunnel_ip "$server_log")

    # Sustained inner UDP flow, server -> client: iperf3 server listens in
    # NS_CLIENT on the tunnel address, iperf3 client sends from NS_SERVER.
    # Mirrors tests/test_e2e_reorder.sh's run_inner_udp_workload, direction
    # reversed per this task's server-is-sender convention.
    ip netns exec "$NS_CLIENT" iperf3 -s -B "$tunnel_client_ip" -p "$udp_port" -1 \
        >/dev/null 2>&1 &
    local iperf_srv_pid=$!
    sleep 1

    local udp_ok=1
    if ! ip netns exec "$NS_SERVER" iperf3 -c "$tunnel_client_ip" -p "$udp_port" \
            -u -b 20M -l 1200 -t 6 >/dev/null 2>&1; then
        udp_ok=0
    fi
    kill "$iperf_srv_pid" 2>/dev/null || true
    wait "$iperf_srv_pid" 2>/dev/null || true

    if (( udp_ok != 1 )); then
        echo "  FAIL: inner UDP workload (server -> client) did not complete"
        return 1
    fi
    echo "  dgram: inner UDP workload (server -> client) completed: OK"

    # Inner reachability sanity, same direction.
    if ! ip netns exec "$NS_SERVER" ping -c 3 -W 2 "$tunnel_client_ip" >/dev/null 2>&1; then
        echo "  FAIL: server->client tunnel ping failed after the UDP workload"
        return 1
    fi
    echo "  dgram: server->client tunnel reachability intact: OK"

    local resp max_bytes
    resp=$(ctrl_local '{"cmd":"get_status"}') || return 1
    max_bytes=$(max_reinject_tx_bytes "$resp")
    if (( max_bytes <= 0 )); then
        echo "  FAIL: no path shows reinject_tx_bytes > 0: $resp"
        return 1
    fi
    echo "  dgram: reinject_tx_bytes=$max_bytes on at least one path: OK"

    return 0
}

# --- Main runner ---

echo ""
echo "================================================================"
echo " Reinjection E2E"
echo " Binary: $MQVPN"
echo "================================================================"

run_test "scenario off — no marker, reinject_tx_bytes==0"      test_scenario_off
run_test "scenario deadline — stream lane reinjection on path degrade" test_scenario_deadline
run_test "scenario dgram — datagram lane unconditional duplication"    test_scenario_dgram

echo ""
echo "================================================================"
echo " Results: PASS=$PASS  FAIL=$FAIL"
echo "================================================================"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
