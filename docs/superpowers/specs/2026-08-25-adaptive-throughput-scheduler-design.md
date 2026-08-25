# Adaptive Throughput Scheduler Design

**Date:** 2026-08-25  
**Status:** Approved design, pending implementation plan  
**Scope:** mqvpn core, xquic WLB scheduler, CT212 server, iOS client, macOS client

## Goal

Make **Max Throughput** the default behavior on iOS and macOS while retaining a
single **Low Latency** alternative. Max Throughput must learn the usable
capacity of every healthy mqvpn path from real acknowledged traffic, keep
recovered paths warm enough to rediscover capacity, and use the same policy in
both traffic directions.

The product must not expose raw scheduler names, numeric wait times, synthetic
speed-test controls, or manual path weights.

## User experience

Both Apple clients add one setting:

```text
Optimize For
  Max Throughput  (default)
  Low Latency
```

Changing the setting requires reconnecting the tunnel, consistent with the
existing settings lifecycle. Existing saved profiles and older clients default
to Max Throughput.

## Approaches considered

### Adaptive acknowledged-delivery weighting — selected

Use existing xquic per-path delivery, congestion, RTT, loss, and PTO state.
Send only real application payload while reserving a bounded exploration share
for paths whose capacity is unknown or may have improved.

This reacts to real conditions without consuming cellular data or battery while
the connection is idle.

### Periodic synthetic probes — rejected

Explicit background speed probes would make capacity visible quickly, but they
waste data, battery, radio time, and server bandwidth. Their result can also be
unrepresentative of the application's congestion state.

### Fixed or user-calibrated weights — rejected

Static weights are simple but become stale as Wi-Fi and cellular conditions
change. They also expose transport internals in the product UI.

## End-to-end policy negotiation

The client stores a two-value performance mode in its provider configuration
and maps it into the public mqvpn configuration API.

The CONNECT-IP request advertises the selected mode with an optional header:

```text
mqvpn-performance: throughput
mqvpn-performance: latency
```

The header is parsed as request-scoped state and applied to the connection only
after normal PSK authentication succeeds. Missing or unknown values select Max
Throughput, preserving compatibility with existing clients. The server records
the effective mode per authenticated connection; a rejected or unrelated
request cannot alter a live tunnel's mode.

The client applies the mode to uplink scheduling. CT212 applies the negotiated
mode to downlink scheduling for that connection. The server configuration may
retain a global administrative override, but the deployed default allows the
authenticated per-connection choice.

## Max Throughput behavior

### Eligibility

A path participates only while it is active, unfrozen, free of socket errors,
and below the existing three-consecutive-PTO black-hole threshold. An excluded
path retains no schedulable deficit.

### Capacity signal

Each WLB path entry samples xquic's acknowledged delivery counters and delivery
timestamps. It maintains an exponentially weighted moving average of delivered
bytes per second. Congestion-controller bandwidth is a bootstrap/fallback
signal when an acknowledged sample is not yet available. RTT is retained for
control traffic and diagnostics but does not by itself suppress a high-capacity
payload path.

Loss below 2% is tolerated consistently with BBR2. Higher loss progressively
reduces payload weight. Three consecutive PTOs remove the path immediately.

### Exploration and warm-up

A new or recovered path remains in warm-up until it has observed at least:

- three seconds of active payload scheduling, or
- one MiB of acknowledged delivery.

During warm-up it receives at least 20% of payload opportunities, subject to
sendability and congestion-window limits. In steady state, every eligible path
retains a 5% exploration floor. Exploration schedules existing application
payload; it never creates padding or synthetic test traffic.

Weights are normalized across eligible paths and clamped so one stale sample
cannot accumulate an unbounded deficit. Topology changes clear or proportionally
renormalize stale deficits before a recovered path re-enters scheduling.

### Packet classes

- ACKs, path validation, and control-only packets use MinRTT.
- Hybrid STREAM payload uses adaptive per-packet weighting; QUIC reassembly
  supplies ordering.
- Unpinned UDP/QUIC payload uses adaptive per-packet weighting.
- Raw inner TCP datagrams retain flow pinning and soft spillover to limit
  reordering.
