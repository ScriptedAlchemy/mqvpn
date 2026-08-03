#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 mp0rta and mqvpn contributors
# run_udp_gso_bench.sh — UdpGso A/B benchmark: throughput + CPU cost
#
# Measures the win (or lack of one) from `udp_gso` (Linux TX UDP GSO /
# batched-send registration — see src/udp_offload.{c,h}, wired in
# init_xquic_engine() in mqvpn_client.c / mqvpn_server.c) on the SAME binary,
# so the comparison is purely the runtime UdpGso=true/false toggle and never
# a rebuild artifact (G20 — see mqvpn-dev-gates skill: compiler/flag drift
# between arms has produced false conclusions before). The binary path and
# its sha256 are recorded in the output header for that reason.
#
# Arms (single client/server pair, same 2-path netns topology as
# run_udp_gso_config_test.sh, fresh netns/PSK/cert every run):
#   A. "default"  — no --config / -C. udp_gso defaults to true
#      (src/mqvpn_config.c:153, src/config.c:1282).
#   B. "disabled" — [Advanced]/UdpGso=false via -C <ini>, passed to BOTH
#      endpoints. INI content mirrors run_udp_gso_config_test.sh's Arm B
#      exactly (== tests/test_config.c's test_advanced_udp_gso fixture).
# Per run we also grep both endpoints' logs for the "udp-gso: " marker
# (pinned wording, see mqvpn_client.c:2843 / mqvpn_server.c:1880 and
# run_udp_gso_config_test.sh's header comment) so the printed table proves
# which code path actually ran in each row, not just which flag was passed.
#
# Per run:
#   - iperf3 TCP, client (NS_CLIENT) -> server (NS_SERVER) upload, no -R.
#     This is the same direction/idiom as bench_aggregate.sh /
#     run_throughput_floor_test.sh (iperf3 -c ... -t DURATION -P STREAMS
#     --json, parsed via python3 for end.sum_received / end.sum). Upload
#     (not -R/download) is deliberate: it drives data from the CLIENT's TUN
#     out through the CLIENT's outer UDP TX path, which is what UdpGso
#     batches — this branch (feat/udp-gso-tx) is TX-only.
#   - CPU: both mqvpn processes (client + server, PIDs tracked by
#     bench_env_setup.sh as $_BENCH_CLIENT_PID / $_BENCH_SERVER_PID) are
#     sampled for the same window as the iperf3 transfer.
#     No bench sibling in this repo uses pidstat (grepped; all CPU/RSS
#     sampling in this tree is /proc-based, e.g.
#     scripts/ci_stress/ci_stress_env.sh:290-312's RSS monitor), so this
#     script prefers pidstat when present (verified empirically against the
#     real /usr/bin/pidstat on a dev box — see comment above
#     proc_cpu_ticks() below for exactly what was checked) and falls back
#     to a plain /proc/[pid]/stat utime+stime delta otherwise. Either
#     method reports whole-process CPU (all threads aggregated), confirmed
#     empirically with a 2-thread pthread busy-loop test process reading
#     ~200% from both methods — not just the main thread.
#   - N runs per arm (default 3), medians reported. Arms ALTERNATE
#     (default, disabled, default, disabled, ...) rather than running all
#     of one arm then all of the other, to spread any monotonic drift
#     (thermal throttling, netns/cert-gen warmup, etc.) evenly across both
#     arms instead of biasing one of them.
#
# Output: a compact per-run table + per-arm medians, echoed to stdout AND
# appended to a file under ci_sweep_results/ (gitignored, transient — see
# AGENTS.md: ci_sweep_results/ is transient, bench_results/ is the curated
# archive; this script deliberately does NOT write bench_results/).
#
# REQUIRES: root (netns + TUN), iperf3, python3, openssl (cert generation
# via bench_env_setup.sh's bench_start_vpn_server). pidstat (sysstat) is
# OPTIONAL — auto-detected, falls back to /proc if absent.
#
# This is a local maintainer tool, NOT wired into CI (no ci.yml/stress.yml
# reference). It is not a throughput/CPU pass/fail gate — a completed
# comparison always prints its table regardless of the numbers — but it
# DOES exit nonzero (after printing the table) if: a sanitizer error fired
# in any run, the "udp-gso: " marker didn't match the expected present/
# absent state for its arm in any run (a silently-void A/B produced a
# plausible-looking table once already — see MARKER_FAIL below), or every
# run failed and there is nothing to report.
#
# --- Optional shaped mode (UDP_GSO_BENCH_NETEM=1) ---
# An unshaped netns never blocks a send: cwnd/pacing never bites, so
# write_mmsg_ex is only ever called with vlen==1 and GSO measures as
# neutral (or worse, due to per-call cmsg overhead with nothing to
# amortize it over). Real links block: with RTT + a rate cap, cwnd/pacing
# queues datagrams and ACK-clocked bursts hand write_mmsg_ex real vlen>1
# batches, which is the only regime GSO can show a win in. Setting
# UDP_GSO_BENCH_NETEM=1 applies tc netem (delay NETEM_DELAY, rate
# NETEM_RATE — same profile on both paths, both directions) via
# bench_env_setup.sh's bench_apply_netem, following the same shape/ordering
# precedent as run_throughput_floor_test.sh:187-191 and
# bench_env_setup.sh:254-274's bench_apply_netem itself. A single
# invocation is either fully shaped or fully unshaped — never mixed, so
# the printed table stays a single-condition comparison (the unshaped
# numbers already exist from prior runs). With the link saturated by
# iperf3, CPU is no longer pinned near 100%; the meaningful comparison
# becomes CPU% at equal throughput between arms, not raw throughput.
#
# Usage:
#   sudo bash scripts/ci_e2e/run_udp_gso_bench.sh [path/to/mqvpn] [duration_s] [runs]
# Defaults: path/to/mqvpn = build/mqvpn (repo-relative), duration_s = 10,
#           runs = 3 (per arm; 2*runs total launches, alternating).
# Env override: IPERF_STREAMS (default 4) — iperf3 -P parallel stream count.
# Env override: UDP_GSO_BENCH_NETEM (default 0) — set to 1 to shape both
#           paths with tc netem instead of running on the bare netns.
# Env override: NETEM_DELAY (default 20ms), NETEM_RATE (default 300mbit) —
#           only consulted when UDP_GSO_BENCH_NETEM=1.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/sanitizer_check.sh"
source "${SCRIPT_DIR}/../../benchmarks/bench_env_setup.sh"

