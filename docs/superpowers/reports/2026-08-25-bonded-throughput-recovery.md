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

**Branch / HEAD:** `codex/lan-relay` at `cbb9fc3` (`docs: plan adaptive throughput scheduler`).
All implementation below is **uncommitted** (`git diff --stat`: 36 files, +393/−23;
`third_party/xquic` dirty at `06f676f`).

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
| **2** | xquic WLB: acknowledged-goodput EWMA, warm-up **3 s \| 1 MiB**, floors **20% / 5%**,
  `xqc_conn_set_wlb_policy()`, `xqc_conn_get_wlb_path_stats()`; standalone CUnit
  **24/24 GREEN**. |
| **3** | Client emits `mqvpn-performance: throughput\|latency` on CONNECT-IP after auth path;
  server applies mode + WLB policy post-PSK; live tunnel duplicate → **409** (cannot mutate). |
| **4–6** | Shared `SchedulerSettings` (“Optimize For”: Max Throughput / Low Latency); iOS + macOS
  Settings UI, provider persistence, `mqvpn_config_set_performance_mode()` in tunnel engine;
  host tests in `ios/poc/Tests/main.swift`, `macos/poc/Tests/main.swift`. |
| **7** | Loopback **9090** `get_status` JSON: client `"performance"` plus per-path
  `"goodput_bps"`, `"warmup"`, `"weight_pct"` via `mqvpn_server_get_client_wlb()`;
  `status.c` CLI prints client `optimize:` plus per-path goodput/warmup/weight;
  bound test updated in `test_control_response_bound.c`. |
| **8** | **PENDING** — no signed deploy, no physical throughput matrix, no acceptance gates claimed. |
