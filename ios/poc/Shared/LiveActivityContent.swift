// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

enum LiveActivityPhase: String, Codable, Hashable {
    case connecting
    case waiting
    case active
    case stopping
    case unavailable
}

struct LiveActivityInterfaceContent: Codable, Hashable {
    let interfaceName: String
    /// Nil is an honest "sampling" state. A measured idle interval is 0.
    let megabitsPerSecond: Double?
}

/// Dynamic data delivered by ActivityKit to the system-owned widget process.
/// It intentionally contains no endpoint, authentication material, or traffic
/// contents.
struct LiveActivityContentState: Codable, Hashable {
    let phase: LiveActivityPhase
    let sampledAt: Double
    let wifi: LiveActivityInterfaceContent?
    let cellular: LiveActivityInterfaceContent?

    static func lifecycle(_ phase: LiveActivityPhase, timestamp: Double) -> Self {
        Self(phase: phase, sampledAt: timestamp, wifi: nil, cellular: nil)
    }
}
