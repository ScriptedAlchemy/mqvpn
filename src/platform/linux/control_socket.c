// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/*
 * control_socket.c — TCP control API for mqvpn server
 *
 * Supported JSON commands:
 *
 *   {"cmd":"add_user",    "name":"alice","key":"alice-secret"}
 *   {"cmd":"remove_user", "name":"alice"}
 *   {"cmd":"list_users"}
 *   {"cmd":"get_stats"}
 *   {"cmd":"get_status"}
 *   {"cmd":"get_build_info"}
 *   {"cmd":"get_fec_stats","user":"alice"}
 *   {"cmd":"get_all_fec_stats"}
 *   {"cmd":"get_reorder_stats"}
 *
 * Responses:
 *   {"ok":true}
 *   {"ok":false,"error":"<reason>"}
 *   {"ok":true,"users":["alice","bob"]}
 *   {"ok":true,"n_clients":N,"bytes_tx":X,"bytes_rx":Y,
 *    "dgram_sent":S,"dgram_recv":R,"dgram_lost":L,"dgram_acked":A,
 *    "uptime_sec":U}
 *   {"ok":true,"version":"0.7.0","scheduler":"backup_fec","fec_enabled":1}
 *   {"ok":true,"user":"alice","enable_fec":1,"mp_state":1,
 *    "mp_state_label":"active_with_standby",
 *    "fec_send_cnt":142,"fec_recover_cnt":17,"lost_dgram_cnt":23,
 *    "total_app_bytes":9123456,"standby_app_bytes":421337}
 *   {"ok":true,"n_clients":N,"clients":[{"user":"alice","enable_fec":1,
 *    "mp_state":1,"mp_state_label":"active_with_standby", ...}, ...]}
 *   {"ok":true,"reorder":{"gap_count":N,"gap_filled_count":N,
 *    "gap_timeout_count":N,"gap_overflow_count":N,"gap_demote_count":N,
 *    "gap_reset_count":N,"ack_demote_count":N,"too_late_drop_count":N,
 *    "too_far_ahead_drop_count":N,"duplicate_drop_count":N,"pool_drop_count":N,
 *    "per_flow_limit_drop_count":N,"reset_discard_count":N,"delivered_count":N,
 *    "added_latency_p99_ms":F,"added_latency_max_ms":F,
 *    "added_latency_buffered_p99_ms":F}}
 */

#include "control_socket.h"
#include "json_mini.h"
#include "log.h"

#include <event2/event.h>
#include "mqvpn_internal.h" /* mqvpn_server_scheduler_label,
                               mqvpn_path_state_label,
                               mqvpn_internal_fec_stats_t (carries mp_state_label),
                               mqvpn_server_get_client_fec_stats,
                               mqvpn_server_get_all_fec_stats,
                               mqvpn_server_get_reorder_stats,
                               mqvpn_reorder_stats_t (via reorder.h),
                               mqvpn_internal_client_reinject_t,
                               mqvpn_server_get_client_reinject,
                               mqvpn_internal_client_wlb_t,
                               mqvpn_server_get_client_wlb */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>
#include <inttypes.h>
#include <sys/time.h>
#include <time.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#define CTRL_MAX_REQ          4096 /* per-connection request buffer */
#define CTRL_MAX_CONNS        8    /* max concurrent control connections */
#define CTRL_READ_TIMEOUT_SEC 5    /* close idle connections after 5s */
#define CTRL_WRITE_TIMEOUT_SEC 5   /* fail closed when a peer does not drain */
#define CTRL_WRITE_BUDGET_BYTES (64 * 1024) /* preserve UDP/libevent fairness */
#define CTRL_WRITE_BUDGET_CALLS 16
/* CTRL_MAX_RESP_BYTES moved to control_socket.h so test_control_response_bound
 * can verify the worst-case JSON size fits. */

/* JSON helpers (json_find_key → json_find_key, json_read_string → json_read_string)
 * are provided by json_mini.h */

/* ── Per-connection state ────────────────────────────────────────────────── */

typedef struct {
    int fd;
    struct event *ev;
    struct event *ev_write;
    char req[CTRL_MAX_REQ + 1];
    size_t req_len;
    char *resp;
    size_t resp_len;
    size_t resp_off;
    uint64_t write_deadline_ms;
    ctrl_socket_t *cs;
} ctrl_conn_t;

/* ── Server handle ───────────────────────────────────────────────────────── */

struct ctrl_socket_s {
    int listen_fd;
    struct event *ev_accept;
    struct event_base *eb;
    mqvpn_server_t *server;
    /* Borrowed platform-owned RX offload counters; see ctrl_socket_create's
     * doc for why these do not travel through mqvpn_stats_t. NULL = report 0. */
    const uint64_t *gro_receives;
    const uint64_t *gro_datagrams;
    int n_conns; /* active control connections */
};

