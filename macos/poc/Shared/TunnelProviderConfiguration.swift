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
    func commit() async throws
    func refresh() async throws
}

func performAtomicSave(_ store: MacConfigStore, merge: [String: Any]) async throws {
    let backup = store.providerConfiguration
    var merged = backup ?? [:]
    for (k, v) in merge { merged[k] = v }
    store.providerConfiguration = merged
    do { try await store.commit() }
    catch { store.providerConfiguration = backup; throw error }
    try? await store.refresh()
}

enum MacConnectGuard {
    static func canStart(isEditable: Bool, isSaving: Bool,
                         server: ServerSettings?,
                         relay: MacRelaySettings?) -> Bool {
        guard isEditable, !isSaving, server?.isValid == true else { return false }
        guard let relay else { return true }
        return !relay.enabled || relay.isValid
    }
}

enum StopLifecycle: Equatable {
    case unavailable
    case alreadyStopped
    case requested

    static func request(hasManager: Bool, status: TunnelStatus) -> StopLifecycle {
        guard hasManager else { return .unavailable }
        return status == .disconnected ? .alreadyStopped : .requested
    }

    static func canStop(hasManager: Bool, status: TunnelStatus) -> Bool {
        request(hasManager: hasManager, status: status) == .requested
    }
}
