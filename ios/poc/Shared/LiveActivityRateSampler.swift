// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// The two physical iPhone interface classes mqvpn can bind independently.
/// Synthetic tunnel devices are deliberately not classifiable.
enum LiveActivityInterfaceKind: String, Codable, Hashable, CaseIterable {
    case wifi
    case cellular

    init?(interfaceName: String) {
        if interfaceName == "en0" {
            self = .wifi
        } else if interfaceName.hasPrefix("pdp_ip") {
            self = .cellular
        } else {
            return nil
        }
    }
}

struct InterfaceByteCounter: Equatable {
    let name: String
    let totalBytes: UInt64
}

struct InterfaceSpeed: Equatable {
    let interfaceName: String
    /// Nil means the interface exists but no trustworthy elapsed sample is
    /// available yet. Zero is a measured, idle interval.
    let megabitsPerSecond: Double?
}

struct LiveActivityRateSnapshot: Equatable {
    let wifi: InterfaceSpeed?
    let cellular: InterfaceSpeed?
}

/// Pure provider-side rate sampler. The source counters remain authoritative;
/// smoothing affects only the glanceable display value.
struct LiveActivityRateSampler {
    private struct Baseline {
        let interfaceName: String
        let totalBytes: UInt64
        let timestamp: Double
        let smoothedMbps: Double?
    }

    private let smoothingFactor: Double
    private let maximumInterval: Double
    private var baselines: [LiveActivityInterfaceKind: Baseline] = [:]

    init(smoothingFactor: Double = 0.65, maximumInterval: Double = 10) {
        self.smoothingFactor = min(max(smoothingFactor, 0), 1)
        self.maximumInterval = maximumInterval
    }

    mutating func sample(timestamp: Double,
                         counters: [InterfaceByteCounter]) -> LiveActivityRateSnapshot {
        // Sum every outer flow on an interface. Keeping only the first
        // measured one flow of four, and the order is not stable across
        // samples: when a later sample happened to pick a younger flow the
        // total went backwards, the monotonic guard below rejected it, and
        // the readout fell back to "--" instead of a speed.
        var current: [LiveActivityInterfaceKind: InterfaceByteCounter] = [:]
        for counter in counters {
            guard let kind = LiveActivityInterfaceKind(interfaceName: counter.name)
            else { continue }
            if let running = current[kind] {
                let (total, overflow) =
                    running.totalBytes.addingReportingOverflow(counter.totalBytes)
                current[kind] = InterfaceByteCounter(
                    name: running.name,
                    totalBytes: overflow ? UInt64.max : total)
            } else {
                current[kind] = counter
            }
        }

        for kind in LiveActivityInterfaceKind.allCases where current[kind] == nil {
            baselines.removeValue(forKey: kind)
        }

        func measure(_ kind: LiveActivityInterfaceKind) -> InterfaceSpeed? {
            guard let counter = current[kind] else { return nil }
            guard let previous = baselines[kind],
                  previous.interfaceName == counter.name,
                  counter.totalBytes >= previous.totalBytes else {
                baselines[kind] = Baseline(interfaceName: counter.name,
                                           totalBytes: counter.totalBytes,
                                           timestamp: timestamp,
                                           smoothedMbps: nil)
                return InterfaceSpeed(interfaceName: counter.name,
                                      megabitsPerSecond: nil)
            }

            let elapsed = timestamp - previous.timestamp
            guard elapsed > 0.05, elapsed <= maximumInterval else {
                baselines[kind] = Baseline(interfaceName: counter.name,
                                           totalBytes: counter.totalBytes,
                                           timestamp: timestamp,
                                           smoothedMbps: nil)
                return InterfaceSpeed(interfaceName: counter.name,
                                      megabitsPerSecond: nil)
            }

            let byteDelta = counter.totalBytes - previous.totalBytes
            let rawMbps = Double(byteDelta) * 8 / elapsed / 1_000_000
            let displayedMbps: Double
            if let prior = previous.smoothedMbps {
                displayedMbps = smoothingFactor * rawMbps + (1 - smoothingFactor) * prior
            } else {
                displayedMbps = rawMbps
            }
            baselines[kind] = Baseline(interfaceName: counter.name,
                                       totalBytes: counter.totalBytes,
                                       timestamp: timestamp,
                                       smoothedMbps: displayedMbps)
            return InterfaceSpeed(interfaceName: counter.name,
                                  megabitsPerSecond: displayedMbps)
        }

        return LiveActivityRateSnapshot(wifi: measure(.wifi),
                                        cellular: measure(.cellular))
    }
}

