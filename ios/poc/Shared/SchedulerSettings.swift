// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// Shared path policy. Missing or unknown values default to Max Throughput.
struct SchedulerSettings: Equatable {
    let policy: Int

    static let maxThroughput = 0
    static let lowLatency = 1
    static let `default` = SchedulerSettings(policy: maxThroughput)

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

    static func displayLabel(for policy: Int) -> String {
        policy == lowLatency ? labelLatency : labelThroughput
    }

    var displayLabel: String { Self.displayLabel(for: policy) }

    /// Dashboards show the persisted request, not server-effective policy.
    static let requestedCaption = "Requested"
    var requestedDisplayLabel: String { "\(Self.requestedCaption) \(displayLabel)" }
}
