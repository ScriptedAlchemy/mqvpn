// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#include "mqvpn/relay_protocol.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

static const uint8_t test_key[MQVPN_RELAY_KEY_SIZE] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
    0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
    0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
};

static const uint64_t test_session = UINT64_C(0x0102030405060708);
static const uint64_t test_sequence = UINT64_C(0x1112131415161718);

static size_t
encode_frame(uint8_t *datagram, size_t capacity, mqvpn_relay_message_type_t type,
             mqvpn_relay_direction_t direction, uint64_t session, uint64_t sequence,
             const uint8_t *payload, size_t payload_length)
{
    size_t datagram_length = 0;
    CHECK(mqvpn_relay_encode(test_key, type, direction, session, sequence, payload,
                             payload_length, datagram, capacity,
                             &datagram_length) == MQVPN_RELAY_OK);
    return datagram_length;
}

TEST(golden_empty_hello_vector)
{
    static const uint8_t expected[] = {
        0x4d, 0x51, 0x52, 0x31, 0x01, 0x01, 0x00, 0x00, 0x01, 0x02, 0x03,
        0x04, 0x05, 0x06, 0x07, 0x08, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16,
        0x17, 0x18, 0x00, 0x00, 0x00, 0x00, 0x33, 0xb3, 0x6c, 0x94, 0x98,
        0x5f, 0x6f, 0x08, 0x72, 0x2c, 0xa9, 0x41, 0x51, 0xd7, 0x7b, 0x4b,
    };
    uint8_t datagram[sizeof(expected)];
    size_t length =
        encode_frame(datagram, sizeof(datagram), MQVPN_RELAY_HELLO,
                     MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, NULL, 0);

    CHECK(length == sizeof(expected));
    CHECK(memcmp(datagram, expected, sizeof(expected)) == 0);
}

TEST(round_trips_every_type_in_both_directions)
{
    static const mqvpn_relay_message_type_t types[] = {
        MQVPN_RELAY_HELLO,       MQVPN_RELAY_HELLO_ACK, MQVPN_RELAY_DATA_TO_SERVER,
        MQVPN_RELAY_DATA_TO_MAC, MQVPN_RELAY_KEEPALIVE,
    };
    static const mqvpn_relay_direction_t directions[] = {
        MQVPN_RELAY_MAC_TO_IPHONE,
        MQVPN_RELAY_IPHONE_TO_MAC,
    };
    static const uint8_t data_payload[] = {0xde, 0xad, 0xbe, 0xef};
    uint8_t
        datagram[MQVPN_RELAY_HEADER_SIZE + sizeof(data_payload) + MQVPN_RELAY_TAG_SIZE];

    for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
        for (size_t j = 0; j < sizeof(directions) / sizeof(directions[0]); j++) {
            const uint8_t *payload = NULL;
            size_t payload_length = 0;
            if (types[i] == MQVPN_RELAY_DATA_TO_SERVER ||
                types[i] == MQVPN_RELAY_DATA_TO_MAC) {
                payload = data_payload;
                payload_length = sizeof(data_payload);
            }
            size_t length = encode_frame(datagram, sizeof(datagram), types[i],
                                         directions[j], test_session,
                                         test_sequence + i + j, payload, payload_length);
            CHECK(datagram[5] == (uint8_t)types[i]);
            CHECK(datagram[6] == (uint8_t)directions[j]);

            mqvpn_relay_frame_t decoded;
            CHECK(mqvpn_relay_decode(test_key, datagram, length, directions[j],
                                     &test_session, &decoded) == MQVPN_RELAY_OK);
            CHECK(decoded.type == types[i]);
            CHECK(decoded.direction == directions[j]);
            CHECK(decoded.session_id == test_session);
            CHECK(decoded.sequence == test_sequence + i + j);
            CHECK(decoded.payload_length == payload_length);
            if (payload_length != 0) {
                CHECK(memcmp(decoded.payload, payload, payload_length) == 0);
            }
        }
    }
}