MQVPN="${1:-${MQVPN:-${SCRIPT_DIR}/../../build/mqvpn}}"
DURATION="${2:-10}"
RUNS="${3:-3}"
IPERF_STREAMS="${IPERF_STREAMS:-4}"
UDP_GSO_BENCH_NETEM="${UDP_GSO_BENCH_NETEM:-0}"
NETEM_DELAY="${NETEM_DELAY:-20ms}"
NETEM_RATE="${NETEM_RATE:-300mbit}"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)" >&2
    exit 2
fi

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -lt 1 ]; then
    echo "ERROR: duration_s must be a positive integer, got '$DURATION'" >&2
    exit 2
fi
if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [ "$RUNS" -lt 1 ]; then
    echo "ERROR: runs must be a positive integer, got '$RUNS'" >&2
    exit 2
fi
if [[ "$UDP_GSO_BENCH_NETEM" != "0" && "$UDP_GSO_BENCH_NETEM" != "1" ]]; then
    echo "ERROR: UDP_GSO_BENCH_NETEM must be 0 or 1, got '$UDP_GSO_BENCH_NETEM'" >&2
    exit 2
fi

# Same profile on both paths, both directions (see the shaped-mode header
# comment above) — bench_apply_netem takes one "netem args" string per path
# and this script deliberately does not offer per-path asymmetry, unlike
# BENCH_ENV_NETEM's profile table (benchmarks/bench_env_setup.sh) which sweep
# scripts use for asymmetric Path A/B scenarios; that is out of scope here.
NETEM_PROFILE="delay ${NETEM_DELAY} rate ${NETEM_RATE}"

