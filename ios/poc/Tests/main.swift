// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors
import Foundation

check(!RelayAdvertisementPolicy.shouldPublish(lanReady: true,
                                               cellularReady: false,
                                               stopped: false) &&
      RelayAdvertisementPolicy.shouldPublish(lanReady: true,
                                              cellularReady: true,
                                              stopped: false) &&
      !RelayAdvertisementPolicy.shouldPublish(lanReady: true,
                                               cellularReady: true,
                                               stopped: true),
      "relay Bonjour advertises only while both forwarding sockets are ready")
check(RelayInterfaceObservation.effective(observed: nil, current: "en0",
                                          socketReady: true) == "en0" &&
      RelayInterfaceObservation.effective(observed: nil, current: "en0",
                                          socketReady: false) == nil &&
      RelayInterfaceObservation.effective(observed: "en1", current: "en0",
                                          socketReady: true) == "en1",
      "a transient monitor miss cannot close a live interface-bound relay socket")
import Darwin

var failures = 0
func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1; print("FAIL: \(msg)") } }

// planReorder
check(ReorderSettings(enabled: false, profile: 4, ports: [443]).planReorder().rules.isEmpty,
      "disabled -> empty plan")
let plan = ReorderSettings(enabled: true, profile: 4, ports: [443, 443, 0, 70000, 5401]).planReorder()
check(plan.rules.map { $0.port } == [443, 5401], "dedupe + range filter")
check(plan.rules.allSatisfy { $0.proto == 17 && $0.profile == 4 }, "proto=17 + profile passthrough")
check(plan.warnings.contains { $0.contains(": 0") } && plan.warnings.contains { $0.contains("70000") },
      "out-of-range warnings")
let many = ReorderSettings(enabled: true, profile: 3, ports: Array(1000..<1020)).planReorder()
check(many.rules.count == 16 && many.warnings.contains { $0.contains("exceed 16") }, "cap at 16 + warning")

// isSavable
check(ReorderSettings(enabled: true, profile: 3, ports: []).isSavable == false, "enabled+no-ports unsavable")
check(ReorderSettings(enabled: true, profile: 3, ports: [443]).isSavable, "enabled+port savable")
check(ReorderSettings(enabled: false, profile: 3, ports: []).isSavable, "disabled always savable")

// parsePorts
let pp = ReorderSettings.parsePorts(" 443, 5401 ,x, ")
check(pp.ports == [443, 5401] && pp.warnings.contains { $0.contains("x") }, "parsePorts trim/skip/warn")

// providerConfiguration round-trip
let s = ReorderSettings(enabled: true, profile: 4, ports: [443, 5401])
check(ReorderSettings(providerConfiguration: s.toProviderConfiguration()) == s, "round-trip")

// exact-int validation
check(ReorderSettings.exactInt(NSNumber(value: true)) == nil, "reject bool NSNumber")
check(ReorderSettings.exactInt(NSNumber(value: 3.0)) == nil, "reject double-backed NSNumber")
check(ReorderSettings.exactInt(NSNumber(value: 3)) == 3, "accept int NSNumber")
let bad: [String: Any] = ["reorderEnabled": NSNumber(value: true),
                          "reorderProfile": NSNumber(value: 3.9),
                          "reorderPorts": [NSNumber(value: true), NSNumber(value: 443)]]
let parsed = ReorderSettings(providerConfiguration: bad)!
check(parsed.profile == 3 && parsed.ports == [443], "double profile clamps; bool port dropped")

// reorderEnableDecision (fail-closed)
check(ReorderSettings.reorderEnableDecision(ruleResults: [false, false]).enable == false, "all-fail -> disabled")
check(ReorderSettings.reorderEnableDecision(ruleResults: [false, true]) == (true, 1), "partial -> enabled, added=1")
check(ReorderSettings.reorderEnableDecision(ruleResults: []).enable == false, "no rules -> disabled")

// old-wire decode: JSON missing the new keys -> safe defaults, no throw
let oldWire = #"{"timestamp":1.0,"clientState":4,"connectedSince":0.5,"footprint":100,"paths":[]}"#
    .data(using: .utf8)!
let old = try! JSONDecoder().decode(TunnelSnapshot.self, from: oldWire)
check(old.seq == 0 && old.reorderConfigured == false && old.reorder == nil, "old-wire safe defaults")

// new-wire round-trip
let full = TunnelSnapshot(timestamp: 2, clientState: 4, connectedSince: 1, footprint: 1, paths: [],
                          seq: 7, reorderConfigured: true,
                          reorder: ReorderStatsSnapshot(delivered: 5, gapCount: 1, gapFilled: 1,
                                                        gapTimeout: 0, ackDemote: 0,
                                                        bufferedP50Ms: 1.5, bufferedP99Ms: 9.0))
