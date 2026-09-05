# RESOLVED: the 22 Mbps upload ceiling (2026-08-30)

Historical diagnosis and measurements; deployment details describe the run below.

> The original version of this document named the hybrid lwIP TCP lane as the
> prime suspect and proposed disabling `[Hybrid]` on the server. Both were
> wrong — kept here as a corrected record so nobody re-walks the dead ends.

## What the ceiling actually was

Uploads to `http://10.77.77.55:8080` target an address INSIDE the tunnel
subnet (`Subnet = 10.77.77.0/24` on CT212), and the classifier forces
tunnel-subnet TCP onto the RAW datagram lane (`client_tunnel_subnet` gate,
`src/hybrid/classifier.c` — laning it would 403 against the server's
unconditional tunnel-subnet egress deny). **The uploads never touched lwIP.**

On the RAW lane, the WLB scheduler pinned every inner TCP flow to ONE outer
path to protect it from cross-path reordering (`xqc_scheduler_wlb.c`,
flow-table pinning). Pinning fragments the aggregate: per-flow throughput is
capped by one path's share, pins concentrate on the hottest Wi-Fi path, idle
cellular paths never earn weight, and doubling app connections just re-deals
pins over the same path set — which is exactly the "flat aggregate, per-flow
halves" signature the original doc attributed to a single shared resource.
Live tcpdump during an upload showed Wi-Fi carrying 13.1/6.7/1.6 Mbps on
three outer flows and all four cellular paths at ~0.3 Mbps combined.

The 42 Mbps Speedtest reference went through the **lane** (H3 streams to
`66.206.0.90:443`, an Ookla host — 22.5k lane-flow records in the journal):
stream data is scheduled per-packet across all paths because QUIC reassembly
absorbs reordering. Same radios, same paths, same send queue — the entire
gap was pinned-datagram vs per-packet-stream scheduling.

Ruled out along the way, with evidence:

| Hypothesis | Killed by |
|---|---|
| lwIP lane pools/timer | uploads classified RAW; lane never in their path |
| Per-outer-flow ISP shaping | one outer flow measured at 13.1 Mbps alone |
| QUIC stream/conn flow-control caps (886dc1c) | uploads are datagrams — no stream FC |
| Client sndq cap | Speedtest hit 42 through the same queue |

## The fix (commit 9338c8b, deployed 2026-08-30)

Reorder-shim-gated unpinning, end to end:

- `mqvpn_reorder_parse_5tuple` accepts non-fragmented **TCP** (was UDP-only).
- `[ReorderRule]` gained `Port = 0` (proto-wide wildcard) and `Proto = tcp`.
- **Stamped datagrams are sent with the WLB unpin sentinel**
  (`mqvpn_dgram_flow_hash`, `src/flow_sched.h`): when the peer resequences a
  flow, per-packet WRR replaces pinning.
- ACK-demotion classifier computes real TCP payload (doff-aware), so
  ACK-direction TCP flows demote to zero-latency pass-through.
- iOS Reorder settings gained a **"Bond TCP flows"** toggle (proto-6/port-0
  rule; ports field stays UDP-only and may be left empty).

Deployed config: CT212 `server.conf` has `[Reorder] Enabled = on` +
`[ReorderRule] Proto = tcp / Port = 0 / Profile = cellular_bond` (50 ms hold,
1024-packet cap/flow). Phone: Reorder ON + Bond TCP ON.

## Measured result (same part-log methodology)

| | before | after |
|---|---|---|
| upload aggregate | 20–23 Mbps | **27.9 Mbps** |
| per-connection | 1.7–2.3 Mbps | 2.6–2.8 Mbps |
| concurrent downlink | ~21 Mbps | ~29 Mbps |
| total tunnel | ~41 Mbps | **~57 Mbps** |
| cellular share of upload | ~0.3 Mbps | ≈ half the packets |

Server resequencer after 19 min: 2.87 M delivered, 95.7 % of 272 k gaps
filled, 0.34 % late-dropped, zero pool/overflow drops.

## Open items

1. **Resequencer hold latency**: p99 added latency runs 128–256 ms against
   the 50 ms design hold (max spike 3.06 s under load) — likely flush
   granularity; first thing to profile if loaded latency matters.
2. **Hybrid-lane reset storm** (`close_msg:remote reset|err:268`): still
   open, still churning background TCP (Apple push/IMAP re-flows by the
   thousands). Not the upload path, but worth its own session.
3. **Server per-path status (fixed in `1dae499`)**: `get_status` exposed only the
   first 8 path slots; after path churn the live paths (higher IDs) are
   invisible and the listed ones were stale/closed. Active paths now take
   priority in the bounded status list, and the CLI prints their actual IDs.
4. `./build.sh` on Linux broke at `test_routing_seq_darwin` after the relay
   fields went Darwin-only; fixed by dropping the target from the non-Apple
   test block (this commit). `make -C build mqvpn` was the workaround.
5. WLB warmup/floor weights were tuned for the pinned era; with per-packet
   spread across a re-added path they may deserve a revisit.

## Measurement crib (unchanged)

Ground truth is the app's part log:
`xcrun devicectl device copy from --device 12998294-... --domain-type
appDataContainer --domain-identifier com.scriptedalchemy.zerofs.drop
--source Library/engine.log --destination engine.log`, parse
`http done segN +len in Nms` over a wall-clock window. Server-side:
`{"cmd":"get_status"}` / `{"cmd":"get_reorder_stats"}` on `127.0.0.1:9090`
inside CT212 — difference two samples, never read cumulative counters as
rates. `du` on the ZeroFS drop dir reads near zero during commits.
