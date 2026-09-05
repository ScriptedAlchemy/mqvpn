// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/* Authenticated iPhone LAN relay exposed as a callback-backed path.
 * Keep code outside __APPLE__ guards portable for the Linux host tests. */

#include "relay_adapter.h"
#include "log.h"

#include <errno.h>
#include <event2/event.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#  include <net/if.h>
#endif

#define RELAY_HELLO_RETRY_MS 1000u
#define RELAY_KEEPALIVE_MS   5000u
#define RELAY_IDLE_MS        15000u
#define RELAY_TIMER_MS       250u

struct darwin_relay_adapter_s {
    darwin_relay_adapter_config_t config;
    darwin_relay_adapter_ops_t ops;
    int fd;
    int started;
    int active;
    int hard_failure;
    mqvpn_path_handle_t path_handle;
    uint64_t session_id;
    uint64_t tx_sequence;
    uint64_t last_hello_ms;
    uint64_t last_keepalive_ms;
    uint64_t last_reopen_ms;
    uint64_t last_authenticated_ms;
    uint64_t bytes_to_iphone;
    uint64_t bytes_from_iphone;
    mqvpn_replay_window_t rx_replay;
    struct event *read_event;
    struct event *timer_event;
};

static void read_cb(evutil_socket_t fd, short events, void *context);

static uint64_t
production_now_ms(void *context)
{
    (void)context;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static uint64_t
production_random_u64(void *context)
{
    (void)context;
    uint64_t value = 0;
    arc4random_buf(&value, sizeof(value));
    return value;
}

static int
production_socket_open(void *context)
{
    darwin_relay_adapter_t *a = context;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) < 0) {
        close(fd);
        return -1;
    }
#ifdef __APPLE__
    (void)fcntl(fd, F_SETNOSIGPIPE, 1);
    if (a->config.interface_name[0] != '\0') {
        unsigned int index = if_nametoindex(a->config.interface_name);
        if (index == 0 ||
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, sizeof(index)) < 0) {
            close(fd);
            return -1;
        }
    }
