# Handoff: the 22 Mbps shared ceiling on phone→ZeroFS uploads

## The task

An iPhone uploads audiobooks through the mqvpn tunnel to a ZeroFS server. It
sustains **~22 Mbps (2.7 MB/s)**. The user expects **5–6 MB/s (40–48 Mbps)**,
and that expectation is well founded: a Speedtest run *through this same
tunnel* reaches **42 Mbps up**.

Find and remove the shared ~22 Mbps ceiling. **It is not in the iOS uploader
app** — that has been ruled out by measurement (see below). The work is almost
certainly in this repo, in the hybrid lwIP TCP lane.

## The stack, layer by layer

```
ZeroFS Drop app (separate repo: /Volumes/bigssd/projects/zerofs-dropbox)
  12 concurrent HTTP PUT connections
        |
  ONE embedded lwIP TCP stack           <-- prime suspect
  src/hybrid/  ([Hybrid] Enabled = true on the server)
  terminates TCP locally, re-originates it server-side
        |
  8 outer QUIC paths
  ios/poc/PacketTunnel/PathBinder.swift  (replicasPerInterface = 4, x en0 + pdp_ip0)
  scheduled by WLB: third_party/xquic/src/transport/scheduler/xqc_scheduler_wlb.c
        |
  UDP 443 -> CT212 (10.77.77.212)
        |
  DNAT alias 10.77.77.55:8080 -> 10.10.10.55:8080  (systemd unit mqvpn-zerofs-alias)
        |
  ZeroFS on CT198
```

## What is already ruled out, with numbers

| Hypothesis | Evidence against it |
|---|---|
| App is idle between parts | Connections measured **89% busy** |
| Part size too small/large | Tested 2 MiB and 8 MiB — no improvement either way |
| Too few app connections | **12 flows → 23.4 Mbps; 24 flows → 21.1 Mbps.** Per-flow rate halved (2.2 → 0.90), aggregate unchanged |
| Per-flow ISP shaping | Ruled out by the same test — shaping would have made 24 flows ≈ 44 Mbps |
| ZeroFS ingest | **2.5 Gbps** single stream, **3.5 Gbps** at 6 parallel, measured inside CT198 |
| Raw tunnel capacity | Speedtest **42 Mbps up** through the tunnel |
| `tcp_max_flows` cap | Defaults to **256**; we use 12 |
| Outer path count | 4 replicas/interface already; 8 was tried and starved the cellular radio |

**The decisive datum:** doubling app connections halved per-flow throughput and
left the aggregate flat. That is the signature of one shared resource, not of
many independently limited ones.

## Prime suspect: the hybrid lwIP TCP lane

`[Hybrid] Enabled = true` in `/etc/mqvpn/server.conf` on CT212, so all TCP is
terminated by lwIP and re-originated rather than passed through. Every one of
the app's 12 connections funnels through that single stack before reaching the
8 QUIC paths.

Why it fits: lwIP here is single-threaded with a **250 ms `tcp_tmr` tick** and
fixed pools. Relevant files:

- `src/hybrid/lwip_port/mqvpn_lwip_profile.h` — `TCP_WND` (scale 3 = 512 KiB;
  iOS build passes `-DMQVPN_LWIP_IOS_RCV_SCALE=4` from `ios/build-ios.sh`),
  `MEMP_NUM_TCP_SEG` (1024), `PBUF_POOL_SIZE`
- `src/hybrid/tcp_lane.c` — per-flow state, backpressure high/low water
- `src/hybrid/tcp_egress.c` — server-side re-origination
- `src/hybrid/classifier.h` — `tcp_max_flows` / `tcp_max_global_flows` defaults

There is a **known open bug in this same lane**: it resets concurrent new flows
mid-handshake and starves survivors. The server log floods with
`close_msg:remote reset|err:268`. Historic symptom recorded as `flows act/tot
3/235` — very few active despite many created. If only a handful of flows are
ever truly active, that alone would explain a fixed aggregate.

## The experiment to run first

Set `[Hybrid] Enabled = false` on CT212 so TCP passes through instead of being
re-originated, restart `mqvpn-server`, and re-measure. If throughput jumps
toward 42 Mbps, lwIP is confirmed as the ceiling and the fix belongs there.

