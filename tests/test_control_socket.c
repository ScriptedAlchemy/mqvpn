// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/*
 * test_control_socket.c — unit tests for the control-API command dispatch
 * (src/platform/linux/control_socket.c::dispatch).
 *
 * dispatch()'s command routing, argument validation, error codes, and response
 * JSON shape had no unit-level test — test_control_response_bound.c only checks
 * the worst-case get_status buffer bound and never calls dispatch(). This test
 * drives dispatch() end to end with the server-facing API mocked, covering
 * handler logic (missing-arg handling, failure propagation, JSON shape) without
 * sudo/netns.
 *
 * dispatch() is static, so — following the test_reorder_rx / test_tcp_lane
 * idiom — this file #include's the .c directly and satisfies the mqvpn_server_*
 * / mqvpn_* symbols the handlers call with configurable stubs (no mqvpn_server.c
 * linked). Uses an always-active CHECK (not assert()) so a Release build cannot
 * no-op the assertions.
 */

#include "libmqvpn.h"
#include "mqvpn_internal.h" /* mqvpn_internal_fec_stats_t / _entry_t, reorder.h */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* ── Configurable stub state ──────────────────────────────────────────────── */

static int g_add_user_rc = MQVPN_OK;
static int g_remove_user_rc = MQVPN_OK;

static int g_list_users_n = 0;
static char g_list_users_names[MQVPN_MAX_USERS][64];

static int g_n_clients = 0;
static uint64_t g_uptime = 0;

static int g_client_info_n = 0;
static mqvpn_client_info_t g_client_info_tmpl;

static mqvpn_internal_client_reinject_t g_reinject_tmpl; /* configured per test */
static mqvpn_internal_client_wlb_t g_wlb_tmpl;           /* configured per test */

static int g_fec_rc = 1;
static mqvpn_internal_fec_stats_t g_fec_tmpl;

static int g_all_fec_rc = 0;
static int g_all_fec_n = 0;

static int g_reorder_rc = 0;

/* ── Stubs for the server-facing API the handlers call ────────────────────── */

int
mqvpn_server_add_user(mqvpn_server_t *s, const char *u, const char *k)
{
    (void)s;
    (void)u;
    (void)k;
    return g_add_user_rc;
}

int
mqvpn_server_remove_user(mqvpn_server_t *s, const char *u)
{
    (void)s;
    (void)u;
    return g_remove_user_rc;
}

int
mqvpn_server_list_users(const mqvpn_server_t *s, char names[][64], int max)
{
    (void)s;
    int n = g_list_users_n < max ? g_list_users_n : max;
    for (int i = 0; i < n; i++) {
        strncpy(names[i], g_list_users_names[i], 63);
        names[i][63] = '\0';
    }
    return n;
}

int
mqvpn_server_get_stats(const mqvpn_server_t *s, mqvpn_stats_t *out)
{
    (void)s;
    memset(out, 0, sizeof(*out));
    out->struct_size = sizeof(*out);
    out->bytes_tx = 111;
    out->tcp_flows_total = 7;
    out->udp_tx_sends = 1234;
    out->udp_tx_datagrams = 5678;
    return 0;
}

int
mqvpn_server_get_n_clients(const mqvpn_server_t *s)
{
    (void)s;
    return g_n_clients;
}

uint64_t
mqvpn_server_uptime_seconds(const mqvpn_server_t *s)
{
    (void)s;
    return g_uptime;
}

int
mqvpn_server_get_client_info(const mqvpn_server_t *s, mqvpn_client_info_t *out,
                             int max_clients, int *n_clients)
{
    (void)s;
    int n = g_client_info_n < max_clients ? g_client_info_n : max_clients;
    for (int i = 0; i < n; i++)
        out[i] = g_client_info_tmpl;
    *n_clients = n;
    return 0;
}

const char *
mqvpn_server_scheduler_label(const mqvpn_server_t *s)
{
    (void)s;
    return "wlb";
}

const char *
mqvpn_path_state_label(int state)
{
    return state == 2 ? "active" : "validating";
}