TEST(round_trips_maximum_payload)
{
    uint8_t *payload = malloc(MQVPN_RELAY_MAX_PAYLOAD_SIZE);
    uint8_t *datagram = malloc(MQVPN_RELAY_MAX_DATAGRAM_SIZE);
    CHECK(payload != NULL);
    CHECK(datagram != NULL);
    for (size_t i = 0; i < MQVPN_RELAY_MAX_PAYLOAD_SIZE; i++) {
        payload[i] = (uint8_t)(i * 17u + 3u);
    }

    size_t length =
        encode_frame(datagram, MQVPN_RELAY_MAX_DATAGRAM_SIZE, MQVPN_RELAY_DATA_TO_SERVER,
                     MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, payload,
                     MQVPN_RELAY_MAX_PAYLOAD_SIZE);
    CHECK(length == MQVPN_RELAY_MAX_DATAGRAM_SIZE);

    mqvpn_relay_frame_t decoded;
    CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE,
                             &test_session, &decoded) == MQVPN_RELAY_OK);
    CHECK(decoded.payload_length == MQVPN_RELAY_MAX_PAYLOAD_SIZE);
    CHECK(memcmp(decoded.payload, payload, MQVPN_RELAY_MAX_PAYLOAD_SIZE) == 0);

    free(datagram);
    free(payload);
}

TEST(rejects_payload_over_udp_datagram_bound)
{
    uint8_t *payload = calloc(MQVPN_RELAY_MAX_PAYLOAD_SIZE + 1u, 1u);
    uint8_t *datagram = calloc(MQVPN_RELAY_MAX_DATAGRAM_SIZE + 1u, 1u);
    size_t length = 99;
    CHECK(payload != NULL);
    CHECK(datagram != NULL);
    CHECK(mqvpn_relay_encode(test_key, MQVPN_RELAY_DATA_TO_SERVER,
                             MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence,
                             payload, MQVPN_RELAY_MAX_PAYLOAD_SIZE + 1u, datagram,
                             MQVPN_RELAY_MAX_DATAGRAM_SIZE + 1u,
                             &length) == MQVPN_RELAY_ERR_PAYLOAD_TOO_LARGE);
    CHECK(length == 0);

    length =
        encode_frame(datagram, MQVPN_RELAY_MAX_DATAGRAM_SIZE, MQVPN_RELAY_DATA_TO_SERVER,
                     MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, payload,
                     MQVPN_RELAY_MAX_PAYLOAD_SIZE);
    datagram[24] = (uint8_t)((MQVPN_RELAY_MAX_PAYLOAD_SIZE + 1u) >> 8);
    datagram[25] = (uint8_t)(MQVPN_RELAY_MAX_PAYLOAD_SIZE + 1u);
    mqvpn_relay_frame_t decoded;
    CHECK(mqvpn_relay_decode(test_key, datagram, length + 1u, MQVPN_RELAY_MAC_TO_IPHONE,
                             &test_session,
                             &decoded) == MQVPN_RELAY_ERR_PAYLOAD_TOO_LARGE);

    free(datagram);
    free(payload);
}

TEST(rejects_every_truncated_empty_frame_length)
{
    uint8_t datagram[MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_TAG_SIZE];
    size_t length =
        encode_frame(datagram, sizeof(datagram), MQVPN_RELAY_HELLO,
                     MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, NULL, 0);
    CHECK(length == sizeof(datagram));

    for (size_t truncated = 0; truncated < length; truncated++) {
        mqvpn_relay_frame_t decoded;
        CHECK(mqvpn_relay_decode(test_key, datagram, truncated, MQVPN_RELAY_MAC_TO_IPHONE,
                                 &test_session, &decoded) == MQVPN_RELAY_ERR_TRUNCATED);
    }
}

TEST(rejects_nonzero_reserved_fields)
{
    static const size_t reserved_offsets[] = {7, 26, 27};
    uint8_t datagram[MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_TAG_SIZE];

    for (size_t i = 0; i < sizeof(reserved_offsets) / sizeof(reserved_offsets[0]); i++) {
        size_t length =
            encode_frame(datagram, sizeof(datagram), MQVPN_RELAY_HELLO,
                         MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, NULL, 0);
        datagram[reserved_offsets[i]] = 1;
        mqvpn_relay_frame_t decoded;
        CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE,
                                 &test_session,
                                 &decoded) == MQVPN_RELAY_ERR_NONZERO_RESERVED);
    }
}

