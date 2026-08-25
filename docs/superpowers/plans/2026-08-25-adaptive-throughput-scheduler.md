# Adaptive Throughput Scheduler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Max Throughput the default two-way mqvpn scheduling policy, with automatic delivery-rate learning and Low Latency as the only alternate exposed by the iOS and macOS clients.

**Architecture:** Extend WLB with connection-local throughput/latency policy and acknowledged-goodput sampling. The client advertises its choice on the authenticated CONNECT-IP request; CT212 applies it to the connection's downlink scheduler, while the Apple provider applies it locally for uplink. Apple UI persists a shared two-value setting and exposes no raw weights, probes, or timing knobs.

**Tech Stack:** C11, xquic multipath internals, CUnit, CMake/CTest, Swift 5.9, SwiftUI, NetworkExtension, XcodeGen, Debian 12 systemd/LXC.

**Spec:** `docs/superpowers/specs/2026-08-25-adaptive-throughput-scheduler-design.md`

## Global Constraints

- Max Throughput is the compatibility and UI default; Low Latency is the only alternate.
- Capacity learning uses acknowledged application traffic only; never create synthetic probe traffic.
- Warm-up floor is 20% until three seconds of active payload scheduling or one MiB acknowledged; steady exploration floor is 5%.
- ACK, validation, and control-only traffic remains MinRTT.
- Three consecutive PTOs exclude a path from weights and deficits.
- Reorder remains disabled by default.
- Performance mode is request-scoped, honored only after PSK authentication, and missing/unknown values default to Max Throughput.
- TCP 9090 remains loopback-only.
- Preserve the dirty `ios/poc/Tests/main.swift` SchedulerSettings tests as existing concurrent work; never discard or overwrite them.
- Work and commit in `/Volumes/bigssd/projects/mqvpn` on the main checkout.

---

### Task 1: Core performance-mode model and configuration API

**Files:**
- Create: `src/performance_mode.h`
- Create: `src/performance_mode.c`
- Modify: `CMakeLists.txt`
- Modify: `include/libmqvpn.h`
- Modify: `src/mqvpn_internal.h`
- Modify: `src/mqvpn_config.c`
- Modify: `src/config.c`
- Modify: `src/config.h`
- Test: `tests/test_api.c`
- Test: `tests/test_config.c`

**Interfaces:**
- Produces: `mqvpn_performance_mode_t` with `MQVPN_PERF_MAX_THROUGHPUT = 0` and `MQVPN_PERF_LOW_LATENCY = 1`.
- Produces: `int mqvpn_config_set_performance_mode(mqvpn_config_t *, mqvpn_performance_mode_t)`.
- Produces: `const char *mqvpn_performance_mode_name(mqvpn_performance_mode_t)` and `int mqvpn_performance_mode_parse(const char *, size_t, mqvpn_performance_mode_t *)`.
- Produces: header constants `MQVPN_PERFORMANCE_HDR_NAME`, `MQVPN_PERFORMANCE_THROUGHPUT`, and `MQVPN_PERFORMANCE_LATENCY` for Task 3.

- [ ] **Step 1: Extend the public API tests with a failing default/validation matrix**

```c
ASSERT_EQ(mqvpn_config_set_performance_mode(cfg, MQVPN_PERF_MAX_THROUGHPUT), MQVPN_OK);
ASSERT_EQ(mqvpn_config_set_performance_mode(cfg, MQVPN_PERF_LOW_LATENCY), MQVPN_OK);
ASSERT_EQ(mqvpn_config_set_performance_mode(cfg, (mqvpn_performance_mode_t)99),
          MQVPN_ERR_INVALID_ARG);
ASSERT_EQ(mqvpn_config_set_performance_mode(NULL, MQVPN_PERF_MAX_THROUGHPUT),
          MQVPN_ERR_INVALID_ARG);
```

- [ ] **Step 2: Add failing config parser tests**

Pin these cases in `tests/test_config.c`:

```c
"[Multipath]\nOptimizeFor = throughput\n"  /* MAX_THROUGHPUT */
"[Multipath]\nOptimizeFor = latency\n"     /* LOW_LATENCY */
"[Multipath]\nOptimizeFor = unknown\n"     /* parse error */
""                                            /* MAX_THROUGHPUT default */
```

