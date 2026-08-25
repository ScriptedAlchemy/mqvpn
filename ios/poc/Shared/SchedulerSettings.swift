// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import CoreFoundation

/// Two-value path policy shared by both Apple apps. Product copy is
/// "Optimize For" / Max Throughput / Low Latency — never xquic scheduler names.
/// Missing or unknown provider values fail closed to Max Throughput.
struct SchedulerSettings: Equatable {
    let policy: Int

    static let maxThroughput = 0
    static let lowLatency = 1
    static let `default` = SchedulerSettings(policy: maxThroughput)

    /// libmqvpn `MQVPN_SCHED_WLB` — app targets do not import the C enum.
    static let coreWLB = 1
    /// libmqvpn `MQVPN_SCHED_MINRTT`.
    static let coreMinRTT = 0

    static let headerThroughput = "throughput"
    static let headerLatency = "latency"
    static let labelThroughput = "Max Throughput"
    static let labelLatency = "Low Latency"
    static let pickerTitle = "Optimize For"

    private enum Key {
        static let policy = "schedulerPolicy"
    }

    init(policy: Int) {
        self.policy = policy == Self.lowLatency ? Self.lowLatency : Self.maxThroughput
    }

    func toProviderConfiguration() -> [String: Any] {
        [Key.policy: NSNumber(value: policy)]
    }

    init(providerConfiguration dict: [String: Any]?) {
        var policy = Self.maxThroughput
        if let n = dict?[Key.policy] as? NSNumber, let v = ReorderSettings.exactInt(n),
           v == Self.maxThroughput || v == Self.lowLatency {
            policy = v
        }
        self.init(policy: policy)
    }

    static func coreScheduler(for policy: Int) -> Int {
        policy == lowLatency ? coreMinRTT : coreWLB
    }

    static func headerValue(for policy: Int) -> String {
        policy == lowLatency ? headerLatency : headerThroughput
    }

    static func displayLabel(for policy: Int) -> String {
        policy == lowLatency ? labelLatency : labelThroughput
    }

    var headerValue: String { Self.headerValue(for: policy) }
    var displayLabel: String { Self.displayLabel(for: policy) }
}