/* ── Command dispatch ────────────────────────────────────────────────────── */

static int
ctrl_cmd_add_user(const char *req, char *resp, size_t resp_len, ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    char name[64] = {0}, key[256] = {0};
    const char *nv = json_find_key(req, "name");
    const char *kv = json_find_key(req, "key");
    if (!nv || json_read_string(nv, name, sizeof(name)) < 0 || !kv ||
        json_read_string(kv, key, sizeof(key)) < 0)
        return snprintf(resp, resp_len,
                        "{\"ok\":false,\"error\":\"name and key required\"}");

    int rc = mqvpn_server_add_user(server, name, key);
    if (rc != MQVPN_OK)
        return snprintf(resp, resp_len,
                        "{\"ok\":false,\"error\":\"add_user failed (%d)\"}", rc);
    return snprintf(resp, resp_len, "{\"ok\":true}");
}

static int
ctrl_cmd_remove_user(const char *req, char *resp, size_t resp_len, ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    char name[64] = {0};
    const char *nv = json_find_key(req, "name");
    if (!nv || json_read_string(nv, name, sizeof(name)) < 0)
        return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"name required\"}");

    int rc = mqvpn_server_remove_user(server, name);
    if (rc != MQVPN_OK)
        return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"user not found\"}");
    return snprintf(resp, resp_len, "{\"ok\":true}");
}

static int
ctrl_cmd_list_users(const char *req, char *resp, size_t resp_len, ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    (void)req;
    char unames[MQVPN_MAX_USERS][64];
    int n_users = mqvpn_server_list_users(server, unames, MQVPN_MAX_USERS);

    char users[MQVPN_MAX_USERS * 68 + 8];
    int pos = 0;
    users[pos++] = '[';
    for (int i = 0; i < n_users; i++) {
        if (i > 0) users[pos++] = ',';
        /* Clamp pos to prevent underflow on sizeof(users) - pos */
        int w = snprintf(users + pos, sizeof(users) - (size_t)pos, "\"%s\"", unames[i]);
        if (w > 0 && (size_t)(pos + w) < sizeof(users))
            pos += w;
        else
            break; /* truncated — stop appending */
    }
    users[pos++] = ']';
    users[pos] = '\0';
    return snprintf(resp, resp_len, "{\"ok\":true,\"users\":%s}", users);
}

static int
ctrl_cmd_get_stats(const char *req, char *resp, size_t resp_len, ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    (void)req;
    mqvpn_stats_t st = {0};
    st.struct_size = sizeof(st);
    mqvpn_server_get_stats(server, &st);
    int nc = mqvpn_server_get_n_clients(server);
    uint64_t uptime = mqvpn_server_uptime_seconds(server);
    return snprintf(
        resp, resp_len,
        "{\"ok\":true,\"n_clients\":%d,"
        "\"bytes_tx\":%" PRIu64 ",\"bytes_rx\":%" PRIu64 ","
        "\"dgram_sent\":%" PRIu64 ",\"dgram_recv\":%" PRIu64 ","
        "\"dgram_lost\":%" PRIu64 ",\"dgram_acked\":%" PRIu64 ","
        "\"pkts_lane_tcp\":%" PRIu64 ",\"pkts_lane_dgram\":%" PRIu64 ","
        "\"pkts_lane_raw\":%" PRIu64 ",\"pkts_lane_tcp_dropped\":%" PRIu64 ","
        "\"tcp_flows_active\":%" PRIu64 ",\"tcp_flows_total\":%" PRIu64 ","
        "\"tcp_flows_rejected\":%" PRIu64 ",\"raw_markers_active\":%" PRIu64 ","
        /* udp_tx_* from the library (it issues those sends); udp_rx_* from the
         * platform (GRO never crosses the library ABI). datagrams/sends and
         * datagrams/receives are the achieved batching and coalescing factors
         * — 1.0 means every datagram cost its own syscall, which the one-shot
         * "udp-gso:"/"udp-gro:" startup markers cannot distinguish because
         * they only report the kernel capability probe. */
        "\"udp_tx_sends\":%" PRIu64 ",\"udp_tx_datagrams\":%" PRIu64 ","
        "\"udp_rx_receives\":%" PRIu64 ",\"udp_rx_datagrams\":%" PRIu64 ","
        "\"uptime_sec\":%" PRIu64 "}",
        nc, st.bytes_tx, st.bytes_rx, st.dgram_sent, st.dgram_recv, st.dgram_lost,
        st.dgram_acked, st.pkts_lane_tcp, st.pkts_lane_dgram, st.pkts_lane_raw,
        st.pkts_lane_tcp_dropped, st.tcp_flows_active, st.tcp_flows_total,
        st.tcp_flows_rejected, st.raw_markers_active, st.udp_tx_sends,
        st.udp_tx_datagrams, cs->gro_receives ? *cs->gro_receives : 0,
        cs->gro_datagrams ? *cs->gro_datagrams : 0, uptime);
}