const char *
mqvpn_version_string(void)
{
    return "9.9.9-test";
}

int
mqvpn_server_get_client_reinject(const mqvpn_server_t *s,
                                 mqvpn_internal_client_reinject_t *out, int max)
{
    (void)s;
    if (max > 0) out[0] = g_reinject_tmpl;
    return max > 0 ? 1 : 0;
}

int
mqvpn_server_get_client_wlb(const mqvpn_server_t *s, mqvpn_internal_client_wlb_t *out,
                            int max)
{
    (void)s;
    if (max > 0) out[0] = g_wlb_tmpl;
    return max > 0 ? 1 : 0;
}

int
mqvpn_server_get_client_fec_stats(const mqvpn_server_t *s, const char *user,
                                  mqvpn_internal_fec_stats_t *out)
{
    (void)s;
    (void)user;
    if (g_fec_rc == 1) *out = g_fec_tmpl;
    return g_fec_rc;
}

int
mqvpn_server_get_all_fec_stats(const mqvpn_server_t *s, mqvpn_internal_fec_entry_t *out,
                               int max)
{
    (void)s;
    if (g_all_fec_rc < 0) return -1;
    int n = g_all_fec_n < max ? g_all_fec_n : max;
    for (int i = 0; i < n; i++) {
        snprintf(out[i].user, sizeof(out[i].user), "user%d", i);
        out[i].stats = g_fec_tmpl;
    }
    return n;
}

int
mqvpn_server_get_reorder_stats(const mqvpn_server_t *s, mqvpn_reorder_stats_t *out)
{
    (void)s;
    memset(out, 0, sizeof(*out));
    out->delivered_count = 55;
    return g_reorder_rc;
}

double
mqvpn_reorder_latency_percentile(const mqvpn_reorder_stats_t *st, double q)
{
    (void)st;
    (void)q;
    return 1.5;
}

double
mqvpn_reorder_latency_buffered_percentile(const mqvpn_reorder_stats_t *st, double q)
{
    (void)st;
    (void)q;
    return 2.5;
}

/* Pull in dispatch() + the command handlers (all static). */
#include "control_socket.c"

/* ── Harness ──────────────────────────────────────────────────────────────── */

static int g_failed = 0;
static char g_resp[CTRL_MAX_RESP_BYTES];
static int g_dummy_server; /* opaque sentinel — stubs never dereference it */

#define CHECK(cond)                                                         \
    do {                                                                    \
        if (!(cond)) {                                                      \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            g_failed++;                                                     \
        }                                                                   \
    } while (0)

/* CHECK a substring is present, printing the actual response on mismatch. */
#define CHECK_HAS(needle)                                                       \
    do {                                                                        \
        if (strstr(g_resp, (needle)) == NULL) {                                 \
            fprintf(stderr, "FAIL %s:%d: response missing \"%s\"\n  got: %s\n", \
                    __FILE__, __LINE__, (needle), g_resp);                      \
            g_failed++;                                                         \
        }                                                                       \
    } while (0)

#define CHECK_EQ_STR(expected)                                                       \
    do {                                                                             \
        if (strcmp(g_resp, (expected)) != 0) {                                       \
            fprintf(stderr, "FAIL %s:%d: response != \"%s\"\n  got: %s\n", __FILE__, \
                    __LINE__, (expected), g_resp);                                   \
            g_failed++;                                                              \
        }                                                                            \
    } while (0)

/* Platform-owned RX offload counters the control socket borrows. Non-zero and
 * unequal so a get_stats regression that hardcodes 0 or swaps the pair cannot
 * pass. */
static uint64_t g_gro_receives = 61;
static uint64_t g_gro_datagrams = 83;

static void
call(const char *req)
{
    memset(g_resp, 0, sizeof(g_resp));
    /* Stack-built context: dispatch and the handlers only read ->server and
     * the borrowed counter pointers, never the libevent members. */
    ctrl_socket_t cs = {
        .server = (mqvpn_server_t *)&g_dummy_server,
        .gro_receives = &g_gro_receives,
        .gro_datagrams = &g_gro_datagrams,
    };
    dispatch(req, g_resp, sizeof(g_resp) - 2, &cs);
}

