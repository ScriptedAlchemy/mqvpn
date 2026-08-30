// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import NetworkExtension
import os

private let providerLog = Logger(subsystem: "mqvpn.poc", category: "provider")

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var engine: MqvpnEngine?
    private var relayEngine: RelayEngine?
    private var binder: PathBinder?
    private var metrics: GateMetrics?
    // Optional (not `!`): handleAppMessage can be delivered independently of
    // the start/stop lifecycle, so the reader must tolerate a nil cache.
    private var snapshot: SnapshotCache?
    private var snapshotReader: (() -> TunnelSnapshot?)?
    private var liveActivityReporter: MqvpnLiveActivityReporting?
    private var defaultPathObservation: NSKeyValueObservation?

    override func startTunnel(options: [String: NSObject]?) async throws {
        let providerConfig = (self.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration
        guard let operatingMode = OperatingMode(providerConfiguration: providerConfig) else {
            throw NSError(domain: "mqvpn.poc", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "operating mode invalid"])
        }
        guard let server = ServerSettings(providerConfiguration: providerConfig) else {
            throw NSError(domain: "mqvpn.poc", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "server not configured"])
        }
        let reorder = ReorderSettings(providerConfiguration: providerConfig) ?? .disabled
        let hybrid = HybridSettings(providerConfiguration: providerConfig) ?? .disabled
        guard let resolved = await Task.detached(priority: .userInitiated, operation: {
            resolveServer(server.host, server.port)
        }).value, let resolvedIP = resolved.ipString else {
            throw NSError(domain: "mqvpn.poc", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "server unresolved: \(server.host)"])
        }
        if operatingMode == .macRelay {
            guard let relaySettings = RelaySettings(providerConfiguration: providerConfig) else {
                throw NSError(domain: "mqvpn.poc", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "relay settings invalid"])
            }
            let relay = RelayEngine(settings: relaySettings, serverAddress: resolved)
            relayEngine = relay
            snapshotReader = { [weak relay] in relay?.readSnapshot() }
            let networkSettings = Self.makeRelaySettings()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                setTunnelNetworkSettings(networkSettings) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            relay.start()
            if #available(iOS 16.2, *) {
                let reporter = MqvpnLiveActivityReporter(mode: .macRelay) { [weak relay] in
                    relay?.readSnapshot()
                }
                liveActivityReporter = reporter
                reporter.start()
            }
            return
        }
        let engine = MqvpnEngine()
        let binder = PathBinder(engine: engine)
        let metrics = GateMetrics(engine: engine, binder: binder)
        let snapshot = SnapshotCache(engine: engine)
        self.engine = engine
        self.binder = binder
        self.metrics = metrics
        self.snapshot = snapshot
        self.snapshotReader = { [weak snapshot] in snapshot?.read() }

        engine.onTunOutput = { [weak self] data in
            // NEPacketTunnelFlow requires a protocol family per packet; the
            // library hands us raw IP bytes, so derive it from the version
            // nibble.
            let proto: NSNumber = (data.first ?? 0) >> 4 == 6 ? NSNumber(value: AF_INET6)
                                                              : NSNumber(value: AF_INET)
            self?.packetFlow.writePackets([data], withProtocols: [proto])
        }
        return try await withCheckedThrowingContinuation { cont in
            // All latches below are tick-thread confined. Each core reconnect
            // emits a new tunnel_config_ready and requires tunActive again.
            var startResolved = false
            var terminal = false
            var settingsInFlight = false
            var pendingConfig: mqvpn_tunnel_info_t?

            func applyConfig(_ info: mqvpn_tunnel_info_t) {
                guard !terminal else { return }
                if settingsInFlight {
                    pendingConfig = info
                    return
                }
                settingsInFlight = true
                let settings = Self.makeSettings(from: info, server: resolvedIP)
                self.setTunnelNetworkSettings(settings) { err in
                    engine.perform {
                        settingsInFlight = false
                        guard !terminal else { return }
                        if let err {
                            terminal = true
                            if !startResolved {
                                startResolved = true
                                cont.resume(throwing: err)
                            } else {
                                self.reasserting = false
                                self.cancelTunnelWithError(err)
                            }
                            return
                        }
                        engine.tunActive()
                        self.reasserting = false
                        if !startResolved {
                            startResolved = true
                            self.readLoop()
                            metrics.start()
                            snapshot.start()
                            if #available(iOS 16.2, *) {
                                let reporter = MqvpnLiveActivityReporter(mode: .vpn) { [weak snapshot] in
                                    snapshot?.read()
                                }
                                self.liveActivityReporter = reporter
                                reporter.start()
                            }
                            cont.resume()
                        }
                        if let pending = pendingConfig {
                            pendingConfig = nil
                            applyConfig(pending)
                        }
                    }
                }
            }

            engine.onTunnelConfig = { info in applyConfig(info) }
            engine.onTunnelClosed = { [weak self] reason in
                guard let self else { return }
                let err = NSError(domain: "mqvpn.poc", code: Int(reason),
                                  userInfo: [NSLocalizedDescriptionKey: "tunnel closed"])
                switch ProviderReconnectPolicy.closed(
                    startResolved: startResolved,
                    permanent: ProviderCloseReason.isPermanent(reason)) {
                case .awaitReconnect:
                    self.reasserting = true
                    providerLog.notice("mqvpn reconnecting after transient close reason=\(reason)")
                case .failStart:
                    terminal = true
                    startResolved = true
                    cont.resume(throwing: err)
                case .cancelTunnel:
                    terminal = true
                    self.reasserting = false
                    self.cancelTunnelWithError(err)
                }
            }
            engine.start(server: server, reorder: reorder, hybrid: hybrid,
                         scheduler: SchedulerSettings(providerConfiguration: providerConfig),
                         serverAddr: resolved)
            binder.start()
            // Redundant trigger for path lifecycle: NWPathMonitor updates
            // have been observed to arrive minutes late inside the provider
            // (device measurement: a WiFi-off unsatisfied delayed ~110 s,
            // blacking out downlink because no orderly remove_path ran).
            // NEProvider.defaultPath is an independent KVO channel that
            // tracks the physical path; any change re-runs the binder's
            // reconciliation. Only the TRIGGER is independent — the value
            // is not read (it has no per-interface-type availability), and
            // the binder probes fresh per-type state itself rather than
            // trusting any possibly-stale monitor snapshot.
            defaultPathObservation = observe(\.defaultPath) { [weak self] _, _ in
                guard self != nil else { return }
                engine.perform { binder.reconcile() }
            }
        }
    }

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, let engine = self.engine else { return }
            engine.perform {
                for p in packets { engine.feedTunPacket(p) }
            }
            self.readLoop()   // MUST re-arm: readPackets delivers once per call
        }
    }

    static func makeSettings(from info: mqvpn_tunnel_info_t,
                             server: String) -> NEPacketTunnelNetworkSettings {
        func ip4(_ b: (UInt8, UInt8, UInt8, UInt8)) -> String {
            "\(b.0).\(b.1).\(b.2).\(b.3)"
        }
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: server)
        let v4 = NEIPv4Settings(
            addresses: [ip4(info.assigned_ip)],
            subnetMasks: [Self.prefixToMask(info.assigned_prefix)])
        v4.includedRoutes = [NEIPv4Route.default()]
        s.ipv4Settings = v4
        s.mtu = NSNumber(value: info.mtu)
        // The tunnel protocol does not carry DNS servers; like the Android
        // client (which takes DNS from app-side config), the platform layer
        // must supply resolvers. Without dnsSettings the phone keeps sending
        // queries to its WiFi LAN resolver, which the full-tunnel default
        // route captures and the server NATs to an unroutable private
        // address — name resolution dies and every app looks offline.
        s.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        // IPv6 (info.has_v6 / assigned_ip6 / assigned_prefix6) is out of PoC
        // scope: the PoC server config assigns IPv4 only.
        return s
    }

    static func prefixToMask(_ prefix: UInt8) -> String {
        let m: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        return "\((m >> 24) & 255).\((m >> 16) & 255).\((m >> 8) & 255).\(m & 255)"
    }

    /// Command-agnostic snapshot request (future commands are YAGNI): any
    /// message returns the latest cached snapshot. Runs on an arbitrary NE
    /// thread, so it MUST NOT touch the engine (its accessors are
    /// tick-thread-confined) — it only reads the lock-guarded cache and
    /// serializes. A missing cache or encode failure yields nil, which the
    /// app renders as "no data".
    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        guard let snap = snapshotReader?(),
              let data = try? ProviderMessage.encode(snap) else {
            completionHandler?(nil)
            return
        }
        completionHandler?(data)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        // The extension process dies right after this returns; the orderly
        // teardown is a BEST-EFFORT clean close for the server (the close
        // frame races the async fd close on monitorQueue — losing the race
        // just means the server falls back to its idle timeout) and gives
        // repeated gate runs a zero state start.
        providerLog.notice("STOP_BEGIN")
        let reporter = liveActivityReporter
        // ActivityKit is ancillary UI: it must never delay or precede the
        // packet/relay transport teardown, so its cleanup is awaited second.
        await stopTransport()
        await reporter?.stop()
        liveActivityReporter = nil
    }

    /// Detaches engine callbacks and shuts the transport down, but leaves the
    /// provider's strong refs (engine/binder/snapshot/snapshotReader) in
    /// place: handleAppMessage reads snapshotReader from an arbitrary NE
    /// thread, so clearing fields here would be an unsynchronized cross-thread
    /// mutation for no benefit — the extension process exits right after
    /// stopTunnel returns.
    private func stopTransport() async {
        defaultPathObservation?.invalidate()
        defaultPathObservation = nil
        if let relayEngine {
            relayEngine.stop()
            providerLog.notice("STOP_FINISHED relay=true")
            return
        }
        await withCheckedContinuation { cont in
            let engine = self.engine
            let binder = self.binder
            // The engine retains these callbacks and applyConfig captures the
            // engine and the provider, so leaving them attached leaks the
            // whole graph after stop. Detach the closed-callback first:
            // disconnect fires tunnel_closed synchronously, and re-entering
            // cancelTunnelWithError during a system-initiated stop is
            // unwanted.
            let detachCallbacks = {
                engine?.onTunnelClosed = nil
                engine?.onTunnelConfig = nil
                engine?.onTunOutput = nil
            }
            let dispatched = engine?.perform {
                providerLog.notice("STOP_DISPATCHED accepted=true")
                detachCallbacks()
                // PathBinder owns asynchronous DispatchSource cancellation.
                // Keep the mqvpn engine alive until every fd is closed and
                // reported back to it, so shutdown runs in stop's completion.
                let done = {
                    engine?.shutdown()
                    providerLog.notice("STOP_FINISHED accepted=true")
                    cont.resume()
                }
                binder?.stop(completion: done) ?? done()
            } ?? false
            if !dispatched {
                // A completed/absent tick thread cannot safely run the
                // tick-confined binder teardown, and with that thread gone the
                // callbacks can never fire again — detaching off-thread here
                // is race-free and still breaks the retain cycle.
                providerLog.notice("STOP_DISPATCHED accepted=false")
                detachCallbacks()
                providerLog.notice("STOP_FINISHED accepted=false")
                cont.resume()
            }
        }
    }

    /// Packet-tunnel lifetime only. Routes and DNS come from
    /// `RelayNetworkPlan.nonRouting` — never the public server address.
    static func makeRelaySettings() -> NEPacketTunnelNetworkSettings {
        let plan = RelayNetworkPlan.nonRouting
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: plan.tunnelRemoteAddress)
        let ipv4 = NEIPv4Settings(addresses: [plan.assignedAddress],
                                  subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = plan.includedIPv4Routes.map {
            NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255")
        }
        settings.ipv4Settings = ipv4
        settings.dnsSettings = plan.dnsServers.isEmpty
            ? nil : NEDNSSettings(servers: plan.dnsServers)
        return settings
    }
}
