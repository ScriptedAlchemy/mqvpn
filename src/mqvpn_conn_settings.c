// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/*
 * mqvpn_conn_settings.c — implementation. See mqvpn_conn_settings.h for
 * the contract; tests/test_conn_settings.c pins the asymmetric fields.
 */

#include "mqvpn_conn_settings.h"

#include "libmqvpn.h"
#include "mqvpn_internal.h"
#include "mqvpn_scheduler.h"
#include "mqvpn_sched_names.h"

#include <string.h>

#include <xquic/xquic.h>

/* Send-queue cap, per side. The send queue holds BOTH unacked in-flight
 * packets AND framed-but-unsent backlog, and it is the deepest queue on the
 * upload path: at MQVPN_MAX_PKT_OUT_SIZE (1400 B) the old shared 16384-packet
 * cap is ~23 MiB, which a 15 Mbit/s uplink drains in ~12.8 s — measured on
 * device as 13.3 s loaded upload latency through the tunnel, i.e. the queue
 * really does fill to its cap. Everything behind it
 * (datagram-lane pings included — the sndq is FIFO across lanes) waited that
 * long.
 *
 * Server keeps 16384: it serves many clients' bulk downlink from one engine
 * and has the memory; its standing queue per connection is bounded by the
 * client-advertised flow-control windows below, not by this cap.
 *
 * Client drops to 4096 (~5.6 MiB): still >= 2x BDP at 100 ms for a ~230
 * Mbit/s send rate (2 * 230 Mbit/s * 0.1 s = 5.6 MiB), so it cannot become
 * the throughput limit on any plausible phone/desktop uplink, but the
 * blocked-sender rewake threshold — xquic re-notifies EAGAIN'd streams and
 * datagram writers only after sndq_max/10 packets free up
 * (XQC_SNDQ_RELEASE_ENOUGH_SPACE_TH, xqc_send_queue.h) — shrinks from 1638
 * pkts (~2.3 MiB ~= 1.2 s of dead time at 15 Mbit/s) to 410 pkts (~560 KiB
 * ~= 0.3 s), and a full queue now EAGAINs the datagram lane after ~3 s of
 * backlog instead of ~13 s, which is the loss signal inner TCP needs to back
 * off (shallower queue = earlier, honest congestion signal). */
#define XQC_SNDQ_MAX_PKTS_SERVER 16384
#define XQC_SNDQ_MAX_PKTS_CLIENT 4096

/* ─── Stream/connection flow-control windows (fork extension, xquic.h) ───
 *
 * xquic's stock transport params advertise XQC_MAX_RECV_WINDOW = 16 MiB per
 * stream (and a max_data derived as streams x 16 MiB, i.e. unbounded in
 * practice), and its receive-window autotuner may double windows up to that
 * same 16 MiB. For the hybrid TCP lane that means one inner TCP flow may
 * keep up to 16 MiB framed-and-unread in flight: the sender frames stream
 * data into packets up to the advertised window REGARDLESS of cwnd
 * (xqc_stream_do_send_flow_ctl checks stream_send_offset, which advances at
 * framing time), so window minus wire-in-flight sits as standing queue.
 * These fields pin both the initial advertisement AND the autotune ceiling.
 *
 * Per-stream 1 MiB:
 *  - throughput floor: window/RTT = 1 MiB / 100 ms ~= 84 Mbit/s per flow
 *    (>= the 20 Mbit/s @ 100 ms target with 4x headroom; still 28 Mbit/s at
 *    a 300 ms tail RTT). The pre-fix hybrid lane was NOT stream-FC-bound
 *    (16 MiB windows); its per-flow collapse came from the sndq bufferbloat
 *    above, so this is a deliberate CEILING being introduced, not a raise.
 *  - bufferbloat bound: one saturating upload flow's standing queue
 *    (framed-unsent + wire) <= 1 MiB ~= 0.56 s at a 15 Mbit/s uplink;
 *    the cwnd-bounded part of that is on the wire, so the standing unsent
 *    share is window - cwnd_share (~0.3-0.4 s typical).
 *  - which side binds what: the SERVER's advertised
 *    init_max_stream_data_bidi_remote governs the phone's upload per flow
 *    (client-initiated bidi streams, client->server direction); the CLIENT's
 *    init_max_stream_data_bidi_local governs download per flow. Both sides
 *    get the same values from this one builder — a server redeploy with this
 *    build is REQUIRED for the upload-direction bound to take effect.
 *
 * Connection-level 8 MiB:
 *  - hard cap on total sent-but-unread bytes across ALL streams of one
 *    connection ==> per-connection stream receive-buffer memory bound of
 *    8 MiB. iOS NE budget arithmetic: 8 MiB is 16% of the ~50 MB resident
 *    ceiling; the lwIP side adds TCP_WND (1 MiB at the shipped iOS scale)
 *    per QUIC-backpressured flow, ~12 MiB at the measured ~12-flow
 *    workload (docs/hybrid_h2_memory_budget.md §5c has the flow-cap worst
 *    case). Without this cap the theoretical exposure was 64 flows x
 *    16 MiB.
 *  - aggregate stream throughput ceiling 8 MiB/RTT: ~670 Mbit/s @ 100 ms,
 *    ~210 Mbit/s @ 320 ms — above the ~175 Mbit/s download measured through
 *    the tunnel, so no regression on the healthy direction.
 *  - also bounds the aggregate upload standing queue at 8 MiB even if many
 *    flows saturate at once (6 flows x 1 MiB = 6 MiB < 8 MiB: per-stream
 *    caps bind first at the real flow counts). */
