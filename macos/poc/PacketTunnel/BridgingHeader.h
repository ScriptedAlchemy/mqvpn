// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#ifndef MQVPN_MAC_POC_BRIDGING_H
#define MQVPN_MAC_POC_BRIDGING_H
#include <libmqvpn.h>
#include <mqvpn/relay_protocol.h>
#include "mqvpn_clock_shim.h"

#include "reorder.h"
int mqvpn_client_get_reorder_stats(const mqvpn_client_t *c, mqvpn_reorder_stats_t *out);
uint64_t mqvpn_ext_reorder_layout_id(void);

#endif
