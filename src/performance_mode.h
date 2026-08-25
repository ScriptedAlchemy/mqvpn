// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#ifndef MQVPN_PERFORMANCE_MODE_H
#define MQVPN_PERFORMANCE_MODE_H

#include "libmqvpn.h"

#include <stddef.h>

#define MQVPN_PERFORMANCE_HDR_NAME "mqvpn-performance"
#define MQVPN_PERFORMANCE_THROUGHPUT "throughput"
#define MQVPN_PERFORMANCE_LATENCY "latency"

const char *mqvpn_performance_mode_name(mqvpn_performance_mode_t mode);
int mqvpn_performance_mode_parse(const char *text, size_t len,
                                 mqvpn_performance_mode_t *out);
int mqvpn_performance_header_match(const void *name, size_t name_len,
                                   const void *value, size_t value_len,
                                   mqvpn_performance_mode_t *out);

#endif /* MQVPN_PERFORMANCE_MODE_H */
