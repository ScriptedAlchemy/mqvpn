// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Darwin
import Foundation

// The production changes these provider-plan tests catch are: installing a
// full-tunnel route before server authentication, omitting either physical
// endpoint exclusion, applying the wrong address/DNS/MTU, failing to bound an
// established all-path outage, or reporting Stop before transport teardown.
let networkPlan = MacProviderNetworkPlan(
    assignedAddress: "10.77.77.10", assignedPrefix: 24, mtu: 1_382,
    serverIPv4: "208.69.79.206", relayIPv4: "192.168.1.42")
check(networkPlan.includedRoutes == [MacIPv4Route(address: "0.0.0.0", prefix: 0)],
      "the authenticated Mac tunnel includes exactly the IPv4 default route")
check(networkPlan.includedIPv6Routes.isEmpty &&
      networkPlan.excludedIPv6Routes.isEmpty,
      "the IPv4-only overlay must not claim ::/0; that blackholes the iPhone ULA relay")
check(networkPlan.excludedRoutes == [
    MacIPv4Route(address: "208.69.79.206", prefix: 32),
    MacIPv4Route(address: "192.168.1.42", prefix: 32),
], "the public server and iPhone LAN peer receive exact /32 exclusions")
check(networkPlan.assignedAddress == "10.77.77.10" &&
      networkPlan.subnetMask == "255.255.255.0" && networkPlan.mtu == 1_382 &&
      networkPlan.dnsServers == ["1.1.1.1", "8.8.8.8"],
      "the server address, prefix, MTU, and explicit tunnel DNS survive planning")
let directOnlyPlan = MacProviderNetworkPlan(
    assignedAddress: "10.77.77.10", assignedPrefix: 24, mtu: 1_382,
    serverIPv4: "208.69.79.206", relayIPv4: nil)
check(directOnlyPlan.excludedRoutes == [MacIPv4Route(address: "208.69.79.206", prefix: 32)],
      "direct-only planning still excludes the public server and never requires a relay")
let relayKey = Data(repeating: 0x5a, count: 32).base64EncodedString()
check((try? MacRelaySettings.startConfiguration(from: nil)) == nil &&
      (try? MacRelaySettings.startConfiguration(from: [:])) == nil,
      "absent Mac relay keys stay direct-only")
do {
    _ = try MacRelaySettings.startConfiguration(from: ["macRelayEnabled": true])
    check(false, "an enabled but incomplete relay configuration must fail Start")
} catch {
    check((error as NSError).code == 20,
          "an enabled but incomplete relay configuration fails closed")
}
let parsedRelay = try? MacRelaySettings.startConfiguration(from: [
    "macRelayEnabled": true, "macRelayHost": "192.168.1.42",
    "macRelayPort": 5443, "macRelayKey": relayKey,
])
check(parsedRelay?.host == "192.168.1.42" && parsedRelay?.isValid == true,
      "a complete enabled Mac relay configuration is accepted")
let discoveredRelay = try? MacRelaySettings.startConfiguration(from: [
    "macRelayEnabled": true, "macRelayHost": "",
    "macRelayPort": 5443, "macRelayKey": relayKey,
])
check(discoveredRelay?.enabled == true && discoveredRelay?.host == "" &&
      discoveredRelay?.isValid == true,
      "an enabled relay without a stored host is valid and waits for discovery")
check(MacRelayDiscovery.choose([
    MacRelayEndpoint(host: "fe80::1", port: 5443),
    MacRelayEndpoint(host: "192.168.1.50", port: 5443),
    MacRelayEndpoint(host: "10.0.0.8", port: 5443),
]) == MacRelayEndpoint(host: "fe80::1", port: 5443),
      "same-LAN relay prefers link-local IPv6 over IPv4")
check(MacRelayDiscovery.choose([
    MacRelayEndpoint(host: "fd97:b933:48b8:4fdb::42", port: 5443),
    MacRelayEndpoint(host: "fe80::1%en1", port: 5443),
    MacRelayEndpoint(host: "192.168.1.50", port: 5443),
]) == MacRelayEndpoint(host: "fe80::1%en1", port: 5443),
      "a scoped link-local beats a ULA that stops answering ND after tunnel start")
check(MacRelayDiscovery.choose([]) == nil &&
      MacRelayDiscovery.choose([MacRelayEndpoint(host: "Zack.local", port: 5443)]) == nil,
      "a hostname without an IP advertisement is a fail-closed Start")
check(MacRelayDiscovery.choose([MacRelayEndpoint(host: "fe80::1", port: 5443)]) ==
      MacRelayEndpoint(host: "fe80::1", port: 5443),
      "link-local IPv6 is accepted when it is the only advertised address")
check(MacRelayDiscovery.interfaceName(for: MacRelayEndpoint(host: "fe80::1%en1",
                                                            port: 5443)) == "en1" &&
      MacRelayDiscovery.interfaceName(for: MacRelayEndpoint(
          host: "fd97:b933:48b8:4fdb::42", port: 5443)) == nil,
      "only a scoped IPv6 literal names the LAN interface")
check(resolveRelayEndpoint("fd97:b933:48b8:4fdb::42", 5443)?.ipString ==
      "fd97:b933:48b8:4fdb::42" &&
      resolveServer("fd97:b933:48b8:4fdb::42", 5443) == nil,
      "the LAN relay may resolve IPv6 while the public server path stays IPv4")
check(ResolvedServerAddress.fromIPLiteral("fe80::1%en1", port: 5443)?.ipString == "fe80::1%en1" &&
      ResolvedServerAddress.fromIPLiteral("Zack.local", port: 5443) == nil,
      "Bonjour numeric peers keep the Wi-Fi zone without getaddrinfo")
check(MacRelayDiscovery.statusText(enabled: false, endpoint: nil) ==
      "optional — not configured" &&
      MacRelayDiscovery.statusText(enabled: true, endpoint: nil) ==
      "No iPhone relay found on this LAN" &&
      MacRelayDiscovery.statusText(
          enabled: true, endpoint: MacRelayEndpoint(host: "192.168.1.50", port: 5443)) ==
      "iPhone relay detected at 192.168.1.50:5443",
      "the dashboard reports detected or not-found without a typed IP")
