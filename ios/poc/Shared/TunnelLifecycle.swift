// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

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
    managers.first { $0.providerBundleID == providerBundleID }
}

/// Pure state and dispatch decisions for a user-initiated tunnel Stop.
enum StopLifecycle: Equatable {
    case unavailable
    case alreadyStopped
    case requested
    case stopped
    case failed

    static func request(hasManager: Bool, status: TunnelStatus) -> StopLifecycle {
        guard hasManager else { return .unavailable }
        return status == .disconnected ? .alreadyStopped : .requested
    }

    /// Stop is visible immediately, while terminal reconciliation remains
    /// driven by NEVPNStatusDidChange.
    static func visibleStatus(after request: StopLifecycle,
                              current: TunnelStatus) -> TunnelStatus {
        request == .requested ? .disconnecting : current
    }

    static func transition(from state: StopLifecycle,
                           observedStatus: TunnelStatus? = nil,
                           timedOut: Bool = false,
                           didError: Bool = false) -> StopLifecycle {
        guard state == .requested else { return state }
        if timedOut || didError { return .failed }
        return observedStatus == .disconnected ? .stopped : state
    }

    /// Execute accepted work on the engine thread, or take the synchronous
    /// local completion path if that thread has already stopped accepting work.
    static func performOrFinish(perform: (@escaping () -> Void) -> Bool,
                                accepted: @escaping () -> Void,
                                rejected: @escaping () -> Void) {
        if !perform(accepted) { rejected() }
    }

}
