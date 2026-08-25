// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import NetworkExtension
import os

private let macProviderLog = Logger(subsystem: "mqvpn.mac", category: "provider")

private struct DiscoveredRelayAddress: @unchecked Sendable {
    let endpoint: MacRelayEndpoint
    let address: ResolvedServerAddress
}

/// The macOS packet-tunnel runtime.  Network Extension, rather than a root
/// helper, owns every route and DNS transaction.  This class only reaches
/// `setTunnelNetworkSettings` after libmqvpn has authenticated and supplied a
/// tunnel configuration.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let lifecycleQueue = DispatchQueue(label: "mqvpn.mac.provider.lifecycle")
    private let readerLock = NSLock()
    private let startGateLock = NSLock()

    private var engine: MqvpnEngine?
    private var directBinder: PathBinder?
    private var snapshotCache: SnapshotCache?
    private var snapshotReader: (() -> MacProviderSnapshot?)?
    private var lifecycle = MacProviderLifecycle()
    private var startupTimer: DispatchSourceTimer?
    private var recoveryTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var relayDiscoveryTimer: DispatchSourceTimer?
    private var relayDiscoveryInFlight = false
    private var relayTransitionInFlight = false
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var settingsApplyInFlight = false
    private var settingsApplyWaiters: [() -> Void] = []
    private var startResolved = false
    private var transportStopTask: Task<Void, Never>?
    private var serverAddress: ResolvedServerAddress?
    private var relayAddress: ResolvedServerAddress?
    private var relayEndpoint: MacRelayEndpoint?
    private var relaySettings: MacRelaySettings?
    private var currentTunnelInfo: mqvpn_tunnel_info_t?
    private var resolvedServerIPv4: String?
    private var lastPathCount = 0
    private var startCancelled = false
    private lazy var relaySession = MacRelayLANSession(
        queue: lifecycleQueue,
        pickInterface: { endpoint in
            let discovered = MacRelayEndpoint(host: endpoint, port: 1)
            if let scoped = MacRelayDiscovery.interfaceName(for: discovered) {
                return scoped
            }
            if MacRelayDiscovery.isIPv6(endpoint) {
                return MacLANInterfaceEnumerator.candidates()
                    .sorted { $0.kind.rawValue < $1.kind.rawValue }
                    .first?.name
            }
            return MacLANInterfaceEnumerator.onLinkInterface(reaching: endpoint)
        })

    override func startTunnel(options: [String: NSObject]?) async throws {
        let rawConfig = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration
        guard let server = ServerSettings(providerConfiguration: rawConfig) else {
            throw Self.error(10, "server not configured")
        }
        let relaySettings: MacRelaySettings?
        do {
            relaySettings = try MacRelaySettings.startConfiguration(from: rawConfig)
        } catch {
            throw error
        }
        guard let resolvedServer = await Task.detached(priority: .userInitiated, operation: {
            resolveServer(server.host, server.port)
        }).value, let serverIPv4 = resolvedServer.ipString else {
            throw Self.error(11, "server unresolved: \(server.host)")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lifecycleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: Self.error(13, "provider unavailable"))
                    return
                }
                guard self.startContinuation == nil, !self.lifecycle.isStopping else {
                    continuation.resume(throwing: Self.error(14, "tunnel lifecycle already active"))
                    return
                }
                self.startContinuation = continuation
                self.startResolved = false
                self.setStartCancelled(false)
                self.serverAddress = resolvedServer
                self.relayAddress = nil
                self.relayEndpoint = nil
                self.relaySettings = relaySettings
                _ = self.lifecycle.begin(nowMs: Self.nowMs())
                self.startRuntime(server: server, serverIPv4: serverIPv4,
                                  relaySettings: relaySettings)
            }
        }
    }

    private func startRuntime(server: ServerSettings, serverIPv4: String,
                              relaySettings: MacRelaySettings?) {
        let engine = MqvpnEngine()
        let direct = PathBinder(engine: engine, interfaceTypes: [.wifi, .wiredEthernet])
        let snapshots = SnapshotCache(engine: engine)
        self.engine = engine
        self.directBinder = direct
        self.snapshotCache = snapshots
        self.resolvedServerIPv4 = serverIPv4
        setSnapshotReader { [weak snapshots] in snapshots?.read() }

        engine.onTunOutput = { [weak self] packet in
            let proto: NSNumber = (packet.first ?? 0) >> 4 == 6
                ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET)
            self?.packetFlow.writePackets([packet], withProtocols: [proto])
        }
        engine.onTunnelConfig = { [weak self, weak engine] info in
            // `info` is C memory owned by the callback. Copy its value before
            // crossing to the provider lifecycle queue.
            let copy = info
            // Config-ready means the server authenticated, but it does not
            // pin a path. Capture the authoritative count on the same tick
            // thread as the callback so an already-dead session cannot start
            // applying a default route.
            let activeCount = engine?.activePathCount() ?? 0
            self?.lifecycleQueue.async {
                self?.receivedTunnelConfiguration(copy, serverIPv4: serverIPv4,
                                                  activePathCount: activeCount)
            }
        }
        engine.onTunnelClosed = { [weak self] reason in
            self?.lifecycleQueue.async { self?.tunnelClosed(reason) }
        }
        engine.onPathEvent = { [weak self, weak engine] _, _ in
            // The event and activePathCount accessor are both tick-thread
            // confined. Only the integer crosses to the NE lifecycle queue.
            let count = engine?.activePathCount() ?? 0
            self?.lifecycleQueue.async { self?.activePathCountChanged(count) }
        }

        // The engine must exist before either transport begins. Direct sockets
        // and the relay's authenticated HELLO/ACK both begin before any route
        // is installed.
        engine.start(server: server,
                     reorder: ReorderSettings(providerConfiguration: providerConfiguration()) ?? .disabled,
                     hybrid: HybridSettings(providerConfiguration: providerConfiguration()) ?? .disabled,
                     scheduler: SchedulerSettings(providerConfiguration: providerConfiguration()),
                     serverAddr: serverAddress!)

        direct.start()
        armStartupTimeout()
        if relaySettings != nil { armRelayDiscovery() }
    }

    /// Lifecycle-queue-only. A relay binder is created only for a live local
    /// interface on the same subnet as the resolved iPhone endpoint.
    private func makeRelayBinder(interfaceName: String) -> MacRelayBinder? {
        guard let settings = relaySettings, let key = settings.decodedKey,
              let engine, let serverAddress, let relayAddress else { return nil }
        let relay = MacRelayBinder(engine: engine, relayEndpoint: relayAddress,
                                   serverPeer: serverAddress, interfaceName: interfaceName,
                                   relayKey: key)
        relay?.onSnapshot = { [weak snapshotCache] relaySnapshot in
            snapshotCache?.updateRelay(relaySnapshot)
        }
        if relay != nil {
            macProviderLog.notice("relay bound interface=\(interfaceName, privacy: .public)")
        }
        return relay
    }

    private func armRelayDiscovery() {
        guard relaySettings != nil, relayDiscoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in self?.discoverRelay() }
        timer.resume()
        relayDiscoveryTimer = timer
    }

    private func cancelRelayDiscovery() {
        relayDiscoveryTimer?.cancel()
        relayDiscoveryTimer = nil
        relayTransitionInFlight = false
    }

    private func discoverRelay() {
        guard relaySettings != nil, !lifecycle.isStopping,
              !relayDiscoveryInFlight else { return }
        relayDiscoveryInFlight = true
        let lookup = Task.detached(priority: .utility) { () -> DiscoveredRelayAddress? in
            guard let endpoint = MacRelayBonjourResolver.resolve(timeout: 1.5),
                  let address = resolveRelayEndpoint(endpoint.host, endpoint.port),
                  let ip = address.ipString,
                  let chosen = MacRelayDiscovery.choose([
                      MacRelayEndpoint(host: ip, port: endpoint.port)
                  ])
            else { return nil }
            return DiscoveredRelayAddress(endpoint: chosen, address: address)
        }
        Task { [weak self] in
            let result = await lookup.value
            self?.lifecycleQueue.async { [weak self] in
                self?.relayDiscoveryCompleted(result)
            }
        }
    }

    private func relayDiscoveryCompleted(_ discovered: DiscoveredRelayAddress?) {
        relayDiscoveryInFlight = false
        guard !lifecycle.isStopping, !relayTransitionInFlight,
              let discovered else { return }
        switch MacRelayEndpointTransition.decide(current: relayEndpoint,
                                                  discovered: discovered.endpoint) {
        case .keep:
            return
        case .attach, .replace:
            prepareRelayRouteAndAttach(discovered)
        }
    }

    /// A late relay is additive: update Network Extension's exclusions first,
    /// then create the LAN socket. This keeps HELLO/ACK off the tunnel even
    /// when the iPhone appears after the default route is already installed.
    private func prepareRelayRouteAndAttach(_ discovered: DiscoveredRelayAddress) {
        guard !settingsApplyInFlight else { return }
        relayTransitionInFlight = true
        guard let info = currentTunnelInfo, let serverIPv4 = resolvedServerIPv4,
              let relayIP = discovered.address.ipString else {
            replaceRelayTransport(with: discovered)
            return
        }
        settingsApplyInFlight = true
        let settings = Self.makeSettings(from: info, serverIPv4: serverIPv4,
                                         relayIPv4: relayIP)
        setTunnelNetworkSettings(settings) { [weak self] error in
            self?.lifecycleQueue.async {
                guard let self else { return }
                self.settingsApplyInFlight = false
                let waiters = self.settingsApplyWaiters
                self.settingsApplyWaiters.removeAll()
                waiters.forEach { $0() }
                guard !self.lifecycle.isStopping else { return }
                guard error == nil else {
                    self.relayTransitionInFlight = false
                    self.snapshotCache?.updateLifecycle(
                        reasserting: self.reasserting,
                        error: "iPhone relay route update failed")
                    return
                }
                self.replaceRelayTransport(with: discovered)
            }
        }
    }

    private func replaceRelayTransport(with discovered: DiscoveredRelayAddress) {
        guard let relayIP = discovered.address.ipString else {
            relayTransitionInFlight = false
            return
        }
        relaySession.cancelMonitor()
        let old = relaySession.takeBinderForTeardown()
        let install = { [weak self] in
            guard let self, !self.lifecycle.isStopping else { return }
            self.relayAddress = discovered.address
            self.relayEndpoint = discovered.endpoint
            let installed = self.relaySession.start(
                relayIPv4: relayIP,
                makeBinder: { [weak self] name in
                    self?.makeRelayBinder(interfaceName: name)
                })
            self.relaySession.onUnavailable = { [weak self] in
                guard let self else { return }
                self.snapshotCache?.updateLifecycle(
                    reasserting: self.reasserting,
                    error: "iPhone relay interface unavailable")
            }
            self.relaySession.armMonitor(relayIPv4: relayIP) { [weak self] in
                self?.lifecycle.isStopping ?? true
            }
            if !installed {
                self.snapshotCache?.updateLifecycle(
                    reasserting: self.reasserting,
                    error: "waiting for a LAN interface to the iPhone relay")
            }
            self.relayTransitionInFlight = false
            macProviderLog.notice(
                "relay endpoint adopted host=\(discovered.endpoint.host, privacy: .public) port=\(discovered.endpoint.port)")
        }
        if let old {
            old.stop { [weak self] in self?.lifecycleQueue.async(execute: install) }
        } else {
            install()
        }
    }

    private func providerConfiguration() -> [String: Any]? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    }

    private func receivedTunnelConfiguration(_ info: mqvpn_tunnel_info_t, serverIPv4: String,
                                             activePathCount: Int) {
        currentTunnelInfo = info
        if startResolved {
            guard !lifecycle.isStopping,
                  lifecycle.tunnelConfigurationReady() == .applyReconnectSettings else { return }
            // Re-apply settings on the live NE session: the reconnected core
            // may have been assigned a different tunnel address.
            let settings = Self.makeSettings(from: info, serverIPv4: serverIPv4,
                                             relayIPv4: relayAddress?.ipString)
            setTunnelNetworkSettings(settings) { [weak self] error in
                self?.lifecycleQueue.async {
                    guard let self, !self.lifecycle.isStopping else { return }
                    if self.lifecycle.reconnectSettingsApplied(error: error != nil)
                        == .completeReconnect {
                        self.refreshRelayRouteAfterSettings { [weak self] in
                            self?.lifecycleQueue.async { self?.completeReconnect() }
                        }
                    }
                }
            }
            return
        }
        // Preserve the same tick-thread observation for the asynchronous
        // settings completion gate. Relying only on a separately delivered
        // path event leaves this at its initial zero when config-ready wins
        // that event race, incorrectly failing every otherwise healthy Start.
        lastPathCount = activePathCount
        guard MacProviderStartupSafety.hasSurvivingPath(activePathCount: activePathCount,
                                                        stopping: lifecycle.isStopping) else {
            failStart(Self.error(21, "mqvpn path disappeared before tunnel settings"))
            return
        }
        guard
              lifecycle.tunnelConfigurationReady() == .applyNetworkSettings else {
            return
        }
        let settings = Self.makeSettings(from: info, serverIPv4: serverIPv4,
                                         relayIPv4: relayAddress?.ipString)
        settingsApplyInFlight = true
        setTunnelNetworkSettings(settings) { [weak self] error in
            self?.lifecycleQueue.async {
                guard let self else { return }
                self.settingsApplyInFlight = false
                let waiters = self.settingsApplyWaiters
                self.settingsApplyWaiters.removeAll()
                waiters.forEach { $0() }
                guard !self.lifecycle.isStopping, !self.startResolved else {
                    // If an earlier bounded wait gave up, this completion may
                    // be the one that actually installed settings. Queue a
                    // final explicit clear so a late success cannot retain a
                    // default route after Start/Stop has terminated.
                    if error == nil {
                        Task { await self.clearTunnelNetworkSettings() }
                    }
                    return
                }
                let action = self.lifecycle.networkSettingsApplied(
                    error: error != nil, activePathCount: self.lastPathCount)
                if action == .completeStart {
                    self.refreshRelayRouteAfterSettings { [weak self] in
                        self?.lifecycleQueue.async { self?.completeStart() }
                    }
                } else if action == .failStart {
                    self.failStart(error ?? Self.error(16, "failed to apply tunnel settings"))
                }
            }
        }
    }

    private func refreshRelayRouteAfterSettings(completion: @escaping () -> Void) {
        guard relayAddress?.ipString != nil else {
            completion()
            return
        }
        relaySession.refreshConnectedRoute(completion: completion)
    }

    private func completeStart() {
        guard !startResolved else { return }
        guard let engine = engine else {
            failStart(Self.error(17, "mqvpn engine stopped during startup"))
            return
        }
        let queued = engine.perform { [weak self, weak engine] in
            guard let self, let engine else { return }
            // This is the second half of the no-blackhole gate: a path can
            // disappear while Network Extension applies settings. Do not
            // enable packet flow or resolve Start until a fresh tick-thread
            // read proves a surviving path.
            let activeCount = engine.activePathCount()
            guard MacProviderStartupSafety.hasSurvivingPath(activePathCount: activeCount,
                                                            stopping: self.isStartCancelled) else {
                self.lifecycleQueue.async {
                    self.failStart(Self.error(22, "mqvpn path disappeared while applying tunnel settings"))
                }
                return
            }
            engine.tunActive()
            self.snapshotCache?.start()
            self.lifecycleQueue.async { [weak self] in
                self?.finishSuccessfulStart(activePathCount: activeCount)
            }
        }
        guard queued else {
            failStart(Self.error(17, "mqvpn tick thread unavailable during startup"))
            return
        }
    }

    private func finishSuccessfulStart(activePathCount: Int) {
        guard !startResolved, !lifecycle.isStopping else { return }
        cancelStartupTimer()
        startResolved = true
        startContinuation?.resume()
        startContinuation = nil
        macProviderLog.notice("START_COMPLETE")
        readLoop()
        // A path event queued just before Start resolved was intentionally
        // ignored during preflight. Re-evaluate the captured count now so the
        // five-second fail-open policy still applies to that edge.
        activePathCountChanged(activePathCount)
    }

    private func armStartupTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now() + .milliseconds(Int(MacProviderLifecycle.startupTimeoutMs)))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.lifecycle.startupTimerFired(nowMs: Self.nowMs()) == .failStart
            else { return }
            self.failStart(Self.error(18, "mqvpn server did not authenticate within 10 seconds"))
        }
        timer.resume()
        startupTimer = timer
    }

    private func cancelStartupTimer() {
        startupTimer?.cancel()
        startupTimer = nil
    }

    private func activePathCountChanged(_ count: Int) {
        lastPathCount = count
        guard !lifecycle.isStopping else { return }
        switch lifecycle.activePathCountChanged(count, nowMs: Self.nowMs()) {
        case .failStart:
            failStart(Self.error(21, "all mqvpn paths lost before Start completed"))
        case let .beginRecovery(deadlineMs):
            reasserting = true
            snapshotCache?.updateLifecycle(reasserting: true, error: "all mqvpn paths lost; recovering")
            armRecoveryTimer(deadlineMs: deadlineMs)
        case .endRecovery:
            recoveryTimer?.cancel()
            recoveryTimer = nil
            reasserting = false
            snapshotCache?.updateLifecycle(reasserting: false, error: nil)
        default:
            break
        }
    }

    private func armRecoveryTimer(deadlineMs: UInt64) {
        recoveryTimer?.cancel()
        let remaining = max(0, Int64(deadlineMs) - Int64(Self.nowMs()))
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now() + .milliseconds(Int(remaining)))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.lifecycle.recoveryTimerFired(nowMs: Self.nowMs()) == .cancelTunnel
            else { return }
            self.reasserting = false
            self.snapshotCache?.updateLifecycle(reasserting: false, error: "all mqvpn paths lost")
            self.cancelTunnelWithError(Self.error(19, "all mqvpn paths lost for five seconds"))
        }
        timer.resume()
        recoveryTimer = timer
    }

    private func tunnelClosed(_ reason: Int32) {
        let error = Self.error(Int(reason), "mqvpn tunnel closed")
        if !startResolved {
            failStart(error)
            return
        }
        guard !lifecycle.isStopping else { return }
        switch lifecycle.tunnelClosed(
            permanent: MacProviderCloseReason.isPermanent(reason),
            nowMs: Self.nowMs()) {
        case let .beginReconnect(deadlineMs):
            // libmqvpn is already running its own backoff reconnect; hold the
            // profile up under reasserting until a fresh config-ready lands
            // or the bounded window expires. This is what lets an interface
            // returning (cable replug, Wi-Fi toggle) rejoin the same NE
            // session instead of tearing it down.
            recoveryTimer?.cancel()
            recoveryTimer = nil
            reasserting = true
            snapshotCache?.updateLifecycle(reasserting: true,
                                           error: "mqvpn session lost; reconnecting")
            macProviderLog.notice("mqvpn reconnecting after transient close reason=\(reason)")
            armReconnectTimer(deadlineMs: deadlineMs)
        case .cancelTunnel:
            reconnectTimer?.cancel()
            reconnectTimer = nil
            reasserting = false
            snapshotCache?.updateLifecycle(reasserting: false, error: error.localizedDescription)
            cancelTunnelWithError(error)
        default:
            break
        }
    }

    private func armReconnectTimer(deadlineMs: UInt64) {
        reconnectTimer?.cancel()
        let remaining = max(0, Int64(deadlineMs) - Int64(Self.nowMs()))
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now() + .milliseconds(Int(remaining)))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.lifecycle.reconnectTimerFired(nowMs: Self.nowMs()) == .cancelTunnel
            else { return }
            self.reasserting = false
            self.snapshotCache?.updateLifecycle(reasserting: false,
                                                error: "mqvpn reconnect window expired")
            self.cancelTunnelWithError(Self.error(23, "mqvpn session did not reconnect in time"))
        }
        timer.resume()
        reconnectTimer = timer
    }

    /// Reconnect epilogue: the core re-established its session and fresh
    /// tunnel settings are installed. Reopen TUN and leave reasserting.
    private func completeReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
        guard let engine else { return }
        _ = engine.perform { [weak self] in
            engine.tunActive()
            self?.lifecycleQueue.async {
                guard let self, !self.lifecycle.isStopping else { return }
                self.reasserting = false
                self.snapshotCache?.updateLifecycle(reasserting: false, error: nil)
                macProviderLog.notice("mqvpn session reconnected; tunnel resumed")
            }
        }
    }

    private func failStart(_ error: Error) {
        guard !startResolved, !lifecycle.isStopping else { return }
        startResolved = true
        _ = lifecycle.beginStop()
        setStartCancelled(true)
        cancelStartupTimer()
        recoveryTimer?.cancel()
        recoveryTimer = nil
        reconnectTimer?.cancel()
        reconnectTimer = nil
        cancelRelayDiscovery()
        relaySession.cancelMonitor()
        snapshotCache?.updateLifecycle(reasserting: false, error: error.localizedDescription)
        let continuation = startContinuation
        startContinuation = nil
        let stopTask = ensureTransportStopTask(clearNetworkSettingsFirst: true)
        Task {
            await stopTask.value
            continuation?.resume(throwing: error)
        }
    }

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, let engine = self.engine, !self.lifecycle.isStopping else { return }
            engine.perform {
                for packet in packets { engine.feedTunPacket(packet) }
            }
            self.readLoop()
        }
    }

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        let reader = currentSnapshotReader()
        guard let snapshot = reader?(), let data = try? snapshot.encoded() else {
            completionHandler?(nil)
            return
        }
        completionHandler?(data)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        let stop = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Task<Void, Never>, CheckedContinuation<Void, Error>?, Bool), Never>) in
            lifecycleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: (Task {}, nil, false))
                    return
                }
                let pendingStart: CheckedContinuation<Void, Error>?
                if self.startResolved {
                    pendingStart = nil
                } else {
                    // A system/user Stop is terminal for this Start. Mark it
                    // resolved before any late config/settings callback can
                    // install or retain routes, then resume the caller only
                    // after the one shared teardown task has finished.
                    self.startResolved = true
                    pendingStart = self.startContinuation
                    self.startContinuation = nil
                }
                let needsPreclear = pendingStart != nil
                continuation.resume(returning: (
                    self.ensureTransportStopTask(clearNetworkSettingsFirst: needsPreclear),
                    pendingStart, needsPreclear))
            }
        }
        await stop.0.value
        stop.1?.resume(throwing: CancellationError())
    }

    /// Lifecycle-queue-only shared teardown. Repeated Stop calls and a Start
    /// failure all await the same task, so none can report completion before
    /// Network Extension transport ownership is actually released.
    private func ensureTransportStopTask(clearNetworkSettingsFirst: Bool) -> Task<Void, Never> {
        if let transportStopTask { return transportStopTask }
        _ = lifecycle.beginStop()
        setStartCancelled(true)
        cancelStartupTimer()
        recoveryTimer?.cancel()
        recoveryTimer = nil
        reconnectTimer?.cancel()
        reconnectTimer = nil
        cancelRelayDiscovery()
        relaySession.cancelMonitor()
        reasserting = false
        let task = Task { [weak self] in
            guard let self else { return }
            if clearNetworkSettingsFirst {
                await self.waitForSettingsApplication()
                await self.clearTunnelNetworkSettings()
            }
            await self.stopTransport()
        }
        transportStopTask = task
        return task
    }

    /// The only teardown path. It waits for the relay's socket/key and logical
    /// callback path to be gone before direct sockets, snapshot timer, and
    /// core shutdown. That order prevents a late logical callback from using a
    /// closed/reused UDP fd.
    private func stopTransport() async {
        relaySession.cancelMonitor()
        let relay = relaySession.takeBinderForTeardown()
        if let relay {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                relay.stop { continuation.resume() }
            }
        }
        let engine = engine
        let direct = directBinder
        let snapshots = snapshotCache
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let engine else { continuation.resume(); return }
            let queued = engine.perform { [weak self] in
                engine.onTunnelClosed = nil
                engine.onPathEvent = nil
                engine.onTunOutput = nil
                direct?.stop {
                    // PathBinder's completion proves every Dispatch source
                    // closed its fd and reported fdClosed on this tick thread.
                    // Only then may core/snapshot destruction run.
                    snapshots?.stop()
                    engine.shutdown()
                    self?.setSnapshotReader(nil)
                    continuation.resume()
                }
            }
            if !queued { continuation.resume() }
        }
        self.engine = nil
        self.directBinder = nil
        self.snapshotCache = nil
        self.serverAddress = nil
        self.relayAddress = nil
        self.relayEndpoint = nil
        self.relaySettings = nil
        self.currentTunnelInfo = nil
        self.resolvedServerIPv4 = nil
        setSnapshotReader(nil)
        macProviderLog.notice("STOP_COMPLETE")
    }

    /// Waits for an in-flight `setTunnelNetworkSettings` completion without
    /// allowing a hung platform callback to strand a Stop/Start caller. A
    /// late success is still harmless: `stopping` causes its callback to skip
    /// activation, and the explicit clearing call below removes settings.
    private func waitForSettingsApplication() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lifecycleQueue.async { [weak self] in
                guard let self, self.settingsApplyInFlight else {
                    continuation.resume()
                    return
                }
                var resumed = false
                let resumeOnce = {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
                self.settingsApplyWaiters.append(resumeOnce)
                self.lifecycleQueue.asyncAfter(deadline: .now() + .seconds(2)) {
                    resumeOnce()
                }
            }
        }
    }

    private func clearTunnelNetworkSettings() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            setTunnelNetworkSettings(nil) { _ in continuation.resume() }
        }
    }

    private func setSnapshotReader(_ reader: (() -> MacProviderSnapshot?)?) {
        readerLock.lock()
        snapshotReader = reader
        readerLock.unlock()
    }

    private func setStartCancelled(_ cancelled: Bool) {
        startGateLock.lock()
        startCancelled = cancelled
        startGateLock.unlock()
    }

    private var isStartCancelled: Bool {
        startGateLock.lock()
        defer { startGateLock.unlock() }
        return startCancelled
    }

    private func currentSnapshotReader() -> (() -> MacProviderSnapshot?)? {
        readerLock.lock()
        defer { readerLock.unlock() }
        return snapshotReader
    }

    static func makeSettings(from info: mqvpn_tunnel_info_t,
                             serverIPv4: String,
                             relayIPv4: String?) -> NEPacketTunnelNetworkSettings {
        let address = "\(info.assigned_ip.0).\(info.assigned_ip.1).\(info.assigned_ip.2).\(info.assigned_ip.3)"
        let relayPeer = relayIPv4
        let relayIPv4 = relayPeer.flatMap {
            MacRelayDiscovery.isIPv4($0) ? $0 : nil
        }
        let relayLAN = relayIPv4.flatMap {
            MacLANInterfaceSelector.onLinkRoute(relayIPv4: $0,
                                                candidates: MacLANInterfaceEnumerator.candidates())
        }
        let plan = MacProviderNetworkPlan(assignedAddress: address,
                                          assignedPrefix: info.assigned_prefix,
                                          mtu: Int(info.mtu),
                                          serverIPv4: serverIPv4,
                                          relayIPv4: relayIPv4,
                                          relayLAN: relayLAN)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverIPv4)
        let ipv4 = NEIPv4Settings(addresses: [plan.assignedAddress], subnetMasks: [plan.subnetMask])
        ipv4.includedRoutes = plan.includedRoutes.map {
            NEIPv4Route(destinationAddress: $0.address, subnetMask: MacProviderNetworkPlan.prefixToMask($0.prefix))
        }
        ipv4.excludedRoutes = plan.excludedRoutes.map {
            NEIPv4Route(destinationAddress: $0.address, subnetMask: MacProviderNetworkPlan.prefixToMask($0.prefix))
        }
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: plan.mtu)
        settings.dnsSettings = NEDNSSettings(servers: plan.dnsServers)
        return settings
    }

    private static func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "mqvpn.mac", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