- [ ] **Step 3: Run the focused tests and record RED**

Run:

```bash
cmake --build build --target test_api test_config -j2
ctest --test-dir build --output-on-failure -R '^(test_api|test_config)$'
```

Expected: compile failure because the performance enum/setter and parsed field do not exist.

- [ ] **Step 4: Implement the enum, validation helpers, default, and parser**

Add to `include/libmqvpn.h`:

```c
typedef enum {
    MQVPN_PERF_MAX_THROUGHPUT = 0,
    MQVPN_PERF_LOW_LATENCY = 1,
} mqvpn_performance_mode_t;

MQVPN_API int mqvpn_config_set_performance_mode(
    mqvpn_config_t *cfg, mqvpn_performance_mode_t mode);
```

Add the mode to the opaque internal config and initialize it to
`MQVPN_PERF_MAX_THROUGHPUT`. Implement exact, case-insensitive parsing for
`throughput` and `latency`; reject other non-empty values. Add
`src/performance_mode.c` to the common source list.

- [ ] **Step 5: Run focused and full native tests**

```bash
cmake --build build -j2
ctest --test-dir build --output-on-failure
```

Expected: every configured native test passes.

- [ ] **Step 6: Commit the core contract**

```bash
git add CMakeLists.txt include/libmqvpn.h src/performance_mode.h \
  src/performance_mode.c src/mqvpn_internal.h src/mqvpn_config.c \
  src/config.c src/config.h tests/test_api.c tests/test_config.c
git commit -m "feat(core): add performance scheduling mode"
```

---

### Task 2: Adaptive acknowledged-goodput WLB

**Files:**
- Modify: `third_party/xquic/include/xquic/xquic.h`
- Modify: `third_party/xquic/src/transport/xqc_conn.c`
- Modify: `third_party/xquic/src/transport/scheduler/xqc_scheduler_wlb.h`
- Modify: `third_party/xquic/src/transport/scheduler/xqc_scheduler_wlb.c`
- Modify: `third_party/xquic/tests/unittest/xqc_wlb_test.c`
- Modify: `third_party/xquic/tests/unittest/xqc_wlb_test.h`
- Modify: `third_party/xquic/tests/unittest/xqc_wlb_test_main.c`

**Interfaces:**
- Consumes: xquic `xqc_send_ctl_t.ctl_delivered`, `ctl_delivered_time`, congestion-controller bandwidth estimate, SRTT, loss, and PTO count.
- Produces: `xqc_wlb_policy_t { XQC_WLB_MAX_THROUGHPUT, XQC_WLB_LOW_LATENCY }`.
- Produces: `int xqc_conn_set_wlb_policy(xqc_engine_t *, const xqc_cid_t *, xqc_wlb_policy_t)`.
- Produces: `xqc_wlb_path_stats_t` and `int xqc_conn_get_wlb_path_stats(xqc_engine_t *, const xqc_cid_t *, xqc_wlb_path_stats_t *, size_t, size_t *)` for bounded status snapshots.
- Produces: connection-local WLB rate data used by status reporting in Task 7.

- [ ] **Step 1: Add failing deterministic fixtures for policy and exploration**

Extend the existing fake-clock fixture with tests that assert:

```c
/* equal delivered rates */
CU_ASSERT_TRUE(path0_count >= 45 && path0_count <= 55);
/* 4:1 delivery rate after warm-up */
CU_ASSERT_TRUE(path0_count >= 75 && path0_count <= 85);
/* new path gets >=20 of 100 payload opportunities during warm-up */
CU_ASSERT_TRUE(new_path_count >= 20);
/* steady eligible path gets >=5 of 100 opportunities */
CU_ASSERT_TRUE(slow_path_count >= 5);
/* latency policy selects the lowest-SRTT sendable path */
CU_ASSERT_EQUAL(selected_path_id, low_rtt_path_id);
```

Also retain the existing black-hole, recovery, STREAM, unpinned datagram,
flow-pinning, and reinjection tests.

- [ ] **Step 2: Run the standalone WLB suite and record RED**

Build the existing arm64 `xquic-static` target, compile
`xqc_wlb_test.c` plus `xqc_wlb_test_main.c` against Homebrew CUnit and the
staged BoringSSL archives, then run the binary.