# bench_check_test_deps (benchmarks/bench_env_setup.sh:101-118): verifies
# $MQVPN exists and resolves it to a realpath (mutates the global $MQVPN —
# no separate existence check needed here), and verifies each named dep is
# on PATH.
bench_check_test_deps iperf3 python3 openssl

HAVE_PIDSTAT=0
if command -v pidstat >/dev/null 2>&1; then
    HAVE_PIDSTAT=1
fi
CLK_TCK="$(getconf CLK_TCK)"

LOG_DIR="$(mktemp -d)"
RAW_RESULTS="$(mktemp)"
SANITIZER_FAIL=0
# Set to 1 by run_one() when the "udp-gso: " marker doesn't match the arm's
# expected present/absent state. A mismatch means the A/B comparison ran
# with the wrong code path in at least one run — the printed table would
# otherwise look like a normal, trustworthy A/B while silently comparing
# apples to apples (or worse). Checked once at exit, same shape as
# SANITIZER_FAIL below.
MARKER_FAIL=0

OUT_DIR="${SCRIPT_DIR}/../../ci_sweep_results"
mkdir -p "$OUT_DIR"
RESULT_FILE="${OUT_DIR}/udp_gso_bench_$(date +%Y%m%d_%H%M%S).txt"
: > "$RESULT_FILE"

# Dual stdout+file echo, with no pipe involved (G19 — a writer|grep -q /
# writer|head pipeline can SIGPIPE-fail the writer under pipefail even on a
# successful match; this sidesteps the whole class by never piping).
log_line() {
    printf '%s\n' "$1"
    printf '%s\n' "$1" >> "$RESULT_FILE"
}

# Named-function trap (same shape as run_udp_gso_config_test.sh): preserve
# logs on failure, reap netns/procs via bench_cleanup, fail the whole run
# if a sanitizer error fired in any arm even though that arm's own
# functional steps (tunnel-up, iperf3) completed.
cleanup() {
    local _rc=$?
    bench_cleanup
    if (( _rc != 0 )); then
        echo "Logs preserved at: $LOG_DIR" >&2
    else
        rm -rf "$LOG_DIR"
    fi
    rm -f "$RAW_RESULTS"
    if (( MARKER_FAIL != 0 )); then
        echo "FAIL: udp-gso marker mismatch detected in one or more runs (see FAIL lines above)" >&2
        exit 1
    fi
    if (( SANITIZER_FAIL != 0 )); then
        echo "FAIL: sanitizer errors detected" >&2
        exit 1
    fi
}
trap cleanup EXIT
echo "Logs: $LOG_DIR"

# --- G20 header facts: binary identity (path is $MQVPN itself, resolved to
#     a realpath by bench_check_test_deps above; never touched again after
#     this point — every one of the 2*RUNS launches below execs this exact
#     same file) ---
BIN_SHA256="$(sha256sum "$MQVPN" | awk '{print $1}')"
KERNEL="$(uname -r)"
RUN_DATE="$(date -Iseconds)"

# --- Disabled-arm INI — mirrors run_udp_gso_config_test.sh's Arm B exactly
#     (== tests/test_config.c's test_advanced_udp_gso fixture: "[Advanced]\n
#     UdpGso = false\n"). Created once, reused for every "disabled" run. ---
DISABLED_INI="${LOG_DIR}/udp_gso_false.ini"
cat >"$DISABLED_INI" <<EOF
[Advanced]
UdpGso = false
EOF

# --- Arm alternation sequence (drift reduction): default, disabled,
#     default, disabled, ... for RUNS iterations of each. ---
ARM_SEQUENCE=()
for (( i = 0; i < RUNS; i++ )); do
    ARM_SEQUENCE+=("default" "disabled")
done

