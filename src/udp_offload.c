// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#define _GNU_SOURCE    /* sendmmsg / struct mmsghdr — glibc exposes them only \
                          under _GNU_SOURCE, and no target in this repo defines \
                          it. Must precede every #include (comments above are   \
                          fine; same ordering in the test file). */
#include "udp_offload.h"
#if defined(__linux__)
/* implementation added by Tasks 2-4 — ALL of it, includes included, goes
 * inside this __linux__ block (netinet/udp.h etc. do not exist on
 * Windows/macOS, and the Windows compile is those files' only CI gate). */

size_t
mqvpn_gso_run_len(const struct iovec *iov, size_t cnt)
{
    size_t seg = iov[0].iov_len;
    for (size_t i = 1; i < cnt; i++) {
        if (iov[i].iov_len == seg) continue;
        if (iov[i].iov_len < seg) return i + 1; /* short tail closes the run */
        return i;                               /* larger starts a new run */
    }
    return cnt;
}

#endif