Expected: the new tests fail because WLB has neither policy nor delivery-rate
state.

- [ ] **Step 3: Add policy and delivery sampling to WLB state**

Extend each `wlb_path_weight_t` with:

```c
uint64_t prior_delivered;
uint64_t prior_delivered_time_us;
uint64_t goodput_ewma_Bps;
uint64_t warmup_started_us;
uint64_t warmup_acked_bytes;
xqc_bool_t warmup;
```

Extend scheduler state with `xqc_wlb_policy_t policy`. Default it to Max
Throughput. Sample only when both delivered bytes and delivery time advance.
Use integer EWMA `new = (7 * old + sample) / 8`; use the congestion-controller
bandwidth estimate when no acknowledged sample exists.

- [ ] **Step 4: Implement normalized floors and bounded deficits**

For `N` eligible paths, calculate raw goodput weights, apply loss penalty above
2%, reserve a per-path floor of 20% during warm-up or 5% in steady state, and
distribute the remaining share proportionally. Clamp each round's normalized
quantum to `[1, 100]`; discard deficits belonging to an ineligible path.

Warm-up ends after either three seconds of active payload scheduling or one MiB
of acknowledged delivery, whichever occurs first. Idle wall time does not
advance the time threshold.

- [ ] **Step 5: Implement the runtime policy setter**

`xqc_conn_set_wlb_policy()` resolves the connection by SCID, verifies that its
scheduler callback is WLB, updates the scheduler's policy on the engine thread,
and clears/renormalizes deficits. Low Latency routes payload through the existing
MinRTT fallback; Max Throughput returns to adaptive WLB with fresh warm-up for
eligible paths.

Add the bounded status type and getter:

```c
typedef struct {
    uint64_t path_id;
    uint64_t goodput_Bps;
    uint8_t weight_pct;
    uint8_t warmup;
    xqc_wlb_policy_t policy;
} xqc_wlb_path_stats_t;
```

The getter copies at most the caller's capacity, reports the required count,
and returns an error when the connection is absent or does not use WLB.

- [ ] **Step 6: Run RED-to-GREEN WLB and xquic builds**

```bash
cmake --build third_party/xquic/build-macos --target xquic-static -j2
# compile and run the focused standalone CUnit driver
./macos/build-macos.sh xquic
```

Expected: all focused WLB tests pass and the production static archive links.

- [ ] **Step 7: Commit xquic, then pin it in mqvpn**

```bash
git -C third_party/xquic add include/xquic/xquic.h \
  src/transport/xqc_conn.c \
  src/transport/scheduler/xqc_scheduler_wlb.h \
  src/transport/scheduler/xqc_scheduler_wlb.c \
  tests/unittest/xqc_wlb_test.c tests/unittest/xqc_wlb_test.h \
  tests/unittest/xqc_wlb_test_main.c
git -C third_party/xquic commit -m "feat(wlb): learn path delivery capacity"
git add third_party/xquic
git commit -m "feat(hybrid): pin adaptive throughput scheduler"
```

---

### Task 3: Authenticated CONNECT-IP policy negotiation

**Files:**
- Modify: `src/mqvpn_client.c`
- Modify: `src/mqvpn_server.c`
- Modify: `src/mqvpn_server_internal.h`
- Modify: `src/mqvpn_conn_settings.c`
- Modify: `src/mqvpn_conn_settings.h`
- Test: `tests/test_server.c`
- Test: `tests/test_conn_settings.c`
- Test: `tests/test_control_socket.c`

**Interfaces:**
- Consumes: Task 1 performance enum/header helpers.
- Consumes: Task 2 `xqc_conn_set_wlb_policy()`.
- Produces: optional `mqvpn-performance` CONNECT-IP header and authenticated, connection-local server policy.

- [ ] **Step 1: Add failing client-header and server parser tests**

Pin these exact request cases:

```text
mqvpn-performance: throughput
mqvpn-performance: latency
mqvpn-performance: invalid
(header missing)
```

Assert missing/invalid selects Max Throughput, and assert a rejected duplicate
CONNECT-IP request cannot mutate the live connection policy.

- [ ] **Step 2: Add a failing post-auth application test**

Drive the real CONNECT-IP request handler with valid and invalid bearer tokens.
Assert `xqc_conn_set_wlb_policy()` is called only after valid authentication and
before the 200 tunnel response.

