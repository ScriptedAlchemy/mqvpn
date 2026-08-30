// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#include "mqvpn/relay_protocol.h"

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/mem.h>

#include <string.h>

static const uint8_t relay_magic[4] = {'M', 'Q', 'R', '1'};

static int
valid_type(mqvpn_relay_message_type_t type)
{
    return type >= MQVPN_RELAY_HELLO && type <= MQVPN_RELAY_KEEPALIVE;
}

static int
valid_direction(mqvpn_relay_direction_t direction)
{
    return direction == MQVPN_RELAY_MAC_TO_IPHONE ||
           direction == MQVPN_RELAY_IPHONE_TO_MAC;
}

static void
write_u64_be(uint8_t *dst, uint64_t value)
{
    for (size_t i = 0; i < 8; i++) {
        dst[7 - i] = (uint8_t)value;
        value >>= 8;
    }
}

static uint64_t
read_u64_be(const uint8_t *src)
{
    uint64_t value = 0;
    for (size_t i = 0; i < 8; i++) {
        value = (value << 8) | src[i];
    }
    return value;
}

static void
write_u16_be(uint8_t *dst, uint16_t value)
{
    dst[0] = (uint8_t)(value >> 8);
    dst[1] = (uint8_t)value;
}

static uint16_t
read_u16_be(const uint8_t *src)
{
    return (uint16_t)(((uint16_t)src[0] << 8) | src[1]);
}

static mqvpn_relay_result_t
make_tag(const uint8_t key[MQVPN_RELAY_KEY_SIZE], const uint8_t *authenticated_data,
         size_t authenticated_length, uint8_t tag[32])
{
    unsigned int tag_length = 0;
    if (!HMAC(EVP_sha256(), key, MQVPN_RELAY_KEY_SIZE, authenticated_data,
              authenticated_length, tag, &tag_length) ||
        tag_length != 32) {
        OPENSSL_cleanse(tag, 32);
        return MQVPN_RELAY_ERR_CRYPTO;
    }
    return MQVPN_RELAY_OK;
}

mqvpn_relay_result_t
mqvpn_relay_encode(const uint8_t key[MQVPN_RELAY_KEY_SIZE],
                   mqvpn_relay_message_type_t type, mqvpn_relay_direction_t direction,
                   uint64_t session_id, uint64_t sequence, const uint8_t *payload,
                   size_t payload_length, uint8_t *datagram, size_t datagram_capacity,
                   size_t *datagram_length)
{
    if (datagram_length) *datagram_length = 0;
    if (!key || !datagram || !datagram_length || (payload_length && !payload) ||
        !valid_type(type) || !valid_direction(direction)) {
        return MQVPN_RELAY_ERR_INVALID_ARGUMENT;
    }
    if (payload_length > MQVPN_RELAY_MAX_PAYLOAD_SIZE)
        return MQVPN_RELAY_ERR_PAYLOAD_TOO_LARGE;

    const size_t encoded_length =
        MQVPN_RELAY_HEADER_SIZE + payload_length + MQVPN_RELAY_TAG_SIZE;
    if (datagram_capacity < encoded_length) return MQVPN_RELAY_ERR_OUTPUT_TOO_SMALL;

    memcpy(datagram, relay_magic, sizeof(relay_magic));
    datagram[4] = MQVPN_RELAY_VERSION;
    datagram[5] = (uint8_t)type;
    datagram[6] = (uint8_t)direction;
    datagram[7] = 0;
    write_u64_be(datagram + 8, session_id);
    write_u64_be(datagram + 16, sequence);
    write_u16_be(datagram + 24, (uint16_t)payload_length);
    datagram[26] = 0;
    datagram[27] = 0;
    if (payload_length)
        memcpy(datagram + MQVPN_RELAY_HEADER_SIZE, payload, payload_length);

    uint8_t tag[32];
    mqvpn_relay_result_t result =
        make_tag(key, datagram, MQVPN_RELAY_HEADER_SIZE + payload_length, tag);
    if (result == MQVPN_RELAY_OK) {
        memcpy(datagram + MQVPN_RELAY_HEADER_SIZE + payload_length, tag,
               MQVPN_RELAY_TAG_SIZE);
        *datagram_length = encoded_length;
    }
    OPENSSL_cleanse(tag, sizeof(tag));
    return result;
}