log_line "================================================================"
log_line " UdpGso A/B bench (throughput + CPU)"
log_line " Binary:   $MQVPN"
log_line " SHA256:   $BIN_SHA256"
log_line " Kernel:   $KERNEL"
log_line " Date:     $RUN_DATE"
log_line " Duration: ${DURATION}s per run, iperf3 TCP -P ${IPERF_STREAMS}, ${RUNS} runs/arm"
log_line " CPU tool: $([ "$HAVE_PIDSTAT" -eq 1 ] && echo "pidstat" || echo "/proc/[pid]/stat fallback (pidstat not found)")"
if [ "$UDP_GSO_BENCH_NETEM" -eq 1 ]; then
    log_line " Netem:    ON  (both paths, both directions: ${NETEM_PROFILE})"
    log_line " NOTE:     shaped mode: compare CPU% at equal tput; expect GSO arm lower"
else
    log_line " Netem:    OFF (unshaped netns — set UDP_GSO_BENCH_NETEM=1 to shape)"
fi
log_line " Arm order (alternating): ${ARM_SEQUENCE[*]}"
log_line "================================================================"

# --- Client launcher with extra-flags support ---
#
# bench_start_vpn_client (benchmarks/bench_env_setup.sh:312-340) only takes
# a --path list, not arbitrary extra flags, so -C can't go through it. Same
# shape as run_udp_gso_config_test.sh's start_client (scripts/ci_e2e/
# run_udp_gso_config_test.sh:138-167): SAME flag set as
# bench_start_vpn_client's body (including --scheduler "$BENCH_SCHEDULER",
# previously missing here — a real flag-set gap, not just parity in name),
# plus an extra_flags passthrough.
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
        --scheduler "$BENCH_SCHEDULER" \
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

# End-of-run teardown: sanitizer-check both endpoints (same idiom as
# run_udp_gso_config_test.sh's finish_arm) and clear the PID vars so the
# next run's bench_cleanup doesn't try to re-kill an already-reaped
# process. A sanitizer failure is recorded in the global SANITIZER_FAIL
# (checked once at final script exit) rather than flipping this run's own
# pass/fail — this is a bench tool, a slow/degraded run still has data
# worth reporting.
finish_run() {
    local desc="$1" server_log="$2" client_log="$3"
    stop_and_check_sanitizer "$_BENCH_CLIENT_PID" "${desc} client" "$client_log" \
        || SANITIZER_FAIL=1
    stop_and_check_sanitizer "$_BENCH_SERVER_PID" "${desc} server" "$server_log" \
        || SANITIZER_FAIL=1
    _BENCH_CLIENT_PID=""
    _BENCH_SERVER_PID=""
}

# --- CPU measurement helpers ---
#
# Verified empirically on the dev box preparing this script (real
# /usr/bin/pidstat from sysstat, not from memory — sysstat's column set
# has changed across versions historically, so this was checked live):
#   - `LC_ALL=C S_TIME_FORMAT=ISO pidstat -p PID 1 N`'s "Average:" line has
#     the shape `Average:  UID  PID  %usr  %system  %guest  %wait  %CPU
#     CPU(-)  Command` — %CPU is field 8 (awk $8). Confirmed against a
#     busy-loop test process (100.00 for a fully CPU-bound single thread).
#   - S_TIME_FORMAT=ISO avoids a real footgun: pidstat's default per-sample
#     timestamp is locale-dependent 12h "HH:MM:SS AM/PM" (adds an extra
#     field vs. 24h), which would shift every awk column index on the
#     *timestamped* lines. This script only ever parses the "Average:"
#     line, which has no timestamp field and is therefore immune to that
#     shift either way — S_TIME_FORMAT=ISO is set anyway so the raw
#     per-sample files left in $LOG_DIR are readable un-ambiguously if a
#     maintainer tails them by hand.
#   - Both pidstat and /proc/[pid]/stat aggregate ALL threads of a PID into
#     one figure, not just the main thread — confirmed with a 2-thread
#     pthread busy-loop process reading ~200.00% from both methods. (A
#     naive assumption that /proc/PID/stat is "just the main thread" would
#     have been wrong and would have undercounted a multi-threaded mqvpn.)
CLIENT_PIDSTAT_PID=""
CLIENT_PIDSTAT_OUT=""
CLIENT_T0=""
CLIENT_TS0=""
SERVER_PIDSTAT_PID=""
SERVER_PIDSTAT_OUT=""
SERVER_T0=""
SERVER_TS0=""