static struct timespec g_timer_started;
static uint64_t g_timer_elapsed_ms;

static void
record_timer_latency(evutil_socket_t fd, short what, void *arg)
{
    (void)fd;
    (void)what;
    (void)arg;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    g_timer_elapsed_ms =
        (uint64_t)(now.tv_sec - g_timer_started.tv_sec) * 1000 +
        (uint64_t)(now.tv_nsec - g_timer_started.tv_nsec) / 1000000;
}

/* A maximum get_status response must not monopolize the libevent thread when
 * the local peer applies backpressure. The child deliberately waits 800 ms
 * before reading. A 20 ms event-loop timer must still run while the response
 * is blocked, and the complete newline-terminated JSON must eventually arrive. */
static void
test_large_response_does_not_stall_event_loop(void)
{
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    if (g_failed) return;

    int sndbuf = 4096;
    CHECK(setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf)) == 0);
    int flags = fcntl(sv[0], F_GETFL, 0);
    CHECK(flags >= 0 && fcntl(sv[0], F_SETFL, flags | O_NONBLOCK) == 0);

    memset(&g_client_info_tmpl, 0, sizeof(g_client_info_tmpl));
    memset(&g_reinject_tmpl, 0, sizeof(g_reinject_tmpl));
    memset(&g_wlb_tmpl, 0, sizeof(g_wlb_tmpl));
    memset(g_client_info_tmpl.username, 'u', sizeof(g_client_info_tmpl.username) - 1);
    memset(g_client_info_tmpl.endpoint, 'e', sizeof(g_client_info_tmpl.endpoint) - 1);
    g_client_info_tmpl.n_paths = MQVPN_MAX_PATHS;
    for (int p = 0; p < MQVPN_MAX_PATHS; p++) {
        g_client_info_tmpl.paths[p].path_id = (uint64_t)p;
        g_client_info_tmpl.paths[p].state = 2;
    }
    g_client_info_n = MQVPN_MAX_USERS;

    static const char request[] = "{\"cmd\":\"get_status\"}";
    CHECK(write(sv[1], request, sizeof(request) - 1) == (ssize_t)(sizeof(request) - 1));

    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(sv[0]);
        usleep(800000);
        char *response = calloc(1, CTRL_MAX_RESP_BYTES);
        size_t used = 0;
        ssize_t n;
        while (response && used < CTRL_MAX_RESP_BYTES - 1 &&
               (n = read(sv[1], response + used, CTRL_MAX_RESP_BYTES - 1 - used)) > 0) {
            used += (size_t)n;
        }
        int ok = response && used > 0 && response[used - 1] == '\n' &&
                 strstr(response, "\"n_clients\":64") != NULL;
        free(response);
        close(sv[1]);
        _exit(ok ? 0 : 1);
    }
    if (child < 0) {
        close(sv[0]);
        close(sv[1]);
        return;
    }
    close(sv[1]);

    struct event_base *base = event_base_new();
    CHECK(base != NULL);
    ctrl_socket_t cs = {
        .eb = base,
        .server = (mqvpn_server_t *)&g_dummy_server,
        .gro_receives = &g_gro_receives,
        .gro_datagrams = &g_gro_datagrams,
        .n_conns = 1,
    };
    ctrl_conn_t *conn = calloc(1, sizeof(*conn));
    CHECK(conn != NULL);
    if (!base || !conn) {
        if (conn) free(conn);
        if (base) event_base_free(base);
        close(sv[0]);
        (void)waitpid(child, NULL, 0);
        return;
    }
    conn->fd = sv[0];
    conn->cs = &cs;
    conn->next = cs.conns;
    cs.conns = conn;
    conn->ev = event_new(base, sv[0], EV_READ | EV_PERSIST, ctrl_on_read, conn);
    CHECK(conn->ev != NULL);
    struct event *timer = evtimer_new(base, record_timer_latency, NULL);
    CHECK(timer != NULL);

    g_timer_elapsed_ms = UINT64_MAX;
    clock_gettime(CLOCK_MONOTONIC, &g_timer_started);
    struct timeval timer_delay = {.tv_usec = 20000};
    event_add(conn->ev, NULL);
    evtimer_add(timer, &timer_delay);
    CHECK(event_base_dispatch(base) == 1);

    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(g_timer_elapsed_ms < 600);
    CHECK(cs.n_conns == 0);

    event_free(timer);
    event_base_free(base);
    g_client_info_n = 0;
}

