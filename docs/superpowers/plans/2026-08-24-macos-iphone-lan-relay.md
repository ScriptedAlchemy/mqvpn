# macOS Client with iPhone Cellular LAN Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing macOS mqvpn CLI aggregate its direct uplink with an authenticated iPhone cellular relay, while fixing iOS Stop and exposing ZeroFS privately through the mqvpn server.

**Architecture:** Complete libmqvpn's callback-backed logical-path contract, carry its opaque QUIC datagrams through a small HMAC-authenticated LAN relay protocol, and run the relay in the existing iOS Packet Tunnel extension without routing phone application traffic. The Mac remains the only mqvpn client and retains all existing utun, Hybrid, route, DNS, and kill-switch behavior.

**Tech Stack:** C11, libevent, xquic, BoringSSL, Darwin route sockets/utun/pf, Swift 6, NetworkExtension, XcodeGen, CMake/CTest, systemd, iptables.

**Spec:** `docs/superpowers/specs/2026-08-24-macos-iphone-lan-relay-design.md`

## Global Constraints

- Work in `/Volumes/bigssd/projects/mqvpn` on `codex/lan-relay`; do not create another worktree.
- Preserve the existing local bundle identifiers and manual provisioning profiles.
- Commit each completed task as a self-contained verified slice.
- Use test-first RED/GREEN cycles for every production behavior change.
- The Mac owns exactly one mqvpn client session; iPhone relay mode never starts a second mqvpn client.
- Relay mode forwards only opaque mqvpn UDP datagrams to the configured GT server address and port.
- Relay and server authentication keys are separate; neither key appears in logs, argv, Notes, tests, or committed fixtures.
- Do not add a macOS GUI, mDNS/Bonjour discovery, QR pairing, accounts, cloud coordination, or arbitrary proxying.
- Do not change MTU, reorder buffering, scheduler constants, qdisc, socket buffers, or GRO without a controlled measurement identifying that limiter.
- Physical-device and live-server claims require fresh end-to-end evidence; simulator, host tests, or builds alone are insufficient.

---

### Task 1: Make iOS Stop deterministic and select the correct VPN manager

**Files:**
- Create: `ios/poc/Shared/TunnelLifecycle.swift`
- Modify: `ios/poc/App/MqvpnPoCApp.swift`
- Modify: `ios/poc/App/DashboardView.swift`
- Modify: `ios/poc/PacketTunnel/MqvpnEngine.swift`
- Modify: `ios/poc/PacketTunnel/PacketTunnelProvider.swift`
- Modify: `ios/poc/Tests/main.swift`
- Modify: `ios/poc/Tests/run-host-tests.sh`

**Interfaces:**
- Produces `ManagerDescriptor`, `selectMatchingManager(_:, providerBundleID:)`, and `StopLifecycle` as pure shared logic.
- Changes `MqvpnEngine.perform(_:)` to return `Bool`, where `false` means the tick-thread closure was not accepted.
- Guarantees `PacketTunnelProvider.stopTunnel` returns after best-effort cleanup even if `engine` or `binder` is nil or the tick thread has exited.

- [ ] **Step 1: Read the test-quality rules**

Run:

```bash
cat /Users/zackjackson/.codex/plugins/cache/openai-curated-remote/superpowers/6.3.0/skills/test-driven-development/writing-good-tests.md
```

- [ ] **Step 2: Add failing pure lifecycle and manager-selection tests**

Add host tests that prove:

```swift
selectMatchingManager([
    .init(id: "old", providerBundleID: "com.mp0rta.mqvpnpoc.PacketTunnel", status: .connected),
    .init(id: "current", providerBundleID: TunnelController.providerBundleID, status: .disconnected),
], providerBundleID: TunnelController.providerBundleID)?.id == "current"
```

and that `StopLifecycle.request(hasManager:status:)` returns `.unavailable` for no manager, `.alreadyStopped` for `.disconnected`, and `.requested` plus visible `.disconnecting` state for `.connected` or `.reasserting`. Add transitions for `.disconnected` success and timeout/error failure.

- [ ] **Step 3: Run the host test and verify RED**

Run:

```bash
bash ios/poc/Tests/run-host-tests.sh
```

Expected: compilation fails because `TunnelLifecycle.swift` and its types do not exist.

