// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/*
 * relay_adapter.h — authenticated iPhone LAN relay path for Darwin
 *
 * Owns one connected UDP socket to the iPhone relay endpoint and presents
 * it to libmqvpn as a single callback-backed logical path: HELLO/HELLO_ACK
 * session authentication, replay-window enforcement, keepalive liveness,
 * and transport recovery all live behind this API so platform_darwin.c
 * only wires callbacks. The implementation is portable POSIX outside its
 * __APPLE__ guards because CMake also builds it on Linux CI for
 * tests/test_relay_adapter_darwin.c.
 */

#ifndef MQVPN_PLATFORM_RELAY_ADAPTER_H
#define MQVPN_PLATFORM_RELAY_ADAPTER_H

#include "libmqvpn.h"
#include "mqvpn/relay_protocol.h"

#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>

struct event_base;

typedef struct darwin_relay_adapter_s darwin_relay_adapter_t;

typedef struct {
    mqvpn_client_t *client;
    struct event_base *event_base;
    struct sockaddr_in endpoint;
    struct sockaddr_storage server_peer;
    socklen_t server_peer_length;
    char interface_name[IFNAMSIZ];
    uint8_t key[MQVPN_RELAY_KEY_SIZE];
    void (*on_activity)(void *context);
    void *activity_context;
} darwin_relay_adapter_config_t;

typedef struct {
    void *context;
    uint64_t (*now_ms)(void *context);
    uint64_t (*random_u64)(void *context);
    int (*socket_open)(void *context);
    void (*socket_close)(void *context, int fd);
    ssize_t (*socket_send)(void *context, int fd, const uint8_t *data, size_t length);
    mqvpn_path_handle_t (*path_add)(void *context, const mqvpn_path_desc_t *desc,
                                    mqvpn_add_path_outcome_t *outcome);
    int (*path_remove)(void *context, mqvpn_path_handle_t handle);
    int (*path_recv)(void *context, mqvpn_path_handle_t handle, const uint8_t *data,
                     size_t length, const struct sockaddr *peer, socklen_t peer_length);
} darwin_relay_adapter_ops_t;

typedef struct {
    int active;
    mqvpn_path_handle_t path_handle;
    uint64_t session_id;
    uint64_t bytes_to_iphone;
    uint64_t bytes_from_iphone;
} darwin_relay_adapter_status_t;

/* `ops` overrides individual production defaults (NULL entries keep them);
 * pass NULL for all-production behavior. */
darwin_relay_adapter_t *
darwin_relay_adapter_create(const darwin_relay_adapter_config_t *config,
                            const darwin_relay_adapter_ops_t *ops);
void darwin_relay_adapter_destroy(darwin_relay_adapter_t *adapter);
int darwin_relay_adapter_start(darwin_relay_adapter_t *adapter);
void darwin_relay_adapter_stop(darwin_relay_adapter_t *adapter);
/* Drives the HELLO retry / keepalive / idle-expiry / failure-recovery
 * timers. Runs from an internal 250 ms libevent timer when a base was
 * configured; tests without a base call it directly. */
void darwin_relay_adapter_tick(darwin_relay_adapter_t *adapter);
/* Connection-level reconnect notification (state_changed → RECONNECTING).
 * libmqvpn owns and invalidates every path slot during that reconnect, so
 * this must NOT call path_remove for the stale handle — it only forgets
 * the handle and begins a fresh HELLO session on the existing socket. */
void darwin_relay_adapter_reconnect(darwin_relay_adapter_t *adapter);
/* Feeds one datagram received from the relay endpoint. Returns 0 when the
 * frame authenticated and was consumed: HELLO_ACK (first one activates the
 * logical path; repeats are liveness answers), DATA_TO_MAC delivered to
 * path_recv while active, or KEEPALIVE. Returns -1 when the adapter is not
 * started, the frame fails decode or the replay window, DATA_TO_MAC
 * arrives before activation, the path add fails, or path_recv rejects the
 * payload. -1 never tears state down — unauthenticated LAN noise must be
 * droppable for free. */
int darwin_relay_adapter_on_datagram(darwin_relay_adapter_t *adapter,
                                     const uint8_t *datagram, size_t length);
/* Encrypts and sends one QUIC datagram on the relay path. Returns the
 * payload length on success. -EAGAIN is transient transport pushback
 * (EAGAIN/ENOBUFS): the caller retries later and the transport is kept.
 * -EINVAL from the entry checks (inactive, wrong path, bad args) is also
 * state-preserving. Any other negative return is -errno-shaped (-ENOTCONN
 * no socket, -EIO short send, or the send() errno) and marks the transport
 * failed — the next tick closes the socket, removes the path, reopens, and
 * re-authenticates. */
ssize_t darwin_relay_adapter_send_packet(darwin_relay_adapter_t *adapter,
                                         mqvpn_path_handle_t path, const uint8_t *packet,
                                         size_t length);
void darwin_relay_adapter_get_status(const darwin_relay_adapter_t *adapter,
                                     darwin_relay_adapter_status_t *status);
int darwin_relay_adapter_fd(const darwin_relay_adapter_t *adapter);

#endif /* MQVPN_PLATFORM_RELAY_ADAPTER_H */