var advertised = sockaddr_in()
advertised.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
advertised.sin_family = sa_family_t(AF_INET)
advertised.sin_port = in_port_t(UInt16(5443).bigEndian)
_ = "192.168.1.50".withCString { inet_pton(AF_INET, $0, &advertised.sin_addr) }
let advertisedBytes = withUnsafeBytes(of: advertised) { Data($0) }
check(MacRelayDiscovery.ipv4(fromSockaddr: advertisedBytes) == "192.168.1.50" &&
      MacRelayDiscovery.choose(port: 5443, addresses: [advertisedBytes]) ==
      MacRelayEndpoint(host: "192.168.1.50", port: 5443),
      "Start uses the IPv4 already attached to a resolved Bonjour service")
var advertised6 = sockaddr_in6()
advertised6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
advertised6.sin6_family = sa_family_t(AF_INET6)
advertised6.sin6_port = in_port_t(UInt16(5443).bigEndian)
_ = "fd97:b933:48b8:4fdb::42".withCString { inet_pton(AF_INET6, $0, &advertised6.sin6_addr) }
let advertised6Bytes = withUnsafeBytes(of: advertised6) { Data($0) }
check(MacRelayDiscovery.ipv6(fromSockaddr: advertised6Bytes) == "fd97:b933:48b8:4fdb::42",
      "Start can still read a ULA attached to a resolved Bonjour service")
var advertisedLL = sockaddr_in6()
advertisedLL.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
advertisedLL.sin6_family = sa_family_t(AF_INET6)
advertisedLL.sin6_port = in_port_t(UInt16(5443).bigEndian)
advertisedLL.sin6_scope_id = if_nametoindex("en1")
_ = "fe80::1".withCString { inet_pton(AF_INET6, $0, &advertisedLL.sin6_addr) }
let advertisedLLBytes = withUnsafeBytes(of: advertisedLL) { Data($0) }
if advertisedLL.sin6_scope_id != 0 {
    check(MacRelayDiscovery.choose(port: 5443,
                                   addresses: [advertisedBytes, advertised6Bytes, advertisedLLBytes]) ==
          MacRelayEndpoint(host: "fe80::1%en1", port: 5443),
          "Start prefers the scoped link-local already attached to Bonjour")
}

var startupTimeout = MacProviderLifecycle()
check(startupTimeout.begin(nowMs: 0) == .none && !startupTimeout.settingsRequested,
      "starting probes does not request Network Extension routes")
check(startupTimeout.activePathCountChanged(1, nowMs: 100) == .none &&
      !startupTimeout.settingsRequested,
      "a locally active path alone cannot install routes before server authentication")
check(startupTimeout.startupTimerFired(nowMs: 10_000) == .failStart &&
      !startupTimeout.settingsRequested,
      "startup expiry fails before any default route was requested")
check(!MacProviderStartupSafety.hasSurvivingPath(activePathCount: 0, stopping: false) &&
      !MacProviderStartupSafety.hasSurvivingPath(activePathCount: 1, stopping: true) &&
      MacProviderStartupSafety.hasSurvivingPath(activePathCount: 1, stopping: false),
      "a zero-path or stopping start cannot install or retain default tunnel settings")

var settingsTimeout = MacProviderLifecycle()
_ = settingsTimeout.begin(nowMs: 0)
_ = settingsTimeout.tunnelConfigurationReady()
check(settingsTimeout.startupTimerFired(nowMs: 10_000) == .failStart,
      "startup remains bounded if Network Extension settings application stalls")

var lifecycle = MacProviderLifecycle()
check(lifecycle.begin(nowMs: 0) == .none,
      "provider startup begins in preflight without applying settings")
check(lifecycle.tunnelConfigurationReady() == .applyNetworkSettings &&
      lifecycle.settingsRequested,
      "real tunnel configuration is the sole settings-install gate")
check(lifecycle.networkSettingsApplied(error: false, activePathCount: 1) == .completeStart &&
      lifecycle.isEstablished,
      "successful Network Extension settings complete Start")
check(lifecycle.activePathCountChanged(0, nowMs: 1_000) ==
      .beginRecovery(deadlineMs: 6_000),
      "all-path loss starts the exact five-second fail-open window")
check(lifecycle.activePathCountChanged(1, nowMs: 5_999) == .endRecovery &&
      lifecycle.isEstablished,
      "a recovered path before the deadline clears reasserting")
check(lifecycle.activePathCountChanged(0, nowMs: 8_000) ==
      .beginRecovery(deadlineMs: 13_000) &&
      lifecycle.recoveryTimerFired(nowMs: 12_999) == .none &&
      lifecycle.recoveryTimerFired(nowMs: 13_000) == .cancelTunnel,
      "an unrecovered five-second outage cancels the tunnel")

var failedSettings = MacProviderLifecycle()
_ = failedSettings.begin(nowMs: 0)
_ = failedSettings.tunnelConfigurationReady()
check(failedSettings.networkSettingsApplied(error: true, activePathCount: 1) == .failStart,
      "a settings failure cannot become a connected VPN")

var lostDuringApply = MacProviderLifecycle()
_ = lostDuringApply.begin(nowMs: 0)
_ = lostDuringApply.tunnelConfigurationReady()
check(lostDuringApply.activePathCountChanged(0, nowMs: 100) == .failStart &&
      !lostDuringApply.isEstablished,
      "all-path loss before Start completes fails instead of installing a default route")
var zeroAtApply = MacProviderLifecycle()
_ = zeroAtApply.begin(nowMs: 0)
_ = zeroAtApply.tunnelConfigurationReady()
check(zeroAtApply.networkSettingsApplied(error: false, activePathCount: 0) == .failStart,
      "settings completion with zero active paths cannot become a connected VPN")

var stopping = MacProviderLifecycle()
_ = stopping.begin(nowMs: 0)
check(stopping.beginStop() && stopping.isStopping && !stopping.beginStop(),
      "Stop is idempotent and is owned by the lifecycle stage, not a parallel flag")
