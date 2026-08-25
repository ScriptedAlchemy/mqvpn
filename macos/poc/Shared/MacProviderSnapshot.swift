// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

struct MacProviderPathSnapshot: Codable, Equatable {
    let name: String
    let status: Int32
    let txBytes: UInt64
    let rxBytes: UInt64
}

struct MacProviderRelaySnapshot: Codable, Equatable {
    let started: Bool
    let active: Bool
    let helloSent: UInt64
    let rawReceived: UInt64
    let authAccepted: UInt64
    let authRejected: UInt64
    let ackReceived: UInt64
    let lanTxBytes: UInt64
    let lanRxBytes: UInt64
    let dataToMacBytes: UInt64
    let sendAgain: UInt64
    let sendFailures: UInt64
    let hardFailures: UInt64
    let lastError: String?
}

struct MacProviderSnapshot: Codable, Equatable {
    let timestamp: Double
    let clientState: Int32
    let connectedSince: Double?
    let footprint: UInt64
    let reasserting: Bool
    let lastError: String?
    let paths: [MacProviderPathSnapshot]
    let relay: MacProviderRelaySnapshot?

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> MacProviderSnapshot {
        try JSONDecoder().decode(MacProviderSnapshot.self, from: data)
    }
}