static int
ctrl_cmd_get_status(const char *req, char *resp, size_t resp_len, ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    (void)req;
    mqvpn_client_info_t clients[MQVPN_MAX_USERS];
    int n_clients = 0;
    mqvpn_server_get_client_info(server, clients, MQVPN_MAX_USERS, &n_clients);

    /* Index-aligned with clients[] above — contract is on
     * mqvpn_server_get_client_reinject() in mqvpn_internal.h. Matched by
     * path_id below anyway, not by array position alone. */
    mqvpn_internal_client_reinject_t reinj[MQVPN_MAX_USERS];
    int n_reinj = mqvpn_server_get_client_reinject(server, reinj, MQVPN_MAX_USERS);
    if (n_reinj < 0) n_reinj = 0;

    /* Same index-alignment contract as reinj[] above. The per-path JSON still
     * matches by path_id so missing/misaligned snapshots degrade to zero/false
     * fields without changing the response shape. */
    mqvpn_internal_client_wlb_t wlb[MQVPN_MAX_USERS];
    int n_wlb = mqvpn_server_get_client_wlb(server, wlb, MQVPN_MAX_USERS);
    if (n_wlb < 0) n_wlb = 0;

    uint64_t now = 0;
    struct timeval tv;
    if (gettimeofday(&tv, NULL) == 0)
        now = (uint64_t)tv.tv_sec * 1000000 + (uint64_t)tv.tv_usec;

    /* Truncation discipline: any append that would not fit sets
     * `truncated = 1`. After both loops we check the flag once and
     * substitute a small "response too large" envelope so a malformed
     * inner JSON never escapes. The caller-side guard is now defence
     * in depth, not the only line of defence. */
    char buf[CTRL_MAX_RESP_BYTES];
    int pos = 0;
    int truncated = 0;
    int w;

#define APPEND(...)                                                      \
    do {                                                                 \
        w = snprintf(buf + pos, sizeof(buf) - (size_t)pos, __VA_ARGS__); \
        if (w < 0 || (size_t)(pos + w) >= sizeof(buf)) {                 \
            truncated = 1;                                               \
            goto get_status_done;                                        \
        }                                                                \
        pos += w;                                                        \
    } while (0)

    APPEND("{\"ok\":true,\"n_clients\":%d,\"clients\":[", n_clients);

    for (int i = 0; i < n_clients; i++) {
        mqvpn_client_info_t *ci = &clients[i];
        uint64_t conn_sec = (ci->connected_at_us > 0 && now > ci->connected_at_us)
                                ? (now - ci->connected_at_us) / 1000000
                                : 0;

        if (i > 0) APPEND(",");
        APPEND("{\"user\":\"%s\",\"endpoint\":\"%s\","
               "\"connected_sec\":%" PRIu64 ","
               "\"bytes_tx\":%" PRIu64 ",\"bytes_rx\":%" PRIu64 ","
               "\"performance\":\"%s\","
               "\"n_paths\":%d,\"paths\":[",
               ci->username, ci->endpoint, conn_sec, ci->bytes_tx, ci->bytes_rx,
               ci->performance[0] ? ci->performance : "throughput",
               ci->n_paths);

        for (int p = 0; p < ci->n_paths; p++) {
            mqvpn_path_stats_t *ps = &ci->paths[p];
            if (p > 0) APPEND(",");

            /* Emit 0 on mismatch/absence (index out of range, or no path_id
             * match within reinj[i]) rather than skipping the field — the
             * JSON shape must stay constant so test_control_response_bound's
             * worst-case model holds. */
            uint64_t reinject_tx_bytes = 0;
            if (i < n_reinj) {
                mqvpn_internal_client_reinject_t *re = &reinj[i];
                for (int rp = 0; rp < re->n_paths; rp++) {
                    if (re->paths[rp].path_id == ps->path_id) {
                        reinject_tx_bytes = re->paths[rp].reinject_tx_bytes;
                        break;
                    }
                }
            }

            uint64_t goodput_Bps = 0;
            int warmup = 0;
            unsigned weight_pct = 0;
            if (i < n_wlb) {
                mqvpn_internal_client_wlb_t *wl = &wlb[i];
                for (int wp = 0; wp < wl->n_paths; wp++) {
                    if (wl->paths[wp].path_id == ps->path_id) {
                        goodput_Bps = wl->paths[wp].goodput_Bps;
                        warmup = wl->paths[wp].warmup ? 1 : 0;
                        weight_pct = wl->paths[wp].weight_pct;
                        break;
                    }
                }
            }

            APPEND(
                "{\"path_id\":%" PRIu64 ",\"srtt_ms\":%" PRIu64 ",\"min_rtt_ms\":%" PRIu64
                ",\"cwnd\":%" PRIu64 ",\"in_flight\":%" PRIu64 ",\"bytes_tx\":%" PRIu64
                ",\"bytes_rx\":%" PRIu64 ",\"pkt_sent\":%" PRIu64 ",\"pkt_recv\":%" PRIu64
                ",\"pkt_lost\":%" PRIu64 ",\"state\":%u,\"state_label\":\"%s\","
                "\"reinject_tx_bytes\":%" PRIu64 ",\"goodput_Bps\":%" PRIu64
                ",\"warmup\":%s,\"weight_pct\":%u}",
                ps->path_id, ps->srtt_us / 1000, ps->min_rtt_us / 1000, ps->cwnd,
                ps->bytes_in_flight, ps->bytes_tx, ps->bytes_rx, ps->pkt_sent,
                ps->pkt_recv, ps->pkt_lost, ps->state, mqvpn_path_state_label(ps->state),
                reinject_tx_bytes, goodput_Bps, warmup ? "true" : "false", weight_pct);
        }

        APPEND("]}");
    }

    APPEND("]}");

get_status_done:
#undef APPEND
    if (truncated) {
        /* The envelope is 41 bytes — well under any plausible resp_len
         * (callers pass CTRL_MAX_RESP_BYTES - 2). The same
         * guard exists at the connection layer as defence in depth. */
        return snprintf(resp, resp_len,
                        "{\"ok\":false,\"error\":\"response too large\"}");
    }
    return snprintf(resp, resp_len, "%.*s", pos, buf);
}