check(MacRelayRebindPolicy.decide(current: "en1", desired: "en1") == .keep &&
      MacRelayRebindPolicy.decide(current: "en1", desired: nil) == .keep &&
      MacRelayRebindPolicy.decide(current: "en1", desired: "en5") == .rebind(to: "en5") &&
      MacRelayRebindPolicy.decide(current: nil, desired: "en1") == .rebind(to: "en1"),
      "a live relay interface survives a probe miss; only a new interface rebinds")
check(MacPathIdentity.relayName == "iphone-relay",
      "direct and relay path identity share one constant")

let snapshotStore = MacProviderSnapshotStore()
let providerSnapshot = MacProviderSnapshot(
    timestamp: 123, clientState: 4, connectedSince: 100, footprint: 4_096,
    reasserting: false, lastError: nil,
    paths: [MacProviderPathSnapshot(name: "en1", status: 1,
                                    txBytes: 10, rxBytes: 20)], relay: nil)
snapshotStore.publish(providerSnapshot)
check(snapshotStore.read() == providerSnapshot,
      "the arbitrary app-message thread reads the latest immutable provider snapshot")
check((try? MacProviderSnapshot.decode(providerSnapshot.encoded())) == providerSnapshot,
      "the Mac provider snapshot has one round-trippable app-message wire format")
snapshotStore.clear()
check(snapshotStore.read() == nil,
      "Stop clears stale app-facing state instead of presenting a disconnected session as live")

let lanCandidates = [
    MacLANInterfaceCandidate(name: "en5", kind: .wiredEthernet,
                             address: "192.168.1.20", netmask: "255.255.255.0"),
    MacLANInterfaceCandidate(name: "en1", kind: .wifi,
                             address: "192.168.1.195", netmask: "255.255.255.0"),
    MacLANInterfaceCandidate(name: "en9", kind: .wifi,
                             address: "10.0.0.2", netmask: "255.255.255.0"),
]
check(MacLANInterfaceSelector.select(relayIPv4: "192.168.1.42",
                                     candidates: lanCandidates) == "en1",
      "the live Wi-Fi subnet is preferred over wired Ethernet for iPhone relay LAN traffic")
check(MacLANInterfaceSelector.select(relayIPv4: "172.16.0.4",
                                     candidates: lanCandidates) == nil,
      "relay preflight fails honestly when no live local subnet reaches the iPhone")
check(MacLANInterfaceSelector.onLinkRoute(relayIPv4: "192.168.1.42",
                                          candidates: lanCandidates) ==
      MacIPv4Route(address: "192.168.1.0", prefix: 24),
      "the live Wi-Fi prefix stays excluded so ARP to the iPhone cannot enter the tunnel")
check(MacLANInterfaceSelector.interfaceName(reaching: "fd97:b933:48b8:4fdb::42",
                                            candidates: lanCandidates) == "en1",
      "an IPv6 relay still binds to the live Wi-Fi interface")
check(MacLANInterfaceSelector.onLinkRoute(relayIPv4: "fd97:b933:48b8:4fdb::42",
                                          candidates: lanCandidates) == nil,
      "an IPv6 relay does not invent an IPv4 LAN exclusion")
let planWithLAN = MacProviderNetworkPlan(
    assignedAddress: "10.77.77.10", assignedPrefix: 24, mtu: 1_382,
    serverIPv4: "208.69.79.206", relayIPv4: "192.168.1.42",
    relayLAN: MacIPv4Route(address: "192.168.1.0", prefix: 24))
check(planWithLAN.excludedRoutes == [
    MacIPv4Route(address: "208.69.79.206", prefix: 32),
    MacIPv4Route(address: "192.168.1.42", prefix: 32),
    MacIPv4Route(address: "192.168.1.0", prefix: 24),
], "settings keep the peer /32 and the on-link LAN after the default route is installed")
let planWithIPv6Relay = MacProviderNetworkPlan(
    assignedAddress: "10.77.77.10", assignedPrefix: 24, mtu: 1_382,
    serverIPv4: "208.69.79.206", relayIPv4: nil,
    relayIPv6: "fd97:b933:48b8:4fdb::42%en1")
check(planWithIPv6Relay.includedIPv6Routes.isEmpty &&
      planWithIPv6Relay.excludedIPv6Routes.isEmpty,
      "an IPv6 LAN relay does not install IPv6 tunnel routes")

let relayDraft = MacRelaySettings(enabled: true, host: " 192.168.1.42 ", port: 5_443,
                                  keyBase64: Data(repeating: 7, count: 32).base64EncodedString())
check(relayDraft.isValid &&
      (try? MacRelaySettings.startConfiguration(from: relayDraft.toProviderConfiguration())) == relayDraft,
      "enabled Mac relay configuration round-trips only with a real 32-byte key")
check((try? MacRelaySettings.startConfiguration(from: nil)) == nil,
      "absent relay keys preserve direct-only startup")

check(TunnelProviderConfiguration.providerBundleID ==
      "com.zackjackson.mqvpn.mac.PacketTunnel",
      "the Mac app owns exactly one packet-tunnel provider identifier")
check(TunnelProviderConfiguration.localizedName == "mqvpn" &&
      TunnelProviderConfiguration.excludeLocalNetworks &&
      !TunnelProviderConfiguration.enforceRoutes &&
      !TunnelProviderConfiguration.includeAllNetworks,
      "the saved Mac VPN protocol excludes LAN and does not enforce exclusive routes")
let foreign = ManagerDescriptor(id: "0",
                                providerBundleID: "com.speedify.vpn.PacketTunnel",
                                status: .connected)
let ours = ManagerDescriptor(id: "1",
                             providerBundleID: TunnelProviderConfiguration.providerBundleID,
                             status: .disconnected)
let leftover = ManagerDescriptor(id: "2",
                                 providerBundleID: "com.zackjackson.mqvpn.PacketTunnel",
                                 status: .disconnected)
check(selectMatchingManager([foreign, ours, leftover],
                            providerBundleID: TunnelProviderConfiguration.providerBundleID)?.id == "1",
      "only the Mac provider identifier is adopted")
