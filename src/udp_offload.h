// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/* UDP TX offload (Linux): GSO-batched send used by the write_mmsg_ex
 * callbacks. Pure syscall/mechanics layer — no xquic types, no client or
 * server state. See docs spec 2026-08-02 (rev5) for the contracts. */
#ifndef MQVPN_UDP_OFFLOAD_H
#define MQVPN_UDP_OFFLOAD_H

#if defined(__linux__)

#  include <stddef.h>
#  include <stdint.h>
#  include <sys/socket.h>
#  include <sys/uio.h>

/* Result classes for mqvpn_udp_send_batch() when 0 datagrams were sent.
 * (>= 0 return = contiguous-prefix count of datagrams handed to the kernel.) */
#  define MQVPN_SEND_EAGAIN (-1) /* would block; caller maps to XQC_SOCKET_EAGAIN */
#  define MQVPN_SEND_ERR    (-2) /* hard socket error; caller decides fate */

/* Stateless capability probe: does the kernel accept UDP_SEGMENT?
 * (Kernel property; callers store the result per client/server instance —
 * no global cache, per the spec's plan-review decision.) */
int mqvpn_udp_gso_probe(void);

/* Length of the maximal GSO run starting at iov[0]: the longest prefix of
 * equal-size datagrams, optionally closed by ONE shorter datagram (kernel
 * rule: all segments equal, only the last may be short). A larger datagram
 * always ends the run before itself. cnt >= 1. Pure function. */
size_t mqvpn_gso_run_len(const struct iovec *iov, size_t cnt);

/* Send cnt datagrams to peer on fd, honoring the contiguous-prefix
 * contract:
 *   - use_gso != 0 and *gso_disabled == 0: one sendmsg + UDP_SEGMENT cmsg
 *     per run (single-datagram runs skip the cmsg); GSO-class errors
 *     (EIO/EINVAL/ENOTSUP) set *gso_disabled = 1 and, iff nothing was sent
 *     yet, the whole batch is retried via sendmmsg within this call.
 *   - otherwise: one sendmmsg for the whole batch.
 *   - Any failure after >= 1 datagram sent: return the cumulative count
 *     (never send later runs after a failed one).
 *   - 0 sent: MQVPN_SEND_EAGAIN on EAGAIN/EWOULDBLOCK, MQVPN_SEND_ERR else.
 *   - EINTR: retry the current syscall.  All syscalls use MSG_DONTWAIT.
 *   - *bytes_sent accumulates actual bytes from syscall results. */
ssize_t mqvpn_udp_send_batch(int fd, const struct iovec *iov, unsigned int cnt,
                             const struct sockaddr *peer, socklen_t peerlen, int use_gso,
                             int *gso_disabled, uint64_t *bytes_sent);

#endif /* __linux__ */
#endif /* MQVPN_UDP_OFFLOAD_H */
