// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Combine
@preconcurrency import NetworkExtension

@MainActor
final class TunnelController: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var statusText = "not loaded"
    @Published var lastError: String?
    @Published var snapshot: MacProviderSnapshot?
    @Published var serverSettings: ServerSettings?
    @Published var relaySettings: MacRelaySettings?
    @Published var hybridSettings: HybridSettings = .disabled
    @Published var configError: String?
    @Published private(set) var isSaving = false
    @Published var showSettings = false

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?
    private var rateSampler = MacSnapshotRateSampler()
    private var pathRates: [MacPathRate] = []
    private var lastSnapshotReceivedAt: TimeInterval?
    private var relayConfigurationIsValid = true

    var isEditable: Bool { manager != nil && status == .disconnected }
    var isConnectable: Bool {
        MacConnectGuard.canStart(isEditable: isEditable, isSaving: isSaving,
                                 server: serverSettings, relay: relaySettings,
                                 relayConfigurationIsValid: relayConfigurationIsValid)
    }
    var isStoppable: Bool {
        StopLifecycle.canStop(hasManager: manager != nil,
                              status: TunnelStatus.fromNEVPNRawValue(Int(status.rawValue)))
    }

    var displayedSnapshot: MacProviderSnapshot? {
        MacSnapshotFreshness.isFresh(receivedAt: lastSnapshotReceivedAt,
                                     now: Date().timeIntervalSince1970) ? snapshot : nil
    }

    var directRow: (name: String, mbps: Double?, bytes: UInt64)? {
        guard let path = displayedSnapshot?.paths.first(where: { $0.name != "iphone-relay" })
        else { return nil }
        let rate = pathRates.first { $0.pathID == path.name }
        return (path.name, rate?.megabitsPerSecond, rate?.totalBytes ?? 0)
    }

    var relayRow: (active: Bool, mbps: Double?, lastError: String?)? {
        guard let relay = displayedSnapshot?.relay else { return nil }
        let rate = pathRates.first { $0.pathID == "iphone-relay" }?.megabitsPerSecond
        return (relay.active, rate, relay.lastError)
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, let connection = note.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.applyStatus(connection.status)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func loadOrCreateManager() async {
        do {
            let existing = try await NETunnelProviderManager.loadAllFromPreferences()
            let descriptors = existing.enumerated().map { index, manager in
                ManagerDescriptor(
                    id: String(index),
                    providerBundleID: (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier,
                    status: TunnelStatus.fromNEVPNRawValue(Int(manager.connection.status.rawValue)))
            }
            let matching = selectMatchingManager(
                descriptors, providerBundleID: TunnelProviderConfiguration.providerBundleID)
            let loaded: NETunnelProviderManager
            if let matching, let index = Int(matching.id) {
                loaded = existing[index]
            } else {
                loaded = NETunnelProviderManager()
                try await applyProtocol(to: loaded, configuration: [:])
            }
            try await read(from: loaded)
            manager = loaded
            applyStatus(loaded.connection.status)
        } catch {
            statusText = "load error"
            lastError = error.localizedDescription
        }
    }

    func start() {
        guard isConnectable, let manager else { return }
        lastError = nil
        applyStatus(.connecting)
        do {
            try manager.connection.startVPNTunnel()
            statusText = "starting"
        } catch {
            lastError = error.localizedDescription
            statusText = "start error"
        }
    }

    func stop() {
        let request = StopLifecycle.request(
            hasManager: manager != nil,
            status: TunnelStatus.fromNEVPNRawValue(Int(status.rawValue)))
        guard request == .requested else { return }
        applyStatus(.disconnecting)
        manager?.connection.stopVPNTunnel()
        statusText = "stopping"
    }

    func save(server: ServerSettings, relay: MacRelaySettings) async {
        guard let manager,
              saveGuard(isSaving: isSaving, isEditable: isEditable,
                        hasManager: true) == nil else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let merged = MacProviderConfiguration.make(server: server, relay: relay,
                                                       hybrid: hybridSettings)
            try await applyProtocol(to: manager, configuration: merged)
            try await read(from: manager)
            if relayConfigurationIsValid { configError = nil }
        } catch {
            configError = error.localizedDescription
        }
    }

    private func applyProtocol(to manager: NETunnelProviderManager,
                               configuration: [String: Any]) async throws {
        let backupProtocol = manager.protocolConfiguration
        let backupEnabled = manager.isEnabled
        let backupName = manager.localizedDescription
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelProviderConfiguration.providerBundleID
        proto.serverAddress = (configuration["serverHost"] as? String)
            ?? serverSettings?.host ?? "mqvpn"
        proto.includeAllNetworks = TunnelProviderConfiguration.includeAllNetworks
        proto.excludeLocalNetworks = TunnelProviderConfiguration.excludeLocalNetworks
        proto.enforceRoutes = TunnelProviderConfiguration.enforceRoutes
        var next = proto.providerConfiguration ?? [:]
        for (key, value) in configuration { next[key] = value }
        proto.providerConfiguration = next
        manager.protocolConfiguration = proto
        manager.localizedDescription = TunnelProviderConfiguration.localizedName
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            manager.protocolConfiguration = backupProtocol
            manager.isEnabled = backupEnabled
            manager.localizedDescription = backupName
            throw error
        }
    }

    private func read(from manager: NETunnelProviderManager) async throws {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        let config = proto?.providerConfiguration
        if let server = ServerSettings(providerConfiguration: config) {
            serverSettings = server
        } else if serverSettings == nil {
            configError = "server config invalid — re-enter in Settings"
        }
        hybridSettings = HybridSettings(providerConfiguration: config) ?? .disabled
        do {
            relaySettings = try MacRelaySettings.startConfiguration(from: config)
                ?? MacRelaySettings(providerConfiguration: config)
            relayConfigurationIsValid = true
        } catch {
            relaySettings = nil
            relayConfigurationIsValid = false
            configError = error.localizedDescription
        }
    }

    private func applyStatus(_ status: NEVPNStatus) {
        self.status = status
        statusText = Self.label(status)
        let tunnelStatus = TunnelStatus.fromNEVPNRawValue(Int(status.rawValue))
        if MacPollingLifecycle.shouldPoll(status: tunnelStatus) {
            startPolling()
        } else {
            stopPolling()
            if tunnelStatus == .disconnected || tunnelStatus == .invalid {
                expireSnapshot()
            }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.expireIfStale()
                self?.poll()
            }
        }
        poll()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func expireSnapshot() {
        snapshot = nil
        pathRates = []
        lastSnapshotReceivedAt = nil
        rateSampler = MacSnapshotRateSampler()
    }

    private func expireIfStale() {
        if !MacSnapshotFreshness.isFresh(receivedAt: lastSnapshotReceivedAt,
                                         now: Date().timeIntervalSince1970) {
            snapshot = nil
            pathRates = []
        }
    }

    private func poll() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage(Data([0])) { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    guard let data, let next = try? MacProviderSnapshot.decode(data) else { return }
                    self.snapshot = next
                    self.pathRates = self.rateSampler.ingest(next)
                    self.lastSnapshotReceivedAt = Date().timeIntervalSince1970
                    if let error = next.lastError, !error.isEmpty { self.lastError = error }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func label(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "not loaded"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }
}
