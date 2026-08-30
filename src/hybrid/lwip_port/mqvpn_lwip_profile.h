// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/* lwIP TCP-lane sizing profile — single definition point for the values
 * lwipopts.h and tcp_lane.h must derive from the SAME source.
 *
 * Two independent axes:
 *   - WINDOW sizing (TCP_RCV_SCALE / TCP_SND_BUF / PBUF_POOL_SIZE), a
 *     two-way iOS-vs-rest split kept in lwipopts.h. MQVPN_LWIP_IOS_PROFILE
 *     (CMake option) selects it; MQVPN_LWIP_IOS_RCV_SCALE (default 4 =
 *     ~1 MiB window) is the ONLY per-value override allowed.
 *   - POOL sizing (the two pool constants below), a three-way split, because
 *     the pcb pool is what bounds the concurrent-flow cap: tcp_lane.c clamps
 *     hybrid.tcp_max_flows to MQVPN_LWIP_TCP_PCB_POOL / 2.
 *
 * The pool axis keys on __ANDROID__ rather than a CMake option on purpose.
 * The profile constants are consumed by lwip_core AND by every tcp_lane.h
 * includer (mqvpn_lib, tests, fuzz, microbench); a toolchain predefine is
 * uniform across all of them by construction, so no build script can wire
 * the flag into one target and forget another and silently split the
 * profile across TUs. */

#ifndef MQVPN_LWIP_PROFILE_H
#define MQVPN_LWIP_PROFILE_H

/* Tripwire for the pre-rename spelling. Deliberately an #error rather than a
 * compatibility alias: silently accepting the old name would keep the
 * ambiguous "mobile" spelling alive, and silently IGNORING it is worse still —
 * an iOS Network Extension build that still passes -DMQVPN_LWIP_MOBILE_PROFILE
 * would fall through to the desktop/router branch and get its 512 KiB windows
 * with an 8192-pcb pool — a 64x larger flow ceiling against the NE memory
 * ceiling, failing at runtime instead of at
 * build time. Every in-tree caller was renamed with the macro; this only fires
 * for an out-of-tree build script. */
#if defined(MQVPN_LWIP_MOBILE_PROFILE) || defined(MQVPN_LWIP_MOBILE_RCV_SCALE)
#  error \
      "MQVPN_LWIP_MOBILE_{PROFILE,RCV_SCALE} were renamed to MQVPN_LWIP_IOS_{PROFILE,RCV_SCALE}"
#endif

#ifdef MQVPN_LWIP_IOS_PROFILE
/* Default scale 4 (65535<<4 = 1 MiB effective receive window). The tunnel
 * couples this window to the WAN round trip: the lane withholds tcp_recved
 * until the QUIC side takes the bytes, so a flow's ceiling is window/RTT.
 * At 120 ms the old 256 KiB default capped one flow near 17 Mbps in theory
 * and ~5 Mbps measured, while the paths carry 15+; 1 MiB lifts that ceiling
 * fourfold. Budget: PBUF_POOL_SIZE follows the ladder to 128 (~1.1 MiB) and
 * MEMP_NUM_TCP_SEG is already 1024, inside the NE's 50 MB allowance even
 * with a dozen concurrent flows. */
#  ifndef MQVPN_LWIP_IOS_RCV_SCALE
#    define MQVPN_LWIP_IOS_RCV_SCALE 4
#  endif
/* MEMP_NUM_TCP_SEG >= TCP_SND_QUEUELEN (lwIP init.c #error). The gate is
 * kept at scale<=4 (conservative — 1024 would mathematically admit scale 5,
 * but nobody has sized the rest of the iOS budget for a 2 MiB window). */