let rt = try! JSONDecoder().decode(TunnelSnapshot.self, from: try! JSONEncoder().encode(full))
check(rt.seq == 7 && rt.reorderConfigured && rt.reorder == full.reorder, "new-wire round-trip")

// saveGuard order
check(saveGuard(isSaving: true, isEditable: false, hasManager: false) == .inProgress, "inProgress first")
check(saveGuard(isSaving: false, isEditable: false, hasManager: true) == .notEditable, "notEditable")
check(saveGuard(isSaving: false, isEditable: true, hasManager: false) == .notReady, "notReady")
check(saveGuard(isSaving: false, isEditable: true, hasManager: true) == nil, "proceed")

// performAtomicSave (real rollback logic, fault-injected via a fake store)
enum TestErr: Error { case boom }
final class FakeStore: ReorderConfigStore {
    var providerConfiguration: [String: Any]?
    var commitThrows = false
    var refreshThrows = false
    func commit() async throws { if commitThrows { throw TestErr.boom } }
    func refresh() async throws { if refreshThrows { throw TestErr.boom } }
}
func runAsync(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    sem.wait()
}
func boolOf(_ store: FakeStore, _ k: String) -> Bool? {
    (store.providerConfiguration?[k] as? NSNumber)?.boolValue
}
runAsync {
    // commit fails -> providerConfiguration rolled back to the backup value
    let store = FakeStore(); store.providerConfiguration = ["reorderEnabled": NSNumber(value: false)]
    store.commitThrows = true
    var threw = false
    do { try await performAtomicSave(store, merge: ["reorderEnabled": NSNumber(value: true)]) }
    catch { threw = true }
    check(threw && boolOf(store, "reorderEnabled") == false, "commit fail -> rethrow + rollback")
}
runAsync {
    // commit ok but refresh fails -> committed value stays (refresh non-fatal)
    let store = FakeStore(); store.providerConfiguration = [:]
    store.refreshThrows = true
    var threw = false
    do { try await performAtomicSave(store, merge: ["reorderEnabled": NSNumber(value: true)]) }
    catch { threw = true }
    check(!threw && boolOf(store, "reorderEnabled") == true, "refresh fail -> committed")
}

// IngestGate
check(!IngestGate.accept(capturedEpoch: 1, currentEpoch: 2, isUp: true, snapSeq: 5,
                         snapTimestamp: 9, lastSeq: 0, lastTimestamp: 0), "stale epoch rejected")
check(!IngestGate.accept(capturedEpoch: 1, currentEpoch: 1, isUp: false, snapSeq: 5,
                         snapTimestamp: 9, lastSeq: 0, lastTimestamp: 0), "not-up rejected")
check(!IngestGate.accept(capturedEpoch: 1, currentEpoch: 1, isUp: true, snapSeq: 5,
                         snapTimestamp: 9, lastSeq: 5, lastTimestamp: 0), "seq regression rejected")
check(IngestGate.accept(capturedEpoch: 1, currentEpoch: 1, isUp: true, snapSeq: 6,
                        snapTimestamp: 9, lastSeq: 5, lastTimestamp: 0), "seq advance accepted")
check(IngestGate.accept(capturedEpoch: 1, currentEpoch: 1, isUp: true, snapSeq: 0,
                        snapTimestamp: 2, lastSeq: 0, lastTimestamp: 1), "legacy ts advance accepted")
check(!IngestGate.accept(capturedEpoch: 1, currentEpoch: 1, isUp: true, snapSeq: 0,
                         snapTimestamp: 1, lastSeq: 0, lastTimestamp: 2), "legacy ts regression rejected")
// legacy response must NOT slip in after a modern snapshot (lastSeq != 0)
check(!IngestGate.accept(capturedEpoch: 1, currentEpoch: 1, isUp: true, snapSeq: 0,
                         snapTimestamp: 99, lastSeq: 5, lastTimestamp: 0), "legacy rejected once modern seen")

