// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import Network

/// Keeps the Mac-to-iPhone LAN hop outside the packet tunnel.
enum MacRelayTransportPolicy {
    /// Exclude virtual interfaces (including utun) while allowing LAN rebinding.
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

    /// Translate Network.framework failures to the core's socket error codes.
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
        let code = errnoValue(for: error)
        return code == ENETUNREACH || code == EHOSTUNREACH || code == EADDRNOTAVAIL
    }
}