enum LiveActivityCounterSource {
    private static func sum(_ first: UInt64, _ second: UInt64) -> UInt64 {
        let (result, overflow) = first.addingReportingOverflow(second)
        return overflow ? UInt64.max : result
    }

    static func counters(from snapshot: TunnelSnapshot) -> [InterfaceByteCounter] {
        switch snapshot.operatingMode {
        case .vpn:
            // Sum EVERY present flow on a physical interface, regardless of
            // path status: per-path byte counters are monotonic while the
            // path entry exists, but a flow dipping from ACTIVE to
            // degraded/pending during failover used to leave a
            // status-filtered sum, shrink the interface total, trip the
            // sampler's monotonic guard, and blank the island to "--" for a
            // cycle. ACTIVE feeds only the phase decision in
            // LiveActivityContentFactory, never byte accounting.
            return snapshot.paths.compactMap { path in
                guard LiveActivityInterfaceKind(interfaceName: path.name) != nil else {
                    return nil
                }
                return InterfaceByteCounter(
                    name: path.name,
                    totalBytes: sum(path.txBytes, path.rxBytes))
            }
        case .macRelay:
            guard let relay = snapshot.relay else { return [] }
            var counters: [InterfaceByteCounter] = []
            if relay.wifiAvailable, let name = relay.listenerInterface {
                counters.append(InterfaceByteCounter(
                    name: name,
                    totalBytes: sum(relay.lanRxBytes, relay.lanTxBytes)))
            }
            if relay.cellularAvailable, let name = relay.cellularInterface {
                counters.append(InterfaceByteCounter(
                    name: name,
                    totalBytes: sum(relay.serverRxBytes, relay.serverTxBytes)))
            }
            return counters
        }
    }
}

enum LiveActivityContentFactory {
    static let staleInterval: TimeInterval = 6

    static func make(snapshot: TunnelSnapshot,
                     sampler: inout LiveActivityRateSampler)
        -> (state: LiveActivityContentState, staleDate: Date) {
        let rates = sampler.sample(timestamp: snapshot.timestamp,
                                   counters: LiveActivityCounterSource.counters(from: snapshot))
        return (make(snapshot: snapshot, rates: rates),
                Date(timeIntervalSince1970: snapshot.timestamp + staleInterval))
    }

    static func make(snapshot: TunnelSnapshot,
                     rates: LiveActivityRateSnapshot) -> LiveActivityContentState {
        let phase: LiveActivityPhase
        switch snapshot.operatingMode {
        case .vpn:
            // MQVPN_PATH_ACTIVE is raw value 1 in libmqvpn.h. The app target
            // intentionally does not link libmqvpn, so the wire uses Int32.
            let hasActivePhysicalPath = snapshot.paths.contains {
                $0.status == 1 && LiveActivityInterfaceKind(interfaceName: $0.name) != nil
            }
            phase = snapshot.clientState == 4 && hasActivePhysicalPath ? .active : .waiting
        case .macRelay:
            if snapshot.relay?.error != nil {
                phase = .unavailable
            } else if snapshot.relay?.isReady == true {
                phase = .active
            } else {
                phase = .waiting
            }
        }

        return LiveActivityContentState(
            phase: phase,
            sampledAt: snapshot.timestamp,
            wifi: content(from: rates.wifi),
            cellular: content(from: rates.cellular))
    }

    private static func content(from speed: InterfaceSpeed?) -> LiveActivityInterfaceContent? {
        guard let speed else { return nil }
        return LiveActivityInterfaceContent(interfaceName: speed.interfaceName,
                                            megabitsPerSecond: speed.megabitsPerSecond)
    }
}