#define MQVPN_STREAM_FC_WINDOW (1u * 1024 * 1024)
#define MQVPN_CONN_FC_WINDOW   (8u * 1024 * 1024)

void
mqvpn_apply_scheduler(xqc_conn_settings_t *cs, mqvpn_scheduler_t sched)
{
    /* Invalid/out-of-range values (e.g. a direct API caller bypassing
     * mqvpn_config_set_scheduler()'s validation) fall back to MINRTT,
     * matching the old `default:` case below. Handled up front so the
     * switch itself can drop `default:` and get compile-time coverage:
     * with -Werror -Wswitch (see AGENTS.md build gate), a new
     * mqvpn_scheduler_t enumerator added to libmqvpn.h without a
     * corresponding case here becomes a build failure instead of a
     * silently-missed dispatch. */
    if (!mqvpn_sched_is_valid(sched)) {
        cs->scheduler_callback = xqc_minrtt_scheduler_cb;
        return;
    }

    switch (sched) {
    case MQVPN_SCHED_WLB:
    case MQVPN_SCHED_WLB_UDP_PIN: cs->scheduler_callback = xqc_wlb_scheduler_cb; break;
    case MQVPN_SCHED_BACKUP_FEC:
#if defined(XQC_ENABLE_FEC) && defined(XQC_ENABLE_XOR)
        cs->scheduler_callback = xqc_backup_fec_scheduler_cb;
        cs->enable_encode_fec = 1;
        cs->enable_decode_fec = 1;
        cs->fec_params.fec_encoder_schemes_num = 1;
        cs->fec_params.fec_encoder_schemes[0] = MQVPN_FEC_SCHEME;
        cs->fec_params.fec_decoder_schemes_num = 1;
        cs->fec_params.fec_decoder_schemes[0] = MQVPN_FEC_SCHEME;
        cs->fec_params.fec_code_rate = MQVPN_FEC_CODE_RATE;
        cs->fec_params.fec_max_symbol_num_per_block = MQVPN_FEC_BLOCK_SIZE;
        cs->fec_params.fec_mp_mode = XQC_FEC_MP_USE_STB;
        /* fec_callback intentionally left zero — xqc_set_valid_*_scheme_cb()
           fills it after FEC scheme negotiation completes. */
#else
        /* Built without FEC — silently degrade to MINRTT. main.c parser
           also rejects "backup_fec" at the CLI surface in this case, so this
           branch only protects against direct API callers. */
        cs->scheduler_callback = xqc_minrtt_scheduler_cb;
#endif
        break;
    case MQVPN_SCHED_MINRTT: cs->scheduler_callback = xqc_minrtt_scheduler_cb; break;
    }
}

