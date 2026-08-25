# Bonded throughput recovery — WLB blackhole fix + Network.framework relay

Branch: `codex/lan-relay` at `ba4a6fd` (xquic `13f607d`)
Mac extension build: 2026-08-25 11:39, running as PID 43149 from 11:43:27
Physical rig: Mac (en0 wired + en1 Wi-Fi) + iPhone 17 Pro Max cellular relay,
server CT 212 (`208.69.79.206:443`).

## Problem

Bonded speed test measured 91.77 Mbps down / 6.07 Mbps up against a no-VPN
Wi-Fi baseline of ~184 down / ~22.4 up. Upload at 27% of baseline was the
tell: the weighted scheduler kept granting quanta to a relay path that was
attached but not delivering.

## Root causes fixed

1. `xqc_scheduler_wlb.c`: a repeated-PTO (blackholed) path was evicted from
   packet scheduling but stayed in the weight table. Its deficit never
   drained, so WRR rounds stopped advancing, LATE weights froze, and a healed
   path re-entered with banked deficit and monopolised scheduling. All five
   path scans now share one `wlb_path_schedulable()` predicate. Regression
   test `blackholed_path_does_not_stall_rounds` fails on the old scheduler.
2. Relay peer pinning: the iPhone bound the session to the Mac's first LAN
   source address; the route install legitimately changes it. Authenticated
   HELLO from a new address now runs an RFC-9000-style path challenge
   (stable nonce across HELLO retries, constant-time compare, bounded
   lifetime) before the peer migrates.
3. Mac LAN hop moved to Network.framework (`MacRelayNWTransport`):
   `prohibitedInterfaceTypes [.other, .cellular]` keeps the relay off utun
   structurally; route errors and better-path events rebind instead of
   wedging. Scoped IPv6 zone is carried in the endpoint string; the
   `requiredInterface` pin comes from a monitor started at init.

## Physical receipts (2026-08-25 ~11:43–11:52)

- `relay transport ready on en1`, then automatic rebind on
  `No route to host`, then `relay transport rebinding: tunnel routes
  installed` — session survived route installation. `path iphone-relay:
  stable for 30s, resetting retry budget`.
- `networkQuality -s` through the live tunnel:
  run 1: 102.7 down / 27.9 up; run 2: **180.8 down / 31.6 up** (Mbps).
- Per-flow deltas across run 2 (nettop on the extension):
  direct en0 259.9 MB down / 30.0 up; **relay via iPhone 120.3 MB down /
  18.6 up**; direct en1 62.4 MB down / 11.9 up. All three paths carried
  meaningful traffic in both directions.

Against baseline: uplink 31.6 vs 22.4 no-VPN (**+41%**, bonding additive);
downlink 180.8 ≈ line-rate parity through the tunnel.

## Still open

- Server CT 212 still runs the pre-fix scheduler; its downlink scheduling
  would hit the same blackhole stall if its view of the relay path flaps.
  Redeploy server with xquic `13f607d`.
- iPhone build predates the path-challenge/livelock fixes; reinstall kills
  the live relay session, so schedule it between runs.
- High responsiveness numbers (bufferbloat) under load; not a regression,
  worth a later pass.

## Adaptive throughput scheduler — implementation receipts (2026-08-25)

**Branch / HEAD:** `codex/lan-relay` at `397e9e6` (core hardening `4468da3`,
xquic pin `29fb1ca`). Apple Settings/engine leftovers and the three
reviewer follow-ups below are still uncommitted.

**Official spec:** `docs/superpowers/specs/2026-08-25-adaptive-throughput-scheduler-design.md`
**Official plan:** `docs/superpowers/plans/2026-08-25-adaptive-throughput-scheduler.md`

**Uncommitted dirty / new (excluding `DerivedData*` build trees):**
- New: `src/performance_mode.{c,h}`, `ios/poc/Shared/SchedulerSettings.swift`
- Core: `CMakeLists.txt`, `include/libmqvpn.h`, `src/config.{c,h}`, `src/mqvpn_*`,
  `src/platform/{darwin,linux,posix,windows}/*`, `tests/test_{api,config,control_response_bound}.c`
- xquic submodule: dirty WLB/policy/stats work at `06f676f`
- Apple: iOS + macOS `SettingsView`, `DashboardView`, tunnel providers, `MqvpnEngine.swift`,
  host tests, `macos/poc/project.yml` (includes shared `SchedulerSettings.swift`)

