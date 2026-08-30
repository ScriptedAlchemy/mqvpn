// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import CoreFoundation

/// Single source of the reorder wire schema + validation, shared by the app
/// (writes providerConfiguration) and the extension (reads it, emits setter
/// calls). Plain Foundation — the app target does not link libmqvpn, so profile
/// values are plain ints matching the native enum (3=CELLULAR_BOND,
/// 4=FIBER_LTE) and proto is 17 (UDP).
struct ReorderSettings: Equatable {
    var enabled: Bool
    var profile: Int          // 3 = CELLULAR_BOND, 4 = FIBER_LTE
    var ports: [Int]
    var bondTCP: Bool

    // Explicit memberwise init: defining the custom `init?(providerConfiguration:)`
    // below would otherwise suppress Swift's synthesized memberwise init, which
    // `.disabled` and `init?` both call.
    init(enabled: Bool, profile: Int, ports: [Int], bondTCP: Bool) {
        self.enabled = enabled
        self.profile = profile
        self.ports = ports
        self.bondTCP = bondTCP
    }

    static let disabled = ReorderSettings(enabled: false, profile: 3, ports: [],
                                          bondTCP: false)
    static let profileCellularBond = 3
    static let profileFiberLTE = 4
    static let protoUDP = 17
    static let protoTCP = 6
    static let maxRules = 16

    private enum Key {
        static let enabled = "reorderEnabled"
        static let profile = "reorderProfile"
        static let ports = "reorderPorts"
        static let bondTCP = "reorderBondTCP"
    }

    func toProviderConfiguration() -> [String: Any] {
        [Key.enabled: NSNumber(value: enabled),
         Key.profile: NSNumber(value: profile),
         Key.ports: ports.map { NSNumber(value: $0) },
         Key.bondTCP: NSNumber(value: bondTCP)]
    }

    /// Validates on read. A malformed top-level dict yields nil (caller falls
    /// back to `.disabled`). profile out of {3,4} clamps to 3. Within a valid
    /// NSNumber ports array, out-of-range or bool-backed entries are dropped
    /// per element; if the ports value is not a homogeneous NSNumber array, the
    /// whole ports list is dropped.
    init?(providerConfiguration dict: [String: Any]?) {
        guard let dict else { return nil }
        var enabled = false
        if let n = dict[Key.enabled] as? NSNumber, Self.isBool(n) { enabled = n.boolValue }
        var profile = Self.profileCellularBond
        if let n = dict[Key.profile] as? NSNumber, let v = Self.exactInt(n),
           v == Self.profileCellularBond || v == Self.profileFiberLTE {
            profile = v
        }
        var ports: [Int] = []
        if let arr = dict[Key.ports] as? [NSNumber] {
            for n in arr where !Self.isBool(n) {
                if let v = Self.exactInt(n), (1...65535).contains(v) { ports.append(v) }
            }
        }
        // Same strict-bool discipline as `enabled`: only a genuine CFBoolean
        // counts; missing/malformed/numeric-backed values stay false.
        var bondTCP = false
        if let n = dict[Key.bondTCP] as? NSNumber, Self.isBool(n) { bondTCP = n.boolValue }
        self.init(enabled: enabled, profile: profile, ports: ports, bondTCP: bondTCP)
    }

    /// True iff `n` is a genuine integer NSNumber (not boolean, not
    /// float/double-backed — CFNumberIsFloatType catches `NSNumber(3.0)`).
    static func exactInt(_ n: NSNumber) -> Int? {
        if isBool(n) { return nil }
        if CFNumberIsFloatType(n as CFNumber) { return nil }
        return n.intValue
    }

    static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Parse the comma-separated ports field. Non-numeric entries are skipped
    /// with a warning; range/dedupe happen in planReorder.
    static func parsePorts(_ text: String) -> (ports: [Int], warnings: [String]) {
        var ports: [Int] = []
        var warnings: [String] = []
        for raw in text.split(separator: ",") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let v = Int(t) { ports.append(v) } else { warnings.append("not a number: \(t)") }
        }
        return (ports, warnings)
    }

    /// Empty plan when !enabled. Else dedupe, range-filter, cap UDP ports so
    /// the optional proto-6/port-0 TCP wildcard still fits in maxRules, then
    /// map surviving ports to UDP rules. Port 0 is the match-rule wildcard
    /// ("all TCP"), not a UDP listen port.
    func planReorder(maxRules: Int = ReorderSettings.maxRules)
        -> (rules: [ReorderRuleSpec], warnings: [String]) {
        guard enabled else { return ([], []) }
        var warnings: [String] = []
        var seen = Set<Int>()
        var valid: [Int] = []
        for p in ports {
            guard (1...65535).contains(p) else { warnings.append("port out of range: \(p)"); continue }
            if seen.insert(p).inserted { valid.append(p) }
        }
        // Reserve one slot for the TCP wildcard so total rules stay ≤ maxRules.
        let udpCap = maxRules - (bondTCP ? 1 : 0)
        if valid.count > udpCap {
            warnings.append("ports exceed \(udpCap); dropping \(valid.count - udpCap)")
            valid = Array(valid.prefix(udpCap))
        }
        var rules = valid.map { ReorderRuleSpec(proto: Self.protoUDP, port: $0, profile: profile) }
        if bondTCP {
            rules.append(ReorderRuleSpec(proto: Self.protoTCP, port: 0, profile: profile))
        }
        return (rules, warnings)
    }

    /// Save-gate: enabling requires at least one rule.
    var isSavable: Bool { !enabled || !planReorder().rules.isEmpty }

    /// Fail-closed enable decision: reorder is enabled only if at least one
    /// add-rule call succeeded. `ruleResults[i] == true` means rule i landed.
    static func reorderEnableDecision(ruleResults: [Bool]) -> (enable: Bool, added: Int) {
        let added = ruleResults.filter { $0 }.count
        return (added > 0, added)
    }
}

struct ReorderRuleSpec: Equatable {
    let proto: Int
    let port: Int
    let profile: Int
}