/* Wires the stock xquic reinjection ctls. Never touches scheduler_callback:
 * Scheduler and Reinjection are orthogonal axes (see the design doc; the
 * xquic datagram_redundancy switch is NOT used precisely because it would
 * override the scheduler). */
static void
mqvpn_apply_reinjection(const mqvpn_conn_settings_input_t *in, xqc_conn_settings_t *cs)
{
    /* Invalid/out-of-range values fall back to OFF (same treatment as
     * mqvpn_apply_scheduler above). */
    mqvpn_reinjection_t mode = in->reinjection;
    if (!mqvpn_reinj_is_valid(mode)) mode = MQVPN_REINJ_OFF;

    switch (mode) {
    case MQVPN_REINJ_OFF: break;
    case MQVPN_REINJ_IDLE:
        cs->reinj_ctl_callback = xqc_default_reinj_ctl_cb;
        cs->mp_enable_reinjection = XQC_REINJ_UNACK_AFTER_SCHED;
        break;
    case MQVPN_REINJ_DEADLINE:
        cs->reinj_ctl_callback = xqc_deadline_reinj_ctl_cb;
        /* AFTER_SEND set explicitly rather than relying on xquic's
         * BEFORE_SCHED auto-add (xqc_conn.c) so the intent is visible here. */
        cs->mp_enable_reinjection =
            XQC_REINJ_UNACK_BEFORE_SCHED | XQC_REINJ_UNACK_AFTER_SEND;
        cs->reinj_flexible_deadline_srtt_factor =
            (in->reinj_srtt_factor_pct > 0 ? in->reinj_srtt_factor_pct : 110) / 100.0;
        cs->reinj_hard_deadline =
            (uint64_t)(in->reinj_hard_deadline_ms > 0 ? in->reinj_hard_deadline_ms
                                                      : 500) *
            1000;
        cs->reinj_deadline_lower_bound =
            (uint64_t)(in->reinj_deadline_lower_bound_ms > 0
                           ? in->reinj_deadline_lower_bound_ms
                           : 20) *
            1000;
        /* xquic computes max(min(factor*min_srtt, hard), lower) — an
         * unclamped lower > hard would silently dominate the max() and
         * defeat the documented "hard is the upper clamp" semantics. */
        if (cs->reinj_deadline_lower_bound > cs->reinj_hard_deadline) {
            cs->reinj_deadline_lower_bound = cs->reinj_hard_deadline;
        }
        break;
    case MQVPN_REINJ_DGRAM:
        cs->reinj_ctl_callback = xqc_dgram_reinj_ctl_cb;
        cs->mp_enable_reinjection = XQC_REINJ_UNACK_AFTER_SEND;
        break;
    }
}