#endif
    if (connect(fd, (const struct sockaddr *)&a->config.endpoint,
                sizeof(a->config.endpoint)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void
production_socket_close(void *context, int fd)
{
    (void)context;
    close(fd);
}

static ssize_t
production_socket_send(void *context, int fd, const uint8_t *data, size_t length)
{
    (void)context;
    ssize_t sent;
    do {
        sent = send(fd, data, length, 0);
    } while (sent < 0 && errno == EINTR);
    if (sent >= 0) return sent;
    /* ENOBUFS on Darwin UDP is a transient no-mbuf condition under send
     * load, not a dead transport. Report it as -EAGAIN so callers back off
     * instead of tearing down the socket and path — the same downgrade the
     * library applies to its own path sends while a path is attached
     * (mqvpn_client.c, client_send_packet_on_path). */
    return (errno == ENOBUFS) ? -EAGAIN : -errno;
}

static mqvpn_path_handle_t
production_path_add(void *context, const mqvpn_path_desc_t *desc,
                    mqvpn_add_path_outcome_t *outcome)
{
    darwin_relay_adapter_t *a = context;
    return mqvpn_client_add_path_fd_with_outcome(a->config.client, -1, desc, outcome);
}

static int
production_path_remove(void *context, mqvpn_path_handle_t handle)
{
    darwin_relay_adapter_t *a = context;
    return mqvpn_client_remove_path(a->config.client, handle);
}

static int
production_path_recv(void *context, mqvpn_path_handle_t handle, const uint8_t *data,
                     size_t length, const struct sockaddr *peer, socklen_t peer_length)
{
    darwin_relay_adapter_t *a = context;
    return mqvpn_client_on_socket_recv(a->config.client, handle, data, length, peer,
                                       peer_length);
}

static uint64_t
now_ms(darwin_relay_adapter_t *a)
{
    return a->ops.now_ms(a->ops.context);
}

static ssize_t
send_frame(darwin_relay_adapter_t *a, mqvpn_relay_message_type_t type,
           const uint8_t *payload, size_t payload_length)
{
    if (a->fd < 0) return -ENOTCONN;
    uint8_t datagram[MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    size_t datagram_length = 0;
    if (mqvpn_relay_encode(a->config.key, type, MQVPN_RELAY_MAC_TO_IPHONE, a->session_id,
                           a->tx_sequence++, payload, payload_length, datagram,
                           sizeof(datagram), &datagram_length) != MQVPN_RELAY_OK)
        return -EINVAL;
    ssize_t sent = a->ops.socket_send(a->ops.context, a->fd, datagram, datagram_length);
    if (sent < 0) return sent;
    if ((size_t)sent != datagram_length) return -EIO;
    a->bytes_to_iphone += datagram_length;
    return (ssize_t)payload_length;
}

static void
remove_path(darwin_relay_adapter_t *a)
{
    if (a->path_handle >= 0) {
        (void)a->ops.path_remove(a->ops.context, a->path_handle);
        a->path_handle = -1;
    }
    a->active = 0;
}

static void
remove_read_event(darwin_relay_adapter_t *a)
{
    if (!a->read_event) return;
    event_del(a->read_event);
    event_free(a->read_event);
    a->read_event = NULL;
}

static void
close_transport(darwin_relay_adapter_t *a)
{
    remove_read_event(a);
    if (a->fd >= 0) {
        a->ops.socket_close(a->ops.context, a->fd);
        a->fd = -1;
    }
}

static int
open_transport(darwin_relay_adapter_t *a)
{
    int fd = a->ops.socket_open(a->ops.context);
    if (fd < 0) return -1;
    a->fd = fd;
    if (!a->config.event_base) return 0;
    a->read_event =
        event_new(a->config.event_base, a->fd, EV_READ | EV_PERSIST, read_cb, a);
    if (!a->read_event || event_add(a->read_event, NULL) < 0) {
        remove_read_event(a);
        a->ops.socket_close(a->ops.context, a->fd);
        a->fd = -1;
        return -1;
    }
    return 0;
}

static void
begin_session(darwin_relay_adapter_t *a, uint64_t now)
{
    remove_path(a);
    do {
        a->session_id = a->ops.random_u64(a->ops.context);
    } while (a->session_id == 0);
    a->tx_sequence = 0;
    memset(&a->rx_replay, 0, sizeof(a->rx_replay));
    a->last_authenticated_ms = now;
    a->last_keepalive_ms = now;
    a->hard_failure = 0;
    ssize_t rc = send_frame(a, MQVPN_RELAY_HELLO, NULL, 0);
    if (rc < 0 && rc != -EAGAIN) a->hard_failure = 1;
    a->last_hello_ms = now;
}

static void
timer_cb(evutil_socket_t fd, short events, void *context)
{
    (void)fd;
    (void)events;
    darwin_relay_adapter_t *a = context;
    darwin_relay_adapter_tick(a);
    if (a->started && a->timer_event) {
        struct timeval tv = {.tv_sec = 0, .tv_usec = RELAY_TIMER_MS * 1000};
        evtimer_add(a->timer_event, &tv);
    }
}

static void
read_cb(evutil_socket_t fd, short events, void *context)
{
    (void)events;
    darwin_relay_adapter_t *a = context;
    uint8_t datagram[MQVPN_RELAY_MAX_DATAGRAM_SIZE];
    for (;;) {
        ssize_t n = recv(fd, datagram, sizeof(datagram), 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            a->hard_failure = 1;
            break;
        }
        /* recv() == 0 on a connected UDP socket is a valid zero-length
         * datagram, not EOF. Treating it as a transport failure let one
         * spoofed empty datagram — pre-auth, no MAC required — reset the
         * whole session. Skip it and keep draining. */
        if (n == 0) continue;
        (void)darwin_relay_adapter_on_datagram(a, datagram, (size_t)n);
    }
    if (a->config.on_activity) a->config.on_activity(a->config.activity_context);
}

darwin_relay_adapter_t *
darwin_relay_adapter_create(const darwin_relay_adapter_config_t *config,
                            const darwin_relay_adapter_ops_t *ops)
{
    if (!config) return NULL;
    darwin_relay_adapter_t *a = calloc(1, sizeof(*a));
    if (!a) return NULL;
    a->config = *config;
    a->fd = -1;
    a->path_handle = -1;
    if (ops) a->ops = *ops;
    if (!a->ops.context) a->ops.context = a;
    if (!a->ops.now_ms) a->ops.now_ms = production_now_ms;
    if (!a->ops.random_u64) a->ops.random_u64 = production_random_u64;
    if (!a->ops.socket_open) a->ops.socket_open = production_socket_open;
    if (!a->ops.socket_close) a->ops.socket_close = production_socket_close;
    if (!a->ops.socket_send) a->ops.socket_send = production_socket_send;
    if (!a->ops.path_add) a->ops.path_add = production_path_add;
    if (!a->ops.path_remove) a->ops.path_remove = production_path_remove;
    if (!a->ops.path_recv) a->ops.path_recv = production_path_recv;
    return a;
}

void
darwin_relay_adapter_destroy(darwin_relay_adapter_t *a)
{
    if (!a) return;
    darwin_relay_adapter_stop(a);
    memset(a->config.key, 0, sizeof(a->config.key));
    free(a);
}

int
darwin_relay_adapter_start(darwin_relay_adapter_t *a)
{
    if (!a) return -1;
    if (a->started) return 0;
    a->started = 1;
    if (open_transport(a) < 0) {
        a->started = 0;
        return -1;
    }
    begin_session(a, now_ms(a));
    if (a->config.event_base) {
        a->timer_event = evtimer_new(a->config.event_base, timer_cb, a);
        if (!a->timer_event) {
            darwin_relay_adapter_stop(a);
            return -1;
        }
        struct timeval tv = {.tv_sec = 0, .tv_usec = RELAY_TIMER_MS * 1000};
        evtimer_add(a->timer_event, &tv);
    }
    return 0;
}

void
darwin_relay_adapter_stop(darwin_relay_adapter_t *a)
{
    if (!a) return;
    remove_path(a);
    close_transport(a);
    if (a->timer_event) {
        event_del(a->timer_event);
        event_free(a->timer_event);
        a->timer_event = NULL;
    }
    a->started = 0;
    a->active = 0;
    a->hard_failure = 0;
    a->session_id = 0;
    a->tx_sequence = 0;
    memset(&a->rx_replay, 0, sizeof(a->rx_replay));
}

void
darwin_relay_adapter_tick(darwin_relay_adapter_t *a)
{
    if (!a || !a->started) return;
    uint64_t now = now_ms(a);
    if (a->hard_failure) {
        /* Rate-limit reopens regardless of socket state: tick fires every
         * 250 ms, and gating only the fd<0 case let a hard failure with a
         * still-open socket churn close/reopen (and path remove/re-add)
         * at 4 Hz. */
        if (now - a->last_reopen_ms < RELAY_HELLO_RETRY_MS) return;
        remove_path(a);
        close_transport(a);
        a->last_reopen_ms = now;
        if (open_transport(a) < 0) return;
        begin_session(a, now);
        return;
    }
    if (now - a->last_authenticated_ms >= RELAY_IDLE_MS) {
        begin_session(a, now);
        return;
    }
    if (!a->active && now - a->last_hello_ms >= RELAY_HELLO_RETRY_MS) {
        (void)send_frame(a, MQVPN_RELAY_HELLO, NULL, 0);
        a->last_hello_ms = now;
    } else if (a->active && now - a->last_keepalive_ms >= RELAY_KEEPALIVE_MS) {
        /* A same-session HELLO is the protocol's liveness probe: the iPhone
         * authenticates it and returns HELLO_ACK. A one-way KEEPALIVE would
         * refresh only the phone and leave the Mac unable to distinguish an
         * idle healthy relay from a vanished phone. */
        ssize_t rc = send_frame(a, MQVPN_RELAY_HELLO, NULL, 0);
        if (rc < 0 && rc != -EAGAIN) a->hard_failure = 1;
        a->last_keepalive_ms = now;
    }
}

void
darwin_relay_adapter_reconnect(darwin_relay_adapter_t *a)
{
    if (!a || !a->started) return;
    /* libmqvpn owns and invalidates every path slot during connection-level
     * reconnect. Do not call remove_path re-entrantly from state_changed. */
    a->path_handle = -1;
    a->active = 0;
    begin_session(a, now_ms(a));
}

int
darwin_relay_adapter_on_datagram(darwin_relay_adapter_t *a, const uint8_t *datagram,
                                 size_t length)
{
    if (!a || !a->started) return -1;
    mqvpn_relay_frame_t frame;
    mqvpn_relay_result_t rc =
        mqvpn_relay_decode(a->config.key, datagram, length, MQVPN_RELAY_IPHONE_TO_MAC,
                           &a->session_id, &frame);
    if (rc != MQVPN_RELAY_OK ||
        mqvpn_replay_window_accept(&a->rx_replay, frame.sequence) != MQVPN_RELAY_OK)
        return -1;
    uint64_t now = now_ms(a);
    a->last_authenticated_ms = now;
    a->bytes_from_iphone += length;

    if (frame.type == MQVPN_RELAY_HELLO_ACK && a->active) return 0;
    if (frame.type == MQVPN_RELAY_HELLO_ACK) {
        mqvpn_path_desc_t desc;
        memset(&desc, 0, sizeof(desc));
        desc.struct_size = sizeof(desc);
        desc.fd = -1;
        snprintf(desc.iface, sizeof(desc.iface), "iphone-relay");
        mqvpn_add_path_outcome_t outcome = MQVPN_ADD_PATH_TRANSIENT_FAIL;
        mqvpn_path_handle_t handle = a->ops.path_add(a->ops.context, &desc, &outcome);
        if (handle < 0) return -1;
        if (outcome == MQVPN_ADD_PATH_PERMANENT_FAIL) {
            (void)a->ops.path_remove(a->ops.context, handle);
            return -1;
        }
        a->path_handle = handle;
        a->active = 1;
        LOG_INF("iPhone relay authenticated; logical path %lld added", (long long)handle);
        return 0;
    }
    if (frame.type == MQVPN_RELAY_DATA_TO_MAC && a->active) {
        return a->ops.path_recv(a->ops.context, a->path_handle, frame.payload,
                                frame.payload_length,
                                (const struct sockaddr *)&a->config.server_peer,
                                a->config.server_peer_length) == MQVPN_OK
                   ? 0
                   : -1;
    }
    return frame.type == MQVPN_RELAY_KEEPALIVE ? 0 : -1;
}

ssize_t
darwin_relay_adapter_send_packet(darwin_relay_adapter_t *a, mqvpn_path_handle_t path,
                                 const uint8_t *packet, size_t length)
{
    if (!a || !a->active || path != a->path_handle || !packet || length == 0)
        return -EINVAL;
    ssize_t rc = send_frame(a, MQVPN_RELAY_DATA_TO_SERVER, packet, length);
    if (rc < 0 && rc != -EAGAIN) a->hard_failure = 1;
    return rc;
}

void
darwin_relay_adapter_get_status(const darwin_relay_adapter_t *a,
                                darwin_relay_adapter_status_t *status)
{
    if (!status) return;
    memset(status, 0, sizeof(*status));
    status->path_handle = -1;
    if (!a) return;
    status->active = a->active;
    status->path_handle = a->path_handle;
    status->session_id = a->session_id;
    status->bytes_to_iphone = a->bytes_to_iphone;
    status->bytes_from_iphone = a->bytes_from_iphone;
}

int
darwin_relay_adapter_fd(const darwin_relay_adapter_t *a)
{
    return a ? a->fd : -1;
}
