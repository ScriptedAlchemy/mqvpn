# macOS Network Extension Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and physically validate a macOS VPN app/profile that bonds a direct Mac path with the authenticated iPhone cellular relay without root-managed routes.

**Architecture:** A SwiftUI app owns one `NETunnelProviderManager`; an embedded macOS `NEPacketTunnelProvider` owns packet flow and one `MqvpnEngine`. The provider binds physical UDP sockets, adds the iPhone as a callback-backed logical path after authenticated ACK, and lets Network Extension own route/DNS lifecycle.

**Tech Stack:** Swift 5.9, SwiftUI, NetworkExtension, Network, XcodeGen, C11 libmqvpn, xquic, BoringSSL, lwIP.

**Spec:** `docs/superpowers/specs/2026-08-24-macos-network-extension-client-design.md`

## Global Constraints

- All source and build products stay under `/Volumes/bigssd/projects/mqvpn`.
- The app never invokes the root CLI, `route`, `networksetup`, or `pfctl`.
- The iPhone and Mac share one Mac-owned mqvpn client session.
- Relay authentication and replay protection use `src/relay_protocol.c` only.
- Default tunnel settings are applied only after a real path authenticates.
- All-path loss cancels the VPN after a five-second recovery window.
- Other VPN profiles are preserved and never enumerated for mutation.

---

### Task 1: Expose callback-backed paths in the Apple engine

**Files:**
- Modify: `ios/poc/PacketTunnel/MqvpnEngine.swift`
- Modify: `ios/poc/Tests/main.swift`
- Modify: `ios/poc/Tests/run-host-tests.sh`

**Interfaces:**
- Produces: `onLogicalPathSend`, `addLogicalPath(desc:)`, and existing `socketRecv`/`removePath` support for a callback-backed handle.
- Produces: authoritative `onPathEvent` and `activePathCount()` for fail-open recovery.

- [ ] Add host tests proving callback path registration is not treated as an fd path, send result mapping preserves full length/`EAGAIN`/hard errno, and path events report zero versus nonzero active paths.
- [ ] Run `bash ios/poc/Tests/run-host-tests.sh` and require the new assertions to fail before implementation.
- [ ] Set `mqvpn_client_callbacks_t.send_packet_ex` to a static Swift callback that hops only through the tick-thread-owned engine closure; add `fd = -1` registration and path-event accessors.
- [ ] Rerun host tests and the native 14-test CTest suite.
- [ ] Commit as `feat(apple): expose logical relay paths`.

### Task 2: Implement the Mac relay binder and preflight

**Files:**
- Create: `macos/poc/PacketTunnel/MacRelayBinder.swift`
- Create: `macos/poc/Shared/MacRelayRuntimeState.swift`
- Create: `macos/poc/Tests/main.swift`
- Create: `macos/poc/Tests/run-host-tests.sh`

**Interfaces:**
- Consumes: Task 1 logical path hooks and C `mqvpn_relay_encode`/`mqvpn_relay_decode`.
- Produces: `start()`, `stop()`, `snapshot()`, and authenticated path lifecycle.

- [ ] Add pure state tests for HELLO retry, invalid HMAC/direction/session/replay drops, ACK activation, DATA_TO_MAC delivery, hard socket reopen, expiry, local-address rejection, and key erasure.
- [ ] Run the Mac host test script and require RED for the missing runtime state.
- [ ] Implement a Wi-Fi/Ethernet-bound connected UDP socket, Dispatch read source, C-codec framing, and tick-thread engine hops. Add the logical path only after ACK.
- [ ] Emit separate HELLO sent, raw received, auth accepted/rejected, ACK, and byte counters without logging secrets.
- [ ] Rerun Mac host tests, iOS host tests, and native CTests.
- [ ] Commit as `feat(macos): add authenticated relay binder`.

### Task 3: Build the macOS packet-tunnel provider

**Files:**
- Create: `macos/poc/PacketTunnel/PacketTunnelProvider.swift`
- Create: `macos/poc/PacketTunnel/Info.plist`
- Create: `macos/poc/PacketTunnel/BridgingHeader.h`
- Create: `macos/poc/PacketTunnel/SnapshotCache.swift`
- Create: `macos/poc/Shared/MacProviderPlan.swift`
- Modify: `ios/poc/PacketTunnel/PathBinder.swift`

**Interfaces:**
- Consumes: `MqvpnEngine`, direct `PathBinder`, and `MacRelayBinder`.
- Produces: a complete `NEPacketTunnelProvider` with app-message snapshots.