- [ ] **Step 3: Run focused tests and record RED**

```bash
cmake --build build --target test_server test_conn_settings test_control_socket -j2
ctest --test-dir build --output-on-failure \
  -R '^(test_server|test_conn_settings|test_control_socket)$'
```

- [ ] **Step 4: Emit the client request header**

Increase CONNECT-IP header capacity from 8 to 9. Append exactly one header from
the config's performance mode before `xqc_h3_request_send_headers()`; never emit
unknown text.

- [ ] **Step 5: Parse into request-local state and apply after auth**

Extend `svr_req_headers_t` with:

```c
mqvpn_performance_mode_t performance_mode;
int has_performance_mode;
```

Initialize the parsed default to Max Throughput. In
`svr_connect_ip_on_request()`, authenticate first, release stale session state,
then apply the effective policy through Task 2's setter. Store it on
`svr_conn_t` for status output. If the server's configured scheduler is not WLB,
leave the administrative scheduler unchanged and report that override.

- [ ] **Step 6: Run focused and full native tests**

```bash
cmake --build build -j2
ctest --test-dir build --output-on-failure
```

- [ ] **Step 7: Commit negotiation**

```bash
git add src/mqvpn_client.c src/mqvpn_server.c src/mqvpn_server_internal.h \
  src/mqvpn_conn_settings.c src/mqvpn_conn_settings.h tests/test_server.c \
  tests/test_conn_settings.c tests/test_control_socket.c
git commit -m "feat(protocol): negotiate performance scheduling"
```

---

### Task 4: Shared Apple setting and provider mapping

**Files:**
- Create: `ios/poc/Shared/SchedulerSettings.swift`
- Modify: `ios/poc/Tests/main.swift` (preserve and complete the existing dirty tests)
- Modify: `ios/poc/Tests/run-host-tests.sh`
- Modify: `macos/poc/Tests/main.swift`
- Modify: `macos/poc/Tests/run-host-tests.sh`
- Modify: `ios/poc/project.yml`
- Modify: `macos/poc/project.yml`
- Modify: `ios/poc/PacketTunnel/MqvpnEngine.swift`
- Modify: `ios/poc/PacketTunnel/PacketTunnelProvider.swift`
- Modify: `macos/poc/PacketTunnel/PacketTunnelProvider.swift`

**Interfaces:**
- Consumes: Task 1 `mqvpn_config_set_performance_mode()`.
- Produces: `SchedulerSettings.default`, `.maxThroughput`, `.lowLatency`, provider serialization, and core mapping shared by both apps.

- [ ] **Step 1: Run the existing dirty SchedulerSettings tests and record RED**

```bash
bash ios/poc/Tests/run-host-tests.sh
```

Expected: compile failure because `SchedulerSettings` is undefined.

- [ ] **Step 2: Implement the strict shared value type**

Create:

```swift
struct SchedulerSettings: Equatable {
    static let maxThroughput = 0
    static let lowLatency = 1
    static let `default` = SchedulerSettings(policy: maxThroughput)
    let policy: Int

    init(policy: Int) {
        self.policy = policy == Self.lowLatency ? Self.lowLatency : Self.maxThroughput
    }
}
```

Serialize under `schedulerPolicy`, reject `NSNumber` booleans using the same
strict helper pattern as `HybridSettings`, and map to the Task 1 core enum.

- [ ] **Step 3: Include the file in host tests and all Apple targets**

Update both host scripts and both XcodeGen projects so the app and Packet Tunnel
extension compile the identical shared file.

- [ ] **Step 4: Thread the setting through provider startup**

Change `MqvpnEngine.start()` and `setupClient()` to accept
`scheduler: SchedulerSettings`, call
`mqvpn_config_set_performance_mode()` before `mqvpn_client_new()`, and fail the
start if the setter rejects the value. Parse the provider configuration in both
Packet Tunnel providers and pass it into the engine.

- [ ] **Step 5: Run both Apple host suites**

```bash
bash ios/poc/Tests/run-host-tests.sh
bash macos/poc/Tests/run-host-tests.sh
```

- [ ] **Step 6: Commit the shared setting**