mqvpn_relay_result_t
mqvpn_relay_decode(const uint8_t key[MQVPN_RELAY_KEY_SIZE], const uint8_t *datagram,
                   size_t datagram_length, mqvpn_relay_direction_t expected_direction,
                   const uint64_t *expected_session, mqvpn_relay_frame_t *frame)
{
    if (!key || !datagram || !frame || !valid_direction(expected_direction)) {
        return MQVPN_RELAY_ERR_INVALID_ARGUMENT;
    }
    memset(frame, 0, sizeof(*frame));
    if (datagram_length < MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_TAG_SIZE)
        return MQVPN_RELAY_ERR_TRUNCATED;
    if (memcmp(datagram, relay_magic, sizeof(relay_magic)) != 0)
        return MQVPN_RELAY_ERR_BAD_MAGIC;
    if (datagram[4] != MQVPN_RELAY_VERSION) return MQVPN_RELAY_ERR_UNSUPPORTED_VERSION;
    mqvpn_relay_message_type_t type = (mqvpn_relay_message_type_t)datagram[5];
    if (!valid_type(type)) return MQVPN_RELAY_ERR_UNKNOWN_TYPE;
    mqvpn_relay_direction_t direction = (mqvpn_relay_direction_t)datagram[6];
    if (!valid_direction(direction)) return MQVPN_RELAY_ERR_INVALID_DIRECTION;
    if (datagram[7] != 0 || datagram[26] != 0 || datagram[27] != 0)
        return MQVPN_RELAY_ERR_NONZERO_RESERVED;

    /* An oversized datagram with an in-range payload_length field falls out
     * as LENGTH_MISMATCH below: expected_length is bounded by
     * MQVPN_RELAY_MAX_DATAGRAM_SIZE once payload_length passes this check. */
    size_t payload_length = read_u16_be(datagram + 24);
    if (payload_length > MQVPN_RELAY_MAX_PAYLOAD_SIZE)
        return MQVPN_RELAY_ERR_PAYLOAD_TOO_LARGE;
    const size_t expected_length =
        MQVPN_RELAY_HEADER_SIZE + payload_length + MQVPN_RELAY_TAG_SIZE;
    if (datagram_length != expected_length) return MQVPN_RELAY_ERR_LENGTH_MISMATCH;

    uint8_t tag[32];
    mqvpn_relay_result_t result =
        make_tag(key, datagram, MQVPN_RELAY_HEADER_SIZE + payload_length, tag);
    if (result != MQVPN_RELAY_OK) {
        OPENSSL_cleanse(tag, sizeof(tag));
        return result;
    }
    const uint8_t *received_tag = datagram + MQVPN_RELAY_HEADER_SIZE + payload_length;
    if (CRYPTO_memcmp(tag, received_tag, MQVPN_RELAY_TAG_SIZE) != 0) {
        OPENSSL_cleanse(tag, sizeof(tag));
        return MQVPN_RELAY_ERR_AUTH_FAILED;
    }
    OPENSSL_cleanse(tag, sizeof(tag));

    uint64_t session_id = read_u64_be(datagram + 8);
    if (direction != expected_direction) return MQVPN_RELAY_ERR_WRONG_DIRECTION;
    if (expected_session && session_id != *expected_session)
        return MQVPN_RELAY_ERR_WRONG_SESSION;

    frame->type = type;
    frame->direction = direction;
    frame->session_id = session_id;
    frame->sequence = read_u64_be(datagram + 16);
    frame->payload = datagram + MQVPN_RELAY_HEADER_SIZE;
    frame->payload_length = payload_length;
    return MQVPN_RELAY_OK;
}

mqvpn_relay_result_t
mqvpn_replay_window_accept(mqvpn_replay_window_t *window, uint64_t sequence)
{
    if (!window) return MQVPN_RELAY_ERR_INVALID_ARGUMENT;
    if (!window->initialized) {
        window->highest_sequence = sequence;
        window->received_bitmap = UINT64_C(1);
        window->initialized = 1;
        return MQVPN_RELAY_OK;
    }
    if (sequence > window->highest_sequence) {
        uint64_t advance = sequence - window->highest_sequence;
        if (advance >= 64) {
            window->received_bitmap = UINT64_C(1);
        } else {
            window->received_bitmap = (window->received_bitmap << advance) | UINT64_C(1);
        }
        window->highest_sequence = sequence;
        return MQVPN_RELAY_OK;
    }

    uint64_t age = window->highest_sequence - sequence;
    if (age >= 64) return MQVPN_RELAY_ERR_REPLAY;
    uint64_t sequence_bit = UINT64_C(1) << age;
    if (window->received_bitmap & sequence_bit) return MQVPN_RELAY_ERR_REPLAY;
    window->received_bitmap |= sequence_bit;
    return MQVPN_RELAY_OK;
}