check(managersEligibleForMutation([foreign, ours, leftover],
                                  providerBundleID: TunnelProviderConfiguration.providerBundleID) == [ours],
      "nonmatching VPN profiles are never selected for mutation")
check(TunnelStatus.fromNEVPNRawValue(3) == .connected &&
      TunnelStatus.fromNEVPNRawValue(4) == .reasserting &&
      TunnelStatus.fromNEVPNRawValue(1) == .disconnected,
      "system VPN status values map onto the host-testable lifecycle")
check(saveGuard(isSaving: true, isEditable: false, hasManager: false) == .inProgress &&
      saveGuard(isSaving: false, isEditable: false, hasManager: true) == .notEditable &&
      saveGuard(isSaving: false, isEditable: true, hasManager: false) == .notReady &&
      saveGuard(isSaving: false, isEditable: true, hasManager: true) == nil,
      "save rejects in-flight, non-editable, and missing-manager states first")
let validServer = ServerSettings(host: "vpn.example", port: 443, serverName: "",
                                 authKey: "psk", insecure: false)
let hybrid = HybridSettings(enabled: true, tcpMode: HybridSettings.modeAuto)
let directOnlyConfiguration = MacProviderConfiguration.make(
    server: validServer,
    relay: MacRelaySettings(enabled: false, host: "", port: 5443, keyBase64: ""),
    hybrid: hybrid)
check(ServerSettings(providerConfiguration: directOnlyConfiguration) == validServer &&
      HybridSettings(providerConfiguration: directOnlyConfiguration) == hybrid &&
      (try? MacRelaySettings.startConfiguration(from: directOnlyConfiguration)) == nil,
      "one Mac provider configuration persists server, Hybrid, and an explicit direct-only relay state")
check(MacPollingLifecycle.shouldPoll(status: .connected) &&
      MacPollingLifecycle.shouldPoll(status: .reasserting) &&
      !MacPollingLifecycle.shouldPoll(status: .connecting) &&
      !MacPollingLifecycle.shouldPoll(status: .disconnected),
      "loading an already-connected Mac profile starts app-message polling while down states stay quiet")
check(MacConnectGuard.canStart(isEditable: true, isSaving: false,
                               server: validServer, relay: nil),
      "direct-only Start is allowed with a valid server and no relay")
check(!MacConnectGuard.canStart(isEditable: false, isSaving: false,
                                server: validServer, relay: nil),
      "Start stays disabled while the profile is not editable")
check(!MacConnectGuard.canStart(isEditable: true, isSaving: false,
                                server: validServer,
                                relay: MacRelaySettings(enabled: true, host: "",
                                                        port: 5443, keyBase64: "")),
      "an enabled but incomplete iPhone relay cannot Start")
check(!MacConnectGuard.canStart(isEditable: true, isSaving: false,
                                server: validServer,
                                relay: MacRelaySettings(enabled: true, host: "",
                                                        port: 5443, keyBase64: relayKey)),
      "an enabled relay cannot Start until discovery resolves a LAN peer")
check(MacConnectGuard.canStart(isEditable: true, isSaving: false,
                               server: validServer,
                               relay: MacRelaySettings(enabled: true, host: "",
                                                       port: 5443, keyBase64: relayKey),
                               discoveredRelay: MacRelayEndpoint(host: "192.168.1.50",
                                                                 port: 5443)),
      "Start is allowed after a real IPv4 relay endpoint resolves")
check(MacConnectGuard.canStart(isEditable: true, isSaving: false,
                               server: validServer,
                               relay: MacRelaySettings(enabled: true, host: "",
                                                       port: 5443, keyBase64: relayKey),
                               discoveredRelay: MacRelayEndpoint(
                                   host: "fd97:b933:48b8:4fdb::42", port: 5443)),
      "Start is allowed after a real IPv6 relay endpoint resolves")
check(!MacConnectGuard.canStart(isEditable: true, isSaving: false,
                                server: validServer, relay: nil,
                                relayConfigurationIsValid: false),
      "a persisted malformed enabled relay cannot silently downgrade to direct-only Start")
check(!MacConnectGuard.canStart(isEditable: true, isSaving: false,
                                server: validServer, relay: nil,
                                profileIsCurrent: false),
      "Start remains disabled when a committed profile could not be reloaded")
check(StopLifecycle.canStop(hasManager: true, status: .connected) &&
      StopLifecycle.request(hasManager: true, status: .disconnected) == .alreadyStopped &&
      StopLifecycle.request(hasManager: true, status: .connected) == .requested &&
      !StopLifecycle.canStop(hasManager: true, status: .disconnecting) &&
      !StopLifecycle.canStop(hasManager: true, status: .invalid) &&
      StopLifecycle.request(hasManager: false, status: .connected) == .unavailable,
      "Stop is idempotent for an already-disconnected profile and refuses a missing manager")
enum TestErr: Error { case boom }
final class FakeStore: MacConfigStore {
    var providerConfiguration: [String: Any]?
    var localizedName: String?
    var isEnabled = false
    var commitThrows = false
    var refreshThrows = false
    var refreshAttempts = 0
    var refreshFailuresBeforeSuccess = 0
    func commit() async throws { if commitThrows { throw TestErr.boom } }
    func refresh() async throws {
        refreshAttempts += 1
        if refreshThrows { throw TestErr.boom }
        if refreshAttempts <= refreshFailuresBeforeSuccess { throw TestErr.boom }
    }
}
func runAsync(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    sem.wait()
}
runAsync {
    let store = FakeStore()
    store.providerConfiguration = ["macRelayEnabled": NSNumber(value: false)]
    store.localizedName = "old"
    store.isEnabled = false
    store.commitThrows = true
    var commitFailed = false
    do {
        try await performAtomicSave(store, merge: ["macRelayEnabled": NSNumber(value: true)],
                                    name: TunnelProviderConfiguration.localizedName,
                                    enabled: true)
    } catch MacSaveFailure.commit {
        commitFailed = true
    } catch { }
    let rolledBack = (store.providerConfiguration?["macRelayEnabled"] as? NSNumber)?.boolValue == false
    check(commitFailed && rolledBack && store.localizedName == "old" && store.isEnabled == false,
          "commit failure rolls configuration, name, and enabled back together")
}
runAsync {
    let store = FakeStore()
    store.providerConfiguration = [:]
    store.refreshThrows = true
    var refreshFailed = false
    do {
        try await performAtomicSave(store, merge: ["macRelayHost": "192.168.1.42"])
    } catch MacSaveFailure.refresh {
        refreshFailed = true
    } catch { }
    check(refreshFailed && store.providerConfiguration?["macRelayHost"] as? String == "192.168.1.42",
          "a post-commit refresh failure is surfaced instead of claiming the profile reloaded")
}
runAsync {
    let store = FakeStore()
    store.providerConfiguration = [:]
    store.refreshFailuresBeforeSuccess = 1
    var succeeded = false
    do {
        try await performAtomicSave(store, merge: ["macRelayHost": "192.168.1.42"])
        succeeded = true
    } catch { }
    check(succeeded && store.refreshAttempts == 2,
          "a committed profile gets exactly one refresh retry before Start is disabled")
}

