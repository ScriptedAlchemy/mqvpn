// SPDX-License-Identifier: Apache-2.0
#ifndef MQVPN_PATH_METRICS_SELECTION_H
#define MQVPN_PATH_METRICS_SELECTION_H

#include "mqvpn_internal.h"
#include <xquic/xquic.h>

/* xquic retains closed paths across migrations. A bounded status snapshot
 * must show current paths first; otherwise historical entries hide the
 * replacement paths and their scheduler weights. Preserve order within each
 * tier, retaining historical entries only when there is room. */
static inline size_t
mqvpn_select_path_metrics(const xqc_path_metrics_t *paths, size_t count,
                           size_t *indices, size_t capacity)
{
    size_t n = 0;
    if (!paths || !indices) return 0;
    for (int tier = 0; tier < 3 && n < capacity; tier++) {
        for (size_t i = 0; i < count && n < capacity; i++) {
            unsigned state = paths[i].path_state;
            int rank = 2;
            if (state == MQVPN_XQC_PATH_STATE_ACTIVE) rank = 0;
            else if (state < MQVPN_XQC_PATH_STATE_ACTIVE) rank = 1;
            if (rank == tier) indices[n++] = i;
        }
    }
    return n;
}

#endif