- [ ] Add host tests for excluded server/relay `/32` routes, default inclusion, DNS/MTU, first-path startup, five-second all-path cancellation, recovery, and deterministic Stop ordering.
- [ ] Run host tests and require RED for the missing provider plan.
- [ ] Implement provider startup so direct and relay probes begin before settings, and apply settings only after `tunnel_config_ready`.
- [ ] Implement `packetFlow` read/write, provider snapshots, `reasserting`, bounded cancellation, and transport-first Stop.
- [ ] Rerun all host/native tests and compile the provider target unsigned.
- [ ] Commit as `feat(macos): add packet tunnel provider`.

### Task 4: Build the macOS app and VPN-profile controller

**Files:**
- Create: `macos/poc/App/MqvpnMacApp.swift`
- Create: `macos/poc/App/TunnelController.swift`
- Create: `macos/poc/App/DashboardView.swift`
- Create: `macos/poc/App/SettingsView.swift`
- Create: `macos/poc/App/Info.plist`
- Create: `macos/poc/Shared/TunnelProviderConfiguration.swift`

**Interfaces:**
- Produces: exactly one app-owned `NETunnelProviderManager` and a simple Start/Stop/settings UI.

- [ ] Add pure tests for matching-manager selection, atomic save/reload, Start/Stop guards, exact provider ID, status transitions, and no mutation of nonmatching managers.
- [ ] Run tests and require RED for the missing Mac controller helpers.
- [ ] Implement manager creation with provider ID `com.zackjackson.mqvpn.mac.PacketTunnel`, localized name `mqvpn`, `excludeLocalNetworks = true`, and `enforceRoutes = false`.
- [ ] Implement a compact SwiftUI dashboard with direct/relay rows, rates, last error, settings, and idempotent Stop.
- [ ] Rerun host tests and compile the app target unsigned.
- [ ] Commit as `feat(macos): add mqvpn VPN app`.

### Task 5: Add reproducible macOS native libraries, Xcode project, and signing

**Files:**
- Create: `macos/build-macos.sh`
- Create: `macos/poc/project.yml`
- Create: `macos/poc/Config.example.xcconfig`
- Create: `macos/poc/App.entitlements`
- Create: `macos/poc/PacketTunnel.entitlements`
- Modify: `README.md`

**Interfaces:**
- Produces: signed app `com.zackjackson.mqvpn.mac` embedding signed provider `com.zackjackson.mqvpn.mac.PacketTunnel`.

- [ ] Implement a clean arm64 macOS dependency build/stage under `macos/build`, reusing pinned submodule commits.
- [ ] Generate the Xcode project with app sandbox, network client/server, and `packet-tunnel-provider` entitlements on both targets.
- [ ] Require a clean generic arm64 Release build and embedded binary validation before signing.
- [ ] Create/download macOS development profiles for both identifiers with team `5NDMQZP6KR`, then require `codesign -dvvv --entitlements :-` to show the exact Network Extension entitlement.
- [ ] Commit as `build(macos): package network extension client`.

### Task 6: Physical safety, bonding, and ZeroFS acceptance

**Files:**
- Create: `docs/superpowers/reports/2026-08-24-macos-network-extension-acceptance.md`
- Modify: `deploy/proxmox/README.md`

**Interfaces:**
- Consumes: the signed Mac app/provider and the signed iPhone relay app.
- Produces: end-to-end receipts; no product code is accepted from unit tests alone.

- [ ] Disconnect other full-tunnel VPNs, install the app, create the visible mqvpn VPN profile, and verify direct-only GT egress plus clean Stop restoration.
- [ ] Start with the server unreachable and prove no default route is installed after the failed Start.
- [ ] Run the LAN preflight and require HELLO sent, iPhone raw receive, auth accept, ACK, and relay-active receipts.
- [ ] Connect one server client with two paths; prove direct and relay bytes both increase.
- [ ] Test direct loss, relay loss, then both loss; require automatic ordinary-Internet restoration after both loss.
- [ ] Run three 60-second repetitions each for direct-only, relay-only, and combined against one fixed endpoint; record medians, per-path bytes, CPU, and drops.
- [ ] Require combined median at least `1.05 * max(single paths)` and each path at least five percent plus 32 MiB.
- [ ] Verify `ws://10.77.77.55:8080/ws/9p`, resume the ZeroFS uploader with `--jobs 1 --resume`, and record destination durability.
- [ ] Commit the acceptance report and updated Proxmox notes.
