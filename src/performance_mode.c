// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#include "performance_mode.h"

#include <ctype.h>
#include <string.h>

const char *
mqvpn_performance_to_name(mqvpn_performance_mode_t mode)
{
    switch (mode) {
    case MQVPN_PERF_MAX_THROUGHPUT: return MQVPN_PERFORMANCE_THROUGHPUT;
    case MQVPN_PERF_LOW_LATENCY: return MQVPN_PERFORMANCE_LATENCY;
    }
    return "unknown";
}

int
mqvpn_performance_from_name(const char *text, size_t len, mqvpn_performance_mode_t *out)
{
    static const struct {
        const char *name;
        mqvpn_performance_mode_t mode;
    } modes[] = {
        {MQVPN_PERFORMANCE_THROUGHPUT, MQVPN_PERF_MAX_THROUGHPUT},
        {MQVPN_PERFORMANCE_LATENCY, MQVPN_PERF_LOW_LATENCY},
    };

    if (!text || !out || len == 0) return MQVPN_ERR_INVALID_ARG;

    for (size_t m = 0; m < sizeof(modes) / sizeof(modes[0]); m++) {
        size_t name_len = strlen(modes[m].name);
        if (len != name_len) continue;
        size_t i = 0;
        while (i < len &&
               tolower((unsigned char)text[i]) == (unsigned char)modes[m].name[i]) {
            i++;
        }
        if (i == len) {
            *out = modes[m].mode;
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
    if (mqvpn_performance_from_name((const char *)value, value_len, out) != MQVPN_OK) {
        *out = MQVPN_PERF_MAX_THROUGHPUT;
    }
    return 1;
}