let firstRateSnapshot = MacProviderSnapshot(
    timestamp: 10, clientState: 4, connectedSince: 0, footprint: 0,
    reasserting: false, lastError: nil,
    paths: [
        MacProviderPathSnapshot(name: "en1", status: 1, txBytes: 100, rxBytes: 100),
        MacProviderPathSnapshot(name: "en5", status: 1, txBytes: 200, rxBytes: 200),
    ], relay: nil)
let secondRateSnapshot = MacProviderSnapshot(
    timestamp: 12, clientState: 4, connectedSince: 0, footprint: 0,
    reasserting: false, lastError: nil,
    paths: [
        MacProviderPathSnapshot(name: "en5", status: 1, txBytes: 1_000_200, rxBytes: 200),
        MacProviderPathSnapshot(name: "en1", status: 1, txBytes: 100, rxBytes: 500_100),
    ], relay: nil)
var rateSampler = MacSnapshotRateSampler()
check(rateSampler.ingest(firstRateSnapshot).allSatisfy { $0.megabitsPerSecond == nil },
      "the first per-path sample is unavailable rather than a fabricated zero rate")
let stableRates = Dictionary(uniqueKeysWithValues: rateSampler.ingest(secondRateSnapshot)
    .map { ($0.pathID, $0.megabitsPerSecond) })
let en1Rate = stableRates["en1"] ?? nil
let en5Rate = stableRates["en5"] ?? nil
check(abs((en1Rate ?? -1) - 2.0) < 0.001 &&
      abs((en5Rate ?? -1) - 4.0) < 0.001,
      "per-path rates follow stable interface identity even when provider path order changes")
let resetSnapshot = MacProviderSnapshot(
    timestamp: 14, clientState: 4, connectedSince: 0, footprint: 0,
    reasserting: false, lastError: nil,
    paths: [MacProviderPathSnapshot(name: "en1", status: 1, txBytes: 1, rxBytes: 1)], relay: nil)
check(rateSampler.ingest(resetSnapshot).first?.megabitsPerSecond == nil,
      "a path counter reset is unavailable rather than an unsigned-wrap throughput spike")
var relaySampler = MacSnapshotRateSampler()
check(relaySampler.ingest(id: MacPathIdentity.relayLANSampleID, timestamp: 10, totalBytes: 100)
        .megabitsPerSecond == nil &&
      abs((relaySampler.ingest(id: MacPathIdentity.relayLANSampleID, timestamp: 12,
                               totalBytes: 100 + 500_000).megabitsPerSecond ?? -1) - 2.0) < 0.001,
      "relay LAN counters use the same sampler as direct paths")
check(MacSnapshotFreshness.isFresh(receivedAt: 10, now: 12.9) &&
      !MacSnapshotFreshness.isFresh(receivedAt: 10, now: 13.1),
      "a missing provider response expires displayed rates instead of retaining stale throughput")

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

let key = Data(repeating: 0x5a, count: Int(MQVPN_RELAY_KEY_SIZE))
let session: UInt64 = 0x0102_0304_0506_0708

// The production changes that these tests catch are: emitting a HELLO only
// once, accepting unauthenticated/wrong-direction/wrong-session/replayed
// frames, marking a listener active before an ACK, forwarding DATA before a
// logical path exists, retaining credentials after Stop, or treating a local
// address as a safe relay endpoint.
var state = MacRelayRuntimeState(key: key, idleTimeoutMs: 15_000)
check(state.beginSession(sessionID: session, nowMs: 100) == .started,
      "a fresh nonzero session starts")
let hello = state.encode(type: MQVPN_RELAY_HELLO, payload: Data(), nowMs: 100)
check(hello != nil && state.snapshot.helloAttempts == 1 && state.snapshot.helloSent == 0 &&
      state.snapshot.lanTxBytes == 0 && !state.snapshot.active,
      "encoding a HELLO records an attempt but never claims a kernel send")
state.recordSendAgain()
check(state.snapshot.sendAgain == 1 && state.snapshot.helloSent == 0 &&
      state.snapshot.lanTxBytes == 0,
      "EAGAIN is surfaced separately and does not inflate byte counters")
state.recordSuccessfulSend(type: MQVPN_RELAY_HELLO, datagramLength: hello!.count)
check(state.snapshot.helloSent == 1 && state.snapshot.lanTxBytes == UInt64(hello!.count),
      "only a full socket send contributes HELLO and LAN byte counters")
let attemptedData = state.encode(type: MQVPN_RELAY_DATA_TO_SERVER, payload: Data([1]), nowMs: 101)
state.recordSendFailure()
check(attemptedData != nil && state.snapshot.sendAttempts == 2 &&
      state.snapshot.sendFailures == 1 && state.snapshot.lanTxBytes == UInt64(hello!.count),
      "hard send failure remains distinct from a successful encoded datagram")
check(state.shouldRetryHello(nowMs: 1_099) == false &&
      state.shouldRetryHello(nowMs: 1_100),
      "unacknowledged HELLO is retried after one second")

