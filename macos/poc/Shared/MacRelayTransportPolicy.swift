// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import Network

/// Policy for the Network.framework relay transport, kept free of sockets and
/// connection objects so the host suite can prove it without a LAN.
///
/// The relay hop is Mac -> iPhone over the shared Wi-Fi/wired LAN. It must
/// never egress through this Mac's own packet tunnel: that is the loop which
/// stranded the session when installing the default route let the kernel
/// reselect a utun source address.
enum MacRelayTransportPolicy {
    /// `NWInterface.InterfaceType.other` is how Network.framework reports utun
    /// and other virtual interfaces. Prohibiting it, rather than pinning one
    /// exact source address, is what keeps the relay off our own tunnel while
    /// still allowing the system to rebind within the LAN interface.
    static let prohibitedInterfaceTypes: [NWInterface.InterfaceType] = [.other, .cellular]

    /// Bytes allowed in flight to Network.framework before the core is told to
    /// back off. The mqvpn core calls send synchronously and expects an errno,
    /// but NWConnection completes asynchronously, so outstanding bytes are the
    /// only backpressure signal available.
    static let sendHighWaterBytes = 1 << 20

    static func shouldApplyBackpressure(outstandingBytes: Int,
                                        pendingBytes: Int) -> Bool {
        outstandingBytes + pendingBytes > sendHighWaterBytes
    }

    /// A relay LAN hop is only ever Wi-Fi or wired. Loopback would mean the
    /// configured relay address is this Mac, which the binder already rejects.
    static func isUsableRelayInterface(_ type: NWInterface.InterfaceType) -> Bool {
        type == .wifi || type == .wiredEthernet
    }

    /// Map a Network.framework failure onto the errno the mqvpn core expects.
    /// Route-scoped failures keep the recovery behaviour the socket path had:
    /// refresh and retry rather than tearing the authenticated session down.
    static func errnoValue(for error: NWError) -> Int32 {
        switch error {
        case let .posix(code):
            return code.rawValue
        case .dns:
            return EHOSTUNREACH
        case .tls:
            return EIO
        case .wifiAware:
            // Wi-Fi Aware is never a relay LAN hop; treat it as unreachable
            // rather than a transient route error worth rebinding for.
            return EHOSTUNREACH
        @unknown default:
            return EIO
        }
    }

    static func isRecoverableRouteError(_ error: NWError) -> Bool {
        MacRelaySendRecovery.shouldRefreshRoute(errnoValue(for: error))
    }
}