static int
ctrl_cmd_get_build_info(const char *req, char *resp, size_t resp_len, ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    (void)req;
    const char *ver = mqvpn_version_string();
    const char *sched = mqvpn_server_scheduler_label(server);
#ifdef XQC_ENABLE_FEC
    int fec_enabled = 1;
#else
    int fec_enabled = 0;
#endif
    return snprintf(resp, resp_len,
                    "{\"ok\":true,\"version\":\"%s\","
                    "\"scheduler\":\"%s\",\"fec_enabled\":%d}",
                    ver ? ver : "unknown", sched, fec_enabled);
}

static int
ctrl_cmd_get_fec_stats(const char *req, char *resp, size_t resp_len, ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    char user[64] = {0};
    const char *uv = json_find_key(req, "user");
    if (!uv || json_read_string(uv, user, sizeof(user)) < 0)
        return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"user required\"}");

    mqvpn_internal_fec_stats_t fs;
    int rc = mqvpn_server_get_client_fec_stats(server, user, &fs);
    if (rc < 0)
        return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"fec not built\"}");
    if (rc == 0)
        return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"user not found\"}");

    /* `user` is echoed without explicit JSON-escape: mqvpn_server_add_user
     * and add_user_entry reject quote, backslash, and control bytes at
     * intake (src/auth.c), so any user that survived to the sessions[]
     * table cannot produce JSON-unsafe output here. If a future code path
     * registers users via an unvalidated source (e.g., LDAP bridge), this
     * point must add a JSON-safe escape pass. */
    return snprintf(resp, resp_len,
                    "{\"ok\":true,\"user\":\"%s\","
                    "\"enable_fec\":%u,\"mp_state\":%u,"
                    "\"mp_state_label\":\"%s\","
                    "\"fec_send_cnt\":%" PRIu64 ",\"fec_recover_cnt\":%" PRIu64 ","
                    "\"lost_dgram_cnt\":%" PRIu64 ","
                    "\"total_app_bytes\":%" PRIu64 ","
                    "\"standby_app_bytes\":%" PRIu64 "}",
                    user, (unsigned)fs.enable_fec, (unsigned)fs.mp_state,
                    fs.mp_state_label ? fs.mp_state_label : "unknown", fs.fec_send_cnt,
                    fs.fec_recover_cnt, fs.lost_dgram_cnt, fs.total_app_bytes,
                    fs.standby_app_bytes);
}