func phoneFrame(_ type: mqvpn_relay_message_type_t,
                sessionID: UInt64 = session,
                sequence: UInt64,
                payload: Data = Data(),
                signingKey: Data = key,
                direction: mqvpn_relay_direction_t = MQVPN_RELAY_IPHONE_TO_MAC) -> Data {
    var out = [UInt8](repeating: 0,
                       count: Int(MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE +
                                  MQVPN_RELAY_TAG_SIZE))
    var length = 0
    let rc = signingKey.withUnsafeBytes { keyBytes in
        payload.withUnsafeBytes { payloadBytes in
            mqvpn_relay_encode(
                keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), type, direction,
                sessionID, sequence,
                payloadBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), payload.count,
                &out, out.count, &length)
        }
    }
    precondition(rc == MQVPN_RELAY_OK)
    return Data(out.prefix(length))
}

let badTag = phoneFrame(MQVPN_RELAY_HELLO_ACK, sequence: 1,
                        signingKey: Data(repeating: 0xa5, count: Int(MQVPN_RELAY_KEY_SIZE)))
check(state.receive(badTag, nowMs: 101) == .drop(.authentication) &&
      state.snapshot.authRejected == 1 && !state.snapshot.active,
      "invalid HMAC is rejected before activation")

let wrongDirection = phoneFrame(MQVPN_RELAY_HELLO_ACK, sequence: 1,
                                direction: MQVPN_RELAY_MAC_TO_IPHONE)
check(state.receive(wrongDirection, nowMs: 102) == .drop(.direction),
      "MAC-to-iPhone datagrams are rejected on the inbound relay socket")
let wrongSession = phoneFrame(MQVPN_RELAY_HELLO_ACK, sessionID: session + 1, sequence: 1)
check(state.receive(wrongSession, nowMs: 103) == .drop(.session),
      "a valid but wrong session cannot take over the relay")

let ack = phoneFrame(MQVPN_RELAY_HELLO_ACK, sequence: 2)
check(state.receive(ack, nowMs: 104) == .activateLogicalPath &&
      state.snapshot.ackReceived == 1 && state.snapshot.authAccepted == 1 &&
      !state.snapshot.active,
      "only a valid HELLO_ACK requests logical-path registration")
let beforeAttach = phoneFrame(MQVPN_RELAY_DATA_TO_MAC, sequence: 3, payload: Data([9, 8, 7]))
check(state.receive(beforeAttach, nowMs: 104) == .drop(.messageType),
      "DATA_TO_MAC cannot reach the core before logical-path registration")
check(state.attachLogicalPath(44) && state.snapshot.active && state.snapshot.pathHandle == 44,
      "relay becomes active only after the engine accepts its callback path")
check(!state.shouldProbeActiveRelay(nowMs: 5_099) &&
      state.shouldProbeActiveRelay(nowMs: 5_100),
      "an active relay asks the core for a QUIC path probe every five seconds")
check(state.encode(type: MQVPN_RELAY_DATA_TO_SERVER,
                   payload: Data(count: 1452),
                   nowMs: 104) != nil &&
      state.snapshot.active && state.snapshot.sessionID == session,
      "xquic's encrypted UDP ceiling must encode after HELLO_ACK")
check(state.encode(type: MQVPN_RELAY_DATA_TO_SERVER,
                   payload: Data(count: Int(MQVPN_RELAY_MAX_PAYLOAD_SIZE) + 1),
                   nowMs: 104) == nil &&
      state.snapshot.active && state.snapshot.sessionID == session &&
      state.snapshot.pathHandle == 44 && state.snapshot.hardFailures == 0,
      "an oversized core datagram fails encoding without erasing the authenticated session")

let toMac = phoneFrame(MQVPN_RELAY_DATA_TO_MAC, sequence: 4, payload: Data([9, 8, 7]))
check(state.receive(toMac, nowMs: 105) == .deliverToCore(Data([9, 8, 7]), 44) &&
      state.snapshot.dataToMacBytes == 3,
      "authenticated DATA_TO_MAC is delivered to the matching logical path")
check(state.receive(toMac, nowMs: 106) == .drop(.replay),
      "duplicate authenticated data is rejected by the shared replay window")

let emptyKeepalive = phoneFrame(MQVPN_RELAY_KEEPALIVE, sequence: 5)
check(state.receive(emptyKeepalive, nowMs: 106) == .none && state.snapshot.active,
      "an empty keepalive is idle traffic and does not echo")
let probeNonce = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
let probeKeepalive = phoneFrame(MQVPN_RELAY_KEEPALIVE, sequence: 6, payload: probeNonce)
check(state.receive(probeKeepalive, nowMs: 106) == .echoKeepalive(probeNonce) &&
      state.snapshot.active && state.snapshot.pathHandle == 44,
      "an 8-byte keepalive nonce is echoed so the iPhone can promote the path")
let shortKeepalive = phoneFrame(MQVPN_RELAY_KEEPALIVE, sequence: 7, payload: Data(count: 7))
check(state.receive(shortKeepalive, nowMs: 106) == .drop(.malformed) && state.snapshot.active,
      "a 7-byte keepalive is malformed and must not echo")
let longKeepalive = phoneFrame(MQVPN_RELAY_KEEPALIVE, sequence: 8, payload: Data(count: 9))
check(state.receive(longKeepalive, nowMs: 106) == .drop(.malformed) && state.snapshot.active,
      "a 9-byte keepalive is malformed and must not echo")

check(MacRelaySendRecovery.shouldRefreshRoute(ENETUNREACH) &&
      MacRelaySendRecovery.shouldRefreshRoute(EHOSTUNREACH) &&
      MacRelaySendRecovery.shouldRefreshRoute(EADDRNOTAVAIL) &&
      !MacRelaySendRecovery.shouldRefreshRoute(ECONNRESET),
      "a stale connected UDP route is refreshed on the same socket; ECONNRESET still reopens")
check(MacRelaySourcePin.shouldBindExactSource(pinnedAddressLength: 28) &&
      !MacRelaySourcePin.shouldBindExactSource(pinnedAddressLength: 0),
      "reopen binds the first connected LAN source; the first open still lets connect() choose")
