// SPDX-License-Identifier: Apache-2.0

#include "relay_adapter.h"
#include "mqvpn/relay_protocol.h"

#include <errno.h>
#include <event2/event.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int g_pass, g_fail;
#define CHECK(c, m) do { if (c) g_pass++; else { g_fail++; fprintf(stderr, "FAIL: %s\n", m); } } while (0)

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

static uint64_t fake_now(void *ctx) { return ((fake_t *)ctx)->now_ms; }
static uint64_t fake_random(void *ctx) { return ((fake_t *)ctx)->next_random++; }
static int fake_open(void *ctx)
{
    fake_t *f = ctx;
    int raw = socket(AF_INET, SOCK_DGRAM, 0);
    if (raw < 0) return -1;
    struct sockaddr_in local = {.sin_family = AF_INET,
                                .sin_port = 0,
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
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
static void fake_close(void *ctx, int fd) { close(fd); ((fake_t *)ctx)->close_count++; }
static ssize_t fake_send(void *ctx, int fd, const uint8_t *data, size_t length)
{
    (void)fd;
    fake_t *f = ctx;
    if (f->send_result != 0) return f->send_result;
    int slot = f->send_count++;
    memcpy(f->sent[slot], data, length);
    f->sent_length[slot] = length;
    return (ssize_t)length;
}
static mqvpn_path_handle_t fake_add(void *ctx, const mqvpn_path_desc_t *desc,
                                    mqvpn_add_path_outcome_t *outcome)
{
    fake_t *f = ctx;
    f->add_count++;
    CHECK(desc->fd == -1, "relay adds callback-backed path");
    *outcome = MQVPN_ADD_PATH_OK;
    return 42;
}
static int fake_remove(void *ctx, mqvpn_path_handle_t handle)
{
    fake_t *f = ctx;
    f->remove_count++;
    f->removed_handle = handle;
    return MQVPN_OK;
}
static int fake_recv(void *ctx, mqvpn_path_handle_t handle, const uint8_t *data,
                     size_t length, const struct sockaddr *peer, socklen_t peer_len)
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

static darwin_relay_adapter_t *make_adapter(fake_t *f, uint8_t key[32])
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
    return darwin_relay_adapter_create(&cfg, &ops);
}

static void encode_phone(const uint8_t key[32], mqvpn_relay_message_type_t type,
                         uint64_t session, uint64_t seq, const uint8_t *payload,
                         size_t payload_len, uint8_t *out, size_t *out_len)
{
    CHECK(mqvpn_relay_encode(key, type, MQVPN_RELAY_IPHONE_TO_MAC, session, seq,
                             payload, payload_len, out,
                             MQVPN_RELAY_MAX_DATAGRAM_SIZE, out_len) == MQVPN_RELAY_OK,
          "phone test frame encodes");
}

static void test_lifecycle(void)
{
    uint8_t key[32] = {0};
    fake_t f;
    darwin_relay_adapter_t *a = make_adapter(&f, key);
    CHECK(a != NULL, "adapter created");
    CHECK(darwin_relay_adapter_start(a) == 0, "adapter starts");
    CHECK(f.open_count == 1 && f.send_count == 1, "start opens socket and sends HELLO");

    darwin_relay_adapter_status_t status;
    darwin_relay_adapter_get_status(a, &status);
    CHECK(!status.active && status.session_id == 100, "HELLO is pending on fresh session");

    f.now_ms = 999;
    darwin_relay_adapter_tick(a);
    CHECK(f.send_count == 1, "HELLO not retried early");
    f.now_ms = 1000;
    darwin_relay_adapter_tick(a);
    CHECK(f.send_count == 2, "HELLO retried after one second");

    uint8_t frame[MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    size_t frame_len = 0;
    encode_phone(key, MQVPN_RELAY_HELLO_ACK, status.session_id, 1, NULL, 0, frame,
                 &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == 0,
          "authenticated ACK accepted");
    darwin_relay_adapter_get_status(a, &status);
    CHECK(status.active && status.path_handle == 42 && f.add_count == 1,
          "ACK activates exactly one logical path");

    f.now_ms = 6000;
    darwin_relay_adapter_tick(a);
    mqvpn_relay_frame_t decoded;
    CHECK(mqvpn_relay_decode(key, f.sent[2], f.sent_length[2],
                             MQVPN_RELAY_MAC_TO_IPHONE, &status.session_id,
                             &decoded) == MQVPN_RELAY_OK &&
              decoded.type == MQVPN_RELAY_HELLO,
          "active liveness probe requests an authenticated ACK");
    encode_phone(key, MQVPN_RELAY_HELLO_ACK, status.session_id, 2, NULL, 0, frame,
                 &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == 0,
          "active liveness ACK refreshes session without adding another path");
    CHECK(f.add_count == 1, "liveness ACK does not duplicate logical path");

    const uint8_t quic[] = {1, 2, 3, 4};
    CHECK(darwin_relay_adapter_send_packet(a, 42, quic, sizeof(quic)) ==
              (ssize_t)sizeof(quic),
          "callback send frames complete QUIC datagram");
    CHECK(mqvpn_relay_decode(key, f.sent[3], f.sent_length[3],
                             MQVPN_RELAY_MAC_TO_IPHONE, &status.session_id,
                             &decoded) == MQVPN_RELAY_OK &&
              decoded.type == MQVPN_RELAY_DATA_TO_SERVER &&
              decoded.payload_length == sizeof(quic) &&
              memcmp(decoded.payload, quic, sizeof(quic)) == 0,
          "callback send uses authenticated DATA_TO_SERVER frame");

    const uint8_t reply[] = {9, 8, 7};
    encode_phone(key, MQVPN_RELAY_DATA_TO_MAC, status.session_id, 3, reply,
                 sizeof(reply), frame, &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == 0,
          "authenticated server reply accepted");
    CHECK(f.recv_count == 1 && f.recv_handle == 42 && f.recv_length == sizeof(reply) &&
              memcmp(f.recv_payload, reply, sizeof(reply)) == 0,
          "reply delivered to exact libmqvpn logical handle");
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == -1 &&
              f.recv_count == 1,
          "replayed reply is dropped before delivery");

    uint8_t wrong_key[32] = {1};
    encode_phone(wrong_key, MQVPN_RELAY_KEEPALIVE, status.session_id, 4, NULL, 0,
                 frame, &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == -1,
          "wrong-key frame is dropped before state mutation");

    f.now_ms = 21001;
    uint64_t active_session = status.session_id;
    darwin_relay_adapter_tick(a);
    darwin_relay_adapter_get_status(a, &status);
    CHECK(f.remove_count == 1 && !status.active && status.session_id != active_session,
          "idle expiry removes active path and starts a fresh session");
    encode_phone(key, MQVPN_RELAY_HELLO_ACK, status.session_id, 1, NULL, 0, frame,
                 &frame_len);
    CHECK(darwin_relay_adapter_on_datagram(a, frame, frame_len) == 0,
          "fresh session can authenticate after expiry");

    f.send_result = -EAGAIN;
    CHECK(darwin_relay_adapter_send_packet(a, 42, quic, sizeof(quic)) == -EAGAIN,
          "temporary socket backpressure is preserved");
    f.send_result = -EIO;
    CHECK(darwin_relay_adapter_send_packet(a, 42, quic, sizeof(quic)) == -EIO,
          "hard socket error is preserved");
    int old_fd = darwin_relay_adapter_fd(a);
    f.send_result = 0;
    darwin_relay_adapter_tick(a);
    CHECK(f.remove_count == 2 && f.removed_handle == 42,
          "hard socket error removes relay path on tick");
    CHECK(f.open_count == 2 && f.close_count == 1 &&
              darwin_relay_adapter_fd(a) != old_fd,
          "hard socket error recreates a fresh connected LAN socket");

    darwin_relay_adapter_get_status(a, &status);
    encode_phone(key, MQVPN_RELAY_HELLO_ACK, status.session_id, 1, NULL, 0, frame,
                 &frame_len);
    struct sockaddr_in fresh_addr;
    socklen_t fresh_len = sizeof(fresh_addr);
    CHECK(getsockname(darwin_relay_adapter_fd(a), (struct sockaddr *)&fresh_addr,
                      &fresh_len) == 0,
          "fresh relay fd has a bound address");
    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(sendto(sender, frame, frame_len, 0, (struct sockaddr *)&fresh_addr,
                 fresh_len) == (ssize_t)frame_len,
          "authenticated ACK sent to recreated socket");
    event_base_loop(f.base, EVLOOP_ONCE);
    close(sender);
    darwin_relay_adapter_get_status(a, &status);
    CHECK(status.active && f.add_count == 3,
          "recreated read event authenticates and adds a fresh logical path");

    uint64_t failed_session = status.session_id;
    f.now_ms += 16000;
    darwin_relay_adapter_tick(a);
    darwin_relay_adapter_get_status(a, &status);
    CHECK(!status.active && status.session_id != failed_session,
          "idle/reconnect creates a fresh authenticated session");

    darwin_relay_adapter_stop(a);
    CHECK(f.close_count == 2, "stop closes recreated LAN socket");
    darwin_relay_adapter_destroy(a);
    event_base_free(f.base);
}

int main(void)
{
    test_lifecycle();
    printf("test_relay_adapter_darwin: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