# Cumulative CPU ticks (utime+stime) for a PID, from /proc/[pid]/stat.
# proc(5): comm (field 2) is parenthesized and may itself contain ')', so
# this skips past the LAST ') ' rather than splitting on whitespace
# naively; the remainder's 0-indexed fields are state=0 ppid=1 ... utime=11
# stime=12 (verified against the documented /proc/[pid]/stat field order
# and against a live busy-loop process above).
# Echoes 0 and returns 1 if the pid is gone (process died mid-measurement)
# — callers must check the return status, not just trust a numeric 0.
proc_cpu_ticks() {
    local pid="$1" line rest
    line="$(cat "/proc/${pid}/stat" 2>/dev/null)"
    if [ -z "$line" ]; then
        echo 0
        return 1
    fi
    rest="${line##*) }"
    local -a f
    read -r -a f <<< "$rest"
    echo "$(( ${f[11]:-0} + ${f[12]:-0} ))"
}

cpu_start_client() {
    local pid="$1" tag="$2"
    if [ "$HAVE_PIDSTAT" -eq 1 ]; then
        CLIENT_PIDSTAT_OUT="${LOG_DIR}/pidstat_client_${tag}.out"
        ( LC_ALL=C S_TIME_FORMAT=ISO pidstat -p "$pid" 1 "$DURATION" \
            >"$CLIENT_PIDSTAT_OUT" 2>/dev/null ) &
        CLIENT_PIDSTAT_PID=$!
    else
        CLIENT_T0="$(proc_cpu_ticks "$pid")" || true
        CLIENT_TS0="$(date +%s%N)"
    fi
}

cpu_start_server() {
    local pid="$1" tag="$2"
    if [ "$HAVE_PIDSTAT" -eq 1 ]; then
        SERVER_PIDSTAT_OUT="${LOG_DIR}/pidstat_server_${tag}.out"
        ( LC_ALL=C S_TIME_FORMAT=ISO pidstat -p "$pid" 1 "$DURATION" \
            >"$SERVER_PIDSTAT_OUT" 2>/dev/null ) &
        SERVER_PIDSTAT_PID=$!
    else
        SERVER_T0="$(proc_cpu_ticks "$pid")" || true
        SERVER_TS0="$(date +%s%N)"
    fi
}

# Echoes a %CPU float. On any measurement failure this echoes "0.0" (so the
# printed table still has a well-formed number) but ALSO prints the actual
# observed failure to stderr first (G19: failure paths print actual
# values, not just a silently-plausible number).
cpu_finish_client() {
    local pid="$1"
    if [ "$HAVE_PIDSTAT" -eq 1 ]; then
        wait "$CLIENT_PIDSTAT_PID" 2>/dev/null || true
        local pct
        pct="$(awk '/^Average:/ {print $8}' "$CLIENT_PIDSTAT_OUT" 2>/dev/null)" || true
        if [ -z "$pct" ]; then
            echo "WARN: no pidstat Average line for client pid $pid; raw output:" >&2
            cat "$CLIENT_PIDSTAT_OUT" >&2 2>/dev/null || true
            echo "0.0"
            return
        fi
        echo "$pct"
    else
        local t1 ts1 rc=0
        t1="$(proc_cpu_ticks "$pid")" || rc=$?
        ts1="$(date +%s%N)"
        if [ "$rc" -ne 0 ]; then
            echo "WARN: /proc/${pid}/stat unreadable at measurement end (client pid $pid gone)" >&2
            echo "0.0"
            return
        fi
        python3 -c "
clk = ${CLK_TCK}
dticks = ${t1} - ${CLIENT_T0}
dns = ${ts1} - ${CLIENT_TS0}
pct = (100.0 * dticks / clk / (dns / 1e9)) if dns > 0 else 0.0
print(f'{max(pct, 0.0):.1f}')
"
    fi
}