// ── ServerSettings ──
let ss = ServerSettings(host: "1.2.3.4", port: 443, serverName: "vpn.example.com", authKey: "k", insecure: true)
check(ServerSettings(providerConfiguration: ss.toProviderConfiguration()) == ss, "server round-trip")
check(ServerSettings(host: " 1.2.3.4 ", port: 443, serverName: "", authKey: " k ", insecure: false).host == "1.2.3.4", "host trimmed")
check(ServerSettings(host: " 1.2.3.4 ", port: 443, serverName: "", authKey: " k ", insecure: false).authKey == "k", "authKey trimmed")
check(ServerSettings(host: "h", port: 443, serverName: " vpn.example.com ", authKey: "", insecure: false).serverName == "vpn.example.com", "serverName trimmed")
check(ss.isValid, "valid savable")
check(ServerSettings(host: "  ", port: 443, serverName: "", authKey: "", insecure: true).isValid == false, "empty host invalid")
check(ServerSettings(host: "h", port: 0, serverName: "", authKey: "", insecure: true).isValid == false, "port 0 invalid")
check(ServerSettings(host: "h", port: 70000, serverName: "", authKey: "", insecure: true).isValid == false, "port hi invalid")
check(ServerSettings(host: "h", port: 443, serverName: "", authKey: "", insecure: true).isValid, "empty authKey ok")
// read validation
check(ServerSettings(providerConfiguration: ["serverHost": "h", "serverPort": NSNumber(value: 443), "authKey": "k"]) == nil, "missing tlsInsecure → nil")
check(ServerSettings(providerConfiguration: ["serverHost": "h", "serverPort": NSNumber(value: true), "authKey": "k", "tlsInsecure": NSNumber(value: false)]) == nil, "bool port → nil")
check(ServerSettings(providerConfiguration: ["serverHost": "", "serverPort": NSNumber(value: 443), "authKey": "k", "tlsInsecure": NSNumber(value: false)]) == nil, "empty host → nil")
// serverName: pre-key configs (absent) stay valid and read as ""; wrong type is corrupt
let preKey = ServerSettings(providerConfiguration: ["serverHost": "h", "serverPort": NSNumber(value: 443), "authKey": "k", "tlsInsecure": NSNumber(value: false)])
check(preKey?.serverName == "", "absent serverName → \"\"")
check(ServerSettings(providerConfiguration: ["serverHost": "h", "serverPort": NSNumber(value: 443), "serverName": NSNumber(value: 1), "authKey": "k", "tlsInsecure": NSNumber(value: false)]) == nil, "non-string serverName → nil")
// existence (Rigor E): wrong-type key still counts as present → corrupt, not absent
check(ServerSettings.serverKeysPresent(in: ["serverPort": "not-a-number"]) == true, "wrong-type key present")
check(ServerSettings.serverKeysPresent(in: ["reorderEnabled": NSNumber(value: true)]) == false, "only reorder keys → absent")
check(ServerSettings.serverKeysPresent(in: nil) == false, "nil dict → absent")

// ── resolveServer (offline) ──
// Shared assertion: AF_INET, big-endian port, exact sockaddr_in length.
func check4(_ r: ResolvedServerAddress?, _ port: UInt16, _ label: String) {
    guard let r else { check(false, "\(label): returned nil"); return }
    var sa = r.storage
    let ok = withUnsafeBytes(of: &sa) { raw -> Bool in
        let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
        return sin.sin_family == sa_family_t(AF_INET)
            && sin.sin_port == in_port_t(port.bigEndian)
            && r.len == socklen_t(MemoryLayout<sockaddr_in>.size)
    }
    check(ok, label)
}
check4(resolveServer("127.0.0.1", 443), 443, "resolve IP literal 127.0.0.1:443")
check4(resolveServer("localhost", 8080), 8080, "resolve hostname localhost:8080")  // /etc/hosts, offline; proves the name (non-literal) path + port propagation
check(resolveServer("", 443) == nil, "empty host → nil")       // Optional<T> == nil compiles for any T
check(resolveServer("   ", 443) == nil, "whitespace host → nil")

// ipString: NE requires an IP literal for tunnelRemoteAddress; hostnames must
// resolve to their dotted-decimal form, not pass through unresolved.
check(resolveServer("127.0.0.1", 443)?.ipString == "127.0.0.1", "ipString IP literal")
check(resolveServer("localhost", 8080)?.ipString == "127.0.0.1", "ipString from hostname")

// HybridSettings
let hy = HybridSettings(enabled: true, tcpMode: 0)
check(HybridSettings(providerConfiguration: hy.toProviderConfiguration()) == hy, "hybrid round-trip")
check(HybridSettings.disabled == HybridSettings(enabled: false, tcpMode: 2), "hybrid disabled default auto")
check(HybridSettings(providerConfiguration: nil) == nil, "hybrid nil dict -> nil")
let hyBad: [String: Any] = ["hybridEnabled": NSNumber(value: true), "hybridTcpMode": NSNumber(value: 9)]
check(HybridSettings(providerConfiguration: hyBad)!.tcpMode == 2, "out-of-range mode clamps to auto")
let hyBool: [String: Any] = ["hybridEnabled": NSNumber(value: 1), "hybridTcpMode": NSNumber(value: true)]
let hyParsed = HybridSettings(providerConfiguration: hyBool)!
check(hyParsed.enabled == false, "int-backed enabled rejected (isBool strict)")
check(hyParsed.tcpMode == 2, "bool-backed mode clamps to auto")

