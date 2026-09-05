// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import AVFoundation
import SwiftUI
import os
@preconcurrency import NetworkExtension

@main
struct MqvpnPoCApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = TunnelController()

    var body: some Scene {
        WindowGroup {
            DashboardView(controller: controller, eventLog: controller.eventLog)
                // Poll while foregrounded OR while the tunnel keepalive holds the app
                // alive; otherwise pause IPC to avoid
                // battery drain and pointless sendProviderMessage churn.
                .onChange(of: scenePhase) { phase in
                    controller.setScenePhaseActive(phase == .active)
                }
        }
    }
}

/// PoC container controller: load/save the one NETunnelProviderManager,
/// start/stop it, and — while foregrounded and connected — poll the provider
/// for a development snapshot over `sendProviderMessage`. Per-path transfer
/// rates are derived here from consecutive snapshots.
@MainActor
final class TunnelController: ObservableObject {
    static let providerBundleID = TunnelProviderConfiguration.providerBundleID

    @Published var status: NEVPNStatus = .invalid
    @Published var statusText = "not loaded"
    @Published var snapshot: TunnelSnapshot?       // nil = no data
    @Published var pathRates: [String: Double] = [:]   // iface name -> Mbps
    @Published var reorderSettings: ReorderSettings = .disabled
    @Published var hybridSettings = HybridSettings.disabled
    @Published var schedulerSettings = SchedulerSettings.default
    @Published var serverSettings: ServerSettings?   // nil = unset/corrupt → Connect disabled
    @Published var operatingMode: OperatingMode = .vpn
    @Published var relaySettings: RelaySettings?
    @Published var configError: String?              // separate from statusText (updateStatus overwrites)
    @Published private(set) var isSaving = false
    /// Observed directly by the dashboard; fed the same snapshot stream.
    let eventLog = EventLog()
    private var prevSnapshot: TunnelSnapshot?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?
    private var scenePhaseActive = true            // WindowGroup starts active
    /// Bumped on every up->down transition; a poll response captured under a
    /// stale epoch is discarded even if it arrives after the tunnel comes back
    /// up, since it may describe the wrong session.
    private var sessionEpoch = 0
    /// Ordering key for accepted poll responses, reset at each session boundary.
    private var lastIngestedSeq: UInt64 = 0
    private var lastIngestedTimestamp: Double = 0
    private var liveActivityStarted = false
    // Optional app-process keepalive for background Live Activity publishing.
    private let keepAlive = TunnelKeepAlive()
    /// Opt-in, default off. The tunnel itself needs no background execution —
    /// the extension runs regardless — so this trades a silent audio session
    /// for an island that keeps updating after the app is backgrounded.
    static let keepAliveDefaultsKey = "liveActivityKeepAlive"
    private var keepAliveEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.keepAliveDefaultsKey)
    }
    private var defaultsObserver: (any NSObjectProtocol)?
    private var liveActivitySampler = LiveActivityRateSampler()
    // Publish throttle, the same gate the extension's reporter uses:
    // ActivityKit budgets background updates, and publishing every poll
    // exhausted that budget within minutes.
    private var lastPublished: LiveActivityContentState?
    private var lastPublishedAt: Double?

    var isEditable: Bool { manager != nil && status == .disconnected }
    var isConnectable: Bool {
        isEditable && !isSaving &&
            RelayStartGuard.canStart(mode: operatingMode, server: serverSettings,
                                     relay: relaySettings)
    }
    var isStoppable: Bool {
        guard manager != nil else { return false }
        switch Self.tunnelStatus(status) {
        case .connecting, .connected, .reasserting: return true
        default: return false
        }
    }
    static func isUp(_ s: NEVPNStatus) -> Bool { s == .connected || s == .reasserting }

    func loadOrCreateManager() async {
        do {
            let existing = try await NETunnelProviderManager.loadAllFromPreferences()
            let descriptors = existing.enumerated().map { index, manager in
                ManagerDescriptor(
                    id: String(index),
                    providerBundleID: (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier,
                    status: Self.tunnelStatus(manager.connection.status))
            }
            let matching = selectMatchingManager(descriptors, providerBundleID: Self.providerBundleID)
            let m: NETunnelProviderManager
            if let matching, let index = Int(matching.id) {
                m = existing[index]
            } else {
                m = NETunnelProviderManager()
                // Placeholder only: NE rejects an empty serverAddress at save.
                // Decoupled from the real peer, which the seeding step below
                // (and ultimately the extension) resolves and sets itself.
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Self.providerBundleID
                proto.serverAddress = (try? ServerSettings.fromBundle())?.host ?? "mqvpn"
                // Match the Mac profile: local networks stay off-tunnel so
                // Wi-Fi deploys, AirDrop, and LAN peers keep working while
                // the VPN is up.
                proto.excludeLocalNetworks = true
                m.protocolConfiguration = proto
                m.localizedDescription = "mqvpn PoC"
                m.isEnabled = true
                try await m.saveToPreferences()
                try await m.loadFromPreferences()
            }
            manager = nil  // reset until we decide the manager is usable
            guard let proto = m.protocolConfiguration as? NETunnelProviderProtocol else {
                statusText = "config error"; return
            }
            let pc = proto.providerConfiguration
            if !ServerSettings.serverKeysPresent(in: pc) {                 // ABSENT → seed
                let seed = try ServerSettings.fromBundle()
                try await performAtomicSave(NEConfigStore(manager: m, proto: proto),
                                            merge: seed.toProviderConfiguration())
                serverSettings = seed
            } else if let s = ServerSettings(providerConfiguration: pc) {  // VALID
                serverSettings = s
            } else {                                                       // CORRUPT → D4: no overwrite
                serverSettings = nil
                configError = "server config invalid — re-enter in Settings"
            }
            manager = m
            reorderSettings = ReorderSettings(providerConfiguration: pc) ?? .disabled
            hybridSettings = HybridSettings(providerConfiguration: pc) ?? .disabled
            schedulerSettings = SchedulerSettings(providerConfiguration: pc)
            if let mode = OperatingMode(providerConfiguration: pc) {
                operatingMode = mode
                relaySettings = RelaySettings(providerConfiguration: pc)
                if mode == .macRelay && relaySettings == nil {
                    serverSettings = nil
                    configError = "relay config invalid — re-enter in Settings"
                }
            } else {
                operatingMode = .vpn
                relaySettings = nil
                serverSettings = nil
                configError = "operating mode invalid — re-enter in Settings"
            }
            attachObserver(to: m)
            updateStatus(m.connection.status)
        } catch {
            statusText = "load error: \(error.localizedDescription)"
        }
    }

    private func attachObserver(to manager: NETunnelProviderManager) {
        // NotificationCenter's completion closure is not MainActor-isolated
        // even with queue: .main (it is typed @Sendable by the SDK), so hop
        // explicitly before touching @MainActor state.
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self, weak manager] _ in
            Task { @MainActor in
                guard let self, let manager else { return }
                self.updateStatus(manager.connection.status)
            }
        }
    }

    private func updateStatus(_ s: NEVPNStatus) {
        let wasUp = Self.isUp(status)
        status = s
        statusText = Self.describe(s)
        if wasUp && !Self.isUp(s) {          // up -> down session boundary
            sessionEpoch += 1
            lastIngestedSeq = 0
            lastIngestedTimestamp = 0
        }
        if #available(iOS 16.2, *) {
            let up = Self.isUp(s)
            let terminal = s == .disconnected || s == .invalid
            if LiveActivitySessionPolicy.shouldEnd(alreadyStarted: liveActivityStarted,
                                                   isTerminal: terminal) {
                liveActivityStarted = false
                Task { await MqvpnLiveActivityLifecycle.endImmediately() }
            } else if LiveActivitySessionPolicy.shouldBegin(alreadyStarted: liveActivityStarted,
                                                            isUp: up) {
                liveActivityStarted = MqvpnLiveActivityLifecycle.begin(mode: operatingMode)
            }
        }
        reconcileKeepAlive()
    }

    func start() {
        guard isConnectable, let manager else { return }
        if #available(iOS 16.2, *) {
            liveActivityStarted = MqvpnLiveActivityLifecycle.begin(mode: operatingMode)
        }
        Task { await startReclaimingConfiguration(manager) }
    }

    /// Another VPN app selecting its own configuration flips this one to
    /// disabled, and a bare startVPNTunnel then fails with NEVPNErrorDomain
    /// error 2 (configurationDisabled). Re-assert enablement on every start
    /// so pressing Start always reclaims the active VPN slot.
    private func startReclaimingConfiguration(_ manager: NETunnelProviderManager) async {
        do {
            try await manager.loadFromPreferences()
            var needsSave = !manager.isEnabled
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
               !proto.excludeLocalNetworks {
                // Configurations saved before this flag existed keep
                // swallowing the LAN; upgrade them in place on Start.
                proto.excludeLocalNetworks = true
                needsSave = true
            }
            manager.isEnabled = true
            if needsSave {
                try await manager.saveToPreferences()
                // NE requires a reload after save before the connection can
                // be started against the freshly enabled configuration.
                try await manager.loadFromPreferences()
            }
            try manager.connection.startVPNTunnel()
        } catch {
            statusText = "start error: \(error.localizedDescription)"
            if liveActivityStarted, #available(iOS 16.2, *) {
                liveActivityStarted = false
                Task { await MqvpnLiveActivityLifecycle.endImmediately() }
            }
        }
    }

    func stop() {
        guard let manager, isStoppable else { return }
        let request = StopLifecycle.request(hasManager: true, status: Self.tunnelStatus(status))
        guard request == .requested else { return }
        status = .disconnecting
        statusText = Self.describe(status)
        if liveActivityStarted, #available(iOS 16.2, *) {
            liveActivityStarted = false
            MqvpnLiveActivityLifecycle.markStopping()
            Task { await MqvpnLiveActivityLifecycle.endImmediately() }
        }
        // The immediate display is an acknowledged user intent; all terminal
        // reconciliation remains exclusively driven by NEVPNStatusDidChange.
        manager.connection.stopVPNTunnel()
    }

    /// Persists server + reorder + hybrid settings via the atomic snapshot -> merge ->
    /// mutate -> commit -> refresh sequence in performAtomicSave, the exact
    /// function the host tests fault-inject — so the tested logic IS the
    /// production logic.
    func saveSettings(server: ServerSettings, reorder: ReorderSettings,
                      hybrid: HybridSettings, scheduler: SchedulerSettings,
                      operatingMode: OperatingMode,
                      relay: RelaySettings?) async throws {
        if let e = saveGuard(isSaving: isSaving, isEditable: isEditable, hasManager: manager != nil) {
            throw e
        }
        guard let manager,
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw SaveError.notReady
        }
        isSaving = true
        defer { isSaving = false }
        var merged = server.toProviderConfiguration()
        for (k, v) in reorder.toProviderConfiguration() { merged[k] = v }
        for (k, v) in hybrid.toProviderConfiguration() { merged[k] = v }
        for (k, v) in scheduler.toProviderConfiguration() { merged[k] = v }
        for (k, v) in operatingMode.toProviderConfiguration() { merged[k] = v }
        if let relay, relay.isValid {
            for (k, v) in relay.toProviderConfiguration() { merged[k] = v }
        }
        try await performAtomicSave(NEConfigStore(manager: manager, proto: proto), merge: merged)
        serverSettings = server
        reorderSettings = reorder
        hybridSettings = hybrid
        // NEConfigStore holds the pre-refresh proto; loadFromPreferences can
        // replace manager.protocolConfiguration. Publish the manager's current
        // value, not the caller object. Missing proto → Max Throughput default.
        let savedProto = manager.protocolConfiguration as? NETunnelProviderProtocol
        schedulerSettings = SchedulerSettings(providerConfiguration: savedProto?.providerConfiguration)
        self.operatingMode = operatingMode
        relaySettings = relay?.isValid == true ? relay : nil
        configError = nil   // only on success
    }

    // MARK: - Snapshot polling

    /// Called by the scene on activation changes; gates polling together with
    /// the connection state.
    func setScenePhaseActive(_ active: Bool) {
        scenePhaseActive = active
        reconcilePolling()
    }

    /// Single decision point: poll only while foregrounded AND the tunnel is
    /// up. When the tunnel is down, drop the snapshot so the UI shows no data.
    /// Keepalive follows two inputs — tunnel up, and the user's opt-in — and
    /// re-evaluates on either changing. The defaults observer is armed on
    /// first use so a toggle flipped while connected takes effect at once.
    private func reconcileKeepAlive() {
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reconcileKeepAlive() }
            }
        }
        if Self.isUp(status) && keepAliveEnabled {
            keepAlive.begin()
        } else {
            keepAlive.end()
        }
        reconcilePolling()
    }

    private func reconcilePolling() {
        let up = (status == .connected || status == .reasserting)
        if (scenePhaseActive || keepAlive.isActive) && up {
            startPolling()
        } else {
            stopPolling()
            if !up { clearSnapshot() }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        poll()   // immediate first sample
        let t = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func clearSnapshot() {
        snapshot = nil
        pathRates = [:]
        prevSnapshot = nil
        lastIngestedSeq = 0
        lastIngestedTimestamp = 0
        eventLog.resetBaseline()
        liveActivitySampler = LiveActivityRateSampler()
        lastPublished = nil
        lastPublishedAt = nil
    }

    private func poll() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let epoch = sessionEpoch
        do {
            // Payload is ignored by the provider (command-agnostic); an empty
            // request means "give me the latest snapshot".
            try session.sendProviderMessage(Data()) { [weak self] resp in
                Task { @MainActor in
                    guard let self else { return }
                    // Pre-decode session check: a stale/late response must never
                    // clear the live snapshot of a newer session.
                    guard self.sessionEpoch == epoch, Self.isUp(self.status) else { return }
                    guard let resp, let snap = try? ProviderMessage.decode(resp) else { return }
                    guard IngestGate.accept(capturedEpoch: epoch, currentEpoch: self.sessionEpoch,
                                            isUp: Self.isUp(self.status), snapSeq: snap.seq,
                                            snapTimestamp: snap.timestamp,
                                            lastSeq: self.lastIngestedSeq,
                                            lastTimestamp: self.lastIngestedTimestamp) else { return }
                    if snap.seq == 0 { self.lastIngestedTimestamp = snap.timestamp }
                    else { self.lastIngestedSeq = snap.seq }
                    self.ingest(snap)
                }
            }
        } catch { /* transient; keep the current snapshot */ }
    }

    /// Total bytes carried by each physical interface, summed over the
    /// outer flows sharing it. Each flow keeps its own counters in the C
    /// client (`p->bytes_tx` is incremented per path entry), so a single
    /// flow speaks only for its own share of the link.
    static func bytesByInterface(_ paths: [PathSnapshot]) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for p in paths {
            out[p.name, default: 0] &+= p.txBytes &+ p.rxBytes
        }
        return out
    }

    /// Update dashboard rates and publish the accepted VPN or relay snapshot.
    private func ingest(_ snap: TunnelSnapshot) {
        if snap.operatingMode == .macRelay {
            pathRates = [:]
        } else if let prev = prevSnapshot {
            let dt = snap.timestamp - prev.timestamp
            if dt > 0.05 {
                // Sum every outer flow on an interface before differencing.
                // Keying a dictionary by interface name kept only the last
                // flow of the four, so the rate shown was one flow's, and
                // the row under-reported the link by roughly that factor.
                let now = Self.bytesByInterface(snap.paths)
                let before = Self.bytesByInterface(prev.paths)
                var rates: [String: Double] = [:]
                for (name, current) in now {
                    guard let old = before[name] else { continue }
                    // Double avoids UInt64 wrap; a counter reset (path re-add)
                    // yields a negative delta which we clamp to 0.
                    let delta = Double(current) - Double(old)
                    rates[name] = delta > 0 ? delta * 8.0 / dt / 1_000_000.0 : 0.0
                }
                pathRates = rates
            }
        }
        prevSnapshot = snap
        snapshot = snap
        eventLog.ingest(snap)
        publishLiveActivity(snap)
    }

    /// Throttle visible updates independently of the snapshot polling cadence.
    private func publishLiveActivity(_ snap: TunnelSnapshot) {
        guard liveActivityStarted else { return }
        if #available(iOS 16.2, *) {
            let published = LiveActivityContentFactory.make(snapshot: snap,
                                                            sampler: &liveActivitySampler)
            guard LiveActivityPublishGate.shouldPublish(candidate: published.state,
                                                        lastPublished: lastPublished,
                                                        lastPublishedAt: lastPublishedAt) else {
                return
            }
            lastPublished = published.state
            lastPublishedAt = published.state.sampledAt
            let mode = operatingMode
            Task {
                _ = await MqvpnLiveActivityLifecycle.updateExisting(
                    mode: mode, state: published.state, staleDate: published.staleDate)
            }
        }
    }

    private static func describe(_ s: NEVPNStatus) -> String {
        switch s {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    var dashboardStatusText: String {
        guard operatingMode == .macRelay else { return statusText }
        return RelayDashboard.statusLabel(tunnelStatus: Self.tunnelStatus(status),
                                          snapshot: snapshot)
    }

    private static func tunnelStatus(_ s: NEVPNStatus) -> TunnelStatus {
        switch s {
        case .invalid: return .invalid
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .reasserting: return .reasserting
        case .disconnecting: return .disconnecting
        @unknown default: return .invalid
        }
    }
}

/// Binds performAtomicSave's ReorderConfigStore to the live NE objects.
final class NEConfigStore: ReorderConfigStore {
    private let manager: NETunnelProviderManager
    private let proto: NETunnelProviderProtocol
    init(manager: NETunnelProviderManager, proto: NETunnelProviderProtocol) {
        self.manager = manager; self.proto = proto
    }
    var providerConfiguration: [String: Any]? {
        get { proto.providerConfiguration }
        set { proto.providerConfiguration = newValue }
    }
    func commit() async throws { try await manager.saveToPreferences() }
    func refresh() async throws { try await manager.loadFromPreferences() }
}

/// Opt-in silent-audio keepalive for app-side Live Activity updates.
/// This is independent of the packet tunnel and does not guarantee execution.
@MainActor
final class TunnelKeepAlive {
    private static let log = Logger(subsystem: "mqvpn.poc", category: "keepalive")
    private var player: AVAudioPlayer?
    private var interruptionObserver: (any NSObjectProtocol)?

    var isActive: Bool { player != nil }

    func begin() {
        guard player == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
            let silent = try AVAudioPlayer(data: Self.silentWAV())
            silent.numberOfLoops = -1
            silent.volume = 0
            silent.play()
            player = silent
            observeInterruptions()
            Self.log.notice("tunnel keepalive: audio session active")
        } catch {
            player = nil
            Self.log.error("tunnel keepalive failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A phone call or Siri ends the audio session; without resuming, iOS
    /// suspends the app seconds later and the island goes stale again.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
                Self.log.notice("tunnel keepalive: resumed after interruption")
            }
        }
    }

    func end() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation]
        )
        Self.log.notice("tunnel keepalive: released")
    }

    /// One second of 16-bit mono silence at 8 kHz, built in memory so the
    /// bundle carries no asset.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let samples = Int(sampleRate)
        let dataSize = UInt32(samples * 2)
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        wav.append(contentsOf: Array("WAVE".utf8)); wav.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(sampleRate)
        append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(dataSize)
        wav.append(Data(count: samples * 2))
        return wav
    }
}