TEST(rejects_bad_magic_version_type_and_direction)
{
    static const struct {
        size_t offset;
        uint8_t value;
        mqvpn_relay_result_t result;
    } mutations[] = {
        {0, 0, MQVPN_RELAY_ERR_BAD_MAGIC},
        {4, 2, MQVPN_RELAY_ERR_UNSUPPORTED_VERSION},
        {5, 0, MQVPN_RELAY_ERR_UNKNOWN_TYPE},
        {5, 6, MQVPN_RELAY_ERR_UNKNOWN_TYPE},
        {6, 2, MQVPN_RELAY_ERR_INVALID_DIRECTION},
    };
    uint8_t datagram[MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_TAG_SIZE];

    for (size_t i = 0; i < sizeof(mutations) / sizeof(mutations[0]); i++) {
        size_t length =
            encode_frame(datagram, sizeof(datagram), MQVPN_RELAY_HELLO,
                         MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, NULL, 0);
        datagram[mutations[i].offset] = mutations[i].value;
        mqvpn_relay_frame_t decoded;
        CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE,
                                 &test_session, &decoded) == mutations[i].result);
    }
}

TEST(rejects_payload_length_mismatch)
{
    uint8_t datagram[MQVPN_RELAY_HEADER_SIZE + 1 + MQVPN_RELAY_TAG_SIZE];
    static const uint8_t payload = 0xa5;
    size_t length =
        encode_frame(datagram, sizeof(datagram), MQVPN_RELAY_DATA_TO_SERVER,
                     MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, &payload, 1);
    datagram[25] = 2;

    mqvpn_relay_frame_t decoded;
    CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE,
                             &test_session, &decoded) == MQVPN_RELAY_ERR_LENGTH_MISMATCH);
}

TEST(rejects_corrupt_tag_and_wrong_key)
{
    uint8_t datagram[MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_TAG_SIZE];
    size_t length =
        encode_frame(datagram, sizeof(datagram), MQVPN_RELAY_HELLO,
                     MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, NULL, 0);
    mqvpn_relay_frame_t decoded;

    datagram[length - 1] ^= 1;
    CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE,
                             &test_session, &decoded) == MQVPN_RELAY_ERR_AUTH_FAILED);
    datagram[length - 1] ^= 1;

    uint8_t wrong_key[MQVPN_RELAY_KEY_SIZE];
    memcpy(wrong_key, test_key, sizeof(wrong_key));
    wrong_key[0] ^= 1;
    CHECK(mqvpn_relay_decode(wrong_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE,
                             &test_session, &decoded) == MQVPN_RELAY_ERR_AUTH_FAILED);
}

TEST(rejects_authenticated_wrong_direction_and_session)
{
    uint8_t datagram[MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_TAG_SIZE];
    size_t length =
        encode_frame(datagram, sizeof(datagram), MQVPN_RELAY_HELLO,
                     MQVPN_RELAY_MAC_TO_IPHONE, test_session, test_sequence, NULL, 0);
    mqvpn_relay_frame_t decoded;
    uint64_t other_session = test_session + 1;

    CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_IPHONE_TO_MAC,
                             &test_session, &decoded) == MQVPN_RELAY_ERR_WRONG_DIRECTION);
    CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE,
                             &other_session, &decoded) == MQVPN_RELAY_ERR_WRONG_SESSION);
    CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE, NULL,
                             &decoded) == MQVPN_RELAY_OK);
}

TEST(rejects_invalid_arguments_and_small_output)
{
    uint8_t datagram[MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_TAG_SIZE];
    size_t length = 77;
    mqvpn_relay_frame_t decoded;

    CHECK(mqvpn_relay_encode(NULL, MQVPN_RELAY_HELLO, MQVPN_RELAY_MAC_TO_IPHONE,
                             test_session, test_sequence, NULL, 0, datagram,
                             sizeof(datagram),
                             &length) == MQVPN_RELAY_ERR_INVALID_ARGUMENT);
    CHECK(length == 0);
    CHECK(mqvpn_relay_encode(test_key, MQVPN_RELAY_HELLO, MQVPN_RELAY_MAC_TO_IPHONE,
                             test_session, test_sequence, NULL, 0, datagram,
                             sizeof(datagram) - 1,
                             &length) == MQVPN_RELAY_ERR_OUTPUT_TOO_SMALL);
    CHECK(length == 0);
    CHECK(mqvpn_relay_encode(test_key, MQVPN_RELAY_HELLO, MQVPN_RELAY_MAC_TO_IPHONE,
                             test_session, test_sequence, NULL, 1, datagram,
                             sizeof(datagram),
                             &length) == MQVPN_RELAY_ERR_INVALID_ARGUMENT);
    CHECK(mqvpn_relay_encode(test_key, MQVPN_RELAY_HELLO, MQVPN_RELAY_MAC_TO_IPHONE,
                             test_session, test_sequence, NULL, 0, datagram,
                             sizeof(datagram), &length) == MQVPN_RELAY_OK);
    CHECK(mqvpn_relay_decode(NULL, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE, NULL,
                             &decoded) == MQVPN_RELAY_ERR_INVALID_ARGUMENT);
    CHECK(mqvpn_relay_decode(test_key, NULL, length, MQVPN_RELAY_MAC_TO_IPHONE, NULL,
                             &decoded) == MQVPN_RELAY_ERR_INVALID_ARGUMENT);
    CHECK(mqvpn_relay_decode(test_key, datagram, length, MQVPN_RELAY_MAC_TO_IPHONE, NULL,
                             NULL) == MQVPN_RELAY_ERR_INVALID_ARGUMENT);
}

