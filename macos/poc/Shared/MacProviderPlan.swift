// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// No persisted host/port: the provider reaches the iPhone exclusively
/// through Bonjour discovery, so the durable relay preference is only the
/// enabled bit and the shared key.
struct MacRelaySettings: Equatable {
    let enabled: Bool
    let keyBase64: String

    private enum Key {
        static let enabled = "macRelayEnabled"
        static let key = "macRelayKey"
        static let all = [enabled, key]
    }

    init(enabled: Bool, keyBase64: String) {
        self.enabled = enabled
        self.keyBase64 = keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init?(providerConfiguration config: [String: Any]?) {
        guard let config else { return nil }
        let enabled: Bool
        if let number = config[Key.enabled] as? NSNumber {
            enabled = number.boolValue
        } else {
            enabled = config[Key.enabled] as? Bool ?? false
        }
        let key = (config[Key.key] as? String) ?? ""
        self.init(enabled: enabled, keyBase64: key)
        guard !enabled || isValid else { return nil }
    }

    /// Absent keys mean direct-only. Any present key that does not produce a
    /// valid enabled relay is a hard Start failure, not a silent downgrade.
    static func startConfiguration(from config: [String: Any]?) throws -> MacRelaySettings? {
        guard let config, Key.all.contains(where: { config[$0] != nil }) else { return nil }
        guard let settings = MacRelaySettings(providerConfiguration: config) else {
            throw NSError(domain: "mqvpn.mac", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "relay configuration invalid"])
        }
        return settings.enabled ? settings : nil
    }

    var decodedKey: Data? {
        guard let data = Data(base64Encoded: keyBase64), data.count == 32 else { return nil }
        return data
    }

    var isValid: Bool {
        decodedKey != nil
    }

    func toProviderConfiguration() -> [String: Any] {
        [Key.enabled: NSNumber(value: enabled), Key.key: keyBase64]
    }
}

enum MacPathIdentity {
    static let relayName = "iphone-relay"
    static let relayLANSampleID = "iphone-relay.lan"
}

enum MacLANInterfaceKind: Int, Equatable {
    case wifi = 0
    case wiredEthernet = 1
}

struct MacLANInterfaceCandidate: Equatable {
    let name: String
    let kind: MacLANInterfaceKind
    let address: String
    let netmask: String
}

enum MacLANInterfaceSelector {
    static func select(relayIPv4: String,
                       candidates: [MacLANInterfaceCandidate]) -> String? {
        guard let relay = ipv4(relayIPv4) else { return nil }
        return candidates.sorted { $0.kind.rawValue < $1.kind.rawValue }.first { candidate in
            guard !candidate.name.isEmpty,
                  let local = ipv4(candidate.address),
                  let mask = ipv4(candidate.netmask), mask != 0 else { return false }
            return local & mask == relay & mask
        }?.name
    }

    /// IPv4 stays subnet-matched. IPv6 uses the same live Wi-Fi/Ethernet
    /// candidate because the Mac IPv4 tunnel does not own IPv6 LAN reachability.
    static func interfaceName(reaching host: String,
                              candidates: [MacLANInterfaceCandidate]) -> String? {
        if let name = select(relayIPv4: host, candidates: candidates) { return name }
        guard MacRelayDiscovery.isIPv6(host) else { return nil }
        return candidates.sorted { $0.kind.rawValue < $1.kind.rawValue }
            .first { !$0.name.isEmpty }?.name
    }

    static func onLinkRoute(relayIPv4: String,
                            candidates: [MacLANInterfaceCandidate]) -> MacIPv4Route? {
        guard let name = select(relayIPv4: relayIPv4, candidates: candidates),
              let candidate = candidates.first(where: { $0.name == name }),
              let local = ipv4(candidate.address),
              let mask = ipv4(candidate.netmask), mask != 0 else { return nil }
        let network = local & mask
        var prefix: UInt8 = 0
        var bit = mask
        while bit & 0x8000_0000 != 0 {
            prefix += 1
            bit <<= 1
        }
        return MacIPv4Route(address: dotted(network), prefix: prefix)
    }