static int
ctrl_cmd_get_all_fec_stats(const char *req, char *resp, size_t resp_len,
                           ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    (void)req;
    /* Bulk variant collapsing the per-user N+1 RPC pattern in scrapers
     * (Prometheus exporter) to a single call. Same XQC_ENABLE_FEC guard
     * as get_fec_stats — we surface "fec not built" so the consumer can
     * stop probing for the rest of the scrape. */
    mqvpn_internal_fec_entry_t entries[MQVPN_MAX_USERS];
    int n = mqvpn_server_get_all_fec_stats(server, entries, MQVPN_MAX_USERS);
    if (n < 0)
        return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"fec not built\"}");

    char buf[CTRL_MAX_RESP_BYTES];
    int pos = 0;
    int truncated = 0;
    int w;

#define APPEND(...)                                                      \
    do {                                                                 \
        w = snprintf(buf + pos, sizeof(buf) - (size_t)pos, __VA_ARGS__); \
        if (w < 0 || (size_t)(pos + w) >= sizeof(buf)) {                 \
            truncated = 1;                                               \
            goto get_all_fec_done;                                       \
        }                                                                \
        pos += w;                                                        \
    } while (0)

    /* Field name parity with get_status: "n_clients" + "clients[]". A
     * connected user IS a client in mqvpn nomenclature; "users" is used
     * by list_users for the registered auth-table users (a superset). */
    APPEND("{\"ok\":true,\"n_clients\":%d,\"clients\":[", n);
    for (int i = 0; i < n; i++) {
        mqvpn_internal_fec_entry_t *e = &entries[i];
        if (i > 0) APPEND(",");
        APPEND("{\"user\":\"%s\","
               "\"enable_fec\":%u,\"mp_state\":%u,"
               "\"mp_state_label\":\"%s\","
               "\"fec_send_cnt\":%" PRIu64 ",\"fec_recover_cnt\":%" PRIu64 ","
               "\"lost_dgram_cnt\":%" PRIu64 ","
               "\"total_app_bytes\":%" PRIu64 ","
               "\"standby_app_bytes\":%" PRIu64 "}",
               e->user, (unsigned)e->stats.enable_fec, (unsigned)e->stats.mp_state,
               e->stats.mp_state_label ? e->stats.mp_state_label : "unknown",
               e->stats.fec_send_cnt, e->stats.fec_recover_cnt, e->stats.lost_dgram_cnt,
               e->stats.total_app_bytes, e->stats.standby_app_bytes);
    }
    APPEND("]}");

get_all_fec_done:
#undef APPEND
    if (truncated) {
        return snprintf(resp, resp_len,
                        "{\"ok\":false,\"error\":\"response too large\"}");
    }
    return snprintf(resp, resp_len, "%.*s", pos, buf);
}

static int
ctrl_cmd_get_reorder_stats(const char *req, char *resp, size_t resp_len,
                           ctrl_socket_t *cs)
{
    mqvpn_server_t *server = cs->server;
    (void)req;
    /* Aggregate reorder-shim RX counters across all live conns (§17). One
     * fixed-shape object, no per-conn array, so a single snprintf with a
     * bounded resp_len is sufficient — no APPEND/truncation dance needed.
     * The getter zero-fills when no conn has reorder enabled, so the JSON
     * is always well-formed (all-zero counters). */
    mqvpn_reorder_stats_t rs;
    if (mqvpn_server_get_reorder_stats(server, &rs) < 0)
        return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"internal error\"}");

    return snprintf(
        resp, resp_len,
        "{\"ok\":true,\"reorder\":{"
        "\"gap_count\":%" PRIu64 ",\"gap_filled_count\":%" PRIu64 ","
        "\"gap_timeout_count\":%" PRIu64 ",\"gap_overflow_count\":%" PRIu64 ","
        "\"gap_demote_count\":%" PRIu64 ",\"gap_reset_count\":%" PRIu64 ","
        "\"ack_demote_count\":%" PRIu64 ",\"too_late_drop_count\":%" PRIu64 ","
        "\"too_far_ahead_drop_count\":%" PRIu64 ",\"duplicate_drop_count\":%" PRIu64 ","
        "\"pool_drop_count\":%" PRIu64 ",\"per_flow_limit_drop_count\":%" PRIu64 ","
        "\"reset_discard_count\":%" PRIu64 ",\"delivered_count\":%" PRIu64 ","
        "\"added_latency_p99_ms\":%.3f,\"added_latency_max_ms\":%.3f,"
        "\"added_latency_buffered_p99_ms\":%.3f"
        "}}",
        rs.gap_count, rs.gap_filled_count, rs.gap_timeout_count, rs.gap_overflow_count,
        rs.gap_demote_count, rs.gap_reset_count, rs.ack_demote_count,
        rs.too_late_drop_count, rs.too_far_ahead_drop_count, rs.duplicate_drop_count,
        rs.pool_drop_count, rs.per_flow_limit_drop_count, rs.reset_discard_count,
        rs.delivered_count, mqvpn_reorder_latency_percentile(&rs, 0.99),
        (double)rs.residence_max_us / 1000.0,
        mqvpn_reorder_latency_buffered_percentile(&rs, 0.99));
}