cpu_finish_server() {
    local pid="$1"
    if [ "$HAVE_PIDSTAT" -eq 1 ]; then
        wait "$SERVER_PIDSTAT_PID" 2>/dev/null || true
        local pct
        pct="$(awk '/^Average:/ {print $8}' "$SERVER_PIDSTAT_OUT" 2>/dev/null)" || true
        if [ -z "$pct" ]; then
            echo "WARN: no pidstat Average line for server pid $pid; raw output:" >&2
            cat "$SERVER_PIDSTAT_OUT" >&2 2>/dev/null || true
            echo "0.0"
            return
        fi
        echo "$pct"
    else
        local t1 ts1 rc=0
        t1="$(proc_cpu_ticks "$pid")" || rc=$?
        ts1="$(date +%s%N)"
        if [ "$rc" -ne 0 ]; then
            echo "WARN: /proc/${pid}/stat unreadable at measurement end (server pid $pid gone)" >&2
            echo "0.0"
            return
        fi
        python3 -c "
clk = ${CLK_TCK}
dticks = ${t1} - ${SERVER_T0}
dns = ${ts1} - ${SERVER_TS0}
pct = (100.0 * dticks / clk / (dns / 1e9)) if dns > 0 else 0.0
print(f'{max(pct, 0.0):.1f}')
"
    fi
}