/* Destroy must own in-flight connections: a delayed peer cannot leave a
 * write callback holding a freed ctrl_socket_t. */
static void
test_destroy_closes_in_flight_write(void)
{
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    if (g_failed) return;

    int sndbuf = 4096;
    CHECK(setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf)) == 0);
    struct timeval recv_timeout = {.tv_sec = 1};
    CHECK(setsockopt(sv[1], SOL_SOCKET, SO_RCVTIMEO, &recv_timeout,
                     sizeof(recv_timeout)) == 0);
    int flags = fcntl(sv[0], F_GETFL, 0);
    CHECK(flags >= 0 && fcntl(sv[0], F_SETFL, flags | O_NONBLOCK) == 0);

    memset(&g_client_info_tmpl, 0, sizeof(g_client_info_tmpl));
    memset(&g_reinject_tmpl, 0, sizeof(g_reinject_tmpl));
    memset(&g_wlb_tmpl, 0, sizeof(g_wlb_tmpl));
    g_client_info_n = MQVPN_MAX_USERS;

    static const char request[] = "{\"cmd\":\"get_status\"}";
    CHECK(write(sv[1], request, sizeof(request) - 1) == (ssize_t)(sizeof(request) - 1));

    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(sv[0]);
        usleep(200000);
        char buf[256];
        ssize_t n;
        do {
            n = read(sv[1], buf, sizeof(buf));
        } while (n > 0);
        close(sv[1]);
        _exit(n == 0 ? 0 : 1);
    }
    if (child < 0) {
        close(sv[0]);
        close(sv[1]);
        return;
    }
    close(sv[1]);

    struct event_base *base = event_base_new();
    CHECK(base != NULL);
    ctrl_socket_t *cs = calloc(1, sizeof(*cs));
    CHECK(cs != NULL);
    ctrl_conn_t *conn = calloc(1, sizeof(*conn));
    CHECK(conn != NULL);
    if (!base || !cs || !conn) {
        if (conn) free(conn);
        if (cs) free(cs);
        if (base) event_base_free(base);
        close(sv[0]);
        (void)waitpid(child, NULL, 0);
        return;
    }
    cs->eb = base;
    cs->server = (mqvpn_server_t *)&g_dummy_server;
    cs->gro_receives = &g_gro_receives;
    cs->gro_datagrams = &g_gro_datagrams;
    cs->listen_fd = -1;
    conn->fd = sv[0];
    conn->cs = cs;
    conn->next = cs->conns;
    cs->conns = conn;
    cs->n_conns = 1;
    conn->ev = event_new(base, sv[0], EV_READ | EV_PERSIST, ctrl_on_read, conn);
    CHECK(conn->ev != NULL);
    event_add(conn->ev, NULL);
    (void)event_base_loop(base, EVLOOP_ONCE);
    CHECK(conn->ev_write != NULL);
    CHECK(cs->conns == conn);
    CHECK(event_base_get_num_events(base, EVENT_BASE_COUNT_ADDED) >= 1);
    int server_fd = conn->fd;
    ctrl_socket_destroy(cs);

    errno = 0;
    CHECK(fcntl(server_fd, F_GETFD, 0) == -1 && errno == EBADF);
    CHECK(event_base_get_num_events(base, EVENT_BASE_COUNT_ADDED) == 0);
    CHECK(event_base_loop(base, EVLOOP_NONBLOCK) == 1);

    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    event_base_free(base);
    g_client_info_n = 0;
}