    private static func dotted(_ value: UInt32) -> String {
        "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }

    private static func ipv4(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}

struct MacIPv4Route: Equatable {
    let address: String
    let prefix: UInt8
}

/// Framework-free description of the settings that Network Extension applies
/// only after libmqvpn has authenticated and delivered tunnel configuration.
/// The plan is IPv4-only by design; see makeSettings for the ::/0 rationale.
struct MacProviderNetworkPlan: Equatable {
    let assignedAddress: String
    let subnetMask: String
    let mtu: Int
    let serverIPv4: String
    let includedRoutes: [MacIPv4Route]
    let excludedRoutes: [MacIPv4Route]
    let dnsServers: [String]

    init(assignedAddress: String, assignedPrefix: UInt8, mtu: Int,
         serverIPv4: String, relayIPv4: String?, relayLAN: MacIPv4Route? = nil) {
        self.assignedAddress = assignedAddress
        self.subnetMask = Self.prefixToMask(assignedPrefix)
        self.mtu = mtu
        self.serverIPv4 = serverIPv4
        self.includedRoutes = [MacIPv4Route(address: "0.0.0.0", prefix: 0)]
        var excluded = [MacIPv4Route(address: serverIPv4, prefix: 32)]
        if let relayIPv4, MacRelayDiscovery.isIPv4(relayIPv4) {
            excluded.append(MacIPv4Route(address: relayIPv4, prefix: 32))
        }
        if let relayLAN { excluded.append(relayLAN) }
        self.excludedRoutes = excluded
        self.dnsServers = ["1.1.1.1", "8.8.8.8"]
    }

    static func prefixToMask(_ prefix: UInt8) -> String {
        let bounded = min(prefix, 32)
        let mask: UInt32 = bounded == 0 ? 0 : ~UInt32(0) << (32 - UInt32(bounded))
        return "\((mask >> 24) & 255).\((mask >> 16) & 255).\((mask >> 8) & 255).\(mask & 255)"
    }
}

enum MacProviderLifecycleAction: Equatable {
    case none
    case applyNetworkSettings
    case completeStart
    case failStart
    case beginRecovery(deadlineMs: UInt64)
    case endRecovery
    case beginReconnect(deadlineMs: UInt64)
    case applyReconnectSettings
    case completeReconnect
    case cancelTunnel
}

/// MQVPN_ERR_TLS, AUTH, PROTOCOL, and ABI_MISMATCH cannot recover without a
/// configuration or binary change. CLOSED, TIMEOUT, and engine-internal
/// closes can: the core schedules its own backoff reconnect for those, and
/// the provider's job is to stay alive (reasserting) until it lands.
enum MacProviderCloseReason {
    static func isPermanent(_ reason: Int32) -> Bool {
        reason == -4 || reason == -5 || reason == -6 || reason == -11
    }
}

enum MacRelayRebindPolicy {
    /// A live binder stays until a different interface is observed; nil means
    /// keep. A transient `getifaddrs` miss after tunnel settings must not
    /// unbind: that dropped the authenticated IPv6 relay about two seconds
    /// after ACK.
    static func rebindTarget(current: String?, desired: String?) -> String? {
        guard let desired, desired != current else { return nil }
        return desired
    }
}

/// Small, framework-free guard used at both sides of Network Extension's
/// asynchronous settings apply. A core config callback is not sufficient by
/// itself: the final active path can vanish before settings complete.
enum MacProviderStartupSafety {
    static func hasSurvivingPath(activePathCount: Int, stopping: Bool) -> Bool {
        !stopping && activePathCount > 0
    }
}

/// Pure lifecycle policy. Runtime timers and Network Extension callbacks map
/// their events into this state machine; it never owns routes or sockets.
struct MacProviderLifecycle {
    static let startupTimeoutMs: UInt64 = 10_000
    static let recoveryWindowMs: UInt64 = 5_000
    /// Long enough for the core's 5s/10s/20s backoff to land two attempts.
    static let reconnectWindowMs: UInt64 = 35_000

    private enum Stage {
        case idle
        case preflight(startedMs: UInt64)
        case applyingSettings(startedMs: UInt64)
        case established
        case recovering(deadlineMs: UInt64)
        /// The core session closed for a transient reason and libmqvpn's own
        /// backoff reconnect is running. NE stays up under `reasserting`; a
        /// fresh tunnel_config_ready re-applies settings.
        case reconnecting(deadlineMs: UInt64)
        case reapplyingReconnectSettings(deadlineMs: UInt64)
        case failed
        case stopping
    }

    private var stage: Stage = .idle

    var isStopping: Bool {
        if case .stopping = stage { return true }
        return false
    }

    mutating func begin(nowMs: UInt64) -> MacProviderLifecycleAction {
        guard case .idle = stage else { return .none }
        stage = .preflight(startedMs: nowMs)
        return .none
    }

    mutating func tunnelConfigurationReady() -> MacProviderLifecycleAction {
        if case let .reconnecting(deadlineMs) = stage {
            stage = .reapplyingReconnectSettings(deadlineMs: deadlineMs)
            return .applyReconnectSettings
        }
        guard case let .preflight(startedMs) = stage else { return .none }
        stage = .applyingSettings(startedMs: startedMs)
        return .applyNetworkSettings
    }

    /// Post-establishment session close. Transient reasons hold the tunnel
    /// under reasserting while the core reconnects; permanent ones, or a
    /// close before establishment, keep today's terminal behavior.
    mutating func tunnelClosed(permanent: Bool,
                               nowMs: UInt64) -> MacProviderLifecycleAction {
        switch stage {
        case .established, .recovering:
            guard !permanent else {
                stage = .failed
                return .cancelTunnel
            }
            let deadline = nowMs + Self.reconnectWindowMs
            stage = .reconnecting(deadlineMs: deadline)
            return .beginReconnect(deadlineMs: deadline)
        case .reconnecting, .reapplyingReconnectSettings:
            // The reconnect attempt itself died; keep waiting for the next
            // one inside the same bounded window. A permanent failure
            // (e.g. rotated PSK) still terminates immediately.
            guard !permanent else {
                stage = .failed
                return .cancelTunnel
            }
            if case let .reapplyingReconnectSettings(deadlineMs) = stage {
                stage = .reconnecting(deadlineMs: deadlineMs)
            }
            return .none
        default:
            return .none
        }
    }

    mutating func reconnectSettingsApplied(error: Bool) -> MacProviderLifecycleAction {
        guard case let .reapplyingReconnectSettings(deadlineMs) = stage else { return .none }
        if error {
            stage = .reconnecting(deadlineMs: deadlineMs)
            return .none
        }
        stage = .established
        return .completeReconnect
    }

    mutating func reconnectTimerFired(nowMs: UInt64) -> MacProviderLifecycleAction {
        switch stage {
        case let .reconnecting(deadlineMs),
             let .reapplyingReconnectSettings(deadlineMs):
            guard nowMs >= deadlineMs else { return .none }
            stage = .failed
            return .cancelTunnel
        default:
            return .none
        }
    }

    mutating func networkSettingsApplied(error: Bool,
                                         activePathCount: Int) -> MacProviderLifecycleAction {
        guard case .applyingSettings = stage else { return .none }
        if error || activePathCount == 0 {
            stage = .failed
            return .failStart
        }
        stage = .established
        return .completeStart
    }

    mutating func startupTimerFired(nowMs: UInt64) -> MacProviderLifecycleAction {
        let startedMs: UInt64
        switch stage {
        case let .preflight(value), let .applyingSettings(value): startedMs = value
        default: return .none
        }
        guard nowMs >= startedMs + Self.startupTimeoutMs else { return .none }
        stage = .failed
        return .failStart
    }

    mutating func activePathCountChanged(_ count: Int,
                                         nowMs: UInt64) -> MacProviderLifecycleAction {
        switch stage {
        case .applyingSettings where count == 0:
            stage = .failed
            return .failStart
        case .established where count == 0:
            let deadline = nowMs + Self.recoveryWindowMs
            stage = .recovering(deadlineMs: deadline)
            return .beginRecovery(deadlineMs: deadline)
        case .recovering where count > 0:
            stage = .established
            return .endRecovery
        case .reconnecting, .reapplyingReconnectSettings:
            // The core tears its paths down and rebuilds them across a
            // reconnect; the recovery machinery must not race the bounded
            // reconnect window with its own five-second cancel.
            return .none
        default:
            return .none
        }
    }

    mutating func recoveryTimerFired(nowMs: UInt64) -> MacProviderLifecycleAction {
        guard case let .recovering(deadlineMs) = stage,
              nowMs >= deadlineMs else { return .none }
        stage = .failed
        return .cancelTunnel
    }

    mutating func beginStop() -> Bool {
        switch stage {
        case .stopping: return false
        default:
            stage = .stopping
            return true
        }
    }
}
