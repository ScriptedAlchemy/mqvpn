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

/// System staleness is presentation truth: once ActivityKit marks an update
/// stale, no surface may continue presenting its last numeric rate as live.
enum LiveActivityDisplayPolicy {
    static func visible(_ content: LiveActivityInterfaceContent?,
                        isStale: Bool) -> LiveActivityInterfaceContent? {
        isStale ? nil : content
    }

    static func accessibilityState(isStale: Bool,
                                   interfaceAvailable: Bool) -> String {
        if isStale { return "stale data" }
        return interfaceAvailable ? "active" : "offline"
    }
}

struct LiveActivityDescriptor: Equatable {
    let id: String
    let mode: String
}

struct LiveActivitySelectionPlan: Equatable {
    let currentID: String?
    let endIDs: [String]
}

/// The Island is created by the foreground app process. A packet-tunnel
/// updater seeing zero descriptors means this session never called begin().
enum LiveActivitySessionPolicy {
    static func shouldBegin(alreadyStarted: Bool, isUp: Bool) -> Bool {
        isUp && !alreadyStarted
    }

    static func shouldEnd(alreadyStarted: Bool, isTerminal: Bool) -> Bool {
        alreadyStarted && isTerminal
    }
}

/// App and packet-provider processes can race asynchronous ActivityKit writes.
/// Accept only a strictly newer sample so a delayed task cannot move the
/// Dynamic Island backwards or extend the life of stale rates.
enum LiveActivityUpdateOrder {
    static func shouldApply(currentSampledAt: Double?,
                            candidateSampledAt: Double) -> Bool {
        guard let currentSampledAt else { return true }
        return candidateSampledAt > currentSampledAt
    }
}

/// ActivityKit budgets background updates: a provider publishing every sample
/// exhausts the budget within minutes (even with the frequent-updates
/// entitlement), after which the system silently drops updates and the widget
/// crosses its staleDate and greys out. The gate keeps SAMPLING at full
/// cadence but publishes only when the reader could tell the difference:
/// phase changes, an interface appearing/disappearing, a material rate move,
/// or a heartbeat that renews staleDate. Pure and deterministic for host
/// tests; the reporter owns the clock.
enum LiveActivityPublishGate {
    /// Publishes may not exceed one per `minimumInterval` even on change;
    /// `heartbeatInterval` bounds how long the island can go without a
    /// staleDate renewal. Both are far under the stale window.
    static let minimumInterval: TimeInterval = 2
    static let heartbeatInterval: TimeInterval = 30

    /// A rate move counts as material when it would read differently at a
    /// glance: at least 0.5 Mbps AND 15% away from the last published value.
    /// nil<->value flips (sampling gaps, interface loss) always count.
    static func materiallyDiffer(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (x?, y?):
            let delta = abs(x - y)
            return delta >= 0.5 && delta >= 0.15 * max(abs(x), abs(y))
        }
    }

    private static func interfacesDiffer(_ a: LiveActivityInterfaceContent?,
                                         _ b: LiveActivityInterfaceContent?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (x?, y?):
            if x.interfaceName != y.interfaceName { return true }
            return materiallyDiffer(x.megabitsPerSecond, y.megabitsPerSecond)
        }
    }

    static func shouldPublish(candidate: LiveActivityContentState,
                              lastPublished: LiveActivityContentState?,
                              lastPublishedAt: Double?) -> Bool {
        guard let lastPublished, let lastPublishedAt else { return true }
        let elapsed = candidate.sampledAt - lastPublishedAt
        if elapsed < minimumInterval { return false }
        if elapsed >= heartbeatInterval { return true }
        if candidate.phase != lastPublished.phase { return true }
        if interfacesDiffer(candidate.wifi, lastPublished.wifi) { return true }
        if interfacesDiffer(candidate.cellular, lastPublished.cellular) { return true }
        return false
    }
}

/// Deterministic duplicate and mode-switch policy shared by the foreground
/// requester and provider updater. There is exactly one current activity, and
/// it must match the running mode.
enum LiveActivitySelection {
    static func plan(activities: [LiveActivityDescriptor],
                     desiredMode: String) -> LiveActivitySelectionPlan {
        let currentID = activities.first(where: { $0.mode == desiredMode })?.id
        let endIDs = activities.compactMap { descriptor in
            descriptor.id == currentID ? nil : descriptor.id
        }
        return LiveActivitySelectionPlan(currentID: currentID, endIDs: endIDs)
    }
}
