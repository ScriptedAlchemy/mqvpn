// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#include "relay_adapter.h"
#include "mqvpn/relay_protocol.h"

#include <errno.h>
#include <event2/event.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int tests_run;

static void
fail(const char *expression, const char *file, int line)
{
    fprintf(stderr, "FAIL %s:%d: %s\n", file, line, expression);
    exit(1);
}

#define CHECK(expression)                          \
    do {                                           \
        if (!(expression)) {                       \
            fail(#expression, __FILE__, __LINE__); \
        }                                          \
    } while (0)

#define TEST(name)                 \
    static void test_##name(void); \
    static void run_##name(void)   \
    {                              \
        tests_run++;               \
        printf("  %-52s ", #name); \
        test_##name();             \
        puts("PASS");              \
    }                              \
    static void test_##name(void)

typedef struct {
    uint64_t now_ms;
    uint64_t next_random;
    int open_count;
    int close_count;
    int add_count;
    int remove_count;
    int recv_count;
    mqvpn_path_handle_t removed_handle;
    mqvpn_path_handle_t recv_handle;
    uint8_t recv_payload[64];
    size_t recv_length;
    ssize_t send_result;
    int send_count;
    uint8_t sent[16][MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    size_t sent_length[16];
    struct event_base *base;
} fake_t;

static uint64_t
fake_now(void *ctx)
{
    return ((fake_t *)ctx)->now_ms;
}

static uint64_t
fake_random(void *ctx)
{
    return ((fake_t *)ctx)->next_random++;
}

static int
fake_open(void *ctx)
{
    fake_t *f = ctx;
    int raw = socket(AF_INET, SOCK_DGRAM, 0);
    if (raw < 0) return -1;
    struct sockaddr_in local = {
        .sin_family = AF_INET, .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (bind(raw, (struct sockaddr *)&local, sizeof(local)) < 0) {
        close(raw);
        return -1;
    }
    int fd = fcntl(raw, F_DUPFD, 100 + f->open_count);
    close(raw);
    if (fd >= 0) {
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        f->open_count++;
    }
    return fd;
}

static void
fake_close(void *ctx, int fd)
{
    close(fd);
    ((fake_t *)ctx)->close_count++;
}

static ssize_t
fake_send(void *ctx, int fd, const uint8_t *data, size_t length)
{
    (void)fd;
    fake_t *f = ctx;
    if (f->send_result != 0) return f->send_result;
    size_t slot = (size_t)f->send_count;
    CHECK(slot < sizeof(f->sent) / sizeof(f->sent[0]));
    f->send_count++;
    memcpy(f->sent[slot], data, length);
    f->sent_length[slot] = length;
    return (ssize_t)length;
}

static mqvpn_path_handle_t
fake_add(void *ctx, const mqvpn_path_desc_t *desc, mqvpn_add_path_outcome_t *outcome)
{
    fake_t *f = ctx;
    f->add_count++;
    /* The relay path is callback-backed: it must never hand libmqvpn an fd. */
    CHECK(desc->fd == -1);
    *outcome = MQVPN_ADD_PATH_OK;
    return 42;
}

static int
fake_remove(void *ctx, mqvpn_path_handle_t handle)
{
    fake_t *f = ctx;
    f->remove_count++;
    f->removed_handle = handle;
    return MQVPN_OK;
}

static int
fake_recv(void *ctx, mqvpn_path_handle_t handle, const uint8_t *data, size_t length,
          const struct sockaddr *peer, socklen_t peer_len)
{
    (void)peer;
    (void)peer_len;
    fake_t *f = ctx;
    f->recv_count++;
    f->recv_handle = handle;
    memcpy(f->recv_payload, data, length);
    f->recv_length = length;
    return MQVPN_OK;
}

static darwin_relay_adapter_t *
make_adapter(fake_t *f, uint8_t key[32])
{
    memset(f, 0, sizeof(*f));
    f->next_random = 100;
    f->base = event_base_new();
    darwin_relay_adapter_config_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    memcpy(cfg.key, key, 32);
    cfg.event_base = f->base;
    cfg.endpoint.sin_family = AF_INET;
    cfg.endpoint.sin_port = htons(5443);
    cfg.endpoint.sin_addr.s_addr = htonl(0xc0a801c3u);
    snprintf(cfg.interface_name, sizeof(cfg.interface_name), "en0");
    cfg.server_peer.ss_family = AF_INET;
    cfg.server_peer_length = sizeof(struct sockaddr_in);

    darwin_relay_adapter_ops_t ops = {
        .context = f,
        .now_ms = fake_now,
        .random_u64 = fake_random,
        .socket_open = fake_open,
        .socket_close = fake_close,
        .socket_send = fake_send,
        .path_add = fake_add,
        .path_remove = fake_remove,
        .path_recv = fake_recv,
    };
    darwin_relay_adapter_t *a = darwin_relay_adapter_create(&cfg, &ops);
    CHECK(a != NULL);
    return a;
}

static void
destroy_adapter(fake_t *f, darwin_relay_adapter_t *a)
{
    darwin_relay_adapter_stop(a);
    darwin_relay_adapter_destroy(a);
    event_base_free(f->base);
}

static void
encode_phone(const uint8_t key[32], mqvpn_relay_message_type_t type, uint64_t session,
             uint64_t seq, const uint8_t *payload, size_t payload_len, uint8_t *out,
             size_t *out_len)
{
    CHECK(mqvpn_relay_encode(key, type, MQVPN_RELAY_IPHONE_TO_MAC, session, seq, payload,
                             payload_len, out, MQVPN_RELAY_MAX_DATAGRAM_SIZE,
                             out_len) == MQVPN_RELAY_OK);
}

/* start + authenticated HELLO_ACK: leaves the adapter active on path 42 with
 * the HELLO in send slot 0. */
static void
activate(fake_t *f, darwin_relay_adapter_t *a, const uint8_t key[32])
{
    darwin_relay_adapter_status_t status;
    uint8_t frame[MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    size_t frame_len = 0;

    CHECK(darwin_relay_adapter_start(a) == 0);
    darwin_relay_adapter_get_status(a, &status);
    encode_phone(key, MQVPN_RELAY_HELLO_ACK, status.session_id, 1, NULL, 0, frame,
                 &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == 0);
    darwin_relay_adapter_get_status(a, &status);
    CHECK(status.active && status.path_handle == 42 && f->add_count == 1);
}

TEST(start_sends_hello_and_retries_each_second)
{
    uint8_t key[32] = {0};
    fake_t f;
    darwin_relay_adapter_t *a = make_adapter(&f, key);

    CHECK(darwin_relay_adapter_start(a) == 0);
    CHECK(f.open_count == 1 && f.send_count == 1);

    darwin_relay_adapter_status_t status;
    darwin_relay_adapter_get_status(a, &status);
    CHECK(!status.active && status.session_id == 100);

    f.now_ms = 999;
    darwin_relay_adapter_tick(a);
    CHECK(f.send_count == 1);
    f.now_ms = 1000;
    darwin_relay_adapter_tick(a);
    CHECK(f.send_count == 2);

    destroy_adapter(&f, a);
}

TEST(hello_ack_activates_one_path_and_liveness_reacks)
{
    uint8_t key[32] = {0};
    fake_t f;
    darwin_relay_adapter_t *a = make_adapter(&f, key);
    activate(&f, a, key);

    darwin_relay_adapter_status_t status;
    darwin_relay_adapter_get_status(a, &status);

    /* The active-session liveness probe is a fresh authenticated HELLO. */
    f.now_ms = 6000;
    darwin_relay_adapter_tick(a);
    mqvpn_relay_frame_t decoded;
    CHECK(mqvpn_relay_decode(key, f.sent[1], f.sent_length[1], MQVPN_RELAY_MAC_TO_IPHONE,
                             &status.session_id, &decoded) == MQVPN_RELAY_OK &&
          decoded.type == MQVPN_RELAY_HELLO);

    uint8_t frame[MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    size_t frame_len = 0;
    encode_phone(key, MQVPN_RELAY_HELLO_ACK, status.session_id, 2, NULL, 0, frame,
                 &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == 0);
    CHECK(f.add_count == 1);

    destroy_adapter(&f, a);
}

TEST(data_round_trip_uses_authenticated_frames_and_drops_replay)
{
    uint8_t key[32] = {0};
    fake_t f;
    darwin_relay_adapter_t *a = make_adapter(&f, key);
    activate(&f, a, key);

    darwin_relay_adapter_status_t status;
    darwin_relay_adapter_get_status(a, &status);

    const uint8_t quic[] = {1, 2, 3, 4};
    CHECK(darwin_relay_adapter_send_packet(a, 42, quic, sizeof(quic)) ==
          (ssize_t)sizeof(quic));
    mqvpn_relay_frame_t decoded;
    CHECK(mqvpn_relay_decode(key, f.sent[1], f.sent_length[1], MQVPN_RELAY_MAC_TO_IPHONE,
                             &status.session_id, &decoded) == MQVPN_RELAY_OK &&
          decoded.type == MQVPN_RELAY_DATA_TO_SERVER &&
          decoded.payload_length == sizeof(quic) &&
          memcmp(decoded.payload, quic, sizeof(quic)) == 0);

    const uint8_t reply[] = {9, 8, 7};
    uint8_t frame[MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    size_t frame_len = 0;
    encode_phone(key, MQVPN_RELAY_DATA_TO_MAC, status.session_id, 2, reply, sizeof(reply),
                 frame, &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == 0);
    CHECK(f.recv_count == 1 && f.recv_handle == 42 && f.recv_length == sizeof(reply) &&
          memcmp(f.recv_payload, reply, sizeof(reply)) == 0);

    /* Replay of the exact frame must be dropped before delivery. */
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == -1);
    CHECK(f.recv_count == 1);

    uint8_t wrong_key[32] = {1};
    encode_phone(wrong_key, MQVPN_RELAY_KEEPALIVE, status.session_id, 3, NULL, 0, frame,
                 &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == -1);

    destroy_adapter(&f, a);
}

TEST(idle_expiry_removes_path_and_fresh_session_reauthenticates)
{
    uint8_t key[32] = {0};
    fake_t f;
    darwin_relay_adapter_t *a = make_adapter(&f, key);
    activate(&f, a, key);

    darwin_relay_adapter_status_t status;
    darwin_relay_adapter_get_status(a, &status);
    uint64_t active_session = status.session_id;

    f.now_ms = 21001;
    darwin_relay_adapter_tick(a);
    darwin_relay_adapter_get_status(a, &status);
    CHECK(f.remove_count == 1 && f.removed_handle == 42);
    CHECK(!status.active && status.session_id != active_session);

    uint8_t frame[MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    size_t frame_len = 0;
    encode_phone(key, MQVPN_RELAY_HELLO_ACK, status.session_id, 1, NULL, 0, frame,
                 &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == 0);
    darwin_relay_adapter_get_status(a, &status);
    CHECK(status.active && f.add_count == 2);

    destroy_adapter(&f, a);
}

TEST(hard_send_error_recovers_socket_and_path)
{
    uint8_t key[32] = {0};
    fake_t f;
    darwin_relay_adapter_t *a = make_adapter(&f, key);
    activate(&f, a, key);

    const uint8_t quic[] = {1, 2, 3, 4};
    f.send_result = -EAGAIN;
    CHECK(darwin_relay_adapter_send_packet(a, 42, quic, sizeof(quic)) == -EAGAIN);
    f.send_result = -EIO;
    CHECK(darwin_relay_adapter_send_packet(a, 42, quic, sizeof(quic)) == -EIO);

    int old_fd = darwin_relay_adapter_fd(a);
    f.send_result = 0;
    /* Reopens are rate-limited to one per RELAY_HELLO_RETRY_MS regardless
     * of socket state (anti-churn), and start() left last_reopen_ms at 0,
     * so the recovery tick must land at t >= 1000. */
    f.now_ms = 1100;
    darwin_relay_adapter_tick(a);
    CHECK(f.remove_count == 1 && f.removed_handle == 42);
    CHECK(f.open_count == 2 && f.close_count == 1 &&
          darwin_relay_adapter_fd(a) != old_fd);

    /* Authenticate the fresh session through the recreated socket for real:
     * the read event must decode, activate, and add a new logical path. */
    darwin_relay_adapter_status_t status;
    darwin_relay_adapter_get_status(a, &status);
    uint8_t frame[MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    size_t frame_len = 0;
    encode_phone(key, MQVPN_RELAY_HELLO_ACK, status.session_id, 1, NULL, 0, frame,
                 &frame_len);
    struct sockaddr_in fresh_addr;
    socklen_t fresh_len = sizeof(fresh_addr);
    CHECK(getsockname(darwin_relay_adapter_fd(a), (struct sockaddr *)&fresh_addr,
                      &fresh_len) == 0);
    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(sendto(sender, frame, frame_len, 0, (struct sockaddr *)&fresh_addr,
                 fresh_len) == (ssize_t)frame_len);
    event_base_loop(f.base, EVLOOP_ONCE);
    close(sender);
    darwin_relay_adapter_get_status(a, &status);
    CHECK(status.active && f.add_count == 2);

    uint64_t recovered_session = status.session_id;
    f.now_ms += 16000;
    darwin_relay_adapter_tick(a);
    darwin_relay_adapter_get_status(a, &status);
    CHECK(!status.active && status.session_id != recovered_session);

    darwin_relay_adapter_stop(a);
    CHECK(f.close_count == 2);
    darwin_relay_adapter_destroy(a);
    event_base_free(f.base);
}

int
main(void)
{
    puts("relay adapter tests:");
    run_start_sends_hello_and_retries_each_second();
    run_hello_ack_activates_one_path_and_liveness_reacks();
    run_data_round_trip_uses_authenticated_frames_and_drops_replay();
    run_idle_expiry_removes_path_and_fresh_session_reauthenticates();
    run_hard_send_error_recovers_socket_and_path();
    printf("relay adapter tests: %d/%d PASS\n", tests_run, tests_run);
    return 0;
}
