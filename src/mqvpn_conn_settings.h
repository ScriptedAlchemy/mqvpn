// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/*
 * mqvpn_conn_settings.h — single source of truth for mqvpn's xquic
 * connection settings construction. To add a knob, extend the input
 * struct, the helper body, and tests/test_conn_settings.c in lock-step.
 */

#ifndef MQVPN_CONN_SETTINGS_H
#define MQVPN_CONN_SETTINGS_H

#include "mqvpn_internal.h"
#include <stdbool.h>
#include <stdint.h>
#include <xquic/xquic.h>

/* Caller-driven inputs. The bools are parameterised (not a single
 * `is_server` flag) so each call site documents its intent. */
typedef struct {
    bool is_server;
    bool enable_multipath; /* server callers pass true */
    mqvpn_scheduler_t scheduler;
    mqvpn_cc_t cc;                     /* congestion control algorithm */
    uint64_t init_max_path_id;         /* 0 = leave xquic default */
    uint64_t recv_rate_bytes_per_sec;  /* 0 = no cap. Client-only: the
         builder hard-zeroes it for servers (a server-side conn-level cap
         would throttle client uplink). */
    mqvpn_reinjection_t reinjection;   /* MQVPN_REINJ_OFF = feature disabled */
    int reinj_srtt_factor_pct;         /* deadline mode; 0 = engine default (110).
         The config layer validates this to [100,1000] and never passes 0
         through, so 0 can only arrive via a direct API caller bypassing
         config parsing. */
    int reinj_hard_deadline_ms;        /* deadline mode; 0 = engine default (500).
         Same 0-only-via-direct-API-caller note as reinj_srtt_factor_pct
         (config layer validates [1,60000] and never passes 0 through). */
    int reinj_deadline_lower_bound_ms; /* deadline mode; 0 = engine default (20).
         Same 0-only-via-direct-API-caller note as reinj_srtt_factor_pct
         (config layer validates [1,60000] and never passes 0 through). */
} mqvpn_conn_settings_input_t;

/* Populates *out with mqvpn-canonical xquic conn settings. Always begins
 * with memset(0), so the caller is not required to zero `out` first. */
MQVPN_INTERNAL void mqvpn_build_conn_settings(const mqvpn_conn_settings_input_t *in,
                                              xqc_conn_settings_t *out);

#endif /* MQVPN_CONN_SETTINGS_H */
