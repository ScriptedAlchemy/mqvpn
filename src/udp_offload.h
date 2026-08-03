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
 * (>= 0 return = contiguous-prefix count of datagrams handed to the kernel.)
 * Deliberately disjoint from XQC_SOCKET_ERROR(-1)/XQC_SOCKET_EAGAIN(-2),
 * whose meanings are SWAPPED relative to these — returning r raw to xquic
 * would invert EAGAIN/ERROR; the callbacks map explicitly. */
#  define MQVPN_SEND_EAGAIN (-3) /* would block; caller maps to XQC_SOCKET_EAGAIN */
#  define MQVPN_SEND_ERR    (-4) /* hard socket error; caller decides fate */

/* Fallback (non-GSO) sendmmsg batch cap. Matches xquic's
 * XQC_MAX_SEND_MSG_ONCE; compile-pinned by the _Static_assert next to each
 * write_mmsg_ex registration in mqvpn_client.c / mqvpn_server.c. */
#  define MQVPN_OFFLOAD_MAX_BATCH 32

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
 *     Sticky-disable fires ONLY when the failed send carried the
 *     UDP_SEGMENT cmsg (run > 1) — a cmsg-less single-datagram (run == 1)
 *     error is a plain hard error and never sticky-disables GSO.
 *   - otherwise: one sendmmsg for the whole batch.
 *   - Any failure after >= 1 datagram sent: return the cumulative count
 *     (never send later runs after a failed one).
 *   - 0 sent: MQVPN_SEND_EAGAIN on EAGAIN/EWOULDBLOCK, MQVPN_SEND_ERR else.
 *   - EINTR: retry the current syscall.  All syscalls use MSG_DONTWAIT.
 *   - *bytes_sent accumulates actual bytes from syscall results.
 * Precondition: cnt >= 1 (the engine's burst path never sends empty); every
 * iov_len >= 1 (QUIC packets are never empty).
 *
 * Forward-compat invariant: today's safety envelope is
 * MQVPN_OFFLOAD_MAX_BATCH (32) packets x 1400B = 44,800B, comfortably under
 * both the ~64KB kernel GSO/UDP ceiling and UDP_MAX_SEGMENTS (64) — cnt is
 * capped at MQVPN_OFFLOAD_MAX_BATCH (== XQC_MAX_SEND_MSG_ONCE). This module
 * never itself checks MQVPN_MAX_PKT_OUT_SIZE: the write_mmsg_ex registration
 * in mqvpn_client.c / mqvpn_server.c's init_xquic_engine() already guards
 * entry to this whole batching path on MQVPN_MAX_PKT_OUT_SIZE <= 1500, so a
 * full run cannot approach the 64KB ceiling today. Run splitting inside this
 * module would only become necessary if that registration guard were lifted
 * (MQVPN_MAX_PKT_OUT_SIZE raised above ~2KB without adding splitting here
 * first) — otherwise a full run could exceed 64KB and fail EMSGSIZE (not a
 * GSO-class errno here). */
ssize_t mqvpn_udp_send_batch(int fd, const struct iovec *iov, unsigned int cnt,
                             const struct sockaddr *peer, socklen_t peerlen, int use_gso,
                             int *gso_disabled, uint64_t *bytes_sent);

#endif /* __linux__ */
#endif /* MQVPN_UDP_OFFLOAD_H */
