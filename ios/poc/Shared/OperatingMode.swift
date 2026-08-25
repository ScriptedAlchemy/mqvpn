// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// The Packet Tunnel extension has two deliberately distinct products: a
/// full-device VPN and a constrained LAN-to-cellular mqvpn datagram relay.
/// Absence means VPN for compatibility with profiles saved before relay mode
/// existed; an unknown present value is corrupt and therefore fails closed.
enum OperatingMode: String, Codable, CaseIterable, Equatable {
    case vpn
    case macRelay

    private static let key = "operatingMode"

    init?(providerConfiguration: [String: Any]?) {
        guard let raw = providerConfiguration?[Self.key] else {
            self = .vpn
            return
        }
        guard let value = raw as? String, let mode = Self(rawValue: value) else {
            return nil
        }
        self = mode
    }

    func toProviderConfiguration() -> [String: Any] {
        [Self.key: rawValue]
    }

    /// Optimize For is consumed only by the VPN engine path. Mac Relay
    /// never constructs `MqvpnEngine`, so the control is hidden there.
    var usesOptimizeFor: Bool { self == .vpn }
}