- The reorder buffer remains disabled by default and is not implicitly enabled
  by Max Throughput.

## Low Latency behavior

Low Latency maps payload and control selection to MinRTT. Other authenticated
paths remain available for failover, but the scheduler does not deliberately
fill them for aggregation.

## Failure and recovery

- Socket error, frozen state, or three PTOs removes a path from all weight and
  deficit calculations.
- A topology change refreshes every traffic mode, including STREAM and
  unpinned datagrams.
- A recovered path receives a fresh warm-up state and bounded deficit.
- If no weighted path is sendable, the existing MinRTT fallback is used.
- Invalid performance-mode configuration fails closed in the Apple settings
  layer; a missing wire header remains backward-compatible Max Throughput.
- Start/Stop continues to use the Network Extension profile and must restore
  the ordinary default route on failure or teardown.

## Components

### Core and public API

- Add a stable two-value performance-mode enum and configuration setter.
- Preserve ABI compatibility through the existing size-gated configuration
  pattern.
- Add configuration-file parsing and status labels without exposing xquic
  scheduler implementation names to Apple UI code.

### xquic WLB

- Extend per-path scheduler state with delivery sampling, EWMA goodput, warm-up
  progress, and bounded exploration accounting.
- Keep the current shared schedulable-path predicate and topology refresh.
- Make calculations deterministic under the fake monotonic clock used by the
  focused WLB tests.

### Server

- Parse the optional CONNECT-IP performance header into request-local state.
- Apply it after authentication to connection-local scheduling.
- Report the effective mode and per-path delivery-rate estimate through the
  local status interface; TCP 9090 remains loopback-only.

### iOS and macOS clients

- Add the shared two-option setting with Max Throughput as the default.
- Persist it atomically with existing server, Hybrid, and reorder settings.
- Pass it through the Packet Tunnel provider into libmqvpn.
- Display the effective mode in diagnostics without adding manual tuning
  controls.

## Tests

### Deterministic tests

- Missing mode defaults to Max Throughput.
- Both CONNECT-IP header values parse and apply only after authentication.
- Unknown values use the compatibility default and cannot mutate another
  request or live tunnel.
- Equal paths converge near equal payload opportunity.
- A 4:1 capacity fixture converges near 4:1 after warm-up.
- A new path receives the 20% warm-up floor.
- A steady healthy path receives the 5% exploration floor.
- Loss downweights a path; three PTOs exclude it.
- A recovered path re-enters without stale-deficit monopolization.
- Control traffic remains MinRTT.
- Hybrid STREAM and unpinned datagrams both use adaptive weighting.
- Raw flow pinning and reinjection behavior remain intact.
- Apple host tests cover defaulting, persistence, provider mapping, and UI
  labeling on both platforms.

### Physical acceptance

Use the signed Release clients, fixed server and endpoint, 60-second trials,
three repetitions, and medians. Restart the mqvpn session between topologies
and wait until every intended path is active.

Measure:

1. Mac direct-only through mqvpn.
2. Mac iPhone-relay-only through mqvpn.
3. Mac combined direct plus iPhone relay through one mqvpn session.
4. iPhone Wi-Fi-only, cellular-only, and combined VPN mode.

Hard gates:

- Combined median is at least 1.05 times the faster tunneled single path.
- Each usable path contributes at least 5% and 32 MiB during a 60-second bulk
  trial.
- No route loss after Start, Stop, relay disappearance, or relay recovery.
- No incremental UDP buffer errors, qdisc drops, or tunnel-interface drops.
- CT212 remains below 80% of one core during the trial.

Performance target:

- Combined median reaches at least 85% of the two tunneled single-path medians
  added together.
- When the two legs have comparable tunneled capacity, target a 1.6–1.8x gain
  over the faster single leg.

## Deployment

Land and verify small commits in this order: core/wire contract, adaptive WLB,
server connection policy, Apple shared settings, macOS UI/provider, iOS
UI/provider. Rebuild and install signed Release clients, build CT212 beside the
running service, retain rollback binaries, then restart the server only after
tests pass. Do not claim completion until the physical acceptance matrix passes.