/* Commands take the whole socket context, not just the server handle: some
 * answers (get_stats' udp_rx_* pair) come from platform-owned state that
 * never crosses the library ABI. Handlers that only need the server open
 * with `mqvpn_server_t *server = cs->server;` and are otherwise unchanged. */
typedef int (*ctrl_cmd_fn)(const char *req, char *resp, size_t resp_len,
                           ctrl_socket_t *cs);

/* Keep in sync (and in order) with the file-header command list. */
static const struct {
    const char *name;
    ctrl_cmd_fn fn;
} ctrl_cmds[] = {
    {"add_user", ctrl_cmd_add_user},
    {"remove_user", ctrl_cmd_remove_user},
    {"list_users", ctrl_cmd_list_users},
    {"get_stats", ctrl_cmd_get_stats},
    {"get_status", ctrl_cmd_get_status},
    {"get_build_info", ctrl_cmd_get_build_info},
    {"get_fec_stats", ctrl_cmd_get_fec_stats},
    {"get_all_fec_stats", ctrl_cmd_get_all_fec_stats},
    {"get_reorder_stats", ctrl_cmd_get_reorder_stats},
};

static int
dispatch(const char *req, char *resp, size_t resp_len, ctrl_socket_t *cs)
{
    char cmd[32] = {0};
    const char *v = json_find_key(req, "cmd");
    if (!v || json_read_string(v, cmd, sizeof(cmd)) < 0)
        return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"missing cmd\"}");

    for (size_t i = 0; i < sizeof(ctrl_cmds) / sizeof(ctrl_cmds[0]); i++)
        if (strcmp(cmd, ctrl_cmds[i].name) == 0)
            return ctrl_cmds[i].fn(req, resp, resp_len, cs);

    return snprintf(resp, resp_len, "{\"ok\":false,\"error\":\"unknown cmd\"}");
}

/* ── Connection read handler ─────────────────────────────────────────────── */

/* Common per-connection teardown: unhook the libevent event, close the fd,
 * release the connection's slot in the ctrl-socket's active-connection
 * count, and free the connection struct. conn->fd is set once in
 * ctrl_on_accept() and never changes, so it always matches the fd the
 * caller's event fired on. */
static void
ctrl_conn_close(ctrl_conn_t *conn)
{
    if (conn->ev) {
        event_del(conn->ev);
        event_free(conn->ev);
    }
    if (conn->ev_write) {
        event_del(conn->ev_write);
        event_free(conn->ev_write);
    }
    close(conn->fd);
    conn->cs->n_conns--;
    free(conn->resp);
    free(conn);
}

static void
ctrl_on_write(evutil_socket_t fd, short what, void *arg)
{
    ctrl_conn_t *conn = (ctrl_conn_t *)arg;
    struct timespec now;
    uint64_t now_ms = 0;
    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0)
        now_ms = (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
    if ((what & EV_TIMEOUT) ||
        (conn->write_deadline_ms > 0 && now_ms >= conn->write_deadline_ms)) {
        LOG_WRN("control: response write timed out after %d seconds",
                CTRL_WRITE_TIMEOUT_SEC);
        ctrl_conn_close(conn);
        return;
    }

    size_t callback_bytes = 0;
    int calls = 0;
    while (conn->resp_off < conn->resp_len &&
           callback_bytes < CTRL_WRITE_BUDGET_BYTES &&
           calls++ < CTRL_WRITE_BUDGET_CALLS) {
        size_t remaining = conn->resp_len - conn->resp_off;
        size_t allowance = CTRL_WRITE_BUDGET_BYTES - callback_bytes;
        if (remaining > allowance) remaining = allowance;
        ssize_t n = send(fd, conn->resp + conn->resp_off, remaining, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            ctrl_conn_close(conn);
            return;
        }
        if (n == 0) {
            ctrl_conn_close(conn);
            return;
        }
        conn->resp_off += (size_t)n;
        callback_bytes += (size_t)n;
    }

    if (conn->resp_off == conn->resp_len) {
        ctrl_conn_close(conn);
    }
}