static void
test_control_listener_accepts_loopback_only(void)
{
    CHECK(ctrl_addr_is_loopback("127.0.0.1"));
    CHECK(ctrl_addr_is_loopback("::1"));
    CHECK(!ctrl_addr_is_loopback("0.0.0.0"));
    CHECK(!ctrl_addr_is_loopback("192.168.1.10"));
    CHECK(!ctrl_addr_is_loopback("not-an-address"));
}

/* ── Envelope / routing ───────────────────────────────────────────────────── */

static void
test_missing_cmd(void)
{
    call("{}");
    CHECK_EQ_STR("{\"ok\":false,\"error\":\"missing cmd\"}");
}

static void
test_unknown_cmd(void)
{
    call("{\"cmd\":\"frobnicate\"}");
    CHECK_EQ_STR("{\"ok\":false,\"error\":\"unknown cmd\"}");
}

/* ── add_user ─────────────────────────────────────────────────────────────── */

static void
test_add_user_success(void)
{
    g_add_user_rc = MQVPN_OK;
    call("{\"cmd\":\"add_user\",\"name\":\"alice\",\"key\":\"secret\"}");
    CHECK_EQ_STR("{\"ok\":true}");
}

static void
test_add_user_missing_name(void)
{
    call("{\"cmd\":\"add_user\",\"key\":\"secret\"}");
    CHECK_HAS("name and key required");
}

static void
test_add_user_missing_key(void)
{
    call("{\"cmd\":\"add_user\",\"name\":\"alice\"}");
    CHECK_HAS("name and key required");
}

static void
test_add_user_server_failure(void)
{
    g_add_user_rc = -5;
    call("{\"cmd\":\"add_user\",\"name\":\"alice\",\"key\":\"secret\"}");
    CHECK_HAS("add_user failed (-5)");
}

/* ── remove_user ──────────────────────────────────────────────────────────── */

static void
test_remove_user_success(void)
{
    g_remove_user_rc = MQVPN_OK;
    call("{\"cmd\":\"remove_user\",\"name\":\"alice\"}");
    CHECK_EQ_STR("{\"ok\":true}");
}

static void
test_remove_user_missing_name(void)
{
    call("{\"cmd\":\"remove_user\"}");
    CHECK_HAS("name required");
}

static void
test_remove_user_not_found(void)
{
    g_remove_user_rc = -1;
    call("{\"cmd\":\"remove_user\",\"name\":\"ghost\"}");
    CHECK_HAS("user not found");
}

/* ── list_users ───────────────────────────────────────────────────────────── */

static void
test_list_users_empty(void)
{
    g_list_users_n = 0;
    call("{\"cmd\":\"list_users\"}");
    CHECK_EQ_STR("{\"ok\":true,\"users\":[]}");
}

static void
test_list_users_two_entries(void)
{
    g_list_users_n = 2;
    strcpy(g_list_users_names[0], "alice");
    strcpy(g_list_users_names[1], "bob");
    call("{\"cmd\":\"list_users\"}");
    CHECK_EQ_STR("{\"ok\":true,\"users\":[\"alice\",\"bob\"]}");
}

/* ── get_stats ────────────────────────────────────────────────────────────── */

static void
test_get_stats(void)
{
    g_n_clients = 3;
    g_uptime = 4242;
    call("{\"cmd\":\"get_stats\"}");
    CHECK_HAS("\"ok\":true");
    CHECK_HAS("\"n_clients\":3");
    CHECK_HAS("\"bytes_tx\":111");
    CHECK_HAS("\"tcp_flows_total\":7");
    CHECK_HAS("\"uptime_sec\":4242");
    /* Offload counters reach the JSON from BOTH sources: udp_tx_* through
     * mqvpn_stats_t (the library issues those sends), udp_rx_* straight from
     * the platform's borrowed counters (GRO never crosses the library ABI).
     * The get_stats body is a hand-written field-by-field snprintf, so a new
     * mqvpn_stats_t field silently reads 0 here unless it is added in both
     * places — that is exactly the failure this pins. */
    CHECK_HAS("\"udp_tx_sends\":1234");
    CHECK_HAS("\"udp_tx_datagrams\":5678");
    CHECK_HAS("\"udp_rx_receives\":61");
    CHECK_HAS("\"udp_rx_datagrams\":83");
}