- [ ] **Step 4: Implement the minimal pure lifecycle logic**

Create value-only shared types with no NetworkExtension dependency. Map `NEVPNStatus` into the pure status enum in the app target. Filter loaded managers by exact `NETunnelProviderProtocol.providerBundleIdentifier`; never select `.first` and never delete nonmatching profiles.

- [ ] **Step 5: Verify lifecycle tests GREEN**

Run the host test and require `host tests: ALL PASS`.

- [ ] **Step 6: Add a failing engine-shutdown acceptance test seam**

Add a small shared/pure dispatch-acceptance helper or host-compilable engine seam proving a shutdown completion executes exactly once when dispatch is accepted and also when dispatch is rejected. The production change that must make it pass is `perform` returning acceptance instead of silently dropping work.

- [ ] **Step 7: Implement deterministic Stop**

- Return `Bool` from `MqvpnEngine.perform`.
- Make `engine` and `binder` optional in the provider lifecycle.
- In `stopTunnel`, invalidate path observation, attempt tick-thread teardown, and immediately perform local best-effort cleanup plus resume when dispatch is rejected.
- Log `STOP_BEGIN`, `STOP_DISPATCHED`, and `STOP_FINISHED` without configuration or key material.
- In the app, disable Stop unless a matching manager is up/connecting, show `disconnecting`, and reconcile only from `NEVPNStatusDidChange`.

- [ ] **Step 8: Run host tests, regenerate the project, and build**

Run:

```bash
bash ios/poc/Tests/run-host-tests.sh
cd ios/poc && xcodegen generate
xcodebuild -project MqvpnPoC.xcodeproj -scheme MqvpnPoC \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: host tests pass and Xcode build exits 0.

- [ ] **Step 9: Commit**

```bash
git add ios/poc
git commit -m "fix(ios): make tunnel stop deterministic"
```

---

### Task 2: Complete callback-backed libmqvpn logical paths

**Files:**
- Modify: `include/libmqvpn.h`
- Modify: `src/mqvpn_client.c`
- Modify: `tests/test_api.c`
- Modify: `CMakeLists.txt`

**Interfaces:**
- Produces ABI-appended `mqvpn_send_packet_ex_fn` in `mqvpn_client_callbacks_t`.
- Allows fd-less paths only when `send_packet_ex` or legacy `send_packet` is present.
- Existing fd-backed paths and callers remain behaviorally unchanged.

- [ ] **Step 1: Add failing API tests**

Cover:

- fd `-1` plus no callback is rejected;
- fd `-1` plus result callback returns a handle;
- xquic write for that handle calls the callback with the same handle and peer;
- success accounts bytes once;
- `-EAGAIN` maps to `XQC_SOCKET_EAGAIN` without closing the path;
- hard error uses existing path-dead behavior;
- remove and re-add cannot reuse a still-live xquic binding;
- normal fd path never invokes the callback.

- [ ] **Step 2: Run the focused test and verify RED**

Configure the existing CMake test build if absent, then run:

```bash
cmake --build build --target test_api
ctest --test-dir build --output-on-failure -R '^test_api$'
```

Expected: the fd-less acceptance/callback assertions fail.

- [ ] **Step 3: Append the result callback without breaking ABI**

Add:

```c
typedef ssize_t (*mqvpn_send_packet_ex_fn)(mqvpn_path_handle_t path,
                                           const uint8_t *pkt, size_t len,
                                           const struct sockaddr *peer,
                                           socklen_t peer_len,
                                           void *user_ctx);
