// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/*
 * flow_sched.h
 *
 * Scheduler mode constants and IPv4/IPv6 5-tuple flow hash utility.
 * Path selection is handled inside xquic scheduler callbacks
 * (minrtt/wlb).
 */
#ifndef MQVPN_FLOW_SCHED_H
#define MQVPN_FLOW_SCHED_H

#include <stdint.h>
#include <stdbool.h>

/* Scheduler mode (mirrors mqvpn_scheduler_t in include/libmqvpn.h).
 * Keep in sync — referenced by tests that include only flow_sched.h. */
#define MQVPN_SCHED_MINRTT      0
#define MQVPN_SCHED_WLB         1
#define MQVPN_SCHED_BACKUP_FEC  2
#define MQVPN_SCHED_WLB_UDP_PIN 3

/* Mirrors the WLB scheduler's internal WLB_FLOW_HASH_UNPINNED sentinel
 * (third_party/xquic/src/transport/scheduler/xqc_scheduler_wlb.c). A datagram
 * sent with this hash is scheduled per-packet WRR with no flow-table pinning.
 * A 1-in-2^32 organic FNV-1a collision with the sentinel is harmless: that
 * one flow is merely scheduled unpinned. */
#define MQVPN_FLOW_HASH_UNPINNED 0xFFFFFFFFU

/* Returns flow hash for xquic WLB scheduler hint.
 *   TCP                        → FNV-1a 5-tuple hash
 *   UDP, udp_pin=true          → FNV-1a 5-tuple hash (used by wlb_udp_pin)
 *   UDP, udp_pin=false / ICMP  → MQVPN_FLOW_HASH_UNPINNED (per-packet WRR)
 *   malformed / unknown        → 0 (xquic falls back to MinRTT)
 *
 * IPv4 fragments for pinned TCP, and for UDP when udp_pin=true, use
 * src/dst IP + protocol + IPv4 Identification because non-first fragments do
 * not carry TCP/UDP ports. UDP fragments remain unpinned when udp_pin=false.
 *
 * IPv6 extension headers are intentionally out of scope for now; IPv6 pinning
 * only recognizes packets whose base header points directly at TCP or UDP. */
uint32_t flow_hash_pkt(const uint8_t *pkt, int len, bool udp_pin);

/* Datagram flow-hash hint for xqc_conn_set_dgram_flow_hash.
 *
 * A reorder-stamped flow is resequenced at the peer, so cross-path reordering
 * is absorbed there. Keeping it pinned would only cap the flow at one path's
 * share (the measured 22-vs-42 Mbps gap on a 12-connection upload). When
 * stamped, return the WLB unpin sentinel so the datagram is scheduled
 * per-packet WRR like stream data; otherwise hash as usual. */
static inline uint32_t
mqvpn_dgram_flow_hash(const uint8_t *pkt, int len, bool udp_pin, bool stamped)
{
    if (stamped) {
        return MQVPN_FLOW_HASH_UNPINNED;
    }
    return flow_hash_pkt(pkt, len, udp_pin);
}

#endif /* MQVPN_FLOW_SCHED_H */
