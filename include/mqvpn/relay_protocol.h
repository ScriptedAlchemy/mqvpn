// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#ifndef MQVPN_RELAY_PROTOCOL_H
#define MQVPN_RELAY_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#  define MQVPN_RELAY_API __declspec(dllexport)
#else
#  define MQVPN_RELAY_API __attribute__((visibility("default")))
#endif

#define MQVPN_RELAY_VERSION          1u
#define MQVPN_RELAY_KEY_SIZE         32u
#define MQVPN_RELAY_HEADER_SIZE      28u
#define MQVPN_RELAY_TAG_SIZE         16u
/* Must cover the complete encrypted UDP datagram xquic hands to write_socket_ex,
 * not only max_pkt_out_size. The current absolute bound is 1452 bytes
 * (1420-byte packet budget + 16-byte ACK space + 16-byte AEAD overhead).
 * Keep bounded headroom so the relay envelope rejects genuinely invalid input
 * without rejecting xquic's own output. */
#define MQVPN_RELAY_MAX_PAYLOAD_SIZE 2048u
#define MQVPN_RELAY_MAX_DATAGRAM_SIZE \
    (MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE + MQVPN_RELAY_TAG_SIZE)

typedef enum {
    MQVPN_RELAY_HELLO = 1,
    MQVPN_RELAY_HELLO_ACK = 2,
    MQVPN_RELAY_DATA_TO_SERVER = 3,
    MQVPN_RELAY_DATA_TO_MAC = 4,
    MQVPN_RELAY_KEEPALIVE = 5,
} mqvpn_relay_message_type_t;

typedef enum {
    MQVPN_RELAY_MAC_TO_IPHONE = 0,
    MQVPN_RELAY_IPHONE_TO_MAC = 1,
} mqvpn_relay_direction_t;

typedef enum {
    MQVPN_RELAY_OK = 0,
    MQVPN_RELAY_ERR_INVALID_ARGUMENT = -1,
    MQVPN_RELAY_ERR_OUTPUT_TOO_SMALL = -2,
    MQVPN_RELAY_ERR_TRUNCATED = -3,
    MQVPN_RELAY_ERR_BAD_MAGIC = -4,
    MQVPN_RELAY_ERR_UNSUPPORTED_VERSION = -5,
    MQVPN_RELAY_ERR_UNKNOWN_TYPE = -6,
    MQVPN_RELAY_ERR_INVALID_DIRECTION = -7,
    MQVPN_RELAY_ERR_NONZERO_RESERVED = -8,
    MQVPN_RELAY_ERR_LENGTH_MISMATCH = -9,
    MQVPN_RELAY_ERR_PAYLOAD_TOO_LARGE = -10,
    MQVPN_RELAY_ERR_AUTH_FAILED = -11,
    MQVPN_RELAY_ERR_WRONG_DIRECTION = -12,
    MQVPN_RELAY_ERR_WRONG_SESSION = -13,
    MQVPN_RELAY_ERR_REPLAY = -14,
    MQVPN_RELAY_ERR_CRYPTO = -15,
} mqvpn_relay_result_t;

typedef struct {
    mqvpn_relay_message_type_t type;
    mqvpn_relay_direction_t direction;
    uint64_t session_id;
    uint64_t sequence;
    const uint8_t *payload;
    size_t payload_length;
} mqvpn_relay_frame_t;

typedef struct {
    uint64_t highest_sequence;
    uint64_t received_bitmap;
    int initialized;
} mqvpn_replay_window_t;

/*
 * Wire header (all multibyte fields are network byte order):
 *   0..3   magic "MQR1"
 *   4      version
 *   5      message type
 *   6      direction
 *   7      reserved, zero
 *   8..15  session identifier
 *   16..23 sequence number
 *   24..25 payload length
 *   26..27 reserved, zero
 */
MQVPN_RELAY_API mqvpn_relay_result_t mqvpn_relay_encode(
    const uint8_t key[MQVPN_RELAY_KEY_SIZE], mqvpn_relay_message_type_t type,
    mqvpn_relay_direction_t direction, uint64_t session_id, uint64_t sequence,
    const uint8_t *payload, size_t payload_length, uint8_t *datagram,
    size_t datagram_capacity, size_t *datagram_length);

/*
 * expected_session may be NULL while accepting a new authenticated HELLO.
 * The returned payload aliases datagram and remains valid only while the
 * caller retains that buffer. Replay state is deliberately updated through
 * mqvpn_replay_window_accept only after decode/authentication succeeds.
 */
MQVPN_RELAY_API mqvpn_relay_result_t
mqvpn_relay_decode(const uint8_t key[MQVPN_RELAY_KEY_SIZE], const uint8_t *datagram,
                   size_t datagram_length, mqvpn_relay_direction_t expected_direction,
                   const uint64_t *expected_session, mqvpn_relay_frame_t *frame);

MQVPN_RELAY_API mqvpn_relay_result_t
mqvpn_replay_window_accept(mqvpn_replay_window_t *window, uint64_t sequence);

#ifdef __cplusplus
}
#endif

#endif /* MQVPN_RELAY_PROTOCOL_H */