// ── Tunnel lifecycle ──
// These catch an accidental selection of a stale or another app's profile,
// a Stop action that leaves a live tunnel visually connected, and a Stop that
// hangs after the engine tick thread has already exited.
let selectedManager = selectMatchingManager([
    .init(id: "old", providerBundleID: "com.mp0rta.mqvpnpoc.PacketTunnel", status: .connected),
    .init(id: "current", providerBundleID: TunnelProviderConfiguration.providerBundleID, status: .disconnected),
], providerBundleID: TunnelProviderConfiguration.providerBundleID)
check(selectedManager?.id == "current", "select matching provider profile, never a stale first profile")
check(selectMatchingManager([
    .init(id: "other", providerBundleID: "com.example.other.PacketTunnel", status: .connected),
], providerBundleID: TunnelProviderConfiguration.providerBundleID) == nil,
      "no matching provider profile stays unavailable")

check(StopLifecycle.request(hasManager: false, status: .connected) == .unavailable,
      "Stop without a manager is unavailable")
check(StopLifecycle.request(hasManager: true, status: .disconnected) == .alreadyStopped,
      "Stop on a disconnected manager is already stopped")
for status in [TunnelStatus.connected, .reasserting] {
    let request = StopLifecycle.request(hasManager: true, status: status)
    check(request == .requested, "Stop requests disconnect from \(status)")
    check(StopLifecycle.visibleStatus(after: request, current: status) == .disconnecting,
          "requested Stop visibly disconnects from \(status)")
}
check(StopLifecycle.transition(from: .requested, observedStatus: .disconnected) == .stopped,
      "disconnected notification completes Stop successfully")
check(StopLifecycle.transition(from: .requested, timedOut: true) == .failed,
      "Stop timeout fails instead of waiting forever")
check(StopLifecycle.transition(from: .requested, didError: true) == .failed,
      "Stop error fails instead of waiting forever")

var acceptedTeardowns = 0
var acceptedCompletions = 0
StopLifecycle.performOrFinish(
    perform: { body in body(); return true },
    accepted: { acceptedTeardowns += 1; acceptedCompletions += 1 },
    rejected: { acceptedCompletions += 100 })
check(acceptedTeardowns == 1 && acceptedCompletions == 1,
      "accepted engine dispatch tears down and finishes exactly once")

var rejectedCompletions = 0
StopLifecycle.performOrFinish(
    perform: { _ in false },
    accepted: { rejectedCompletions += 100 },
    rejected: { rejectedCompletions += 1 })
check(rejectedCompletions == 1,
      "rejected engine dispatch finishes locally exactly once")

// ── Mac Relay settings and provider mode ──
// These catch silently treating a corrupt relay configuration as VPN mode,
// accepting a weak/wrong-size key, and enabling Start without all relay
// prerequisites.
check(OperatingMode(providerConfiguration: nil) == .vpn,
      "pre-relay provider configuration remains VPN mode")
check(OperatingMode(providerConfiguration: [:]) == .vpn,
      "missing operatingMode remains VPN mode")
check(OperatingMode(providerConfiguration: ["operatingMode": "bogus"]) == nil,
      "unknown operatingMode fails closed")
check(OperatingMode(providerConfiguration: OperatingMode.macRelay.toProviderConfiguration()) == .macRelay,
      "Mac Relay mode provider round-trip")

let relayKeyData = Data((0..<32).map(UInt8.init))
let relayKey = relayKeyData.base64EncodedString()
let relay = RelaySettings(keyBase64: relayKey, listenPort: 5443)
check(relay.decodedKey == relayKeyData, "relay key decodes to exactly 32 bytes")
check(relay.isValid, "32-byte relay key and valid port are accepted")
check(RelaySettings(providerConfiguration: relay.toProviderConfiguration()) == relay,
      "relay provider configuration round-trip")
check(!RelaySettings(keyBase64: "not base64", listenPort: 5443).isValid,
      "invalid Base64 relay key is rejected")
check(!RelaySettings(keyBase64: Data(repeating: 1, count: 31).base64EncodedString(), listenPort: 5443).isValid,
      "non-32-byte relay key is rejected")
check(!RelaySettings(keyBase64: relayKey, listenPort: 0).isValid,
      "relay port zero is rejected")
check(!RelaySettings(keyBase64: relayKey, listenPort: 65_536).isValid,
      "relay port above 65535 is rejected")
check(RelaySettings(providerConfiguration: ["relayKey": relayKey]) == nil,
      "missing relay listen port fails closed")

check(RelayStartGuard.canStart(mode: .vpn, server: ss, relay: nil),
      "VPN mode remains startable without relay settings")
check(!RelayStartGuard.canStart(mode: .macRelay, server: ss, relay: nil),
      "Mac Relay mode cannot start without relay settings")
check(RelayStartGuard.canStart(mode: .macRelay, server: ss, relay: relay),
      "Mac Relay mode starts with valid server and relay settings")
