// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

enum MqvpnRelayBonjour {
    static let serviceType = "_mqvpn-relay._udp"
    static let serviceTypeWithDot = "_mqvpn-relay._udp."
    static let instanceName = "mqvpn"
    static let domain = "local."
}

enum RelayAdvertisementPolicy {
    static func shouldPublish(lanReady: Bool, cellularReady: Bool,
                              stopped: Bool) -> Bool {
        !stopped && lanReady && cellularReady
    }
}