static int
ctrl_start_response(ctrl_conn_t *conn, size_t len)
{
    conn->resp_len = len;
    conn->resp_off = 0;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
        conn->write_deadline_ms =
            (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000 +
            CTRL_WRITE_TIMEOUT_SEC * 1000;
    }
    event_del(conn->ev);
    conn->ev_write = event_new(conn->cs->eb, conn->fd,
                               EV_WRITE | EV_PERSIST | EV_TIMEOUT,
                               ctrl_on_write, conn);
    if (!conn->ev_write) return -1;
    struct timeval tv = {.tv_sec = CTRL_WRITE_TIMEOUT_SEC};
    return event_add(conn->ev_write, &tv);
}

static void
ctrl_on_read(evutil_socket_t fd, short what, void *arg)
{
    ctrl_conn_t *conn = (ctrl_conn_t *)arg;

    /* Idle timeout — close without processing */
    if (what & EV_TIMEOUT) {
        ctrl_conn_close(conn);
        return;
    }

    /* Accumulate data until we have a complete request */
    while (conn->req_len < CTRL_MAX_REQ) {
        ssize_t n = read(fd, conn->req + conn->req_len, CTRL_MAX_REQ - conn->req_len);
        if (n > 0) {
            conn->req_len += (size_t)n;

            /* Detect a complete JSON object by brace counting */
            const char *p = conn->req;
            while (*p && isspace((unsigned char)*p))
                p++;
            if (*p == '{') {
                int depth = 0, in_str = 0;
                int complete = 0;
                for (size_t i = (size_t)(p - conn->req); i < conn->req_len; i++) {
                    char c = conn->req[i];
                    if (in_str) {
                        if (c == '\\') {
                            i++;
                            continue;
                        }
                        if (c == '"') in_str = 0;
                    } else {
                        if (c == '"')
                            in_str = 1;
                        else if (c == '{')
                            depth++;
                        else if (c == '}' && --depth == 0) {
                            complete = 1;
                            break;
                        }
                    }
                }
                if (!complete) continue;
            } else if (!memchr(conn->req, '\n', conn->req_len)) {
                continue; /* newline-terminated form: wait for more */
            }
        } else if (n == 0) {
            break; /* EOF — process whatever we have */
        } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return; /* wait for more data */
        } else {
            /* read error — close connection */
            ctrl_conn_close(conn);
            return;
        }
        break;
    }

    conn->req[conn->req_len] = '\0';

    conn->resp = malloc(CTRL_MAX_RESP_BYTES);
    if (!conn->resp) {
        ctrl_conn_close(conn);
        return;
    }
    int rlen = dispatch(conn->req, conn->resp, CTRL_MAX_RESP_BYTES - 2, conn->cs);
    if (rlen <= 0) {
        /* dispatch failed to format anything — close silently. */
        ctrl_conn_close(conn);
        return;
    } else if ((size_t)rlen >= CTRL_MAX_RESP_BYTES - 2) {
        /* snprintf would have truncated. Send a small error JSON instead so the
         * client doesn't see a malformed body, and emit a warning. */
        static const char too_large[] =
            "{\"ok\":false,\"error\":\"response too large\"}\n";
        memcpy(conn->resp, too_large, sizeof(too_large) - 1);
        if (ctrl_start_response(conn, sizeof(too_large) - 1) == 0) return;
        LOG_WRN(
            "control: dispatch response truncated (would have been %d bytes, max %zu)",
            rlen, (size_t)CTRL_MAX_RESP_BYTES - 2);
    } else {
        conn->resp[rlen] = '\n';
        conn->resp[rlen + 1] = '\0';
        if (ctrl_start_response(conn, (size_t)rlen + 1) == 0) return;
    }

    ctrl_conn_close(conn);
}

/* ── Accept handler ──────────────────────────────────────────────────────── */

