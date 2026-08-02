// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

#define _GNU_SOURCE    /* sendmmsg / struct mmsghdr — see src/udp_offload.c header \
                          comment; must precede every #include, same as there. */
/* Keep assert() live even in Release builds: CI runs ctest on Release too,
 * where NDEBUG would silently no-op every assertion in this file. */
#undef NDEBUG
#include <assert.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/udp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include "udp_offload.h"

#ifndef UDP_SEGMENT
#  define UDP_SEGMENT 103
#endif

static struct iovec
iv(size_t len)
{
    struct iovec v = {(void *)"", len};
    return v;
}

static void
test_run_len(void)
{
    struct iovec a[5];
    /* uniform: all one run */
    for (int i = 0; i < 5; i++)
        a[i] = iv(1400);
    assert(mqvpn_gso_run_len(a, 5) == 5);
    /* trailing short joins the run */
    a[4] = iv(200);
    assert(mqvpn_gso_run_len(a, 5) == 5);
    /* short then more: short closes the run */
    a[2] = iv(200);
    assert(mqvpn_gso_run_len(a, 5) == 3); /* 1400,1400,200 */
    /* larger datagram never joins */
    a[0] = iv(1400);
    a[1] = iv(1500);
    assert(mqvpn_gso_run_len(a, 2) == 1);
    /* single */
    assert(mqvpn_gso_run_len(a, 1) == 1);
    /* 32-cap (XQC_MAX_SEND_MSG_ONCE): a full uniform burst is one run */
    {
        struct iovec b[32];
        for (int i = 0; i < 32; i++)
            b[i] = iv(1400);
        assert(mqvpn_gso_run_len(b, 32) == 32);
    }
    /* two consecutive shorts: second short starts the next run */
    {
        struct iovec c[3];
        c[0] = iv(1400);
        c[1] = iv(200);
        c[2] = iv(200);
        assert(mqvpn_gso_run_len(c, 3) == 2);
    }
    /* short at position 1, cnt=2: one run (short tail) */
    {
        struct iovec d[2];
        d[0] = iv(1400);
        d[1] = iv(200);
        assert(mqvpn_gso_run_len(d, 2) == 2);
    }
    printf("test_run_len OK\n");
}

static void
test_probe(void)
{
    /* The probe uses a real socket — not seam-interceptable — so this
     * asserts only the result SHAPE, never a kernel capability: a valid
     * old-kernel/seccomp environment must not fail the suite. */
    int r = mqvpn_udp_gso_probe();
    assert(r == 0 || r == 1);
    if (!r) printf("note: kernel lacks UDP_SEGMENT; GSO paths covered via seam\n");
    printf("test_probe OK\n");
}

int
main(void)
{
    test_run_len();
    test_probe();
    return 0;
}
