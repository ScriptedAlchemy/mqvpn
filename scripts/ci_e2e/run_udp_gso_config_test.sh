#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 mp0rta and mqvpn contributors
# run_udp_gso_config_test.sh — E2E test for [Advanced] UdpGso config key
#
# `udp_gso` (Linux TX UDP GSO / batched-send registration, see
# src/udp_offload.{c,h} and the wiring in mqvpn_client.c / mqvpn_server.c's
# init_xquic_engine()) has NO CLI flag — the [Advanced] section of the INI
# config file is its only input surface (src/config.c's
# CFG_BOOL(SEC_ADVANCED, "UdpGso", "udp_gso", udp_gso) and
# src/mqvpn_config.c's cfg->udp_gso = 1 default). This mirrors
# run_reinjection_test.sh's rationale comment for the same reason
# ([Multipath] Reinjection is also config-file-only).
#
# G13 note — log wording is an observable invariant, pinned here for the
# FIRST time: this script greps both endpoints' startup logs for the
# literal "udp-gso: " prefix that mqvpn_client.c / mqvpn_server.c emit at
# engine-create time:
#     LOG_I(c, "udp-gso: %s", c->gso_available ? "GSO enabled"
#                                               : "GSO unavailable, using sendmmsg");
#     LOG_I(s, "udp-gso: %s", s->gso_available ? "GSO enabled"
#                                               : "GSO unavailable, using sendmmsg");
# Changing that wording, or moving/removing either LOG_I call, silently
# breaks BOTH assertions below (presence in Arm A, absence in Arm B) the
# same way the "reconnecting in" / "stuck in PENDING" wordings are pinned
# invariants elsewhere in this suite (see sanitizer_check.sh and
# AGENTS.md's e2e log marker note). If you reword it, update BOTH grep
# patterns in this file (search "udp-gso:") in the same change. A
# same-commit source comment at both LOG_I call sites points back here.
#
# Race-freedom rationale (why asserting log-ABSENCE right after tunnel-up
# is safe, not a best-effort poll): both LOG_I("udp-gso: ...") call sites
# run inside init_xquic_engine(), synchronously before xqc_engine_create()
# — i.e. strictly before the engine exists, and therefore strictly before
# any handshake can begin. "Tunnel is up" (first successful tunnel ping)
# can only happen after a completed handshake, which happens-after engine
# creation, which happens-after the point where the marker would have been
# emitted had GSO registration run. So by the time the tunnel-ping check
# below passes, there is no remaining window where the marker could still
# be about to appear — checking the log files at that point is equivalent
# to checking them at any later time.
#
# Arms (single client/server pair per arm; fresh netns + fresh PSK/cert
# each time via bench_env_setup.sh):
#   A. default (true)  — no --config / -C. The "udp-gso: " line (either
#      "GSO enabled" or "GSO unavailable, using sendmmsg" — both prove the
#      batch send path was registered; the choice between them depends on
#      the CI runner's kernel, which this test does not pin) MUST be
#      present in BOTH the client and server logs.
#   B. false (-C)       — a minimal INI containing ONLY [Advanced] /
#      UdpGso = false is passed via -C to BOTH endpoints, same flags as
#      Arm A otherwise. The "udp-gso: " line MUST be ABSENT from both
#      logs (proves the escape hatch cleanly restores the legacy
#      per-packet xqc_engine_create() registration with no GSO callback
#      wired in at all — not merely "GSO available but declined").
#
# Both arms verify tunnel connectivity (ping through the tunnel) after
# the marker check, same idiom as every other 2-path e2e script in this
# directory (see run_dellink_test.sh / run_reconnect_test.sh).
#
# REQUIRES: root (netns + TUN), openssl (cert generation via
# bench_env_setup.sh's bench_start_vpn_server).
#
# Run manually:
#   sudo bash scripts/ci_e2e/run_udp_gso_config_test.sh [path/to/mqvpn]
#
# Exit code: 0 if both arms pass and no sanitizer error fired, 1 otherwise.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/sanitizer_check.sh"
source "${SCRIPT_DIR}/../../benchmarks/bench_env_setup.sh"

MQVPN="${1:-${MQVPN:-${SCRIPT_DIR}/../../build/mqvpn}}"
LOG_DIR="$(mktemp -d)"
SANITIZER_FAIL=0

# Named-function trap (same shape as run_reinjection_test.sh /
# run_control_api_test.sh): preserve logs on failure, reap netns/procs via
# bench_cleanup, and fail the whole run if a sanitizer error fired in any
# arm even though that arm's own functional check passed.
cleanup() {
    local _rc=$?
    bench_cleanup
    if (( _rc != 0 )); then
        echo "Logs preserved at: $LOG_DIR" >&2
    else
        rm -rf "$LOG_DIR"
    fi
    if (( SANITIZER_FAIL != 0 )); then
        echo "FAIL: sanitizer errors detected" >&2
        exit 1
    fi
}
trap cleanup EXIT
echo "Logs: $LOG_DIR"

