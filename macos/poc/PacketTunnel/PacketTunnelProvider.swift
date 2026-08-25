// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Darwin
import Foundation
import NetworkExtension
import SystemConfiguration
import os

private let macProviderLog = Logger(subsystem: "mqvpn.mac", category: "provider")

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
    private var relayBinder: MacRelayBinder?
    private var snapshotCache: SnapshotCache?
    private var snapshotReader: (() -> MacProviderSnapshot?)?
    private var lifecycle = MacProviderLifecycle()
    private var startupTimer: DispatchSourceTimer?
    private var recoveryTimer: DispatchSourceTimer?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var settingsApplyInFlight = false
    private var settingsApplyWaiters: [() -> Void] = []
    private var startResolved = false
    private var stopping = false
    private var transportStopTask: Task<Void, Never>?
    private var serverAddress: ResolvedServerAddress?
    private var relayAddress: ResolvedServerAddress?
    private var startCancelled = false
    private var lastPathCount = 0

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
        let resolvedRelay: ResolvedServerAddress?
        if let relaySettings {
            guard let address = await Task.detached(priority: .userInitiated, operation: {
                resolveServer(relaySettings.host, relaySettings.port)
            }).value, address.ipString != nil else {
                throw Self.error(12, "iPhone relay unresolved: \(relaySettings.host)")
            }
            resolvedRelay = address
        } else {
            resolvedRelay = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lifecycleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: Self.error(13, "provider unavailable"))
                    return
                }
                guard self.startContinuation == nil, !self.stopping else {
                    continuation.resume(throwing: Self.error(14, "tunnel lifecycle already active"))
                    return
                }
                self.startContinuation = continuation
                self.startResolved = false
                self.setStartCancelled(false)
                self.serverAddress = resolvedServer
                self.relayAddress = resolvedRelay
                _ = self.lifecycle.begin(nowMs: Self.nowMs())
                self.startRuntime(server: server, serverIPv4: serverIPv4,
                                  relaySettings: relaySettings, resolvedRelay: resolvedRelay)
            }
        }
    }

    private func startRuntime(server: ServerSettings, serverIPv4: String,
                              relaySettings: MacRelaySettings?,
                              resolvedRelay: ResolvedServerAddress?) {
        let engine = MqvpnEngine()
        let direct = PathBinder(engine: engine, interfaceTypes: [.wifi, .wiredEthernet])
        let snapshots = SnapshotCache(engine: engine)
        self.engine = engine
        self.directBinder = direct
        self.snapshotCache = snapshots
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
                     serverAddr: serverAddress!)

        if let relaySettings, let resolvedRelay, let key = relaySettings.decodedKey {
            guard let relayIPv4 = resolvedRelay.ipString,
                  let interface = Self.liveLANInterface(reaching: relayIPv4),
                  let relay = MacRelayBinder(engine: engine, relayEndpoint: resolvedRelay,
                                             serverPeer: serverAddress!, interfaceName: interface,
                                             relayKey: key)
            else {
                failStart(Self.error(15, "no live Wi-Fi or Ethernet interface reaches the iPhone relay"))
                return
            }
            relay.onSnapshot = { [weak snapshots] relaySnapshot in
                snapshots?.updateRelay(relaySnapshot)
            }
            self.relayBinder = relay
            relay.start()
        }

        direct.start()
        armStartupTimeout()
    }

    private func providerConfiguration() -> [String: Any]? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    }

    private func receivedTunnelConfiguration(_ info: mqvpn_tunnel_info_t, serverIPv4: String,
                                             activePathCount: Int) {
        guard !startResolved else { return }
        guard MacProviderStartupSafety.mayApplyNetworkSettings(activePathCount: activePathCount,
                                                               stopping: stopping) else {
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
                guard !self.stopping, !self.startResolved else {
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
                    self.completeStart()
                } else if action == .failStart {
                    self.failStart(error ?? Self.error(16, "failed to apply tunnel settings"))
                }
            }
        }
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
            guard MacProviderStartupSafety.mayActivatePacketFlow(activePathCount: activeCount,
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
        guard !startResolved, !stopping else { return }
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
        guard !stopping else { return }
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
        } else if !stopping {
            snapshotCache?.updateLifecycle(reasserting: false, error: error.localizedDescription)
            cancelTunnelWithError(error)
        }
    }

    private func failStart(_ error: Error) {
        guard !startResolved, !stopping else { return }
        startResolved = true
        stopping = true
        setStartCancelled(true)
        cancelStartupTimer()
        recoveryTimer?.cancel()
        recoveryTimer = nil
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
            guard let self, let engine = self.engine, !self.stopping else { return }
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
        stopping = true
        setStartCancelled(true)
        cancelStartupTimer()
        recoveryTimer?.cancel()
        recoveryTimer = nil
        reasserting = false
        _ = lifecycle.beginStop()
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
        let relay = relayBinder
        relayBinder = nil
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
        let plan = MacProviderNetworkPlan(assignedAddress: address,
                                          assignedPrefix: info.assigned_prefix,
                                          mtu: Int(info.mtu),
                                          serverIPv4: serverIPv4,
                                          relayIPv4: relayIPv4)
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

    /// Builds interface candidates from currently assigned IPv4 addresses and
    /// SystemConfiguration's physical interface type. The selector accepts
    /// only an on-link relay address and explicitly orders Wi-Fi before wired
    /// Ethernet; it never guesses a fixed `en*` device.
    private static func liveLANInterface(reaching relayIPv4: String) -> String? {
        let kinds = Dictionary(uniqueKeysWithValues: (SCNetworkInterfaceCopyAll() as NSArray)
            .compactMap { $0 as! SCNetworkInterface? }
            .compactMap { interface -> (String, MacLANInterfaceKind)? in
                guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
                else { return nil }
                if type == kSCNetworkInterfaceTypeIEEE80211 as String { return (name, .wifi) }
                if type == kSCNetworkInterfaceTypeEthernet as String { return (name, .wiredEthernet) }
                return nil
            })
        guard !kinds.isEmpty else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [MacLANInterfaceCandidate] = []
        for cursor in sequence(first: list, next: { $0.pointee.ifa_next }) {
            let entry = cursor.pointee
            guard let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
                  (entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  netmask.pointee.sa_family == sa_family_t(AF_INET),
                  let name = String(validatingUTF8: entry.ifa_name), let kind = kinds[name],
                  let ip = ipv4Text(address), let mask = ipv4Text(netmask)
            else { continue }
            candidates.append(MacLANInterfaceCandidate(name: name, kind: kind, address: ip, netmask: mask))
        }
        return MacLANInterfaceSelector.select(relayIPv4: relayIPv4, candidates: candidates)
    }

    private static func ipv4Text(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var storage = sockaddr_storage()
        memcpy(&storage, address, Int(address.pointee.sa_len))
        var sin = withUnsafeBytes(of: &storage) {
            $0.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
        }
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sin.sin_addr, &output, socklen_t(output.count)) != nil else { return nil }
        return String(cString: output)
    }

    private static func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "mqvpn.mac", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