check(!RelayStartGuard.canStart(mode: .macRelay, server: .emptyDraft, relay: relay),
      "Mac Relay mode cannot start without a valid fixed server")

let relayWire = TunnelSnapshot(
    timestamp: 10, clientState: -1, connectedSince: nil, footprint: 12,
    paths: [], operatingMode: .macRelay,
    relay: RelaySnapshot(wifiAvailable: true, cellularAvailable: true,
                         authenticatedSession: true, listenerInterface: "en0",
                         cellularInterface: "pdp_ip0", lanRxBytes: 10,
                         lanTxBytes: 20, serverRxBytes: 30, serverTxBytes: 40,
                         lastAuthenticated: 9, error: nil))
let relayWireRoundTrip = try! ProviderMessage.decode(ProviderMessage.encode(relayWire))
check(relayWireRoundTrip.operatingMode == .macRelay && relayWireRoundTrip.relay?.isReady == true,
      "relay snapshot provider round-trip preserves readiness")
check(RelayDashboard.statusLabel(tunnelStatus: .connected, snapshot: relayWireRoundTrip) == "Relay ready",
      "relay dashboard labels an authenticated ready relay")
check(RelayDashboard.statusLabel(tunnelStatus: .connected,
                                 snapshot: TunnelSnapshot.relayStopped(timestamp: 11)) == "Relay waiting",
      "relay dashboard never labels a mere listener as ready")

// ── Live Activity production-rate sampling ──
// These catch displaying cumulative bytes as a speed, carrying a stale rate
// after an interface disappears, treating a counter reset as a huge burst,
// and sourcing relay-mode rates from anything except its real socket counters.
var activityRates = LiveActivityRateSampler(smoothingFactor: 0.5)
let firstRates = activityRates.sample(
    timestamp: 100,
    counters: [
        InterfaceByteCounter(name: "en0", totalBytes: 1_000, active: true),
        InterfaceByteCounter(name: "pdp_ip0", totalBytes: 2_000, active: true),
    ])
check(firstRates.wifi?.interfaceName == "en0" && firstRates.wifi?.megabitsPerSecond == nil,
      "first Wi-Fi counter is sampling, never presented as zero throughput")
check(firstRates.cellular?.interfaceName == "pdp_ip0" &&
      firstRates.cellular?.megabitsPerSecond == nil,
      "first cellular counter is sampling, never presented as zero throughput")

let secondRates = activityRates.sample(
    timestamp: 102,
    counters: [
        InterfaceByteCounter(name: "en0", totalBytes: 3_001_000, active: true),
        InterfaceByteCounter(name: "pdp_ip0", totalBytes: 6_002_000, active: true),
    ])
check(abs((secondRates.wifi?.megabitsPerSecond ?? -1) - 12) < 0.0001,
      "Wi-Fi Mbps derives from the real byte delta and elapsed time")
check(abs((secondRates.cellular?.megabitsPerSecond ?? -1) - 24) < 0.0001,
      "cellular Mbps derives independently from its real byte delta")

let smoothedRates = activityRates.sample(
    timestamp: 104,
    counters: [
        InterfaceByteCounter(name: "en0", totalBytes: 9_001_000, active: true),
        InterfaceByteCounter(name: "pdp_ip0", totalBytes: 6_002_000, active: true),
    ])
check(abs((smoothedRates.wifi?.megabitsPerSecond ?? -1) - 18) < 0.0001,
      "display rate applies bounded exponential smoothing")
check(abs((smoothedRates.cellular?.megabitsPerSecond ?? -1) - 12) < 0.0001,
      "an idle live interface decays honestly instead of retaining its peak")

let missingCellular = activityRates.sample(
    timestamp: 106,
    counters: [InterfaceByteCounter(name: "en0", totalBytes: 9_001_000, active: true)])
check(missingCellular.cellular == nil,
      "a missing cellular interface immediately disappears from the activity")

let resetWiFi = activityRates.sample(
    timestamp: 108,
    counters: [InterfaceByteCounter(name: "en0", totalBytes: 10, active: true)])
check(resetWiFi.wifi?.megabitsPerSecond == nil,
      "a reset Wi-Fi counter restarts sampling instead of underflowing")

let stalledWiFi = activityRates.sample(
    timestamp: 140,
    counters: [InterfaceByteCounter(name: "en0", totalBytes: 4_000_010, active: true)])
check(stalledWiFi.wifi?.megabitsPerSecond == nil,
      "a long sampling stall is marked unavailable instead of averaged as live")

let vpnCounters = LiveActivityCounterSource.counters(from: TunnelSnapshot(
    timestamp: 1, clientState: 4, connectedSince: 0, footprint: 0,
    paths: [
        PathSnapshot(name: "en0", status: 1, txBytes: 100, rxBytes: 200),
        PathSnapshot(name: "pdp_ip0", status: 0, txBytes: 300, rxBytes: 400),
    ]))