/* ── get_status ───────────────────────────────────────────────────────────── */

static void
test_get_status_empty(void)
{
    g_client_info_n = 0;
    call("{\"cmd\":\"get_status\"}");
    CHECK_EQ_STR("{\"ok\":true,\"n_clients\":0,\"clients\":[]}");
}

static void
test_get_status_one_client_with_path(void)
{
    memset(&g_client_info_tmpl, 0, sizeof(g_client_info_tmpl));
    memset(&g_reinject_tmpl, 0, sizeof(g_reinject_tmpl));
    memset(&g_wlb_tmpl, 0, sizeof(g_wlb_tmpl));
    strcpy(g_client_info_tmpl.username, "alice");
    strcpy(g_client_info_tmpl.endpoint, "1.2.3.4:443");
    g_client_info_tmpl.n_paths = 1;
    g_client_info_tmpl.paths[0].path_id = 7;
    g_client_info_tmpl.paths[0].state = 2; /* -> "active" */
    g_client_info_n = 1;

    call("{\"cmd\":\"get_status\"}");
    CHECK_HAS("\"n_clients\":1");
    CHECK_HAS("\"user\":\"alice\"");
    CHECK_HAS("\"endpoint\":\"1.2.3.4:443\"");
    CHECK_HAS("\"performance\":\"throughput\"");
    CHECK_HAS("\"path_id\":7");
    CHECK_HAS("\"state_label\":\"active\"");
    CHECK_HAS("\"reinject_tx_bytes\":0");
    CHECK_HAS("\"goodput_Bps\":0");
    CHECK_HAS("\"warmup\":false");
    CHECK_HAS("\"weight_pct\":0");
}

/* Alignment semantics (a): a reinject snapshot entry whose path_id matches
 * the client-info path emits its nonzero value. */
static void
test_get_status_reinject_matched_path_id(void)
{
    memset(&g_client_info_tmpl, 0, sizeof(g_client_info_tmpl));
    memset(&g_reinject_tmpl, 0, sizeof(g_reinject_tmpl));
    memset(&g_wlb_tmpl, 0, sizeof(g_wlb_tmpl));
    strcpy(g_client_info_tmpl.username, "alice");
    strcpy(g_client_info_tmpl.endpoint, "1.2.3.4:443");
    g_client_info_tmpl.n_paths = 1;
    g_client_info_tmpl.paths[0].path_id = 7;
    g_client_info_tmpl.paths[0].state = 2;
    g_client_info_n = 1;
    g_reinject_tmpl.n_paths = 1;
    g_reinject_tmpl.paths[0].path_id = 7;
    g_reinject_tmpl.paths[0].reinject_tx_bytes = 99999;

    call("{\"cmd\":\"get_status\"}");
    CHECK_HAS("\"path_id\":7");
    CHECK_HAS("\"reinject_tx_bytes\":99999");
}

/* Alignment semantics (b): a mismatched or wholly absent path_id in the
 * reinject snapshot both emit "reinject_tx_bytes":0 — the field is always
 * present so the JSON shape stays constant regardless of match. Two phases
 * pin the same constant-shape outcome from two different snapshot states. */
