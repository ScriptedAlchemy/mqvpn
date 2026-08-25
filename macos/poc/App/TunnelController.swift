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
    private var profileIsCurrent = true
    private var relayRateSample: (timestamp: Double, totalBytes: UInt64)?
    private var relayMegabitsPerSecond: Double?

    var isEditable: Bool { manager != nil && status == .disconnected }
    var isConnectable: Bool {
        MacConnectGuard.canStart(isEditable: isEditable, isSaving: isSaving,
                                 server: serverSettings, relay: relaySettings,
                                 relayConfigurationIsValid: relayConfigurationIsValid,
                                 profileIsCurrent: profileIsCurrent)
    }
    var isStoppable: Bool {
        StopLifecycle.canStop(hasManager: manager != nil,
                              status: TunnelStatus.fromNEVPNRawValue(Int(status.rawValue)))
    }

    var displayedSnapshot: MacProviderSnapshot? {
        MacSnapshotFreshness.isFresh(receivedAt: lastSnapshotReceivedAt,
                                     now: Date().timeIntervalSince1970) ? snapshot : nil
    }

    var directRows: [MacPathRate] {
        guard let snapshot = displayedSnapshot else { return [] }
        let liveIDs = Set(snapshot.paths.map(\.name).filter { $0 != "iphone-relay" })
        return pathRates.filter { $0.pathID != "iphone-relay" && liveIDs.contains($0.pathID) }
    }

    var relayRow: (active: Bool, mbps: Double?, lastError: String?)? {
        guard let relay = displayedSnapshot?.relay else { return nil }
        return (relay.active, relayMegabitsPerSecond, relay.lastError)
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
            profileIsCurrent = true
            applyStatus(loaded.connection.status)
        } catch {
            profileIsCurrent = false
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
            applyStatus(manager.connection.status)
            statusText = "start error: \(error.localizedDescription)"
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

    func save(server: ServerSettings, relay: MacRelaySettings,
              hybrid: HybridSettings) async {
        guard let manager,
              saveGuard(isSaving: isSaving, isEditable: isEditable,
                        hasManager: true) == nil else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let merged = MacProviderConfiguration.make(server: server, relay: relay,
                                                       hybrid: hybrid)
            try await applyProtocol(to: manager, configuration: merged)
            try await read(from: manager)
            profileIsCurrent = true
            if relayConfigurationIsValid { configError = nil }
        } catch MacSaveFailure.refresh {
            profileIsCurrent = false
            configError = "VPN profile was saved but could not be reloaded. Reopen mqvpn before starting."
        } catch {
            configError = error.localizedDescription
        }
    }

    private func applyProtocol(to manager: NETunnelProviderManager,
                               configuration: [String: Any]) async throws {
        let previousProtocol = manager.protocolConfiguration
        let previousEnabled = manager.isEnabled
        let previousName = manager.localizedDescription
        // A new protocol object, never the live manager's instance. Mutating
        // that shared object would make rollback a no-op.
        let proto = NETunnelProviderProtocol()
        if let current = previousProtocol as? NETunnelProviderProtocol {
            proto.providerConfiguration = current.providerConfiguration
        }
        proto.providerBundleIdentifier = TunnelProviderConfiguration.providerBundleID
        proto.serverAddress = (configuration["serverHost"] as? String)
            ?? serverSettings?.host ?? "mqvpn"
        proto.includeAllNetworks = TunnelProviderConfiguration.includeAllNetworks
        proto.excludeLocalNetworks = TunnelProviderConfiguration.excludeLocalNetworks
        proto.enforceRoutes = TunnelProviderConfiguration.enforceRoutes
        manager.localizedDescription = TunnelProviderConfiguration.localizedName
        manager.isEnabled = true
        do {
            try await performAtomicSave(MacNEConfigStore(manager: manager, proto: proto),
                                        merge: configuration)
        } catch MacSaveFailure.commit(let error) {
            manager.protocolConfiguration = previousProtocol
            manager.isEnabled = previousEnabled
            manager.localizedDescription = previousName
            throw error
        } catch MacSaveFailure.refresh {
            // Prefs already committed. Retry the reload; only disable Start if
            // that retry also fails. Never restore the pre-save protocol.
            do {
                try await manager.loadFromPreferences()
            } catch {
                manager.protocolConfiguration = proto
                throw MacSaveFailure.refresh(error)
            }
        }
    }

    private func read(from manager: NETunnelProviderManager) async throws {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        let config = proto?.providerConfiguration
        if let server = ServerSettings(providerConfiguration: config) {
            serverSettings = server
        } else {
            serverSettings = nil
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
        relayRateSample = nil
        relayMegabitsPerSecond = nil
    }

    private func expireIfStale() {
        if !MacSnapshotFreshness.isFresh(receivedAt: lastSnapshotReceivedAt,
                                         now: Date().timeIntervalSince1970) {
            snapshot = nil
            pathRates = []
            relayRateSample = nil
            relayMegabitsPerSecond = nil
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
                    self.ingestRelayRate(from: next)
                    self.lastSnapshotReceivedAt = Date().timeIntervalSince1970
                    if let error = next.lastError, !error.isEmpty { self.lastError = error }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ingestRelayRate(from snapshot: MacProviderSnapshot) {
        guard let relay = snapshot.relay else {
            relayRateSample = nil
            relayMegabitsPerSecond = nil
            return
        }
        let total = relay.lanTxBytes.addingReportingOverflow(relay.lanRxBytes)
        guard !total.overflow else {
            relayRateSample = nil
            relayMegabitsPerSecond = nil
            return
        }
        if let prior = relayRateSample, snapshot.timestamp > prior.timestamp,
           total.partialValue >= prior.totalBytes {
            let elapsed = snapshot.timestamp - prior.timestamp
            relayMegabitsPerSecond = elapsed >= 0.05 && elapsed <= MacSnapshotFreshness.maxAge
                ? Double(total.partialValue - prior.totalBytes) * 8 / elapsed / 1_000_000
                : nil
        } else {
            relayMegabitsPerSecond = nil
        }
        if relayRateSample?.timestamp ?? -.infinity <= snapshot.timestamp {
            relayRateSample = (snapshot.timestamp, total.partialValue)
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

private final class MacNEConfigStore: MacConfigStore {
    private let manager: NETunnelProviderManager
    private var proto: NETunnelProviderProtocol

    init(manager: NETunnelProviderManager, proto: NETunnelProviderProtocol) {
        self.manager = manager
        self.proto = proto
    }

    var providerConfiguration: [String: Any]? {
        get { proto.providerConfiguration }
        set { proto.providerConfiguration = newValue }
    }

    func commit() async throws {
        manager.protocolConfiguration = proto
        try await manager.saveToPreferences()
    }

    func refresh() async throws {
        do {
            try await manager.loadFromPreferences()
        } catch {
            // A save succeeded, so give preferences one immediate retry before
            // declaring the UI unable to reconcile its committed state.
            try await manager.loadFromPreferences()
        }
        guard let refreshed = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw NSError(domain: "mqvpn.mac", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "saved VPN protocol missing"])
        }
        proto = refreshed
    }
}