check(vpnCounters == [InterfaceByteCounter(name: "en0", totalBytes: 300, active: true)],
      "VPN activity consumes only active production path counters")

let relayCounters = LiveActivityCounterSource.counters(from: relayWire)
check(relayCounters == [
    InterfaceByteCounter(name: "en0", totalBytes: 30, active: true),
    InterfaceByteCounter(name: "pdp_ip0", totalBytes: 70, active: true),
], "relay activity consumes the actual Wi-Fi LAN and cellular server socket counters")

check(LiveActivityInterfaceKind(interfaceName: "en0") == .wifi,
      "en0 classifies as Wi-Fi")
check(LiveActivityInterfaceKind(interfaceName: "pdp_ip0") == .cellular,
      "pdp_ip0 classifies as cellular")
check(LiveActivityInterfaceKind(interfaceName: "utun9") == nil,
      "synthetic tunnel interfaces never appear as physical activity paths")

let activeActivityState = LiveActivityContentFactory.make(
    snapshot: TunnelSnapshot(
        timestamp: 200, clientState: 4, connectedSince: 150, footprint: 0,
        paths: [PathSnapshot(name: "en0", status: 1, txBytes: 1, rxBytes: 2)]),
    rates: LiveActivityRateSnapshot(
        wifi: InterfaceSpeed(interfaceName: "en0", megabitsPerSecond: 12.345),
        cellular: nil))
check(activeActivityState.phase == .active &&
      activeActivityState.wifi?.interfaceName == "en0" &&
      activeActivityState.wifi?.megabitsPerSecond == 12.345 &&
      activeActivityState.cellular == nil,
      "active VPN content preserves the sampled physical-interface truth")

let waitingRelayState = LiveActivityContentFactory.make(
    snapshot: TunnelSnapshot(
        timestamp: 201, clientState: -1, connectedSince: 150, footprint: 0,
        paths: [], operatingMode: .macRelay,
        relay: RelaySnapshot(
            wifiAvailable: true, cellularAvailable: true,
            authenticatedSession: false, listenerInterface: "en0",
            cellularInterface: "pdp_ip0", lanRxBytes: 0, lanTxBytes: 0,
            serverRxBytes: 0, serverTxBytes: 0,
            lastAuthenticated: nil, error: nil)),
    rates: LiveActivityRateSnapshot(
        wifi: InterfaceSpeed(interfaceName: "en0", megabitsPerSecond: nil),
        cellular: InterfaceSpeed(interfaceName: "pdp_ip0", megabitsPerSecond: nil)))
check(waitingRelayState.phase == .waiting && waitingRelayState.wifi?.megabitsPerSecond == nil,
      "relay without an authenticated Mac is visibly waiting, not bonded")

let failedRelayState = LiveActivityContentFactory.make(
    snapshot: TunnelSnapshot(
        timestamp: 202, clientState: -1, connectedSince: 150, footprint: 0,
        paths: [], operatingMode: .macRelay,
        relay: RelaySnapshot(
            wifiAvailable: true, cellularAvailable: false,
            authenticatedSession: false, listenerInterface: "en0",
            cellularInterface: nil, lanRxBytes: 0, lanTxBytes: 0,
            serverRxBytes: 0, serverTxBytes: 0,
            lastAuthenticated: nil, error: "Cellular relay socket unavailable")),
    rates: LiveActivityRateSnapshot(wifi: nil, cellular: nil))
check(failedRelayState.phase == .unavailable && failedRelayState.wifi == nil &&
      failedRelayState.cellular == nil,
      "relay socket failure is unavailable and never invents interface rates")

let contentWire = try! JSONEncoder().encode(activeActivityState)
let contentRoundTrip = try! JSONDecoder().decode(LiveActivityContentState.self,
                                                   from: contentWire)
check(contentRoundTrip == activeActivityState,
      "Live Activity content stays Codable and Hashable across the system boundary")

check(LiveActivityDisplayPolicy.visible(activeActivityState.wifi, isStale: false) ==
      activeActivityState.wifi,
      "fresh Live Activity content remains visible")
check(LiveActivityDisplayPolicy.visible(activeActivityState.wifi, isStale: true) == nil,
      "stale Live Activity content never presents the last Mbps as live")
check(LiveActivityDisplayPolicy.accessibilityState(isStale: true,
                                                    interfaceAvailable: true) == "stale data",
      "stale compact interface accessibility says stale data")
check(LiveActivityDisplayPolicy.accessibilityState(isStale: false,
                                                    interfaceAvailable: false) == "offline",
      "missing fresh interface accessibility says offline")