# --- Preflight ---

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)" >&2
    exit 2
fi

# bench_check_test_deps (benchmarks/bench_env_setup.sh:101-118): verifies
# $MQVPN exists and resolves it to a realpath; verifies each named dep is
# on PATH. openssl is the only external dep this script needs (used
# transitively by bench_start_vpn_server for cert generation).
bench_check_test_deps openssl

PASS=0
FAIL=0

# --- run_test wrapper (copied from run_reinjection_test.sh / run_control_api_test.sh) ---

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

# --- Client launcher with extra-flags support ---
#
# bench_start_vpn_client (benchmarks/bench_env_setup.sh:312-340) only takes
# a --path list, not arbitrary extra flags, so -C can't go through it. This
# mirrors run_reinjection_test.sh's start_client_with_auth_key /
# run_control_api_test.sh's client launcher: same fixed flag set as
# bench_start_vpn_client's body, plus an extra_flags passthrough.
start_client() {
    local extra_flags="$1"
    local client_log="$2"

    if [ -n "$_BENCH_CLIENT_PID" ] && kill -0 "$_BENCH_CLIENT_PID" 2>/dev/null; then
        kill "$_BENCH_CLIENT_PID" 2>/dev/null || true
        wait "$_BENCH_CLIENT_PID" 2>/dev/null || true
        _BENCH_CLIENT_PID=""
    fi

    # shellcheck disable=SC2086  # extra_flags is intentionally word-split
    ip netns exec "$NS_CLIENT" "$MQVPN" \
        --mode client \
        --server "${IP_A_SERVER_ADDR}:${VPN_LISTEN_PORT}" \
        --path "$VETH_A0" --path "$VETH_B0" \
        --auth-key "$_BENCH_PSK" \
        --insecure \
        --log-level "$BENCH_LOG_LEVEL" \
        $extra_flags \
        >"$client_log" 2>&1 &
    _BENCH_CLIENT_PID=$!
    sleep 2

    if ! kill -0 "$_BENCH_CLIENT_PID" 2>/dev/null; then
        echo "  ERROR: client process died; tail of $client_log:" >&2
        tail -30 "$client_log" >&2
        return 1
    fi
    return 0
}

# End-of-arm teardown: sanitizer-check both endpoints (same idiom as
# run_reinjection_test.sh's finish_scenario / run_backup_fec_test.sh's
# cleanup_processes) and clear the PID vars so the next arm's bench_cleanup
# doesn't try to re-kill an already-reaped process. A sanitizer failure is
# recorded in the global SANITIZER_FAIL (checked once at final script
# exit) rather than flipping this arm's own PASS/FAIL.
finish_arm() {
    local desc="$1" server_log="$2" client_log="$3"
    stop_and_check_sanitizer "$_BENCH_CLIENT_PID" "${desc} client" "$client_log" \
        || SANITIZER_FAIL=1
    stop_and_check_sanitizer "$_BENCH_SERVER_PID" "${desc} server" "$server_log" \
        || SANITIZER_FAIL=1
    _BENCH_CLIENT_PID=""
    _BENCH_SERVER_PID=""
}