```bash
git add ios/poc/Shared/SchedulerSettings.swift ios/poc/Tests/main.swift \
  ios/poc/Tests/run-host-tests.sh macos/poc/Tests/main.swift \
  macos/poc/Tests/run-host-tests.sh ios/poc/project.yml macos/poc/project.yml \
  ios/poc/PacketTunnel/MqvpnEngine.swift ios/poc/PacketTunnel/PacketTunnelProvider.swift \
  macos/poc/PacketTunnel/PacketTunnelProvider.swift
git commit -m "feat(apple): map performance mode into tunnel providers"
```

---

### Task 5: iOS Optimize For UI and persistence

**Files:**
- Modify: `ios/poc/App/MqvpnPoCApp.swift`
- Modify: `ios/poc/App/SettingsView.swift`
- Test: `ios/poc/Tests/main.swift`

**Interfaces:**
- Consumes: Task 4 `SchedulerSettings`.
- Produces: persisted iOS `Optimize For` selection and atomic save integration.

- [ ] **Step 1: Add failing controller/save tests**

Extend host fixtures to assert missing configuration loads
`SchedulerSettings.default`, Low Latency round-trips through the same atomic
snapshot/merge/save path as Hybrid and reorder settings, and a failed save does
not mutate the published selection.

- [ ] **Step 2: Run iOS host tests and record RED**

```bash
bash ios/poc/Tests/run-host-tests.sh
```

- [ ] **Step 3: Add controller state and atomic persistence**

Add:

```swift
@Published var schedulerSettings = SchedulerSettings.default
```

Load it from provider configuration, accept it in `saveSettings`, merge its
serialized field before `performAtomicSave`, and publish it only after success.

- [ ] **Step 4: Add the two-option picker**

Add a single `Optimize For` picker using labels `Max Throughput` and
`Low Latency`. Initialize it from the controller, pass it to save, and keep the
existing disconnected-only edit rule.

- [ ] **Step 5: Run host and unsigned Release build gates**

```bash
bash ios/poc/Tests/run-host-tests.sh
cd ios/poc && xcodegen generate
xcodebuild -project MqvpnPoC.xcodeproj -scheme MqvpnPoC \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 6: Commit iOS UI**

```bash
git add ios/poc/App/MqvpnPoCApp.swift ios/poc/App/SettingsView.swift \
  ios/poc/Tests/main.swift ios/poc/MqvpnPoC.xcodeproj/project.pbxproj
git commit -m "feat(ios): expose performance optimization mode"
```

---

### Task 6: macOS Optimize For UI and persistence

**Files:**
- Modify: `macos/poc/App/TunnelController.swift`
- Modify: `macos/poc/App/SettingsView.swift`
- Test: `macos/poc/Tests/main.swift`

**Interfaces:**
- Consumes: Task 4 `SchedulerSettings`.
- Produces: persisted macOS `Optimize For` selection and provider configuration.

- [ ] **Step 1: Add failing macOS controller tests**

Assert Max Throughput default, Low Latency serialization, failed-save rollback,
and coexistence with relay discovery fields.

- [ ] **Step 2: Run macOS host tests and record RED**

```bash
bash macos/poc/Tests/run-host-tests.sh
```

- [ ] **Step 3: Add controller state and save wiring**

Mirror the iOS shared-setting behavior in `TunnelController`, merging
`schedulerPolicy` without changing the relay, Hybrid, server, or discovery
fields.

- [ ] **Step 4: Add the two-option macOS picker**

Place `Optimize For` beside Hybrid controls, with Max Throughput selected by
default and no numeric advanced controls.

- [ ] **Step 5: Run host and signed Release build gates**

```bash
bash macos/poc/Tests/run-host-tests.sh
cd macos/poc && xcodegen generate
xcodebuild -project MqvpnMac.xcodeproj -scheme MqvpnMac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath ../DerivedData-throughput-signed clean build
```

- [ ] **Step 6: Commit macOS UI**

```bash
git add macos/poc/App/TunnelController.swift macos/poc/App/SettingsView.swift \
  macos/poc/Tests/main.swift macos/poc/MqvpnMac.xcodeproj/project.pbxproj