static void
ctrl_on_accept(evutil_socket_t fd, short what, void *arg)
{
    (void)what;
    ctrl_socket_t *cs = (ctrl_socket_t *)arg;

    if (cs->n_conns >= CTRL_MAX_CONNS) {
        int cfd = accept(fd, NULL, NULL);
        if (cfd >= 0) {
            const char *msg = "{\"ok\":false,\"error\":\"too many connections\"}\n";
            int flags = fcntl(cfd, F_GETFL, 0);
            if (flags >= 0) (void)fcntl(cfd, F_SETFL, flags | O_NONBLOCK);
            (void)send(cfd, msg, strlen(msg), MSG_NOSIGNAL);
            close(cfd);
        }
        return;
    }

    int cfd = accept(fd, NULL, NULL);
    if (cfd < 0) return;

    int flags = fcntl(cfd, F_GETFL, 0);
    if (flags < 0 || fcntl(cfd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(cfd);
        return;
    }

    ctrl_conn_t *conn = calloc(1, sizeof(*conn));
    if (!conn) {
        close(cfd);
        return;
    }

    conn->fd = cfd;
    conn->cs = cs;
    conn->ev =
        event_new(cs->eb, cfd, EV_READ | EV_PERSIST | EV_TIMEOUT, ctrl_on_read, conn);
    if (!conn->ev) {
        free(conn);
        close(cfd);
        return;
    }
    struct timeval tv = {.tv_sec = CTRL_READ_TIMEOUT_SEC};
    event_add(conn->ev, &tv);
    cs->n_conns++;
}

/* ── Public API ──────────────────────────────────────────────────────────── */

static int
ctrl_addr_is_loopback(const char *addr)
{
    struct in_addr v4;
    struct in6_addr v6;
    if (!addr) return 0;
    if (inet_pton(AF_INET, addr, &v4) == 1)
        return v4.s_addr == htonl(INADDR_LOOPBACK);
    if (inet_pton(AF_INET6, addr, &v6) == 1)
        return IN6_IS_ADDR_LOOPBACK(&v6);
    return 0;
}

ctrl_socket_t *
ctrl_socket_create(struct event_base *eb, const char *addr, int port,
                   mqvpn_server_t *server, const uint64_t *gro_receives,
                   const uint64_t *gro_datagrams)
{
    if (!eb || port <= 0 || port > 65535 || !server) return NULL;

    if (!addr || addr[0] == '\0') addr = "127.0.0.1";

    if (!ctrl_addr_is_loopback(addr)) {
        LOG_ERR("control API: refusing non-loopback address %s", addr);
        return NULL;
    }

    ctrl_socket_t *cs = calloc(1, sizeof(*cs));
    if (!cs) return NULL;
    cs->eb = eb;
    cs->server = server;
    /* Borrowed, not copied — the platform ctx outlives this socket. */
    cs->gro_receives = gro_receives;
    cs->gro_datagrams = gro_datagrams;

    /* Determine address family */
    struct sockaddr_in sin4;
    struct sockaddr_in6 sin6;
    struct sockaddr *sa;
    socklen_t sa_len;

    memset(&sin4, 0, sizeof(sin4));
    memset(&sin6, 0, sizeof(sin6));

    if (inet_pton(AF_INET6, addr, &sin6.sin6_addr) == 1) {
        sin6.sin6_family = AF_INET6;
        sin6.sin6_port = htons((uint16_t)port);
        sa = (struct sockaddr *)&sin6;
        sa_len = sizeof(sin6);
        cs->listen_fd = socket(AF_INET6, SOCK_STREAM, 0);
    } else {
        if (inet_pton(AF_INET, addr, &sin4.sin_addr) != 1) {
            LOG_ERR("control API: invalid address '%s'", addr);
            free(cs);
            return NULL;
        }
        sin4.sin_family = AF_INET;
        sin4.sin_port = htons((uint16_t)port);
        sa = (struct sockaddr *)&sin4;
        sa_len = sizeof(sin4);
        cs->listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    }

    if (cs->listen_fd < 0) {
        LOG_ERR("control API: socket(): %s", strerror(errno));
        free(cs);
        return NULL;
    }

    int opt = 1;
    setsockopt(cs->listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    if (bind(cs->listen_fd, sa, sa_len) < 0) {
        LOG_ERR("control API: bind(%s:%d): %s", addr, port, strerror(errno));
        close(cs->listen_fd);
        free(cs);
        return NULL;
    }

    if (listen(cs->listen_fd, 8) < 0) {
        LOG_ERR("control API: listen(): %s", strerror(errno));
        close(cs->listen_fd);
        free(cs);
        return NULL;
    }

    int flags = fcntl(cs->listen_fd, F_GETFL, 0);
    fcntl(cs->listen_fd, F_SETFL, flags | O_NONBLOCK);

    cs->ev_accept =
        event_new(eb, cs->listen_fd, EV_READ | EV_PERSIST, ctrl_on_accept, cs);
    if (!cs->ev_accept) {
        close(cs->listen_fd);
        free(cs);
        return NULL;
    }
    event_add(cs->ev_accept, NULL);

    LOG_INF("control API listening on %s:%d", addr, port);
    return cs;
}

void
ctrl_socket_destroy(ctrl_socket_t *cs)
{
    if (!cs) return;
    if (cs->ev_accept) {
        event_del(cs->ev_accept);
        event_free(cs->ev_accept);
    }
    if (cs->listen_fd >= 0) close(cs->listen_fd);
    free(cs);
}
