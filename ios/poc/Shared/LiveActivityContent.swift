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

/// The provider reporter must not sample or call ActivityKit when this
/// session never created an exact-mode Island. That miss is steady-state,
/// not an event worth logging every two seconds.
enum LiveActivityReporterPublish {
    static func shouldUpdateExisting(currentID: String?) -> Bool {
        currentID != nil
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

/// Stop ordering contract: ActivityKit is ancillary UI and must never delay
/// or precede the packet/relay transport teardown. Cleanup is deliberately a
/// synchronous scheduling closure, so the provider cannot await ActivityKit.
enum LiveActivityStopSequence {
    static func perform(transportTeardown: () async -> Void,
                        activityCleanup: () async -> Void) async {
        await transportTeardown()
        await activityCleanup()
    }
}
