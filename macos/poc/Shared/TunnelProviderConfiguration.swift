// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// Authoritative identifiers and protocol flags for the macOS VPN profile.
/// `includeAllNetworks` / `excludeLocalNetworks` / `enforceRoutes` live on the
/// persisted `NETunnelProviderProtocol`, never on tunnel network settings.
enum TunnelProviderConfiguration {
    static let providerBundleID = "com.zackjackson.mqvpn.mac.PacketTunnel"
    static let localizedName = "mqvpn"
    static let includeAllNetworks = false
    static let excludeLocalNetworks = true
    static let enforceRoutes = false
}

enum TunnelStatus: Equatable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting

    static func fromNEVPNRawValue(_ raw: Int) -> TunnelStatus {
        switch raw {
        case 1: return .disconnected
        case 2: return .connecting
        case 3: return .connected
        case 4: return .reasserting
        case 5: return .disconnecting
        default: return .invalid
        }
    }
}

struct ManagerDescriptor: Equatable {
    let id: String
    let providerBundleID: String?
    let status: TunnelStatus
}

func selectMatchingManager(_ managers: [ManagerDescriptor],
                           providerBundleID: String) -> ManagerDescriptor? {
    managers.first { $0.providerBundleID == providerBundleID }
}

func managersEligibleForMutation(_ managers: [ManagerDescriptor],
                                 providerBundleID: String) -> [ManagerDescriptor] {
    managers.filter { $0.providerBundleID == providerBundleID }
}

enum SaveError: Error, Equatable { case inProgress, notEditable, notReady }

func saveGuard(isSaving: Bool, isEditable: Bool, hasManager: Bool) -> SaveError? {
    if isSaving { return .inProgress }
    if !isEditable { return .notEditable }
    if !hasManager { return .notReady }
    return nil
}

protocol MacConfigStore: AnyObject {
    var providerConfiguration: [String: Any]? { get set }
    var localizedName: String? { get set }
    var isEnabled: Bool { get set }
    func commit() async throws
    func refresh() async throws
}

enum MacSaveFailure: Error {
    case commit(any Error)
    case refresh(any Error)
}

func performAtomicSave(_ store: MacConfigStore, merge: [String: Any],
                       name: String? = nil, enabled: Bool? = nil) async throws {
    let backupConfig = store.providerConfiguration
    let backupName = store.localizedName
    let backupEnabled = store.isEnabled
    var merged = backupConfig ?? [:]
    for (k, v) in merge { merged[k] = v }
    store.providerConfiguration = merged
    if let name { store.localizedName = name }
    if let enabled { store.isEnabled = enabled }
    do { try await store.commit() }
    catch {
        store.providerConfiguration = backupConfig
        store.localizedName = backupName
        store.isEnabled = backupEnabled
        throw MacSaveFailure.commit(error)
    }
    do { try await store.refresh() }
    catch {
        do { try await store.refresh() }
        catch { throw MacSaveFailure.refresh(error) }
    }
}

enum MacConnectGuard {
    static func canStart(isEditable: Bool, isSaving: Bool,
                         server: ServerSettings?,
                         relay: MacRelaySettings?,
                         relayConfigurationIsValid: Bool = true,
                         profileIsCurrent: Bool = true,
                         discoveredRelay: MacRelayEndpoint? = nil) -> Bool {
        guard isEditable, !isSaving, server?.isValid == true,
              relayConfigurationIsValid, profileIsCurrent else { return false }
        guard let relay else { return true }
        guard !relay.enabled || relay.isValid else { return false }
        // Relay is an additive path. A temporarily absent iPhone must not
        // block the direct Mac path; the provider keeps discovering while the
        // tunnel is running and attaches the relay when it appears.
        _ = discoveredRelay
        return true
    }
}

/// Single source of the provider-configuration wire shape shared by the Mac
/// app and its packet-tunnel provider. The relay's explicit disabled state is
/// retained so an old enabled relay cannot be accidentally revived by a later
/// server-only save.
enum MacProviderConfiguration {
    static func make(server: ServerSettings, relay: MacRelaySettings,
                     hybrid: HybridSettings,
                     scheduler: SchedulerSettings = .default) -> [String: Any] {
        var configuration = server.toProviderConfiguration()
        for (key, value) in relay.toProviderConfiguration() { configuration[key] = value }
        for (key, value) in hybrid.toProviderConfiguration() { configuration[key] = value }
        for (key, value) in scheduler.toProviderConfiguration() { configuration[key] = value }
        return configuration
    }
}

