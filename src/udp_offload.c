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
/* Fault-injection seam for unit tests: prototypes live in udp_offload.h
 * (tests/test_udp_offload.c defines these symbols; the header declaration
 * makes those definitions compiler-checked against this mapping). */
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
    if (fd < 0) fd = (int)socket(AF_INET6, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;
    int zero = 0;
    int ok = setsockopt(fd, SOL_UDP, UDP_SEGMENT, &zero, sizeof(zero)) == 0;
    close(fd);
    return ok;
}

/* Sends one GSO run (run == 1 or run > 1 equal-size datagrams, optionally
 * with a final short one) as a single sendmsg(). */
static ssize_t
send_one_run(int fd, const struct iovec *iov, size_t run, uint16_t seg,
             const struct sockaddr *peer, socklen_t peerlen)
{
    struct msghdr msg;
    /* union: a bare char[] has alignment 1 and CMSG_FIRSTHDR's cast to
     * struct cmsghdr* is UB on it (the exact class G11's UBSan catches) */
    union {
        char buf[CMSG_SPACE(sizeof(uint16_t))];
        struct cmsghdr align;
    } ctrl;
    memset(&msg, 0, sizeof(msg));
    msg.msg_name = (void *)peer;
    msg.msg_namelen = peerlen;
    msg.msg_iov = (struct iovec *)iov;
    msg.msg_iovlen = run;
    if (run > 1) { /* single-datagram runs need no cmsg */
        memset(ctrl.buf, 0, sizeof(ctrl.buf));
        msg.msg_control = ctrl.buf;
        msg.msg_controllen = sizeof(ctrl.buf);
        struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_UDP;
        cm->cmsg_type = UDP_SEGMENT;
        cm->cmsg_len = CMSG_LEN(sizeof(uint16_t)); /* kernel validates exactly */
        memcpy(CMSG_DATA(cm), &seg, sizeof(seg));
        msg.msg_controllen = CMSG_SPACE(sizeof(uint16_t));
    }
    ssize_t r;
    do {
        r = OFFLOAD_SENDMSG(fd, &msg, MSG_DONTWAIT);
    } while (r < 0 && errno == EINTR);
    return r;
}

/* Sends the whole batch via one sendmmsg() call (non-GSO fallback / GSO
 * disabled path). cnt is capped at 32 (XQC_MAX_SEND_MSG_ONCE) — see the
 * forward-compat invariant on mqvpn_udp_send_batch() in udp_offload.h. */
static ssize_t
send_batch_mmsg(int fd, const struct iovec *iov, unsigned int cnt,
                const struct sockaddr *peer, socklen_t peerlen, uint64_t *bytes_sent)
{
    /* XQC_MAX_SEND_MSG_ONCE is 32; keep a static cap with margin. */
    struct mmsghdr mv[64];
    if (cnt > 64) cnt = 64;
    memset(mv, 0, sizeof(mv[0]) * cnt);
    for (unsigned int i = 0; i < cnt; i++) {
        mv[i].msg_hdr.msg_name = (void *)peer;
        mv[i].msg_hdr.msg_namelen = peerlen;
        mv[i].msg_hdr.msg_iov = (struct iovec *)&iov[i];
        mv[i].msg_hdr.msg_iovlen = 1;
    }
    int r;
    do {
        r = OFFLOAD_SENDMMSG(fd, mv, cnt, MSG_DONTWAIT);
    } while (r < 0 && errno == EINTR);
    if (r > 0)
        for (int i = 0; i < r; i++)
            *bytes_sent += mv[i].msg_len;
    return r;
}

/* Errnos that indicate the *kernel/NIC* rejected UDP_SEGMENT itself (as
 * opposed to an ordinary transient send failure) — evidence to sticky-
 * disable GSO for the rest of this socket's lifetime. */
static int
gso_class_error(int e)
{
    return e == EIO || e == EINVAL || e == ENOTSUP;
}

ssize_t
mqvpn_udp_send_batch(int fd, const struct iovec *iov, unsigned int cnt,
                     const struct sockaddr *peer, socklen_t peerlen, int use_gso,
                     int *gso_disabled, uint64_t *bytes_sent)
{
    if (!use_gso || *gso_disabled) {
        ssize_t r = send_batch_mmsg(fd, iov, cnt, peer, peerlen, bytes_sent);
        if (r > 0) return r;
        return (errno == EAGAIN || errno == EWOULDBLOCK) ? MQVPN_SEND_EAGAIN
                                                         : MQVPN_SEND_ERR;
    }

    unsigned int sent = 0;
    while (sent < cnt) {
        size_t run = mqvpn_gso_run_len(&iov[sent], cnt - sent);
        ssize_t r =
            send_one_run(fd, &iov[sent], run, (uint16_t)iov[sent].iov_len, peer, peerlen);
        if (r < 0) {
            /* A GSO-class errno is only evidence of a GSO failure when this
             * send actually carried the UDP_SEGMENT cmsg (run > 1); a plain
             * single-datagram sendmsg EINVAL/EIO must not sticky-disable. */
            if (run > 1 && gso_class_error(errno)) {
                *gso_disabled = 1; /* sticky, any burst position */
                if (sent == 0)     /* in-call retry only at 0 sent */
                    return mqvpn_udp_send_batch(fd, iov, cnt, peer, peerlen, 0,
                                                gso_disabled, bytes_sent);
            }
            if (sent > 0) return sent; /* contiguous prefix */
            return (errno == EAGAIN || errno == EWOULDBLOCK) ? MQVPN_SEND_EAGAIN
                                                             : MQVPN_SEND_ERR;
        }
        *bytes_sent += (uint64_t)r;
        sent += (unsigned int)run;
    }
    return sent;
}

#endif