#  if MQVPN_LWIP_IOS_RCV_SCALE > 4
#    error "iOS profile: scale > 4 violates MEMP_NUM_TCP_SEG >= TCP_SND_QUEUELEN"
#  endif
/* iOS NE (~50 MB resident ceiling): flow cap 64.
 *
 * SEG pool 1024 (was 512 through 2026-08): the pool is GLOBAL across
 * flows while TCP_SND_QUEUELEN caps ONE pcb at ceil(4*TCP_SND_BUF/TCP_MSS)
 * segments — 118 at the scale-2 window this pool was first sized against,
 * 469 at the shipped scale 4 (65536<<4 send buffer) — and SYN-ACKs for NEW
 * connections draw from this same pool: on exhaustion tcp_listen_input
 * silently tcp_abandon()s the freshly-accepted pcb (vendored tcp_in.c), so
 * concurrent-open bursts stall behind SYN retransmits exactly when a few
 * downlink-saturated flows are already holding their queues. At scale 2,
 * 512 covered only ~4 saturated flows and 1024 covered ~8; at scale 4 one
 * saturated pcb takes 469 segs, so 1024 covers ~2 saturated flows plus
 * handshake headroom — the rest of the 12-concurrent field workload
 * (2026-08-27) rides tcp_write()'s ERR_MEM backpressure instead of
 * stalling handshakes. Cost: 32 B/seg = +16 KiB of .bss over 512 — noise
 * against the 50 MB NE ceiling. */
#  define MQVPN_LWIP_TCP_PCB_POOL 128
#  define MQVPN_LWIP_TCP_SEG_POOL 1024
#elif defined(__ANDROID__)
/* Android: flow cap 256 — a handset multiplexes far fewer inner flows than a
 * router, and the pools are .bss touched at lwip_init(), so the desktop
 * profile's larger pcb pool would be resident cost with no matching demand. */
#  define MQVPN_LWIP_TCP_PCB_POOL 512
#  define MQVPN_LWIP_TCP_SEG_POOL 2048
#else
/* Desktop / router (Linux, Windows, macOS): flow cap 4096. The OpenMPTCProuter
 * integration aggregates a whole LAN behind one tunnel, where 256 concurrent
 * inner TCP flows is a real ceiling. Cost of the headroom over the 512/2048
 * this profile used through v0.13.4 is ~2.5 MiB of .bss (pcb 312 B, seg 32 B
 * on LP64), faulted in only when a lane is actually created — lwip_init()
 * runs lazily from the glue, so hybrid-disabled builds pay nothing resident.
 *
 * The seg pool tracks the pcb pool rather than staying at 2048: it is GLOBAL
 * across flows, so 2048 segments against a 4096-flow cap could not hold even
 * one segment per flow, and tcp_write() would return ERR_MEM (relay
 * backpressure — correct, but a throughput cliff) at full occupancy. */
#  define MQVPN_LWIP_TCP_PCB_POOL 8192
#  define MQVPN_LWIP_TCP_SEG_POOL 8192
#endif

/* Window scale for the NON-iOS side of the window axis (desktop/router AND
 * Android — the window split is two-way, unlike the three-way pool split).
 * Overridable so benchmarks/bench_router_window.sh can A/B it without
 * patching the source; 3 (= 512 KiB TCP_WND) is the shipped value, down from
 * the 5 (2 MiB) used through v0.13.4. Measured on the router topology, not
 * inferred from the iOS result: bench_router_window.sh showed no goodput loss
 * against the 2 MiB reference (worst cell -3.6%, gate -5%, and that cell is
 * the LOW-RTT one — a window-BDP limit would worsen with RTT, not improve).
 * A LAN hop needs ~122 KiB at 1 Gbit/s x 1 ms; 512 KiB caps a single inner
 * flow at 4.2 Gbit/s over a 1 ms LAN. See docs/hybrid_h2_memory_budget.md
 * §5d for the run.
 *
 * The per-flow uplink queue is TCP_WND + MQVPN_TCP_LANE_BP_HIGH_WATER, and
 * that product with the flow cap is the lane's aggregate memory bound
 * (docs/hybrid_h2_memory_budget.md §3), so this is the lever for cutting it.
 * Unlike the iOS profile the watermarks here are fixed constants rather than
 * derived from TCP_WND, so a scale low enough to put TCP_WND under the
 * high-water would break the "HIGH < TCP_WND" invariant tcp_lane.h relies on.
 * Guarded below rather than left to produce a subtly wedged backpressure
 * state at runtime. */
#ifndef MQVPN_LWIP_RCV_SCALE
#  define MQVPN_LWIP_RCV_SCALE 3
#endif
#if (65535 << MQVPN_LWIP_RCV_SCALE) <= 262144
#  error "MQVPN_LWIP_RCV_SCALE too low: TCP_WND <= BP_HIGH_WATER breaks HIGH < TCP_WND"
#endif

#endif /* MQVPN_LWIP_PROFILE_H */