```

Append it to the callback table and gate access through `struct_size`. Preserve the existing ABI version unless the repository's ABI tests prove an increment is required; if incremented, accept the previous table size and leave fd paths compatible.

- [ ] **Step 4: Route ops-path writes through the callback**

Centralize fd/callback sending in one helper used by both the legacy and multipath xquic write callbacks. Require full-datagram success. Translate retry and hard errors exactly once and update existing counters only on success.

- [ ] **Step 5: Verify focused and full C tests GREEN**

Run:

```bash
cmake --build build -j
ctest --test-dir build --output-on-failure
```

- [ ] **Step 6: Commit**

```bash
git add include/libmqvpn.h src/mqvpn_client.c tests/test_api.c CMakeLists.txt
git commit -m "feat(core): support callback-backed client paths"
```

---

### Task 3: Add the authenticated relay codec and replay window

**Files:**
- Create: `include/mqvpn/relay_protocol.h`
- Create: `src/relay_protocol.c`
- Create: `tests/test_relay_protocol.c`
- Modify: `CMakeLists.txt`

**Interfaces:**
- Produces `mqvpn_relay_encode`, `mqvpn_relay_decode`, and `mqvpn_replay_window_accept`.
- Uses a caller-provided 32-byte key and fixed v1 network-order header.
- Returns typed parse/auth/replay errors without logging packet or key data.

- [ ] **Step 1: Write failing golden-vector and rejection tests**

Use a deterministic test-only key and nonce. Cover each message type, both directions, empty control payloads, maximum data payload, truncation at every header/tag boundary, nonzero reserved fields, version/type mismatch, payload-length mismatch, one-bit tag corruption, wrong key, duplicate sequence, in-window reordering, and too-old sequence.

- [ ] **Step 2: Run the new test and verify RED**

```bash
cmake --build build --target test_relay_protocol
ctest --test-dir build --output-on-failure -R '^test_relay_protocol$'
```

Expected: target or symbols are missing.

- [ ] **Step 3: Implement the minimal portable codec**

Use BoringSSL HMAC-SHA256, constant-time tag comparison, explicit byte-order helpers, overflow-checked lengths, and zero temporary tag buffers. Keep the encoded packet within one UDP datagram and reject opaque payloads over the spec limit.

- [ ] **Step 4: Verify codec and full C tests GREEN**

Run the focused test, then all CTest tests with `--output-on-failure`.

- [ ] **Step 5: Commit**

```bash
git add include/mqvpn/relay_protocol.h src/relay_protocol.c tests/test_relay_protocol.c CMakeLists.txt
git commit -m "feat(relay): add authenticated datagram protocol"
```

---

### Task 4: Add iPhone Mac Relay mode

**Files:**
- Create: `ios/poc/Shared/OperatingMode.swift`
- Create: `ios/poc/Shared/RelaySettings.swift`
- Create: `ios/poc/PacketTunnel/RelayEngine.swift`
- Modify: `ios/poc/PacketTunnel/BridgingHeader.h`
- Modify: `ios/poc/PacketTunnel/PacketTunnelProvider.swift`
- Modify: `ios/poc/PacketTunnel/SnapshotCache.swift`
- Modify: `ios/poc/Shared/ProviderMessage.swift`
- Modify: `ios/poc/App/SettingsView.swift`
- Modify: `ios/poc/App/DashboardView.swift`
- Modify: `ios/poc/App/MqvpnPoCApp.swift`
- Modify: `ios/poc/Tests/main.swift`
- Modify: `ios/poc/Tests/run-host-tests.sh`
- Modify: `ios/poc/project.yml`

**Interfaces:**
- Produces provider configuration keys for `operatingMode`, `relayKey`, and `relayListenPort`.
- Produces `RelayEngine` with `start`, `stop`, and a snapshot containing readiness, interface names, byte counters, last-authenticated timestamp, and errors.
- Relay mode never creates `MqvpnEngine` or installs a default route.

- [ ] **Step 1: Add failing host tests for settings and state**

Cover VPN-mode backwards compatibility, invalid/missing Base64 key, non-32-byte key, port bounds, relay Start guard, provider configuration round-trip, relay dashboard labels, and Stop reset. Add the new shared Swift files to the host test compilation list.

- [ ] **Step 2: Verify RED with host tests**

Run `bash ios/poc/Tests/run-host-tests.sh` and require failure for missing relay types.

- [ ] **Step 3: Implement operating-mode settings and UI**

Add one segmented/picker choice (`VPN`, `Mac Relay`), relay key secure input, and listen port. Hide VPN-only reorder/Hybrid controls while relay mode is selected. Reuse server host/port and Start/Stop.

- [ ] **Step 4: Add failing RelayEngine lifecycle tests around injected socket operations**

Test authenticated HELLO/ACK, one active Mac session, cellular-only server socket selection, wrong-key/replay drops, fixed server destination, idle expiry, Wi-Fi loss, cellular loss, Stop closing both sockets, and no default route configuration.

- [ ] **Step 5: Implement RelayEngine and provider branch**

Use the existing `IP_BOUND_IF` pattern to bind the LAN listener to Wi-Fi and the connected server socket to cellular. Decode/authenticate before state changes. In relay mode apply non-routing tunnel settings, start only `RelayEngine`, and make `stopTunnel` completion unconditional.

- [ ] **Step 6: Verify host tests and unsigned iOS build GREEN**

Run host tests, `xcodegen generate`, and the generic unsigned iOS build from Task 1.

- [ ] **Step 7: Commit**

```bash
git add ios/poc
git commit -m "feat(ios): add authenticated Mac relay mode"
```

---

### Task 5: Integrate the relay path into the macOS CLI

**Files:**
- Create: `src/platform/darwin/relay_adapter.c`
- Create: `src/platform/darwin/relay_adapter.h`
- Modify: `src/platform/darwin/platform_darwin.c`
- Modify: `src/platform/darwin/platform_darwin.h`
- Modify: `src/platform/darwin/routing.c`
- Modify: `src/platform/darwin/routing.h`
- Modify: `src/platform/darwin/killswitch.c`
- Modify: `src/config.c`
- Modify: `src/config.h`
- Modify: `systemd/client.conf.example`
- Modify: `README.md`
- Create: `tests/test_relay_adapter_darwin.c`
- Modify: `tests/test_config.c`
- Modify: `tests/test_routing_seq_darwin.c`
- Modify: `tests/test_killswitch_rules_darwin.c`
- Modify: `CMakeLists.txt`

**Interfaces:**
- Consumes callback-backed paths and relay codec from Tasks 2-3.
- Produces `[Relay] Enabled`, `Endpoint`, `KeyFile`, and optional `Interface` config.
- Produces a `darwin_relay_adapter_t` that owns LAN socket, session, timers, logical path handle, and counters.

- [ ] **Step 1: Add failing INI/JSON config tests**

Cover disabled default, valid numeric endpoint, hostname rejection, port bounds, missing/unreadable key file, non-private key permissions, wrong decoded key size, duplicate relay declaration, and preservation of existing configs.

- [ ] **Step 2: Verify config tests RED, then implement parsing GREEN**

Run focused `test_config`, implement only the specified fields, and rerun.

- [ ] **Step 3: Add failing route and pf exclusion tests**

Prove the iPhone endpoint receives an outside-utun scoped host route and a narrow relay UDP pf allowance, both are idempotent, and cleanup removes only owned rules.

- [ ] **Step 4: Implement route/pf integration and verify GREEN**

Follow existing command construction and injected-command test patterns; do not introduce an alternate routing subsystem.

- [ ] **Step 5: Add failing adapter tests**

Using injected socket/time/random/send operations, cover HELLO retry, ACK activation, callback send framing, authenticated reply delivery to the correct libmqvpn handle, backpressure, hard socket failure, idle expiry/removal, reconnect with a fresh session, and shutdown cleanup.

- [ ] **Step 6: Implement the adapter and CLI wiring**

Create the adapter after direct paths, add its logical path only after authenticated ACK, count direct plus relay as multipath, and feed replies to `mqvpn_client_on_socket_recv`. Existing signal cleanup must stop the adapter before destroying the client.

- [ ] **Step 7: Verify Darwin tests, full CTest, and a local macOS build**

```bash
cmake --build build -j
ctest --test-dir build --output-on-failure
```

Then run the repository's documented Darwin release configuration against the existing BoringSSL/xquic/libevent artifacts and require the `mqvpn` binary to link.

- [ ] **Step 8: Commit**

```bash
git add src/platform/darwin src/config.c src/config.h systemd/client.conf.example README.md tests CMakeLists.txt
git commit -m "feat(macos): add iPhone cellular relay path"
```

---

### Task 6: Deploy the private ZeroFS alias and document Proxmox guests

**Files:**
- Create: `deploy/proxmox/mqvpn-zerofs-alias.service`
- Create: `docs/proxmox-ct212-mqvpn.md`

**Interfaces:**
- Adds tunnel-only `10.77.77.55:8080 -> 10.10.10.55:8080` DNAT.
- Updates Proxmox Notes for CT 212, CT 198, and VM 104 without secrets.

- [ ] **Step 1: Add a static unit validation test**

Create a shell check that runs `systemd-analyze verify` in Debian 12/CT 212 and asserts the unit contains the exact source interface, source subnet, alias address, destination, port, comments, idempotent starts, and owned-rule cleanup.

- [ ] **Step 2: Verify the check fails before the unit exists**

Run the check and record the missing-unit failure.

- [ ] **Step 3: Add and validate the unit**

The unit must add only the DNAT and stateful forward rules in the spec and remove only rules carrying `mqvpn-zerofs-alias`. Validate with `systemd-analyze verify` and a shell syntax check.

- [ ] **Step 4: Commit the deployment artifact and runbook**

```bash
git add deploy/proxmox/mqvpn-zerofs-alias.service docs/proxmox-ct212-mqvpn.md
git commit -m "ops(proxmox): add private ZeroFS mqvpn alias"
```

- [ ] **Step 5: Deploy and verify live state**

Push the committed unit to CT 212, enable it, and verify service active plus exact iptables rules. From an authenticated mqvpn client, require HTTP 200 and WebSocket 101 through `10.77.77.55:8080`; do not infer end-to-end success from rule presence alone.

- [ ] **Step 6: Update Proxmox Notes**

Append detailed topology, security, service, dependencies, operational commands, and failure boundaries to CT 212. Append the alias/source-NAT relationship to CT 198. Clarify in VM 104 that mqvpn-to-ZeroFS is direct on `vmbr1` and does not traverse the Mullvad gateway. Preserve every existing note and store no keys.

---

### Task 7: Physical integration, optimization, and ZeroFS proof

**Files:**
- Create: `scripts/relay-physical-gate.sh`
- Create: `docs/relay-physical-acceptance.md`

**Interfaces:**
- Consumes all prior tasks.
- Produces timestamped receipts for Stop, two paths, failover, combined speed, and ZeroFS upload.

- [ ] **Step 1: Install the signed iOS build and Mac CLI**

Build with the configured team/profiles, install on the physical iPhone, build/install the Mac CLI, and configure a separate relay key file with owner-only permissions. Do not print either PSK.

- [ ] **Step 2: Prove Stop before relay testing**

Capture `mqvpn.poc` device logs. Start VPN mode, confirm GT egress, press Stop, require the status sequence to `.disconnected`, `STOP_FINISHED`, removal of the VPN route, and a fresh non-GT public IP.

- [ ] **Step 3: Prove relay identity and failover**

Start iPhone Relay mode and the Mac client. Require one server client with two distinct paths, a cellular-bound iPhone server socket, and increasing bytes on both. Stop relay and require Mac traffic to continue direct; restart relay and require a fresh logical path without restarting the Mac VPN.

- [ ] **Step 4: Capture controlled single-path baselines**

Run three 60-second GT-host downloads for direct only and relay only. Record median MB/s, CPU, RTT/loss/cwnd, socket errors, qdisc drops, MTU, Hybrid lane, and per-path bytes.

- [ ] **Step 5: Measure combined mode and optimize one variable at a time**

Run three combined trials. If the median does not exceed the faster baseline by 5 percent with both counters moving, identify the first saturated/error signal and change only its corresponding setting. Re-run all three modes after each change and revert changes that do not improve the controlled median.

- [ ] **Step 6: Prove ZeroFS through the private alias**

Run:

```bash
caffeinate -ims /Users/zackjackson/.cargo/bin/zerofs upload \
  ws://10.77.77.55:8080/ws/9p \
  '/Volumes/JBOD Drive/Audiobooks' \
  '/Audiobooks/JBOD Offload' \
  --jobs 1 \
  --resume
```

Record the route, sustained application rate, per-path contribution, completion status, and a destination receipt. A connection, lease, cache hit, or byte counter without completion is not a durable upload receipt.

- [ ] **Step 7: Commit scripts and acceptance documentation**

```bash
git add scripts/relay-physical-gate.sh docs/relay-physical-acceptance.md
git commit -m "test(relay): add physical aggregation gate"
```

- [ ] **Step 8: Run final verification**

Run host tests, complete CTest, unsigned generic iOS build, signed physical build/install, Stop gate, relay failover gate, combined performance gate, and ZeroFS receipt. Record exact commands, SHAs, and results without secrets.