static void
test_get_status_reinject_mismatched_path_id(void)
{
    memset(&g_client_info_tmpl, 0, sizeof(g_client_info_tmpl));
    memset(&g_reinject_tmpl, 0, sizeof(g_reinject_tmpl));
    memset(&g_wlb_tmpl, 0, sizeof(g_wlb_tmpl));
    strcpy(g_client_info_tmpl.username, "alice");
    strcpy(g_client_info_tmpl.endpoint, "1.2.3.4:443");
    g_client_info_tmpl.n_paths = 1;
    g_client_info_tmpl.paths[0].path_id = 7;
    g_client_info_tmpl.paths[0].state = 2;
    g_client_info_n = 1;

    /* Phase 1: reinject snapshot has an entry, but its path_id mismatches. */
    g_reinject_tmpl.n_paths = 1;
    g_reinject_tmpl.paths[0].path_id = 42; /* mismatch vs client path_id 7 */
    g_reinject_tmpl.paths[0].reinject_tx_bytes = 99999;

    call("{\"cmd\":\"get_status\"}");
    CHECK_HAS("\"path_id\":7");
    CHECK_HAS("\"reinject_tx_bytes\":0");

    /* Phase 2: reinject snapshot has no entry at all (n_paths == 0). */
    memset(&g_reinject_tmpl, 0, sizeof(g_reinject_tmpl)); /* n_paths = 0 */

    call("{\"cmd\":\"get_status\"}");
    CHECK_HAS("\"path_id\":7");
    CHECK_HAS("\"reinject_tx_bytes\":0");
}

static void
test_get_status_wlb_matched_path_id(void)
{
    memset(&g_client_info_tmpl, 0, sizeof(g_client_info_tmpl));
    memset(&g_reinject_tmpl, 0, sizeof(g_reinject_tmpl));
    memset(&g_wlb_tmpl, 0, sizeof(g_wlb_tmpl));
    strcpy(g_client_info_tmpl.username, "alice");
    strcpy(g_client_info_tmpl.endpoint, "1.2.3.4:443");
    g_client_info_tmpl.n_paths = 1;
    g_client_info_tmpl.paths[0].path_id = 7;
    g_client_info_tmpl.paths[0].state = 2;
    g_client_info_n = 1;

    g_wlb_tmpl.n_paths = 1;
    g_wlb_tmpl.paths[0].path_id = 7;
    g_wlb_tmpl.paths[0].goodput_Bps = 123456;
    g_wlb_tmpl.paths[0].warmup = 1;
    g_wlb_tmpl.paths[0].weight_pct = 20;

    call("{\"cmd\":\"get_status\"}");
    CHECK_HAS("\"path_id\":7");
    CHECK_HAS("\"goodput_Bps\":123456");
    CHECK_HAS("\"warmup\":true");
    CHECK_HAS("\"weight_pct\":20");
}

static void
test_get_status_effective_policy_failures_are_explicit(void)
{
    memset(&g_client_info_tmpl, 0, sizeof(g_client_info_tmpl));
    strcpy(g_client_info_tmpl.username, "alice");
    strcpy(g_client_info_tmpl.performance, "admin_override");
    g_client_info_n = 1;
    call("{\"cmd\":\"get_status\"}");
    CHECK_HAS("\"performance\":\"admin_override\"");

    strcpy(g_client_info_tmpl.performance, "unavailable");
    call("{\"cmd\":\"get_status\"}");
    CHECK_HAS("\"performance\":\"unavailable\"");
}

/* ── get_build_info ───────────────────────────────────────────────────────── */

static void
test_get_build_info(void)
{
    call("{\"cmd\":\"get_build_info\"}");
    CHECK_HAS("\"version\":\"9.9.9-test\"");
    CHECK_HAS("\"scheduler\":\"wlb\"");
    CHECK_HAS("\"fec_enabled\":");
}

/* ── get_fec_stats ────────────────────────────────────────────────────────── */

static void
seed_fec_tmpl(void)
{
    memset(&g_fec_tmpl, 0, sizeof(g_fec_tmpl));
    g_fec_tmpl.enable_fec = 1;
    g_fec_tmpl.mp_state = 1;
    g_fec_tmpl.mp_state_label = "active_with_standby";
    g_fec_tmpl.fec_send_cnt = 142;
    g_fec_tmpl.fec_recover_cnt = 17;
}

