// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// Authoritative identifier for the packet-tunnel provider profile. Kept in
/// Foundation-only shared code so the app and host tests cannot drift apart.
enum TunnelProviderConfiguration {
    static let providerBundleID = "com.zackjackson.mqvpn.PacketTunnel"
}

/// NetworkExtension-independent connection states used to make app lifecycle
/// decisions host-testable. The app maps its NEVPNStatus into this value type.
enum TunnelStatus: Equatable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

/// The only data needed to decide whether a persisted VPN profile belongs to
/// this app. The live NETunnelProviderManager stays in the app target.
struct ManagerDescriptor: Equatable {
    let id: String
    let providerBundleID: String?
    let status: TunnelStatus
}

/// Select only the profile whose tunnel-provider identifier exactly matches
/// this app. A persisted profile from another build or app is never adopted.
func selectMatchingManager(_ managers: [ManagerDescriptor],
                           providerBundleID: String) -> ManagerDescriptor? {
    let matching = managers.filter { $0.providerBundleID == providerBundleID }
    func priority(_ status: TunnelStatus) -> Int {
        switch status {
        case .connected: return 5
        case .reasserting: return 4
        case .connecting: return 3
        case .disconnecting: return 2
        case .disconnected: return 1
        case .invalid: return 0
        }
    }
    return matching.max { priority($0.status) < priority($1.status) }
}

enum ProviderReconnectAction: Equatable {
    case awaitReconnect
    case failStart
    case cancelTunnel
}

enum ProviderReconnectPolicy {
    static func closed(startResolved: Bool, permanent: Bool) -> ProviderReconnectAction {
        guard permanent else { return .awaitReconnect }
        return startResolved ? .cancelTunnel : .failStart
    }
}

enum ProviderCloseReason {
    static func isPermanent(_ reason: Int32) -> Bool {
        // MQVPN_ERR_TLS, AUTH, PROTOCOL, and ABI_MISMATCH cannot recover
        // without a configuration or binary change. CLOSED and TIMEOUT can.
        // INVALID_ARG (-1) and ENGINE (-3) are emitted only by the Swift
        // engine wrapper for local setup/connect failures — the core never
        // sends them as close reasons, so no client exists to reconnect.
        // Treating them as transient parked the start continuation in
        // .awaitReconnect forever and let the NE watchdog kill the extension.
        reason == -1 || reason == -3 ||
            reason == -4 || reason == -5 || reason == -6 || reason == -11
    }
}

/// Pure decision for a user-initiated tunnel Stop request. Terminal
/// reconciliation stays driven by NEVPNStatusDidChange, not by this type.
enum StopLifecycle: Equatable {
    case unavailable
    case alreadyStopped
    case requested

    static func request(hasManager: Bool, status: TunnelStatus) -> StopLifecycle {
        guard hasManager else { return .unavailable }
        return status == .disconnected ? .alreadyStopped : .requested
    }
}