check(MacRelaySourcePin.shouldReplacePin(existingAddressLength: 0, newAddressLength: 28) &&
      !MacRelaySourcePin.shouldReplacePin(existingAddressLength: 28, newAddressLength: 16) &&
      !MacRelaySourcePin.shouldReplacePin(existingAddressLength: 28, newAddressLength: 28),
      "a later getsockname after default routes must not replace the first LAN pin")
check(MacRelaySourcePin.shouldClearPinAfterBindFailure(exactBindAttempted: true,
                                                       bindSucceeded: false) &&
      !MacRelaySourcePin.shouldClearPinAfterBindFailure(exactBindAttempted: true,
                                                        bindSucceeded: true) &&
      !MacRelaySourcePin.shouldClearPinAfterBindFailure(exactBindAttempted: false,
                                                        bindSucceeded: false) &&
      !MacRelaySourcePin.shouldClearPinAfterBindFailure(exactBindAttempted: false,
                                                        bindSucceeded: true),
      "only a failed exact-source bind clears the pin so reopen can fall back to the port")
check(state.shouldHelloAfterRouteRefresh() &&
      !MacRelaySourcePin.shouldHelloAfterRouteRefresh(started: false, hardFailure: false) &&
      !MacRelaySourcePin.shouldHelloAfterRouteRefresh(started: true, hardFailure: true),
      "settings apply immediately re-validates the relay with HELLO")
state.hardSocketFailure(nowMs: 107, error: "ECONNRESET")
check(state.snapshot.hardFailures == 1 && !state.snapshot.active &&
      state.shouldReopenSocket(nowMs: 1_106) == false &&
      state.shouldReopenSocket(nowMs: 1_107),
      "hard socket failure removes its path and waits one second before reopen")
check(state.beginSession(sessionID: session + 2, nowMs: 1_107) == .started &&
      state.snapshot.sessionID == session + 2 && state.snapshot.pathHandle == nil,
      "reopen starts a fresh session with no inherited logical path")

let expiredACK = phoneFrame(MQVPN_RELAY_HELLO_ACK, sessionID: session + 2, sequence: 1)
check(state.receive(expiredACK, nowMs: 1_108) == .activateLogicalPath && state.attachLogicalPath(45),
      "new session can authenticate after reopen")
check(state.expireIfIdle(nowMs: 16_108) == false &&
      state.expireIfIdle(nowMs: 16_109),
      "relay expires only after the full fifteen-second authenticated idle window")
check(!state.snapshot.active && state.snapshot.pathHandle == nil,
      "expiry removes the logical callback path")

check(MacRelayEndpointSafety.isLocalEndpoint("192.168.1.20",
                                              localIPv4Addresses: ["192.168.1.20"]),
      "relay endpoint equal to a local address is rejected")
check(!MacRelayEndpointSafety.isLocalEndpoint("192.168.1.42",
                                               localIPv4Addresses: ["192.168.1.20"]),
      "a distinct LAN peer remains eligible")
check(MacRelayTransportGeneration.accepts(capturedGeneration: 7, currentGeneration: 7,
                                          capturedFD: 12, currentFD: 12, stopped: false) &&
      !MacRelayTransportGeneration.accepts(capturedGeneration: 7, currentGeneration: 8,
                                           capturedFD: 12, currentFD: 12, stopped: false) &&
      !MacRelayTransportGeneration.accepts(capturedGeneration: 8, currentGeneration: 8,
                                           capturedFD: 12, currentFD: 12, stopped: true),
      "stale or stopped DispatchSource events are rejected before they can reuse an fd")

state.stop()
check(state.snapshot == .stopped && !state.canEncode,
      "Stop clears active/session/replay state and erases the relay key")

// ── Real UDP binder lifecycle ──
// This is intentionally a real localhost UDP peer, not a socket mock. The
// production binder binds lo0, sends its C-codec HELLO, receives a separately
// C-codec-authenticated ACK, registers a real logical core path, and then
// proves that Stop's completion observes engine-hook removal and key erasure.
func loopbackListener() -> (fd: Int32, port: Int)? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
        close(fd); return nil
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { close(fd); return nil }
    var actual = sockaddr_in()
    var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &actualLength)
        }
    }
    guard named == 0 else { close(fd); return nil }
    return (fd, Int(UInt16(bigEndian: actual.sin_port)))
}

func waitUntil(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return predicate()
}