**Warn the user before restarting mqvpn-server: it cuts both the phone's and
the Mac's internet**, because the Mac's default route rides this tunnel when
MqvpnMac is connected.

## How to measure (do not trust the UI numbers)

**Ground truth is the app's own part log**, not any on-screen figure:

```bash
xcrun devicectl device copy from --device 12998294-6E1B-5C48-9EE0-89E167C6334B \
  --domain-type appDataContainer \
  --domain-identifier com.scriptedalchemy.zerofs.drop \
  --source Library/engine.log --destination engine.log
```

Lines to parse:

- `http part segN @offset (+len): file` — a part started
- `http done segN +len in Nms (N Mbps): file` — a part finished, with duration

Aggregate = summed `+len` over the wall-clock window. Per-connection rate =
summed bytes / summed durations. Concurrency = summed durations / window.

Traps that have already wasted hours:

- `du -sk ~/ZeroFS/Drop` reads near zero during commits — the server
  concatenates segments then deletes them. Do not use it for short samples.
- The mqvpn UI's cumulative per-path byte counters span the whole session.
  **Difference two samples**; never read a lifetime total as a rate.
- A Speedtest taken while mqvpn is connected reports the ISP as **GTHost** and
  is therefore measuring *through* the tunnel. Loaded latency there is
  **728/776 ms** against a 119 ms idle ping — severe bufferbloat, possibly
  relevant.
- Rebuild before trusting a test pass. A stale `xqc_wlb_test` binary once
  reported 43/43 while the change under test was not compiled in.

## Repo and deploy facts

- Branch `codex/lan-relay`. Upstream `mp0rta/mqvpn` is **not** the user's —
  push to `ScriptedAlchemy/mqvpn` (remote `mine`).
- Submodule `third_party/xquic` sits on a **detached HEAD**; push with
  `git push mine HEAD:mqvpn-patches`.
- iOS build: `./ios/build-ios.sh xquic && ./ios/build-ios.sh mqvpn` (~4 min),
  then `xcodebuild -project ios/poc/MqvpnPoC.xcodeproj -scheme MqvpnPoC
  -configuration Release -destination generic/platform=iOS -derivedDataPath
  ../DerivedData-vpnslot -allowProvisioningUpdates` (~7 min). Install via
  `xcrun devicectl device install app`. **Reinstalling kills the live tunnel —
  the user must press Start afterwards.**
- Server: tar the repo → scp to `gthost-tor-pve-public` → `pct push 212` →
  build in CT212 with `./build.sh` (the `test_relay_adapter_darwin` target
  fails on Linux; harmless) → install to `/usr/local/bin/mqvpn` →
  `systemctl restart mqvpn-server`.
- WLB scheduler tests: build with `ninja run_tests` in
  `third_party/xquic/build-wlbtest`, then compile
  `tests/unittest/xqc_wlb_test_main.c` + `xqc_wlb_test.c` with `cc -c` and link
  with `c++` (BoringSSL is C++) against `build-wlbtest/libxquic-static.a` plus
  boringssl `build-macos` libs and `-lcunit`. 43 tests. The upstream
  `run_tests` binary segfaults on unrelated crypto tests — that is pre-existing.

## Recent related work (already done, do not redo)

- `14e489c` (xquic) — WLB now weights an under-fed path by its capacity
  (`xqc_send_ctl_get_est_bw`) but **only while the path is app-limited**. An
  ungated version regressed 3 tests by letting a dead path hold a majority
  share.
- `aa7faf0` (mqvpn) — the iOS dashboard and Live Activity were showing one
  flow of four per interface, and the rate keyed a dict by interface name while
  iterating all four flows. Both now sum. This is why Wi-Fi *looked* starved
  when it was not.
- On the ZeroFS side, a permit-starvation bug wedged the server for four hours
  (16 slow request bodies held every global upload permit). Fixed in ZeroFS
  `8c850613`, deployed as `5f146b7a`. Unrelated to the throughput ceiling, but
  it is why older logs show total stalls rather than slowness.