let duplicateActivityPlan = LiveActivitySelection.plan(
    activities: [
        LiveActivityDescriptor(id: "vpn-old", mode: "vpn"),
        LiveActivityDescriptor(id: "vpn-current", mode: "vpn"),
        LiveActivityDescriptor(id: "relay-stale", mode: "macRelay"),
    ], desiredMode: "vpn")
check(duplicateActivityPlan.currentID == "vpn-old" &&
      duplicateActivityPlan.endIDs == ["vpn-current", "relay-stale"],
      "crash duplicates retain one exact-mode activity and end every extra")

let switchedActivityPlan = LiveActivitySelection.plan(
    activities: [
        LiveActivityDescriptor(id: "vpn-stale", mode: "vpn"),
        LiveActivityDescriptor(id: "relay-current", mode: "macRelay"),
    ], desiredMode: "macRelay")
check(switchedActivityPlan.currentID == "relay-current" &&
      switchedActivityPlan.endIDs == ["vpn-stale"],
      "VPN-to-relay switch selects only the exact relay activity")

let createActivityPlan = LiveActivitySelection.plan(
    activities: [LiveActivityDescriptor(id: "vpn-stale", mode: "vpn")],
    desiredMode: "macRelay")
check(createActivityPlan.currentID == nil &&
      createActivityPlan.endIDs == ["vpn-stale"],
      "missing desired mode requests a new activity and ends stale modes")

runAsync {
    var stopEvents: [String] = []
    await LiveActivityStopSequence.perform(
        transportTeardown: {
            stopEvents.append("transport-begin")
            await Task.yield()
            stopEvents.append("transport-end")
        },
        scheduleActivityCleanup: {
            stopEvents.append("activity-scheduled")
        })
    check(stopEvents == ["transport-begin", "transport-end", "activity-scheduled"],
          "transport teardown completes before bounded ActivityKit cleanup is scheduled")
}

// ── Mac Relay authenticated session state ──
// The socket layer only passes frames here after the shared C codec has
// authenticated them and applied its replay window. These tests catch state
// mutation before authentication, destination-bearing arbitrary forwarding,
// multiple simultaneous Mac sessions, stale sessions, and incomplete Stop.
let peerA = RelayPeerIdentity(Data([192, 168, 1, 30, 0x15, 0x43]))
let peerB = RelayPeerIdentity(Data([192, 168, 1, 31, 0x15, 0x43]))
var relayState = RelaySessionState(idleTimeout: 15)
relayState.updateInterfaces(wifi: "en0", cellular: nil)
check(relayState.handleMacFrame(
    RelayInboundFrame(type: .hello, sessionID: 7, sequence: 1,
                      payload: Data(), peer: peerA,
                      authenticated: true, replayAccepted: true),
    now: 0.5) == [.drop(.unavailable)],
    "authenticated HELLO cannot activate a relay without a connected cellular socket")
check(!relayState.snapshot.authenticatedSession,
      "unavailable relay sends no ACK and creates no session")
relayState.updateInterfaces(wifi: "en0", cellular: "pdp_ip0")
check(relayState.snapshot.wifiAvailable && relayState.snapshot.cellularAvailable,
      "relay reports both injected physical interfaces")

let unauthHello = RelayInboundFrame(type: .hello, sessionID: 7, sequence: 1,
                                    payload: Data(), peer: peerA,
                                    authenticated: false, replayAccepted: false)
check(relayState.handleMacFrame(unauthHello, now: 1) == [.drop(.authentication)],
      "wrong-key HELLO drops before session state changes")
check(!relayState.snapshot.authenticatedSession,
      "wrong-key HELLO does not create a session")

let hello = RelayInboundFrame(type: .hello, sessionID: 7, sequence: 1,
                              payload: Data(), peer: peerA,
                              authenticated: true, replayAccepted: true)
check(relayState.handleMacFrame(hello, now: 2) == [.sendHelloAck(sessionID: 7)],
      "authenticated HELLO creates one session and requests ACK")
check(relayState.snapshot.authenticatedSession && relayState.snapshot.lastAuthenticated == 2,
      "authenticated HELLO updates readiness and liveness")

let competingHello = RelayInboundFrame(type: .hello, sessionID: 8, sequence: 1,
                                       payload: Data(), peer: peerB,
                                       authenticated: true, replayAccepted: true)
check(relayState.handleMacFrame(competingHello, now: 3) == [.drop(.session)],
      "a second Mac session is rejected while the first is live")

let replayed = RelayInboundFrame(type: .dataToServer, sessionID: 7, sequence: 2,
                                 payload: Data([1, 2]), peer: peerA,
                                 authenticated: true, replayAccepted: false)
check(relayState.handleMacFrame(replayed, now: 4) == [.drop(.replay)],
      "replayed DATA is dropped before server forwarding")

let dataToServer = RelayInboundFrame(type: .dataToServer, sessionID: 7, sequence: 3,
                                     payload: Data([9, 8, 7]), peer: peerA,
                                     authenticated: true, replayAccepted: true)