enum MacPollingLifecycle {
    static func shouldPoll(status: TunnelStatus) -> Bool {
        status == .connected || status == .reasserting
    }
}

enum StopLifecycle: Equatable {
    case unavailable
    case alreadyStopped
    case requested

    static func request(hasManager: Bool, status: TunnelStatus) -> StopLifecycle {
        guard hasManager else { return .unavailable }
        switch status {
        case .connecting, .connected, .reasserting:
            return .requested
        case .invalid, .disconnected, .disconnecting:
            return .alreadyStopped
        }
    }

    static func canStop(hasManager: Bool, status: TunnelStatus) -> Bool {
        request(hasManager: hasManager, status: status) == .requested
    }
}

/// App-facing output for one provider path. `pathID` is the provider's stable
/// interface name; list position is deliberately never used as identity.
struct MacPathRate: Equatable, Identifiable {
    let pathID: String
    let totalBytes: UInt64
    let megabitsPerSecond: Double?

    var id: String { pathID }
}

/// Counter-delta sampler for provider snapshots. It fails closed when a path
/// appears for the first time, a counter resets, or provider time does not
/// progress, instead of displaying an invented zero/overflow rate.
struct MacSnapshotRateSampler {
    private struct Sample {
        let timestamp: Double
        let totalBytes: UInt64
    }

    private var samples: [String: Sample] = [:]

    mutating func ingest(id: String, timestamp: Double, totalBytes: UInt64) -> MacPathRate {
        let rate: Double?
        if let previous = samples[id], timestamp > previous.timestamp,
           totalBytes >= previous.totalBytes {
            let elapsed = timestamp - previous.timestamp
            rate = elapsed >= 0.05 && elapsed <= MacSnapshotFreshness.maxAge
                ? Double(totalBytes - previous.totalBytes) * 8 / elapsed / 1_000_000
                : nil
        } else {
            rate = nil
        }
        if samples[id]?.timestamp ?? -.infinity <= timestamp {
            samples[id] = Sample(timestamp: timestamp, totalBytes: totalBytes)
        }
        return MacPathRate(pathID: id, totalBytes: totalBytes, megabitsPerSecond: rate)
    }

    mutating func ingest(_ snapshot: MacProviderSnapshot) -> [MacPathRate] {
        let presentIDs = Set(snapshot.paths.map(\.name))
        samples = samples.filter { presentIDs.contains($0.key) || $0.key == MacPathIdentity.relayLANSampleID }

        return snapshot.paths.map { path in
            let pathID = path.name
            guard let totalBytes = totalBytes(for: path) else {
                samples.removeValue(forKey: pathID)
                return MacPathRate(pathID: pathID, totalBytes: 0, megabitsPerSecond: nil)
            }
            return ingest(id: pathID, timestamp: snapshot.timestamp, totalBytes: totalBytes)
        }
    }

    mutating func ingestRelay(from snapshot: MacProviderSnapshot) -> Double? {
        guard let relay = snapshot.relay else {
            samples.removeValue(forKey: MacPathIdentity.relayLANSampleID)
            return nil
        }
        let total = relay.lanTxBytes.addingReportingOverflow(relay.lanRxBytes)
        guard !total.overflow else {
            samples.removeValue(forKey: MacPathIdentity.relayLANSampleID)
            return nil
        }
        return ingest(id: MacPathIdentity.relayLANSampleID, timestamp: snapshot.timestamp,
                      totalBytes: total.partialValue).megabitsPerSecond
    }

    private func totalBytes(for path: MacProviderPathSnapshot) -> UInt64? {
        let result = path.txBytes.addingReportingOverflow(path.rxBytes)
        return result.overflow ? nil : result.partialValue
    }
}

enum MacSnapshotFreshness {
    static let maxAge: TimeInterval = 3

    static func isFresh(receivedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let receivedAt, now >= receivedAt else { return false }
        return now - receivedAt <= maxAge
    }
}
