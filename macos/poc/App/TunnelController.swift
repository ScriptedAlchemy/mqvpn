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
    @Published var configError: String?
    @Published private(set) var isSaving = false
    @Published var showSettings = false

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?
    private var previous: MacProviderSnapshot?

    var isEditable: Bool { manager != nil && status == .disconnected }
    var isConnectable: Bool {
        MacConnectGuard.canStart(isEditable: isEditable, isSaving: isSaving,
                                 server: serverSettings, relay: relaySettings)
    }
    var isStoppable: Bool {
        StopLifecycle.canStop(hasManager: manager != nil,
                              status: TunnelStatus.fromNEVPNRawValue(Int(status.rawValue)))
    }

    var directRow: (name: String, mbps: Double, bytes: UInt64)? {
        snapshot?.paths.first.map { path in
            (path.name, rateMbps(previous: previous?.paths.first, current: path),
             path.txBytes &+ path.rxBytes)
        }
    }

    var relayRow: (active: Bool, mbps: Double, lastError: String?)? {
        guard let relay = snapshot?.relay else { return nil }
        let prev = previous?.relay
        let bytes = Double((relay.lanTxBytes &+ relay.lanRxBytes) &-
                           ((prev?.lanTxBytes ?? 0) &+ (prev?.lanRxBytes ?? 0)))
        let elapsed = max(snapshot!.timestamp - (previous?.timestamp ?? snapshot!.timestamp), 0.05)
        return (relay.active, max(0, bytes * 8 / elapsed / 1_000_000), relay.lastError)
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, let connection = note.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.status = connection.status
                self.statusText = Self.label(connection.status)
                if connection.status == .disconnected {
                    self.snapshot = nil
                    self.previous = nil
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
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
            status = loaded.connection.status
            statusText = Self.label(loaded.connection.status)
        } catch {
            statusText = "load error"
            lastError = error.localizedDescription
        }
    }

    func start() {
        guard isConnectable, let manager else { return }
        lastError = nil
        do {
            try manager.connection.startVPNTunnel()
            statusText = "starting"
            startPolling()
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
            var merged = server.toProviderConfiguration()
            for (key, value) in relay.toProviderConfiguration() { merged[key] = value }
            try await applyProtocol(to: manager, configuration: merged)
            try await read(from: manager)
            configError = nil
        } catch {
            configError = error.localizedDescription
        }
    }

    private func applyProtocol(to manager: NETunnelProviderManager,
                               configuration: [String: Any]) async throws {
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
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    private func read(from manager: NETunnelProviderManager) async throws {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        let config = proto?.providerConfiguration
        if let server = ServerSettings(providerConfiguration: config) {
            serverSettings = server
        } else if serverSettings == nil {
            configError = "server config invalid — re-enter in Settings"
        }
        relaySettings = try? MacRelaySettings.startConfiguration(from: config)
            ?? MacRelaySettings(providerConfiguration: config)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    private func poll() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage(Data([0])) { [weak self] data in
                Task { @MainActor in
                    guard let self, let data,
                          let next = try? MacProviderSnapshot.decode(data) else { return }
                    self.previous = self.snapshot
                    self.snapshot = next
                    if let error = next.lastError, !error.isEmpty { self.lastError = error }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func rateMbps(previous: MacProviderPathSnapshot?,
                          current: MacProviderPathSnapshot) -> Double {
        guard let previous, let stamp = snapshot?.timestamp,
              let prior = self.previous?.timestamp else { return 0 }
        let bytes = Double((current.txBytes &+ current.rxBytes) &-
                           (previous.txBytes &+ previous.rxBytes))
        let elapsed = max(stamp - prior, 0.05)
        return max(0, bytes * 8 / elapsed / 1_000_000)
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
