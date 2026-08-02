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

#  include <errno.h>
#  include <netinet/in.h>
#  include <netinet/udp.h>
#  include <string.h>
#  include <unistd.h>

#  ifndef UDP_SEGMENT
#    define UDP_SEGMENT 103 /* old glibc headers; value from linux/udp.h UAPI */
#  endif

#  ifdef MQVPN_OFFLOAD_TEST_SEAM
/* Fault-injection seam for unit tests: tests provide these symbols. */
ssize_t mqvpn_seam_sendmsg(int fd, const struct msghdr *msg, int flags);
int mqvpn_seam_sendmmsg(int fd, struct mmsghdr *msgvec, unsigned int vlen, int flags);
#    define OFFLOAD_SENDMSG  mqvpn_seam_sendmsg
#    define OFFLOAD_SENDMMSG mqvpn_seam_sendmmsg
#  else
#    define OFFLOAD_SENDMSG  sendmsg
#    define OFFLOAD_SENDMMSG sendmmsg
#  endif

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

/* Stateless capability probe: does the kernel accept UDP_SEGMENT? Uses a
 * real socket — not seam-interceptable — since it tests an actual kernel
 * property, not a fault-injection scenario. */
int
mqvpn_udp_gso_probe(void)
{
    int fd = (int)socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;
    int zero = 0;
    int ok = setsockopt(fd, SOL_UDP, UDP_SEGMENT, &zero, sizeof(zero)) == 0;
    close(fd);
    return ok;
}

#endif