check(relayState.handleMacFrame(dataToServer, now: 5) == [.forwardToFixedServer(Data([9, 8, 7]))],
      "accepted DATA carries only payload to the already-connected fixed server")

check(!relayState.expireIfIdle(now: 19.9), "session remains before 15-second idle timeout")
check(relayState.expireIfIdle(now: 20.1), "session expires after 15 seconds without authenticated traffic")
check(!relayState.snapshot.authenticatedSession, "idle expiry clears authenticated session")

_ = relayState.handleMacFrame(hello, now: 21)
check(relayState.updateInterfaces(wifi: nil, cellular: "pdp_ip0") == [.closeWifi],
      "Wi-Fi loss closes its listener")
check(!relayState.snapshot.authenticatedSession,
      "Wi-Fi loss erases the peer-bound authenticated session")
check(relayState.updateInterfaces(wifi: "en0", cellular: nil) == [.openWifi("en0"), .closeCellular],
      "cellular loss is observable without fabricating readiness")

_ = relayState.handleMacFrame(hello, now: 22)
let stopActions = relayState.stop()
check(stopActions == [.closeWifi], "Stop closes every currently open relay socket")
check(relayState.snapshot == .stopped, "Stop resets interfaces, counters, session, and errors")
check(RelayNetworkPlan.nonRouting.includedIPv4Routes.isEmpty && RelayNetworkPlan.nonRouting.dnsServers.isEmpty,
      "relay network plan installs no default route and no DNS capture")
check(RelaySocketPlan.fixed.lanListener == .wifi &&
      RelaySocketPlan.fixed.fixedServer == .cellular,
      "LAN listener is Wi-Fi-only and the fixed server socket is cellular-only")

// ── Callback-backed logical Engine paths ──
// A regression to fd-path registration would make libmqvpn reject this -1
// handle because the Engine previously supplied no result-bearing callback.
let logicalEngine = MqvpnEngine()
logicalEngine.start(
    server: ServerSettings(host: "127.0.0.1", port: 443, serverName: "", authKey: "", insecure: true),
    serverAddr: resolveServer("127.0.0.1", 443)!)
let logicalPathReady = DispatchSemaphore(value: 0)
var logicalPathHandle: mqvpn_path_handle_t = -1
var logicalPathCount = -1
var logicalActivePathCount = -1
var logicalPathEvents: [(mqvpn_path_handle_t, mqvpn_path_status_t)] = []
_ = logicalEngine.perform {
    logicalEngine.onLogicalPathSend = { _, _ in -Int(EAGAIN) }
    logicalEngine.onPathEvent = { handle, status in logicalPathEvents.append((handle, status)) }
    var desc = mqvpn_path_desc_t()
    desc.struct_size = UInt32(MemoryLayout<mqvpn_path_desc_t>.size)
    logicalPathHandle = logicalEngine.addLogicalPath(desc: &desc).handle
    logicalPathCount = logicalEngine.paths().count
    logicalActivePathCount = logicalEngine.activePathCount()
    logicalPathReady.signal()
}
logicalPathReady.wait()
check(logicalPathHandle >= 0 && logicalPathCount == 1,
      "callback path registration is accepted as a logical, not fd, path")
check(logicalPathEvents.contains { $0.0 == logicalPathHandle && $0.1 == MQVPN_PATH_PENDING },
      "libmqvpn path events are delivered authoritatively during logical registration")
check(logicalActivePathCount == 0,
      "a pending logical path reports zero active paths")

var inactivePath = mqvpn_path_info_t()
inactivePath.status = MQVPN_PATH_PENDING
var activePath = mqvpn_path_info_t()
activePath.status = MQVPN_PATH_ACTIVE
check(MqvpnEngine.activePathCount(in: [inactivePath]) == 0 &&
      MqvpnEngine.activePathCount(in: [inactivePath, activePath]) == 1,
      "path-event recovery distinguishes zero from nonzero active paths")

let logicalPayload = Data([0x11, 0x22, 0x33, 0x44])
for result in [logicalPayload.count, -Int(EAGAIN), -Int(EIO)] {
    check(MqvpnEngine.logicalPathSendResult({ handle, packet in
        handle == logicalPathHandle && packet == logicalPayload ? result : -Int(EINVAL)
    }, path: logicalPathHandle, packet: logicalPayload) == result,
          "logical send preserves full length, EAGAIN, and hard errno")
}
let logicalShutdown = DispatchSemaphore(value: 0)
_ = logicalEngine.perform { logicalEngine.shutdown(); logicalShutdown.signal() }
logicalShutdown.wait()

if failures == 0 { print("host tests: ALL PASS") } else { print("host tests: \(failures) FAILURES"); exit(1) }