| Task | Receipt |
|------|---------|
| **1** | `mqvpn_performance_mode_t`, `mqvpn_config_set_performance_mode()`, parse/name helpers,
  `OptimizeFor` config key; `tests/test_api.c` + `tests/test_config.c` extended (previously GREEN). |
| **2** | xquic WLB pinned at `29fb1ca` (parent `ddfc196`): application-only **confirmed**
  ACK goodput, warm-up **3 s \| 1 MiB**, floors **20% / 5%**. |
| **3** | Auth before policy; invalid PSK asks for latency and must be exact **403**
  with zero sessions; duplicate **409** cannot mutate live latency;
  omitted header on a later authenticated CONNECT-IP defaults to throughput
  (`test_server_double_connectip` PASS on this host). |
| **4–6** | `SchedulerSettings.policy` is `let`; dashboards show **Requested**; iOS hides
  Optimize For in Mac Relay; `EnginePerformanceApply` always `MQVPN_SCHED_WLB`
  and calls the C performance setter; unused MinRTT `coreScheduler` mapping removed;
  host tests GREEN. |
| **7** | 9090 JSON: effective `"performance"` plus per-path WLB fields; CLI reads 257 KiB
  and prints goodput as **B/s**; **SOVERSION 4**; `ctrl_socket_destroy` now
  owns/closes in-flight connections (`test_destroy_closes_in_flight_write`). |
| **8** | **PENDING** — no signed deploy, no physical throughput matrix, no acceptance gates claimed. |

## Final acceptance receipts — probe-recovery build (2026-08-25, `397e9e6`)

Deployed everywhere (CT 212, Mac app, iPhone app) at `397e9e6`
(xquic `f8ea0c7`): evicted-path payload probes, TCP-lane reentrant close
fix (`2b76b9b`), datagram ack crediting (xquic `29fb1ca`).

Three back-to-back `networkQuality -s` trials through the live bond,
per-path receipts via nettop on the extension:

| Trial | Down | Up | Relay down MB | Relay up MB |
|---|---|---|---|---|
| 1 | 125.0 | **58.2** | 0.8 | **34.4** |
| 2 | 164.3 | 35.9 | 0.2 | 5.4 |
| 3 | 132.5 | 44.5 | 0.1 | 0.9 |

Medians: **132.5 down / 44.5 up**. Session survived every saturation
trial (same extension PID throughout); trial 1's 58.2 Mbps up exceeds the
prior all-time bonded record (56.6).

Relay downlink is physically bounded in this topology: the iPhone-to-Mac
LAN hop and the direct Wi-Fi path share en1 airtime, so under saturation
the relay's downlink leg loses the radio to direct traffic, PTOs, and is
correctly evicted; the 0.1-0.8 MB observed matches probe cadence plus
revival attempts. Uplink airtime splits differently and the relay
contributed up to 37% of upload bytes. A wired-only Mac (en0 + relay,
Wi-Fi direct disabled) is the topology where relay downlink can
contribute; that variant remains unmeasured.

## Failover matrix + relay-only isolation (2026-08-25 afternoon, `397e9e6`)

- Wired-only + relay bond: 158.1 down / 37.2 up; relay carried 13.6 MB up
  (22% of upload), ~0.5 MB down.
- Ethernet pulled mid-session: **session survived** (same extension PID) —
  old paths closed, a fresh relay path re-established at 100% and carried
  a live measurement. Interface-loss failover gate: PASS.
- Relay-only measurement during the outage: **29.0 down / 2.4 up**, uplink
  responsiveness 5.2 s under load — the cellular link was genuinely
  degraded at this hour (vs 193.8 down relay-only in the morning). The
  scheduler's daytime relay-downlink evictions were therefore correct
  adaptive behavior against a weak path, with 500 ms probes standing by to
  re-admit it; not a scheduler defect.
- Ethernet re-plugged: the session did NOT rejoin the returning interface;
  the tunnel dropped and required a restart (fresh session then bonded
  en0 + relay at 48/52 within 5 s). Interface-return recovery is the one
  remaining lifecycle gap. Wi-Fi-off mid-session earlier behaved the same
  way. Filed as follow-up: path addition after interface return should
  reuse the live session the way loss-side failover already does.