void
mqvpn_build_conn_settings(const mqvpn_conn_settings_input_t *in, xqc_conn_settings_t *out)
{
    memset(out, 0, sizeof(*out));

    /* --- shared hardcoded fields --- */
    out->max_datagram_frame_size = 65535;
    out->proto_version = XQC_VERSION_V1;
    out->pacing_on = 1;
    out->max_pkt_out_size = MQVPN_MAX_PKT_OUT_SIZE;
    /* PMTUD probes use a separate ceiling in xquic. Leaving it zero selects
     * xquic's 1420-byte packet budget instead of mqvpn's 1400-byte budget;
     * keep both paths on one deliberate ceiling. The relay codec separately
     * allows xquic's ACK and AEAD expansion around that budget. */
    out->probing_pkt_out_size = MQVPN_MAX_PKT_OUT_SIZE;
    out->idle_time_out = 120000;
    out->init_idle_time_out = 10000;

    /* Flow-control windows — shared by both sides; see the arithmetic on the
     * MQVPN_*_FC_WINDOW defines above. bidi_remote is what actually bounds
     * the phone's upload (peer-initiated bidi streams, receive side of the
     * server); bidi_local bounds download on the client; uni streams carry
     * only H3 control/QPACK traffic and just inherit the same bound. */
    out->init_max_stream_data_bidi_local = MQVPN_STREAM_FC_WINDOW;
    out->init_max_stream_data_bidi_remote = MQVPN_STREAM_FC_WINDOW;
    out->init_max_stream_data_uni = MQVPN_STREAM_FC_WINDOW;
    out->init_max_data = MQVPN_CONN_FC_WINDOW;

    /* Caller-gated, never derived here: see the field comment in
     * mqvpn_conn_settings.h for why this must equal the batched-send
     * registration decision rather than any locally recomputed condition. */
    out->defer_send_flush = in->defer_send_flush ? 1 : 0;

    /* --- congestion control ---
     * Invalid/out-of-range values fall back to BBR2, matching the old
     * `default:` case. Normalized up front so the switch can drop
     * `default:` and get -Wswitch coverage (same treatment as
     * mqvpn_apply_scheduler above). */
    mqvpn_cc_t cc = in->cc;
    if (!mqvpn_cc_is_valid(cc)) cc = MQVPN_CC_BBR2;
#ifndef XQC_ENABLE_UNLIMITED
    /* Built without UNLIMITED — NONE degrades to BBR2, as the old
     * default: case did (main.c's CLI gate rejects "none" up front; this
     * only protects direct API callers). */
    if (cc == MQVPN_CC_NONE) cc = MQVPN_CC_BBR2;
#endif
    switch (cc) {
    case MQVPN_CC_BBR: out->cong_ctrl_callback = xqc_bbr_cb; break;
    case MQVPN_CC_CUBIC: out->cong_ctrl_callback = xqc_cubic_cb; break;
    case MQVPN_CC_NONE:
#ifdef XQC_ENABLE_UNLIMITED
        out->cong_ctrl_callback = xqc_unlimited_cc_cb;
#endif
        /* unreachable when UNLIMITED is off (normalized above); the case
         * label stays so -Wswitch coverage holds in both build configs. */
        break;
    case MQVPN_CC_BBR2:
        out->cong_ctrl_callback = xqc_bbr2_cb;
        /* RTTVAR_COMPENSATION is deliberately NOT set. It adds
         * bw * (srtt - min_rtt) to target cwnd
         * (xqc_bbr2_compensate_cwnd_for_rttvar) — meant to ride out wireless
         * RTT spikes that are NOT congestion. But on a bufferbloated uplink
         * srtt - min_rtt IS our own standing queue's delay, so the addition
         * equals the bytes already sitting in the queue: queue -> srtt up ->
         * cwnd up -> deeper queue, a positive feedback loop with no fixed
         * point below the so_sndbuf cwnd clamp. Observed on device: cwnd
         * pinned at the 8 MiB clamp with srtt inflated
         * 100 ms -> 13.3 s under upload load. Without the flag, cwnd tracks
         * cwnd_gain (2.0) x BDP(min_rtt) + ack-aggregation headroom, i.e.
         * bottleneck queue ~= 1x BDP (~100 ms extra at any rate) instead of
         * "whatever the clamp allows". Throughput cost: none in steady state
         * — BBR2's bw estimate is delivery-rate based and unaffected;
         * genuine non-congestive RTT spikes now cost a temporarily
         * conservative cwnd, the right trade for an interactive VPN. */
        out->cc_params.cc_optimization_flags = XQC_BBR2_FLAG_FAST_CONVERGENCE;
        break;
    }

    /* --- intentional client/server asymmetry (4) ---
     * Each branch documents why these fields differ between sides. Do not
     * collapse without revisiting tests/test_conn_settings.c
     * test_asymmetry_server_vs_client. */
    if (in->is_server) {
        /* server allows multipath unconditionally; client side gates on
         * cfg->multipath. draft-21 §3.2.1 ¶7 PATHS_BLOCKED auto-grant
         * (max_path_id_grant_max_value) is server-only because mqvpn's
         * client is the active path creator. */
        out->enable_multipath = 1;
        out->mp_ping_on = 1;
        out->max_path_id_grant_max_value = 128;

        /* Deep send queue + 8 MiB cwnd clamp: the server's job is bulk
         * downlink at datacenter bandwidth; its per-connection standing
         * queue is bounded by the client-advertised FC windows, not by
         * these. (so_sndbuf is a per-path cwnd clamp in this xquic fork —
         * xqc_send_ctl.c — not a socket buffer.) */
        out->sndq_packets_used_max = XQC_SNDQ_MAX_PKTS_SERVER;
        out->so_sndbuf = 8 * 1024 * 1024;
    } else {
        /* client carries the keep-alive role (ping_on=1) and gates MP on
         * cfg->multipath. */
        out->enable_multipath = in->enable_multipath ? 1 : 0;
        out->mp_ping_on = in->enable_multipath ? 1 : 0;
        out->ping_on = 1;

        if (in->recv_rate_bytes_per_sec) {
            out->recv_rate_bytes_per_sec = in->recv_rate_bytes_per_sec;
        }

        /* Shallower send queue (see XQC_SNDQ_MAX_PKTS_CLIENT's comment for
         * the latency/rewake arithmetic) and a 4 MiB cwnd clamp: 4 MiB =
         * 2x BDP at 100 ms for a 160 Mbit/s uplink (or 200 ms at 80
         * Mbit/s), generous against any plausible phone/home uplink while
         * halving the worst damage a cwnd-runaway regression could do to
         * loaded latency (4 MiB / 15 Mbit/s ~= 2.2 s vs 4.4 s). */
        out->sndq_packets_used_max = XQC_SNDQ_MAX_PKTS_CLIENT;
        out->so_sndbuf = 4 * 1024 * 1024;
    }

    /* --- scheduler / FEC params --- */
    mqvpn_apply_scheduler(out, in->scheduler);

    /* --- reinjection --- */
    mqvpn_apply_reinjection(in, out);

    /* --- init_max_path_id ---
     * xquic's default grant is 8 path IDs, which was ample when a client
     * bound one socket per interface. Consumer uplinks shape per flow
     * though (measured: one outer flow caps near 5 Mbps, four reach 11),
     * so the client now opens several replica sockets per interface and a
     * two-interface phone asks for 16. Grant 32 by default — the ID space
     * is cheap, the server tolerates 128, and refusing a path silently
     * costs exactly the throughput the replicas exist to win. */
    if (in->init_max_path_id > 0) {
        out->init_max_path_id = in->init_max_path_id;
    } else {
        out->init_max_path_id = 32;
    }
}