# --- One arm/run: netns + server + client + marker check + iperf3 + CPU ---
run_one() {
    local arm_label="$1" expect_present="$2" extra_flags="$3" run_idx="$4"
    local tag="${arm_label}_r${run_idx}"
    local server_log="${LOG_DIR}/${tag}_server.log"
    local client_log="${LOG_DIR}/${tag}_client.log"

    echo ""
    echo "--- ${arm_label} run ${run_idx}/${RUNS} ---"

    bench_cleanup
    bench_setup_netns

    # Shaped mode: apply tc netem to BOTH path veths, both directions (same
    # precedent as bench_apply_netem itself — benchmarks/bench_env_setup.sh:
    # 254-274 — and run_throughput_floor_test.sh:187-191), after
    # bench_setup_netns and before the server starts, so the shaping is in
    # place before any packet (including the handshake) crosses the netns.
    # bench_cleanup (called at the top of every run_one, and by the EXIT
    # trap) already runs `tc qdisc del ... root` for every path slot — see
    # bench_env_setup.sh:404-405 — so no separate per-arm teardown is needed
    # here; the qdisc this call adds is torn down by the very next
    # bench_cleanup, same as bench_setup_netns's veths are.
    if [ "$UDP_GSO_BENCH_NETEM" -eq 1 ]; then
        if ! bench_apply_netem "$NETEM_PROFILE" "$NETEM_PROFILE"; then
            echo "  FAIL: tc netem apply failed" >&2
            return 1
        fi
    fi

    # shellcheck disable=SC2086  # extra_flags is intentionally word-split
    if ! bench_start_vpn_server "$extra_flags" "$server_log"; then
        echo "  FAIL: server did not start; tail of $server_log:" >&2
        tail -30 "$server_log" 2>/dev/null >&2
        return 1
    fi

    if ! start_client "$extra_flags" "$client_log"; then
        return 1
    fi

    if ! bench_wait_tunnel 15; then
        echo "  FAIL: tunnel did not come up" >&2
        return 1
    fi

    # udp-gso: marker check. Grep the log FILES directly (no writer|grep -q
    # pipeline — G19: a pipefail'd writer|grep -q can SIGPIPE-fail the
    # writer even on a successful match). Wording pinned by
    # mqvpn_client.c:2843 / mqvpn_server.c:1880 and by
    # run_udp_gso_config_test.sh; keep all three in sync if it ever changes.
    local server_hits client_hits marker_state
    server_hits=$(grep -c "udp-gso: " "$server_log" 2>/dev/null || true)
    client_hits=$(grep -c "udp-gso: " "$client_log" 2>/dev/null || true)
    server_hits="${server_hits:-0}"
    client_hits="${client_hits:-0}"
    if [ "$server_hits" -gt 0 ] && [ "$client_hits" -gt 0 ]; then
        marker_state="present"
    elif [ "$server_hits" -eq 0 ] && [ "$client_hits" -eq 0 ]; then
        marker_state="absent"
    else
        marker_state="MIXED(s=${server_hits},c=${client_hits})"
    fi
    # A mismatch here means this run's throughput/CPU numbers were measured
    # against the WRONG code path (e.g. "disabled" arm actually ran with GSO
    # registered) — a silently-void A/B produced a plausible-looking table
    # once already. This is a hard failure (MARKER_FAIL, checked at script
    # exit), not a WARN: keep the run's row in the table (marker_state below
    # still reports what was actually observed) but fail the script loudly.
    if [ "$expect_present" -eq 1 ] && [ "$marker_state" != "present" ]; then
        echo "  FAIL: expected udp-gso marker present, got ${marker_state}" >&2
        echo "  --- server log tail ($server_log) ---" >&2
        tail -30 "$server_log" >&2 2>/dev/null
        echo "  --- client log tail ($client_log) ---" >&2
        tail -30 "$client_log" >&2 2>/dev/null
        MARKER_FAIL=1
    fi
    if [ "$expect_present" -eq 0 ] && [ "$marker_state" != "absent" ]; then
        echo "  FAIL: expected udp-gso marker absent, got ${marker_state}" >&2
        echo "  --- server log tail ($server_log) ---" >&2
        tail -30 "$server_log" >&2 2>/dev/null
        echo "  --- client log tail ($client_log) ---" >&2
        tail -30 "$client_log" >&2 2>/dev/null
        MARKER_FAIL=1
    fi

    # iperf3 TCP upload (client -> server, no -R): same idiom as
    # bench_aggregate.sh:68-76 / run_throughput_floor_test.sh's
    # run_iperf3_mbps, minus -R (see header comment for why upload, not
    # download, is the deliberate direction here).
    ip netns exec "$NS_SERVER" iperf3 -s -B "$TUNNEL_SERVER_IP" -1 &>/dev/null &
    local iperf_srv_pid=$!
    sleep 1

    cpu_start_client "$_BENCH_CLIENT_PID" "$tag"
    cpu_start_server "$_BENCH_SERVER_PID" "$tag"

    local iperf_json
    iperf_json="$(mktemp)"
    ip netns exec "$NS_CLIENT" iperf3 \
        -c "$TUNNEL_SERVER_IP" -t "$DURATION" -P "$IPERF_STREAMS" --json \
        >"$iperf_json" 2>/dev/null || true

    wait "$iperf_srv_pid" 2>/dev/null || true

    local client_cpu server_cpu
    client_cpu="$(cpu_finish_client "$_BENCH_CLIENT_PID")"
    server_cpu="$(cpu_finish_server "$_BENCH_SERVER_PID")"

    local mbps
    mbps="$(python3 -c "
import json
try:
    with open('${iperf_json}') as f:
        data = json.load(f)
    end = data.get('end', {})
    if 'sum_received' in end:
        print(f\"{end['sum_received']['bits_per_second'] / 1e6:.1f}\")
    elif 'sum' in end:
        print(f\"{end['sum']['bits_per_second'] / 1e6:.1f}\")
    else:
        print('0.0')
except Exception:
    print('0.0')
")"
    rm -f "$iperf_json"

    echo "  tput=${mbps}Mbps  client_cpu=${client_cpu}%  server_cpu=${server_cpu}%  marker=${marker_state}"
    printf '%s %s %s %s %s %s\n' \
        "$arm_label" "$run_idx" "$mbps" "$client_cpu" "$server_cpu" "$marker_state" \
        >> "$RAW_RESULTS"

    finish_run "$tag" "$server_log" "$client_log"
    return 0
}

# --- Main loop: alternate arms, RUNS launches per arm ---
declare -A ARM_RUN_COUNT=( [default]=0 [disabled]=0 )
for arm in "${ARM_SEQUENCE[@]}"; do
    ARM_RUN_COUNT[$arm]=$(( ARM_RUN_COUNT[$arm] + 1 ))
    run_idx="${ARM_RUN_COUNT[$arm]}"

    if [ "$arm" = "default" ]; then
        expect_present=1
        extra_flags=""
    else
        expect_present=0
        extra_flags="-C $DISABLED_INI"
    fi

    if ! run_one "$arm" "$expect_present" "$extra_flags" "$run_idx"; then
        echo "  WARN: run ${arm} #${run_idx} did not complete cleanly (see $LOG_DIR)" >&2
    fi
    sleep 2
done

if [ ! -s "$RAW_RESULTS" ]; then
    echo "ERROR: no successful runs — nothing to report" >&2
    exit 1
fi

# --- Compact table + medians, echoed AND appended to $RESULT_FILE ---
python3 - "$RAW_RESULTS" "$RESULT_FILE" "$MQVPN" "$BIN_SHA256" "$KERNEL" "$RUN_DATE" \
    "$IPERF_STREAMS" "$DURATION" "$UDP_GSO_BENCH_NETEM" "$NETEM_DELAY" "$NETEM_RATE" \
    "${ARM_SEQUENCE[@]}" <<'PYEOF'
import sys
import statistics

argv = sys.argv[1:]
(raw_file, result_file, mqvpn, sha, kernel, run_date, streams, duration,
 netem_on, netem_delay, netem_rate) = argv[:11]
arm_seq = argv[11:]

rows = []
with open(raw_file) as f:
    for line in f:
        parts = line.split()
        if len(parts) != 6:
            continue
        arm, run_idx, mbps, ccpu, scpu, marker = parts
        rows.append({
            "arm": arm,
            "run": int(run_idx),
            "mbps": float(mbps),
            "ccpu": float(ccpu),
            "scpu": float(scpu),
            "marker": marker,
        })

lines = []
lines.append("=" * 72)
lines.append("UdpGso A/B bench result")
lines.append(f"Binary:   {mqvpn}")
lines.append(f"SHA256:   {sha}")
lines.append(f"Kernel:   {kernel}")
lines.append(f"Date:     {run_date}")
lines.append(f"Duration: {duration}s per run, iperf3 TCP -P {streams}")
if netem_on == "1":
    lines.append(f"Netem:    ON  (both paths, both directions: delay {netem_delay} rate {netem_rate})")
    lines.append("NOTE:     shaped mode: compare CPU% at equal tput; expect GSO arm lower")
else:
    lines.append("Netem:    OFF (unshaped netns)")
lines.append(f"Arm order (alternating): {' '.join(arm_seq)}")
lines.append("=" * 72)
lines.append("")
lines.append(
    f"{'arm':<10}{'run':<5}{'tput(Mbps)':<12}{'client%':<10}{'server%':<10}{'marker':<10}"
)
for r in rows:
    lines.append(
        f"{r['arm']:<10}{r['run']:<5}{r['mbps']:<12.1f}"
        f"{r['ccpu']:<10.1f}{r['scpu']:<10.1f}{r['marker']:<10}"
    )

lines.append("")
lines.append("Medians:")
for arm in ("default", "disabled"):
    vals = [r for r in rows if r["arm"] == arm]
    if not vals:
        lines.append(f"  {arm}: no data (all runs failed — see log dir)")
        continue
    med_mbps = statistics.median(v["mbps"] for v in vals)
    med_ccpu = statistics.median(v["ccpu"] for v in vals)
    med_scpu = statistics.median(v["scpu"] for v in vals)
    lines.append(
        f"  {arm:<10} tput={med_mbps:.1f}Mbps  "
        f"client_cpu={med_ccpu:.1f}%  server_cpu={med_scpu:.1f}%  (n={len(vals)})"
    )

text = "\n".join(lines)
print(text)
with open(result_file, "a") as f:
    f.write(text + "\n")
PYEOF

echo ""
echo "Result file: $RESULT_FILE"
exit 0