static void
test_get_fec_stats_missing_user(void)
{
    call("{\"cmd\":\"get_fec_stats\"}");
    CHECK_HAS("user required");
}

static void
test_get_fec_stats_user_not_found(void)
{
    g_fec_rc = 0;
    call("{\"cmd\":\"get_fec_stats\",\"user\":\"ghost\"}");
    CHECK_HAS("user not found");
}

static void
test_get_fec_stats_not_built(void)
{
    g_fec_rc = -1;
    call("{\"cmd\":\"get_fec_stats\",\"user\":\"alice\"}");
    CHECK_HAS("fec not built");
}

static void
test_get_fec_stats_success(void)
{
    seed_fec_tmpl();
    g_fec_rc = 1;
    call("{\"cmd\":\"get_fec_stats\",\"user\":\"alice\"}");
    CHECK_HAS("\"user\":\"alice\"");
    CHECK_HAS("\"mp_state_label\":\"active_with_standby\"");
    CHECK_HAS("\"fec_send_cnt\":142");
    CHECK_HAS("\"fec_recover_cnt\":17");
}

/* ── get_all_fec_stats ────────────────────────────────────────────────────── */

static void
test_get_all_fec_stats(void)
{
    seed_fec_tmpl();
    g_all_fec_rc = 0;
    g_all_fec_n = 2;
    call("{\"cmd\":\"get_all_fec_stats\"}");
    CHECK_HAS("\"n_clients\":2");
    CHECK_HAS("\"user\":\"user0\"");
    CHECK_HAS("\"user\":\"user1\"");
    CHECK_HAS("\"mp_state_label\":\"active_with_standby\"");
}

static void
test_get_all_fec_stats_not_built(void)
{
    g_all_fec_rc = -1;
    call("{\"cmd\":\"get_all_fec_stats\"}");
    CHECK_HAS("fec not built");
}

/* ── get_reorder_stats ────────────────────────────────────────────────────── */

static void
test_get_reorder_stats(void)
{
    g_reorder_rc = 0;
    call("{\"cmd\":\"get_reorder_stats\"}");
    CHECK_HAS("\"reorder\":{");
    CHECK_HAS("\"delivered_count\":55");
    CHECK_HAS("\"added_latency_p99_ms\":");
}

static void
test_get_reorder_stats_internal_error(void)
{
    /* Failure-branch parity with get_fec_stats / get_all_fec_stats: a negative
     * getter return must surface {"error":"internal error"}, not a malformed
     * or half-built reorder object. */
    g_reorder_rc = -1;
    call("{\"cmd\":\"get_reorder_stats\"}");
    CHECK_HAS("\"ok\":false");
    CHECK_HAS("internal error");
}

int
main(void)
{
    test_large_response_does_not_stall_event_loop();
    test_destroy_closes_in_flight_write();
    test_control_listener_accepts_loopback_only();
    test_missing_cmd();
    test_unknown_cmd();

    test_add_user_success();
    test_add_user_missing_name();
    test_add_user_missing_key();
    test_add_user_server_failure();

    test_remove_user_success();
    test_remove_user_missing_name();
    test_remove_user_not_found();

    test_list_users_empty();
    test_list_users_two_entries();

    test_get_stats();

    test_get_status_empty();
    test_get_status_one_client_with_path();
    test_get_status_reinject_matched_path_id();
    test_get_status_reinject_mismatched_path_id();
    test_get_status_wlb_matched_path_id();
    test_get_status_effective_policy_failures_are_explicit();

    test_get_build_info();

    test_get_fec_stats_missing_user();
    test_get_fec_stats_user_not_found();
    test_get_fec_stats_not_built();
    test_get_fec_stats_success();

    test_get_all_fec_stats();
    test_get_all_fec_stats_not_built();

    test_get_reorder_stats();
    test_get_reorder_stats_internal_error();

    if (g_failed) {
        fprintf(stderr, "test_control_socket: %d CHECK(s) FAILED\n", g_failed);
        return 1;
    }
    printf("test_control_socket: all OK\n");
    return 0;
}