#if defined(__linux__)

#  include "udp_offload.h"

/* The fallback sendmmsg path hands xquic's whole burst to one
 * mqvpn_udp_send_batch() call; its mmsghdr array must cover it. Pinned here,
 * next to the one registration site, rather than per caller. */
_Static_assert(XQC_MAX_SEND_MSG_ONCE <= MQVPN_OFFLOAD_MAX_BATCH,
               "fallback mmsghdr array must cover xquic's burst size");

int
mqvpn_tx_batch_register(int udp_gso, xqc_send_mmsg_ex_pt cb,
                        xqc_transport_callbacks_t *tcbs, xqc_config_t *xconfig,
                        int *gso_available)
{
    /* mqvpn_tx_batch_enabled's MQVPN_MAX_PKT_OUT_SIZE <= 1500 term guards
     * mqvpn_udp_send_batch()'s single-run/no-splitting contract
     * (udp_offload.h) — a future raise of the constant above ~2KB must
     * revisit run-splitting before this registration can stay
     * unconditional. */
    if (!mqvpn_tx_batch_enabled(udp_gso)) return 0;
    *gso_available = mqvpn_udp_gso_probe();
    tcbs->write_mmsg_ex = cb;
    xconfig->sendmmsg_on = 1;
    return 1;
}

#endif /* __linux__ */
