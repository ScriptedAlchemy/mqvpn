// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

struct MacRelaySettings: Equatable {
    let enabled: Bool
    let host: String
    let port: Int
    let keyBase64: String

    private enum Key {
        static let enabled = "macRelayEnabled"
        static let host = "macRelayHost"
        static let port = "macRelayPort"
        static let key = "macRelayKey"
        static let all = [enabled, host, port, key]
    }

    init(enabled: Bool, host: String, port: Int, keyBase64: String) {
        self.enabled = enabled
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
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
        let host = (config[Key.host] as? String) ?? ""
        let port: Int
        if let number = config[Key.port] as? NSNumber {
            port = number.intValue
        } else {
            port = config[Key.port] as? Int ?? 5443
        }
        let key = (config[Key.key] as? String) ?? ""
        self.init(enabled: enabled, host: host, port: port, keyBase64: key)
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
        !host.isEmpty && (1...65_535).contains(port) && decodedKey != nil
    }

    func toProviderConfiguration() -> [String: Any] {
        [Key.enabled: NSNumber(value: enabled), Key.host: host,
         Key.port: NSNumber(value: port), Key.key: keyBase64]
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
struct MacProviderNetworkPlan: Equatable {
    let assignedAddress: String
    let subnetMask: String
    let mtu: Int
    let serverIPv4: String
    let includedRoutes: [MacIPv4Route]
    let excludedRoutes: [MacIPv4Route]
    let dnsServers: [String]

    init(assignedAddress: String, assignedPrefix: UInt8, mtu: Int,
         serverIPv4: String, relayIPv4: String?) {
        self.assignedAddress = assignedAddress
        self.subnetMask = Self.prefixToMask(assignedPrefix)
        self.mtu = mtu
        self.serverIPv4 = serverIPv4
        self.includedRoutes = [MacIPv4Route(address: "0.0.0.0", prefix: 0)]
        self.excludedRoutes = [serverIPv4, relayIPv4].compactMap { address in
            guard let address, !address.isEmpty else { return nil }
            return MacIPv4Route(address: address, prefix: 32)
        }
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
    case cancelTunnel
}

enum MacRelayRebindDecision: Equatable {
    case keep
    case unbind
    case rebind(to: String)
}

enum MacRelayRebindPolicy {
    static func decide(current: String?, desired: String?) -> MacRelayRebindDecision {
        if current == desired { return .keep }
        guard let desired else { return .unbind }
        return .rebind(to: desired)
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

    private enum Stage {
        case idle
        case preflight(startedMs: UInt64)
        case applyingSettings(startedMs: UInt64)
        case established
        case recovering(deadlineMs: UInt64)
        case failed
        case stopping
    }

    private var stage: Stage = .idle
    private(set) var settingsRequested = false

    var isEstablished: Bool {
        switch stage {
        case .established, .recovering: return true
        default: return false
        }
    }

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
        guard case .preflight = stage else { return .none }
        settingsRequested = true
        guard case let .preflight(startedMs) = stage else { return .none }
        stage = .applyingSettings(startedMs: startedMs)
        return .applyNetworkSettings
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
