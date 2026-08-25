// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#include "performance_mode.h"

#include <ctype.h>
#include <string.h>

const char *
mqvpn_performance_mode_name(mqvpn_performance_mode_t mode)
{
    switch (mode) {
    case MQVPN_PERF_MAX_THROUGHPUT:
        return MQVPN_PERFORMANCE_THROUGHPUT;
    case MQVPN_PERF_LOW_LATENCY:
        return MQVPN_PERFORMANCE_LATENCY;
    }
    return NULL;
}

int
mqvpn_performance_mode_parse(const char *text, size_t len, mqvpn_performance_mode_t *out)
{
    if (!text || !out || len == 0) return MQVPN_ERR_INVALID_ARG;

    if (len == strlen(MQVPN_PERFORMANCE_THROUGHPUT)) {
        int match = 1;
        for (size_t i = 0; i < len; i++) {
            if (tolower((unsigned char)text[i]) !=
                (unsigned char)MQVPN_PERFORMANCE_THROUGHPUT[i]) {
                match = 0;
                break;
            }
        }
        if (match) {
            *out = MQVPN_PERF_MAX_THROUGHPUT;
            return MQVPN_OK;
        }
    }

    if (len == strlen(MQVPN_PERFORMANCE_LATENCY)) {
        int match = 1;
        for (size_t i = 0; i < len; i++) {
            if (tolower((unsigned char)text[i]) !=
                (unsigned char)MQVPN_PERFORMANCE_LATENCY[i]) {
                match = 0;
                break;
            }
        }
        if (match) {
            *out = MQVPN_PERF_LOW_LATENCY;
            return MQVPN_OK;
        }
    }

    return MQVPN_ERR_INVALID_ARG;
}

int
mqvpn_performance_header_match(const void *name, size_t name_len, const void *value,
                               size_t value_len, mqvpn_performance_mode_t *out)
{
    static const char hdr[] = MQVPN_PERFORMANCE_HDR_NAME;
    if (!name || !value || !out) return 0;
    if (name_len != sizeof(hdr) - 1) return 0;
    if (memcmp(name, hdr, sizeof(hdr) - 1) != 0) return 0;
    if (mqvpn_performance_mode_parse((const char *)value, value_len, out) != MQVPN_OK) {
        *out = MQVPN_PERF_MAX_THROUGHPUT;
    }
    return 1;
}
