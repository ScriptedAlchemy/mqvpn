// SPDX-License-Identifier: Apache-2.0

#ifndef MQVPN_DARWIN_RELAY_ADAPTER_H
#define MQVPN_DARWIN_RELAY_ADAPTER_H

#include "libmqvpn.h"
#include "mqvpn/relay_protocol.h"

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
    char interface_name[16];
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
    int started;
    int active;
    mqvpn_path_handle_t path_handle;
    uint64_t session_id;
    uint64_t bytes_to_iphone;
    uint64_t bytes_from_iphone;
    uint64_t last_authenticated_ms;
} darwin_relay_adapter_status_t;

darwin_relay_adapter_t *
darwin_relay_adapter_create(const darwin_relay_adapter_config_t *config,
                            const darwin_relay_adapter_ops_t *ops);
void darwin_relay_adapter_destroy(darwin_relay_adapter_t *adapter);
int darwin_relay_adapter_start(darwin_relay_adapter_t *adapter);
void darwin_relay_adapter_stop(darwin_relay_adapter_t *adapter);
void darwin_relay_adapter_tick(darwin_relay_adapter_t *adapter);
void darwin_relay_adapter_reconnect(darwin_relay_adapter_t *adapter);
int darwin_relay_adapter_on_datagram(darwin_relay_adapter_t *adapter,
                                     const uint8_t *datagram, size_t length);
ssize_t darwin_relay_adapter_send_packet(darwin_relay_adapter_t *adapter,
                                         mqvpn_path_handle_t path,
                                         const uint8_t *packet, size_t length);
void darwin_relay_adapter_get_status(const darwin_relay_adapter_t *adapter,
                                     darwin_relay_adapter_status_t *status);
int darwin_relay_adapter_fd(const darwin_relay_adapter_t *adapter);

#endif