if let listener = loopbackListener(),
   let relayAddress = resolveServer("127.0.0.1", listener.port),
   let serverAddress = resolveServer("127.0.0.1", listener.port) {
    let peerQueue = DispatchQueue(label: "mqvpn.mac.relay.hosttest.peer")
    var phoneSequence: UInt64 = 1
    let peerSource = DispatchSource.makeReadSource(fileDescriptor: listener.fd, queue: peerQueue)
    peerSource.setEventHandler {
        var bytes = [UInt8](repeating: 0,
                             count: Int(MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE +
                                        MQVPN_RELAY_TAG_SIZE))
        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(listener.fd, &bytes, bytes.count, 0, $0, &peerLength)
            }
        }
        guard count > 0 else { return }
        var frame = mqvpn_relay_frame_t()
        let decoded = key.withUnsafeBytes { keyBytes in
            mqvpn_relay_decode(keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                bytes, Int(count), MQVPN_RELAY_MAC_TO_IPHONE,
                                nil, &frame)
        }
        guard decoded == MQVPN_RELAY_OK, frame.type == MQVPN_RELAY_HELLO else { return }
        var ack = [UInt8](repeating: 0,
                          count: Int(MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE +
                                     MQVPN_RELAY_TAG_SIZE))
        var ackLength = 0
        let encoded = key.withUnsafeBytes { keyBytes in
            mqvpn_relay_encode(keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                MQVPN_RELAY_HELLO_ACK, MQVPN_RELAY_IPHONE_TO_MAC,
                                frame.session_id, phoneSequence, nil, 0,
                                &ack, ack.count, &ackLength)
        }
        guard encoded == MQVPN_RELAY_OK else { return }
        phoneSequence &+= 1
        _ = withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(listener.fd, ack, ackLength, 0, $0, peerLength)
            }
        }
    }
    peerSource.setCancelHandler { close(listener.fd) }
    peerSource.resume()

    let beforeStartEngine = MqvpnEngine()
    let beforeStartBinder = MacRelayBinder(engine: beforeStartEngine,
                                           relayEndpoint: relayAddress,
                                           serverPeer: serverAddress,
                                           interfaceName: "lo0", relayKey: key,
                                           localIPv4Addresses: [])!
    let beforeStartStop = DispatchSemaphore(value: 0)
    beforeStartBinder.stop {
        check(beforeStartBinder.snapshot() == .stopped && beforeStartEngine.onLogicalPathSend == nil,
              "stop-before-start erases the key state and clears the engine callback")
        beforeStartStop.signal()
    }
    check(beforeStartStop.wait(timeout: .now() + 2) == .success,
          "stop-before-start supplies a real completion boundary")

    let liveEngine = MqvpnEngine()
    let liveServer = ServerSettings(host: "127.0.0.1", port: listener.port,
                                    serverName: "", authKey: "host-test", insecure: true)
    liveEngine.start(server: liveServer, serverAddr: serverAddress)
    let liveBinder = MacRelayBinder(engine: liveEngine, relayEndpoint: relayAddress,
                                    serverPeer: serverAddress, interfaceName: "lo0",
                                    relayKey: key, localIPv4Addresses: [])!
    liveBinder.start()
    check(waitUntil({ liveBinder.snapshot().active }),
          "real interface-bound UDP HELLO/ACK activates the logical relay path")
    let activeSnapshot = liveBinder.snapshot()
    check(activeSnapshot.helloSent >= 1 && activeSnapshot.lanTxBytes > 0 &&
          activeSnapshot.ackReceived >= 1,
          "real full UDP send, ACK, and non-secret counters agree")
    let capturedSend = liveEngine.onLogicalPathSend
    if let capturedSend, let activeHandle = activeSnapshot.pathHandle {
        let oversized = Data(count: Int(MQVPN_RELAY_MAX_PAYLOAD_SIZE) + 1)
        check(capturedSend(activeHandle, oversized) == -Int(EMSGSIZE) &&
              liveBinder.snapshot().active &&
              liveBinder.snapshot().sessionID == activeSnapshot.sessionID &&
              liveBinder.snapshot().pathHandle == activeHandle &&
              liveBinder.snapshot().hardFailures == activeSnapshot.hardFailures,
              "an oversized core datagram fails without erasing the authenticated relay")
    } else {
        check(false, "active relay exposes its send callback for oversize handling")
    }
    let raceStarted = DispatchSemaphore(value: 0)
    let raceFinished = DispatchSemaphore(value: 0)
    if let capturedSend, let activeHandle = activeSnapshot.pathHandle {
        DispatchQueue.global(qos: .userInitiated).async {
            raceStarted.signal()
            _ = capturedSend(activeHandle, Data([0x42]))
            raceFinished.signal()
        }
        _ = raceStarted.wait(timeout: .now() + 1)
    } else {
        check(false, "active relay exposes its production logical-send callback")
    }
    // Hold the real engine tick thread before calling Stop twice. Both calls
    // therefore queue behind one actual pending cleanup fence, making an
    // early second completion observable rather than timing-dependent.
    let tickEntered = DispatchSemaphore(value: 0)
    let releaseTick = DispatchSemaphore(value: 0)
    check(liveEngine.perform {
        tickEntered.signal()
        _ = releaseTick.wait(timeout: .now() + 2)
    }, "host test can place a real tick-thread fence before concurrent Stop")
    check(tickEntered.wait(timeout: .now() + 1) == .success,
          "engine tick thread reached the concurrent Stop fence")
    let firstStop = DispatchSemaphore(value: 0)
    let secondStop = DispatchSemaphore(value: 0)
    let completionLock = NSLock()
    var completionObservedLiveHook = false
    let callers = DispatchGroup()
    for done in [firstStop, secondStop] {
        callers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            liveBinder.stop {
                let clean = liveBinder.snapshot() == .stopped && liveEngine.onLogicalPathSend == nil
                completionLock.lock()
                completionObservedLiveHook = completionObservedLiveHook || !clean
                completionLock.unlock()
                done.signal()
            }
            callers.leave()
        }
    }
    callers.wait()
    _ = liveBinder.snapshot() // drains both stop jobs while the tick fence is held
    check(firstStop.wait(timeout: .now()) == .timedOut &&
          secondStop.wait(timeout: .now()) == .timedOut,
          "neither concurrent Stop completion runs before the shared tick cleanup fence")
    releaseTick.signal()
    check(firstStop.wait(timeout: .now() + 3) == .success &&
          secondStop.wait(timeout: .now() + 3) == .success,
          "all concurrent Stop callers complete after one tick-thread teardown")
    completionLock.lock()
    let completionWasEarly = completionObservedLiveHook
    completionLock.unlock()
    check(!completionWasEarly,
          "each Stop completion observes erased state and a cleared engine callback")
    check(raceFinished.wait(timeout: .now() + 1) == .success,
          "a concurrent real logical send cannot deadlock Stop teardown")
    if let capturedSend, let activeHandle = activeSnapshot.pathHandle {
        check(capturedSend(activeHandle, Data([0x43])) == -Int(ENODEV),
              "a callback captured before Stop fails closed without queueing behind teardown")
    }
    let engineStop = DispatchSemaphore(value: 0)
    _ = liveEngine.perform {
        liveEngine.shutdown()
        engineStop.signal()
    }
    check(engineStop.wait(timeout: .now() + 2) == .success,
          "engine remains safe to shut down after relay completion")
    peerSource.cancel()
} else {
    check(false, "real UDP relay lifecycle fixture binds a loopback listener")
}

if failures != 0 {
    print("macOS relay host tests: \(failures) failure(s)")
    exit(1)
}
print("macOS relay host tests: PASS")