git commit -m "feat(macos): expose performance optimization mode"
```

---

### Task 7: Status observability and integration gates

**Files:**
- Modify: `src/mqvpn_server.c`
- Modify: `src/platform/posix/status.c`
- Modify: `include/libmqvpn.h`
- Test: `tests/test_status.c`
- Test: `tests/test_control_socket.c`
- Modify: `docs/superpowers/reports/2026-08-25-bonded-throughput-recovery.md`

**Interfaces:**
- Consumes: Tasks 2–3 effective mode and per-path goodput estimates.
- Produces: bounded local status fields for effective mode, estimated goodput, warm-up state, and allocation weight.

- [ ] **Step 1: Add failing bounded-status tests**

Pin text and JSON fields:

```json
{"performance":"throughput","goodput_bps":123456,"warmup":true,"weight_pct":20}
```

Ensure response-size bounds still hold at maximum clients and paths.

- [ ] **Step 2: Implement status snapshots without exposing mutable scheduler state**

Copy effective mode and bounded per-path scalar snapshots on the engine thread;
format only the copies through the local control interface. Do not expose the
PSK, relay key, or remote control listener.

- [ ] **Step 3: Run all native and Apple host tests**

```bash
cmake --build build -j2
ctest --test-dir build --output-on-failure
bash ios/poc/Tests/run-host-tests.sh
bash macos/poc/Tests/run-host-tests.sh
git diff --check
```

- [ ] **Step 4: Update the recovery report with implementation receipts**

Record commit IDs, RED/GREEN focused tests, build results, and leave physical
throughput results explicitly pending until Task 8.

- [ ] **Step 5: Commit observability and receipts**

```bash
git add include/libmqvpn.h src/mqvpn_server.c src/platform/posix/status.c \
  tests/test_status.c tests/test_control_socket.c \
  docs/superpowers/reports/2026-08-25-bonded-throughput-recovery.md
git commit -m "feat(status): report adaptive path allocation"
```

---

### Task 8: Signed deployment and physical acceptance

**Files:**
- Runtime artifact: `/Applications/MqvpnMac.app`
- Runtime artifact: physical iPhone `MqvpnPoC.app`
- Runtime artifact: CT212 `/usr/local/bin/mqvpn`
- Append verification receipts: `docs/superpowers/reports/2026-08-25-bonded-throughput-recovery.md`

**Interfaces:**
- Consumes: all implementation tasks.
- Produces: real signed client/server deployment and direct/relay/combined evidence.

- [ ] **Step 1: Build all production artifacts**

```bash
./macos/build-macos.sh all
./ios/build-ios.sh
```

Build signed Release Xcode targets with the configured Apple team and existing
manual iPhone provisioning profiles.

- [ ] **Step 2: Install macOS with route-safe replacement**

Stop the `mqvpn` Network Extension profile, verify ordinary default route and
non-GTHost egress, preserve the installed app under
`/Applications/MqvpnMac Backups/`, install the signed Release app, validate app
and embedded extension signatures, and launch it.

- [ ] **Step 3: Install iOS Release on the physical phone**

Use the physical device destination and `devicectl`/Xcode installation path.
Do not use iPhone screen mirroring. Verify the installed bundle and Packet
Tunnel extension come from the new Release build.

- [ ] **Step 4: Build and deploy CT212 beside the running service**

Build BoringSSL, xquic, and mqvpn Release in a versioned source directory. Run
all applicable tests, preserve `/usr/local/bin/mqvpn` under a versioned backup,
perform a bounded service restart with automatic rollback, then verify UDP 443,
`mqvpn0`, forwarding, NAT, loopback-only 9090, and authenticated reconnect.

- [ ] **Step 5: Run three repeated fixed-condition topology trials**

For direct-only, relay-only, and combined, restart the mqvpn session, wait for
the intended active paths, run 60 seconds three times against the same endpoint,
and capture CT status plus per-source/per-path bytes before and after each run.

- [ ] **Step 6: Verify acceptance and teardown**

Calculate medians and check every hard gate from the spec. Press Stop on both
clients, verify the providers terminate, ordinary routes and DNS return, public
egress is no longer GTHost, and CT212 releases the sessions.

- [ ] **Step 7: Commit final physical receipts**

```bash
git add docs/superpowers/reports/2026-08-25-bonded-throughput-recovery.md
git commit -m "docs(report): record adaptive scheduler acceptance"
```