# --- Shared arm body ---
#
# arm_id: short tag for log filenames.
# expect_present: 1 = "udp-gso: " must be present in both logs (Arm A),
#                 0 = must be absent from both (Arm B).
# extra_flags: appended to BOTH the server and client command lines
#              (e.g. "-C <ini>" for Arm B; empty for Arm A).
run_arm() {
    local arm_id="$1" expect_present="$2" extra_flags="$3"
    local server_log="${LOG_DIR}/${arm_id}_server.log"
    local client_log="${LOG_DIR}/${arm_id}_client.log"

    bench_cleanup
    bench_setup_netns

    # bench_start_vpn_server (benchmarks/bench_env_setup.sh:276-310): rolls
    # a fresh PSK + self-signed cert into $_BENCH_PSK / $_BENCH_WORK_DIR,
    # then launches the server with $extra_flags appended raw. start_client
    # (above) reads the SAME $_BENCH_PSK immediately after — no re-roll
    # race, since neither this function nor its callees invoke
    # bench_start_vpn_server a second time per arm (contrast
    # run_reinjection_test.sh's start_server_with_flags, which restarts
    # deliberately to reuse a freshly-rolled PSK across a custom flag set;
    # not needed here since one bench_start_vpn_server call already
    # supports arbitrary extra flags).
    # shellcheck disable=SC2086  # extra_flags is intentionally word-split
    if ! bench_start_vpn_server "$extra_flags" "$server_log"; then
        echo "  FAIL: server did not start; tail of $server_log:"
        tail -30 "$server_log" 2>/dev/null
        return 1
    fi

    if ! start_client "$extra_flags" "$client_log"; then
        return 1
    fi

    # bench_wait_tunnel (benchmarks/bench_env_setup.sh:342-358): polls
    # ping to $TUNNEL_SERVER_IP from $NS_CLIENT up to the given timeout.
    if ! bench_wait_tunnel 15; then
        echo "  --- server log ---"
        cat "$server_log"
        echo "  --- client log ---"
        cat "$client_log"
        return 1
    fi

    # udp-gso: marker check. Race-freedom argument is in the file header:
    # both LOG_I("udp-gso: ...") sites run before engine-create, strictly
    # before any possible handshake, so tunnel-up (just verified above)
    # happens-after the point the marker would have appeared. grep the log
    # FILES directly (no writer | grep -q pipeline — see G19 in AGENTS.md:
    # a pipefail'd writer|grep -q can SIGPIPE-fail the writer even on a
    # successful match).
    local server_hits client_hits
    server_hits=$(grep -c "udp-gso: " "$server_log" 2>/dev/null || true)
    client_hits=$(grep -c "udp-gso: " "$client_log" 2>/dev/null || true)
    server_hits="${server_hits:-0}"
    client_hits="${client_hits:-0}"

    if [ "$expect_present" -eq 1 ]; then
        if [ "$server_hits" -eq 0 ] || [ "$client_hits" -eq 0 ]; then
            echo "  FAIL: 'udp-gso: ' marker missing (server_hits=$server_hits client_hits=$client_hits)"
            echo "  --- server log tail ---"
            tail -30 "$server_log"
            echo "  --- client log tail ---"
            tail -30 "$client_log"
            return 1
        fi
        echo "  OK: 'udp-gso: ' marker present on both ends:"
        grep "udp-gso: " "$server_log" | sed 's/^/    server: /'
        grep "udp-gso: " "$client_log" | sed 's/^/    client: /'
    else
        if [ "$server_hits" -ne 0 ] || [ "$client_hits" -ne 0 ]; then
            echo "  FAIL: 'udp-gso: ' marker unexpectedly present (server_hits=$server_hits client_hits=$client_hits)"
            echo "  --- server log hits ---"
            grep "udp-gso: " "$server_log" || true
            echo "  --- client log hits ---"
            grep "udp-gso: " "$client_log" || true
            return 1
        fi
        echo "  OK: 'udp-gso: ' marker absent on both ends (server_hits=0 client_hits=0)"
    fi

    # Tunnel connectivity, same idiom as run_dellink_test.sh /
    # run_reconnect_test.sh: a few pings through the tunnel address.
    if ! ip netns exec "$NS_CLIENT" ping -c 3 -W 2 "$TUNNEL_SERVER_IP"; then
        echo "  FAIL: tunnel ping failed"
        echo "  --- server log ---"
        cat "$server_log"
        echo "  --- client log ---"
        cat "$client_log"
        return 1
    fi
    echo "  OK: tunnel connectivity verified"

    finish_arm "$arm_id" "$server_log" "$client_log"
    return 0
}

# --- Arm A: default (UdpGso unset -> true) ---

test_arm_default() {
    run_arm "default" 1 ""
}

# --- Arm B: UdpGso = false via -C ---

test_arm_disabled() {
    # Minimal INI containing ONLY [Advanced] / UdpGso = false — mirrors
    # tests/test_config.c's test_advanced_udp_gso fixture
    # ("[Advanced]\nUdpGso = false\n") exactly. main.c loads this file via
    # mqvpn_config_load() before applying CLI overrides per-field (see
    # main.c's "CLI overrides config file values" comment); since udp_gso
    # has no CLI flag, this INI section is the value's only source, and
    # every other value falls back to mqvpn_config_defaults() + this run's
    # flags — an INI with only [Advanced] is valid on its own
    # (parse_section / SEC_ADVANCED in src/config.c never requires
    # sibling sections).
    local ini="${LOG_DIR}/udp_gso_false.ini"
    cat >"$ini" <<EOF
[Advanced]
UdpGso = false
EOF
    run_arm "disabled" 0 "-C $ini"
}

# --- Main runner ---

echo ""
echo "================================================================"
echo " UdpGso config-key E2E"
echo " Binary: $MQVPN"
echo "================================================================"

run_test "Arm A — default (UdpGso unset, true): marker present"    test_arm_default
run_test "Arm B — UdpGso = false via -C: marker absent"             test_arm_disabled

echo ""
echo "================================================================"
echo " Results: PASS=$PASS  FAIL=$FAIL"
echo "================================================================"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
