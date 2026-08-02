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

/* --- seam control -------------------------------------------------- */
static int seam_fail_call; /* 1-based syscall index to fail; 0 = never */
static int seam_fail_errno;
static int seam_mmsg_partial; /* if >0, sendmmsg reports only this many */
static int seam_calls;
static char seam_ops[64];     /* op trace: 'm' = sendmsg, 'M' = sendmmsg
                                 (64 > worst case: 32 single-datagram runs) */
static int seam_last_was_gso; /* last sendmsg carried a VALID UDP_SEGMENT cmsg */
static uint16_t seam_last_seg;
static size_t seam_bytes;

ssize_t
mqvpn_seam_sendmsg(int fd, const struct msghdr *msg, int flags)
{
    (void)fd;
    assert(flags & MSG_DONTWAIT);
    seam_ops[seam_calls++] = 'm';
    seam_last_was_gso = 0;
    if (msg->msg_controllen != 0) {
        /* full TX cmsg ABI check: level/type/exact len/payload value */
        struct cmsghdr *cm = CMSG_FIRSTHDR((struct msghdr *)msg);
        assert(cm != NULL);
        assert(cm->cmsg_level == SOL_UDP);
        assert(cm->cmsg_type == UDP_SEGMENT);
        assert(cm->cmsg_len == CMSG_LEN(sizeof(uint16_t)));
        memcpy(&seam_last_seg, CMSG_DATA(cm), sizeof(seam_last_seg));
        assert(seam_last_seg == msg->msg_iov[0].iov_len);
        seam_last_was_gso = 1;
    }
    if (seam_fail_call == seam_calls) {
        errno = seam_fail_errno;
        return -1;
    }
    size_t n = 0;
    for (size_t i = 0; i < msg->msg_iovlen; i++)
        n += msg->msg_iov[i].iov_len;
    seam_bytes += n;
    return (ssize_t)n;
}
int
mqvpn_seam_sendmmsg(int fd, struct mmsghdr *mv, unsigned int vlen, int flags)
{
    (void)fd;
    assert(flags & MSG_DONTWAIT);
    seam_ops[seam_calls++] = 'M';
    if (seam_fail_call == seam_calls) {
        errno = seam_fail_errno;
        return -1;
    }
    unsigned int n = seam_mmsg_partial ? (unsigned)seam_mmsg_partial : vlen;
    for (unsigned int i = 0; i < n; i++) {
        mv[i].msg_len = (unsigned)mv[i].msg_hdr.msg_iov[0].iov_len;
        seam_bytes += mv[i].msg_len;
    }
    return (int)n;
}
static void
seam_reset(void)
{
    memset(seam_ops, 0, sizeof(seam_ops));
    seam_fail_call = seam_fail_errno = seam_mmsg_partial = 0;
    seam_calls = seam_last_was_gso = 0;
    seam_last_seg = 0;
    seam_bytes = 0;
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

/* --- mqvpn_udp_send_batch cases ------------------------------------- */

static void
test_gso_full_burst(void)
{
    seam_reset();
    struct iovec iov[9] = {iv(1400), iv(1400), iv(1400), iv(1400), iv(1400),
                           iv(1400), iv(1400), iv(1400), iv(300)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 9, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == 9);
    assert(seam_calls == 1);
    assert(seam_ops[0] == 'm');
    assert(seam_last_was_gso == 1);
    assert(seam_last_seg == 1400);
    assert(bytes == 8 * 1400u + 300u);
    printf("test_gso_full_burst OK\n");
}

static void
test_gso_single_skips_cmsg(void)
{
    seam_reset();
    struct iovec iov[1] = {iv(1400)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 1, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == 1);
    assert(seam_calls == 1);
    assert(seam_ops[0] == 'm');
    assert(seam_last_was_gso == 0);
    printf("test_gso_single_skips_cmsg OK\n");
}

static void
test_mixed_runs(void)
{
    seam_reset();
    struct iovec iov[4] = {iv(1400), iv(1400), iv(200), iv(1400)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 4, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == 4);
    assert(seam_calls == 2);
    assert(seam_ops[0] == 'm' && seam_ops[1] == 'm');
    printf("test_mixed_runs OK\n");
}

static void
test_fallback_sendmmsg(void)
{
    seam_reset();
    struct iovec iov[3] = {iv(1400), iv(1400), iv(1400)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 3, (struct sockaddr *)&peer, sizeof peer, 0,
                                     &sticky, &bytes);
    assert(r == 3);
    assert(seam_calls == 1);
    assert(seam_ops[0] == 'M');
    printf("test_fallback_sendmmsg OK\n");
}

static void
test_gso_error_zero_sent_resends(void)
{
    seam_reset();
    struct iovec iov[4] = {iv(1400), iv(1400), iv(1400), iv(1400)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    seam_fail_call = 1;
    seam_fail_errno = EIO;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 4, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == 4);
    assert(sticky == 1);
    assert(seam_ops[0] == 'm' && seam_ops[1] == 'M');
    printf("test_gso_error_zero_sent_resends OK\n");
}

static void
test_gso_error_after_progress_stops(void)
{
    seam_reset();
    struct iovec iov[4] = {iv(1400), iv(1400), iv(1500), iv(1500)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    seam_fail_call = 2;
    seam_fail_errno = EIO;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 4, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == 2);
    assert(sticky == 1);
    assert(seam_calls == 2);
    printf("test_gso_error_after_progress_stops OK\n");
}

static void
test_eagain_first(void)
{
    seam_reset();
    struct iovec iov[2] = {iv(1400), iv(1400)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    seam_fail_call = 1;
    seam_fail_errno = EAGAIN;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 2, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == MQVPN_SEND_EAGAIN);
    assert(sticky == 0);
    printf("test_eagain_first OK\n");
}

static void
test_eagain_mid(void)
{
    seam_reset();
    struct iovec iov[4] = {iv(1400), iv(1400), iv(1500), iv(1500)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    seam_fail_call = 2;
    seam_fail_errno = EAGAIN;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 4, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == 2);
    assert(sticky == 0);
    printf("test_eagain_mid OK\n");
}

static void
test_mmsg_partial_stops(void)
{
    seam_reset();
    struct iovec iov[5] = {iv(100), iv(200), iv(300), iv(400), iv(500)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    seam_mmsg_partial = 3;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 5, (struct sockaddr *)&peer, sizeof peer, 0,
                                     &sticky, &bytes);
    assert(r == 3);
    assert(seam_calls == 1);
    assert(seam_ops[0] == 'M');
    assert(bytes == 100u + 200u + 300u);
    printf("test_mmsg_partial_stops OK\n");
}

static void
test_hard_error_zero(void)
{
    seam_reset();
    struct iovec iov[2] = {iv(1400), iv(1400)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    seam_fail_call = 1;
    seam_fail_errno = EPERM;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 2, (struct sockaddr *)&peer, sizeof peer, 0,
                                     &sticky, &bytes);
    assert(r == MQVPN_SEND_ERR);
    printf("test_hard_error_zero OK\n");
}

static void
test_run1_gso_errno_no_sticky(void)
{
    seam_reset();
    struct iovec iov[1] = {iv(1400)};
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    seam_fail_call = 1;
    seam_fail_errno = EINVAL;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 1, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == MQVPN_SEND_ERR);
    assert(sticky == 0);
    assert(seam_calls == 1);
    printf("test_run1_gso_errno_no_sticky OK\n");
}

static void
test_full_32_burst(void)
{
    seam_reset();
    struct iovec iov[32];
    for (int i = 0; i < 32; i++)
        iov[i] = iv(1400);
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof peer);
    int sticky = 0;
    uint64_t bytes = 0;
    ssize_t r = mqvpn_udp_send_batch(3, iov, 32, (struct sockaddr *)&peer, sizeof peer, 1,
                                     &sticky, &bytes);
    assert(r == 32);
    assert(seam_calls == 1);
    assert(seam_ops[0] == 'm');
    assert(seam_last_seg == 1400);
    assert(bytes == 32 * 1400u);
    printf("test_full_32_burst OK\n");
}

int
main(void)
{
    test_run_len();
    test_probe();
    test_gso_full_burst();
    test_gso_single_skips_cmsg();
    test_mixed_runs();
    test_fallback_sendmmsg();
    test_gso_error_zero_sent_resends();
    test_gso_error_after_progress_stops();
    test_eagain_first();
    test_eagain_mid();
    test_mmsg_partial_stops();
    test_hard_error_zero();
    test_run1_gso_errno_no_sticky();
    test_full_32_burst();
    return 0;
}
