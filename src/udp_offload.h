// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

/* UDP TX offload (Linux): GSO-batched send used by the write_mmsg_ex
 * callbacks. Pure syscall/mechanics layer — no xquic types, no client or
 * server state. (issue #167) */
#ifndef MQVPN_UDP_OFFLOAD_H
#define MQVPN_UDP_OFFLOAD_H

#if defined(__linux__)

#  include <stddef.h>
#  include <stdint.h>
#  include <sys/socket.h>
#  include <sys/uio.h>

#  ifdef MQVPN_OFFLOAD_TEST_SEAM
/* Fault-injection seam for unit tests: tests/test_udp_offload.c DEFINES these
 * symbols; declaring them here (rather than as .c-local prototypes) makes
 * those definitions compiler-checked against the exact signatures
 * src/udp_offload.c maps OFFLOAD_SENDMSG/OFFLOAD_SENDMMSG to. Never defined
 * outside the test_udp_offload target. struct mmsghdr requires _GNU_SOURCE,
 * which every TU that reaches this header (src/udp_offload.c,
 * tests/test_udp_offload.c) already #defines before its first #include. */
ssize_t mqvpn_seam_sendmsg(int fd, const struct msghdr *msg, int flags);
int mqvpn_seam_sendmmsg(int fd, struct mmsghdr *msgvec, unsigned int vlen, int flags);
#  endif

/* Result classes for mqvpn_udp_send_batch() when 0 datagrams were sent.
 * (>= 0 return = contiguous-prefix count of datagrams handed to the kernel.) */
#  define MQVPN_SEND_EAGAIN (-1) /* would block; caller maps to XQC_SOCKET_EAGAIN */
#  define MQVPN_SEND_ERR    (-2) /* hard socket error; caller decides fate */

/* Stateless capability probe: does the kernel accept UDP_SEGMENT?
 * (Kernel property; callers store the result per client/server instance —
 * no global cache: probing is idempotent and engine creation is rare.) */
int mqvpn_udp_gso_probe(void);

/* Length of the maximal GSO run starting at iov[0]: the longest prefix of
 * equal-size datagrams, optionally closed by ONE shorter datagram (kernel
 * rule: all segments equal, only the last may be short). A larger datagram
 * always ends the run before itself. cnt >= 1; every iov_len >= 1 (QUIC
 * packets are never empty). Pure function. */
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
 *   - *bytes_sent accumulates actual bytes from syscall results.
 * Precondition: cnt >= 1 (the engine's burst path never sends empty); every
 * iov_len >= 1 (QUIC packets are never empty).
 *
 * Forward-compat invariant: today's safety envelope is 32 packets x 1400B =
 * 44,800B, comfortably under both the ~64KB kernel GSO/UDP ceiling and
 * UDP_MAX_SEGMENTS (64) — cnt is capped at 32 (XQC_MAX_SEND_MSG_ONCE). If
 * MQVPN_MAX_PKT_OUT_SIZE ever becomes configurable above ~2KB, a full run
 * could exceed 64KB and fail EMSGSIZE (not a GSO-class errno here); run
 * splitting would need to be added at that point. */
ssize_t mqvpn_udp_send_batch(int fd, const struct iovec *iov, unsigned int cnt,
                             const struct sockaddr *peer, socklen_t peerlen, int use_gso,
                             int *gso_disabled, uint64_t *bytes_sent);

#endif /* __linux__ */
#endif /* MQVPN_UDP_OFFLOAD_H */