TEST(replay_window_rejects_duplicate_and_too_old_sequence)
{
    mqvpn_replay_window_t window = {0};

    CHECK(mqvpn_replay_window_accept(&window, 100) == MQVPN_RELAY_OK);
    CHECK(mqvpn_replay_window_accept(&window, 100) == MQVPN_RELAY_ERR_REPLAY);
    CHECK(mqvpn_replay_window_accept(&window, 36) == MQVPN_RELAY_ERR_REPLAY);
    CHECK(mqvpn_replay_window_accept(&window, 35) == MQVPN_RELAY_ERR_REPLAY);
}

TEST(replay_window_accepts_in_window_reordering_once)
{
    mqvpn_replay_window_t window = {0};

    CHECK(mqvpn_replay_window_accept(&window, 100) == MQVPN_RELAY_OK);
    CHECK(mqvpn_replay_window_accept(&window, 98) == MQVPN_RELAY_OK);
    CHECK(mqvpn_replay_window_accept(&window, 99) == MQVPN_RELAY_OK);
    CHECK(mqvpn_replay_window_accept(&window, 98) == MQVPN_RELAY_ERR_REPLAY);
    CHECK(mqvpn_replay_window_accept(&window, 164) == MQVPN_RELAY_OK);
    CHECK(mqvpn_replay_window_accept(&window, 101) == MQVPN_RELAY_OK);
    CHECK(mqvpn_replay_window_accept(&window, 100) == MQVPN_RELAY_ERR_REPLAY);
}

TEST(replay_windows_are_independent)
{
    mqvpn_replay_window_t mac_to_iphone = {0};
    mqvpn_replay_window_t iphone_to_mac = {0};

    CHECK(mqvpn_replay_window_accept(&mac_to_iphone, 7) == MQVPN_RELAY_OK);
    CHECK(mqvpn_replay_window_accept(&iphone_to_mac, 7) == MQVPN_RELAY_OK);
    CHECK(mqvpn_replay_window_accept(&mac_to_iphone, 7) == MQVPN_RELAY_ERR_REPLAY);
    CHECK(mqvpn_replay_window_accept(&iphone_to_mac, 7) == MQVPN_RELAY_ERR_REPLAY);
}

TEST(replay_window_rejects_null_state)
{
    CHECK(mqvpn_replay_window_accept(NULL, 1) == MQVPN_RELAY_ERR_INVALID_ARGUMENT);
}

int
main(void)
{
    puts("relay protocol tests:");
    run_golden_empty_hello_vector();
    run_round_trips_every_type_in_both_directions();
    run_round_trips_maximum_payload();
    run_rejects_payload_over_udp_datagram_bound();
    run_rejects_every_truncated_empty_frame_length();
    run_rejects_nonzero_reserved_fields();
    run_rejects_bad_magic_version_type_and_direction();
    run_rejects_payload_length_mismatch();
    run_rejects_corrupt_tag_and_wrong_key();
    run_rejects_authenticated_wrong_direction_and_session();
    run_rejects_invalid_arguments_and_small_output();
    run_replay_window_rejects_duplicate_and_too_old_sequence();
    run_replay_window_accepts_in_window_reordering_once();
    run_replay_windows_are_independent();
    run_replay_window_rejects_null_state();
    printf("relay protocol tests: %d/%d PASS\n", tests_run, tests_run);
    return 0;
}
