// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Darwin
import Foundation
import os.log

private let macRelayLog = Logger(subsystem: "mqvpn.mac", category: "relay")

/// Owns the Mac-to-iPhone LAN relay socket. It deliberately has no routing,
/// DNS, firewall, or privilege logic: the packet-tunnel provider owns that
/// lifecycle in the next layer. The callback path is added only after the
/// iPhone proves possession of the independent relay key with HELLO_ACK.
final class MacRelayBinder {
    private let engine: MqvpnEngine
    private let relayEndpoint: ResolvedServerAddress
    private let serverPeer: ResolvedServerAddress
    private let interfaceName: String
    private let queue = DispatchQueue(label: "mqvpn.mac.relay")
    private let lifecycleLock = NSLock()
    private var state: MacRelayRuntimeState
    private var timer: DispatchSourceTimer?
    private var stopped = true
    private var teardownStarted = false
    private var teardownComplete = false
    private var stopWaiters: [() -> Void] = []
    private var acceptsCoreSends = false
    /// Network.framework transport for the LAN hop; it owns the datagrams and
    /// every source-address/rebind decision. `resolveRelayEndpoint` only ever
    /// produces IPv4/IPv6 sockaddrs, so an NWEndpoint always exists — there
    /// is deliberately no raw-socket fallback.
    private var nwTransport: MacRelayNWTransport?

    /// Called on the binder's serial queue. Consumers should copy the value;
    /// snapshots contain counters/errors, never the relay key or payloads.
    var onSnapshot: ((MacRelayRuntimeSnapshot) -> Void)?

    /// Returns nil rather than opening a socket when the configured relay is
    /// one of this Mac's own addresses. That avoids a self-loop and makes a
    /// mistaken "relay IP = Mac IP" configuration fail closed before VPN
    /// settings can be applied.
    init?(engine: MqvpnEngine, relayEndpoint: ResolvedServerAddress,
          serverPeer: ResolvedServerAddress, interfaceName: String,
          relayKey: Data, localIPv4Addresses: [String] = MacRelayBinder.localIPv4Addresses()) {
        guard relayKey.count == Int(MQVPN_RELAY_KEY_SIZE),
              let endpoint = relayEndpoint.ipString,
              serverPeer.ipString != nil,
              !MacRelayEndpointSafety.isLocalEndpoint(endpoint,
                                                       localIPv4Addresses: localIPv4Addresses),
              !interfaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.engine = engine
        self.relayEndpoint = relayEndpoint
        self.serverPeer = serverPeer
        self.interfaceName = interfaceName
        self.state = MacRelayRuntimeState(key: relayKey)
    }

    /// Refresh the connected UDP route after Network Extension installs the
    /// default tunnel. Do not close the socket: a new source port would no
    /// longer match the iPhone's authenticated peer identity.
    func refreshConnectedRoute(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            defer { completion() }
            guard let self else { return }
            if self.refreshConnectedRouteLocked() {
                macRelayLog.notice("relay connect refreshed after tunnel routes")
                if self.state.shouldHelloAfterRouteRefresh() {
                    _ = self.sendFrame(type: MQVPN_RELAY_HELLO, payload: Data(),
                                       nowMs: self.nowMs())
                }
            } else if self.nwTransport != nil {
                macRelayLog.error("relay transport rebind after tunnel routes failed")
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.stopped, !self.teardownStarted else { return }
            self.stopped = false
            self.setCoreSendsEnabled(true)
            // Installed here rather than in init so construction has no
            // cross-object side effects and the hook's lifetime is symmetric
            // with clearEngineRelayHooks in stop(). The callback is
            // synchronous on mqvpn's tick thread; transport ownership stays
            // on `queue`, so it uses a bounded serial hop.
            self.engine.onLogicalPathSend = { [weak self] path, packet in
                self?.sendFromCore(path: path, packet: packet) ?? -Int(ENODEV)
            }
            self.startTimer()
            guard self.openTransport() else {
                self.recordSocketFailure("open relay transport failed")
                return
            }
            self.startFreshSession()
            self.publishSnapshot()
        }
    }

    /// Idempotent and transport-first. Completion runs on a different queue
    /// only after the LAN source/socket and key state are gone *and* the
    /// tick thread has executed both path removal and callback clearing.
    func stop(completion: @escaping () -> Void = {}) {
        // This must happen before queueing the teardown. A tick-thread callback
        // that races Stop therefore returns immediately instead of blocking the
        // binder queue while it waits for its own tick-thread cleanup barrier.
        setCoreSendsEnabled(false)
        queue.async { [weak self] in
            guard let self else { Self.finish(completion); return }
            if self.teardownComplete {
                Self.finish(completion)
                return
            }
            self.stopWaiters.append(completion)
            guard !self.teardownStarted else { return }
            self.teardownStarted = true
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            let handle = self.state.detachLogicalPath()
            self.closeTransport()
            self.state.stop()
            self.publishSnapshot()
            self.clearEngineRelayHooks(pathHandle: handle) { [weak self] in
                self?.queue.async { self?.finishStopWaiters() }
            }
        }
    }

    func snapshot() -> MacRelayRuntimeSnapshot {
        queue.sync { state.snapshot }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard !stopped else { return }
        let now = nowMs()
        if state.shouldReopenSocket(nowMs: now) {
            closeTransport()
            guard openTransport() else {
                recordSocketFailure("reopen relay transport failed")
                return
            }
            startFreshSession()
        } else {
            let expiredHandle = state.snapshot.pathHandle
            if state.expireIfIdle(nowMs: now) {
                // This is just the relay's authenticated-session expiry; retain
                // the physical socket and immediately negotiate a fresh session.
                removeEnginePath(expiredHandle)
                startFreshSession()
            } else if state.shouldRetryHello(nowMs: now) {
                _ = sendFrame(type: MQVPN_RELAY_HELLO, payload: Data(), nowMs: now)
            } else if state.shouldProbeActiveRelay(nowMs: now) {
                _ = sendFrame(type: MQVPN_RELAY_HELLO, payload: Data(), nowMs: now)
                _ = engine.perform { [engine] in _ = engine.probePaths() }
            }
        }
        publishSnapshot()
    }

    private func startFreshSession() {
        let previous = state.detachLogicalPath()
        removeEnginePath(previous)
        guard state.beginSession(sessionID: state.resumeSessionID() ?? randomSessionID(),
                                 nowMs: nowMs()) == .started else {
            recordSocketFailure("relay session initialization failed")
            return
        }
        _ = sendFrame(type: MQVPN_RELAY_HELLO, payload: Data(), nowMs: nowMs())
    }

    /// Fails only when the relay address cannot be expressed as an
    /// NWEndpoint, which `resolveRelayEndpoint`'s IPv4/IPv6-only output
    /// should never produce.
    private func openTransport() -> Bool {
        guard let transport = MacRelayNWTransport(relayEndpoint: relayEndpoint,
                                                  interfaceName: interfaceName,
                                                  queue: queue) else { return false }
        let opened = transport.open(
            onDatagram: { [weak self] datagram in
                guard let self, !self.stopped else { return }
                self.processInbound(datagram)
            },
            onRebind: { [weak self] in
                // A rebind can change our source address. HELLO re-authenticates
                // and, if the address moved, drives the iPhone's path challenge.
                guard let self, !self.stopped, self.state.shouldHelloAfterRouteRefresh()
                else { return }
                _ = self.sendFrame(type: MQVPN_RELAY_HELLO, payload: Data(), nowMs: self.nowMs())
            },
            onFailure: { [weak self] message in
                guard let self, !self.stopped else { return }
                self.recordSocketFailure(message)
            })
        guard opened else { return false }
        nwTransport = transport
        return true
    }

    @discardableResult
    private func refreshConnectedRouteLocked() -> Bool {
        guard let nwTransport, !stopped, !teardownStarted else { return false }
        return nwTransport.rebind(reason: "tunnel routes installed")
    }

    private func closeTransport() {
        nwTransport?.close()
        nwTransport = nil
    }

    private func processInbound(_ datagram: Data) {
        switch state.receive(datagram, nowMs: nowMs()) {
        case .none:
            break
        case .activateLogicalPath:
            addLogicalEnginePath()
        case let .echoKeepalive(nonce):
            _ = sendFrame(type: MQVPN_RELAY_KEEPALIVE, payload: nonce, nowMs: nowMs())
        case let .deliverToCore(payload, handle):
            feedEngine(handle: handle, payload: payload)
        case let .drop(reason):
            macRelayLog.debug("relay datagram rejected reason=\(String(describing: reason), privacy: .public)")
        }
        publishSnapshot()
    }

    private func addLogicalEnginePath() {
        let queued = engine.perform { [weak self, engine] in
            guard let self else { return }
            var desc = mqvpn_path_desc_t()
            desc.struct_size = UInt32(MemoryLayout<mqvpn_path_desc_t>.size)
            desc.fd = -1
            withUnsafeMutableBytes(of: &desc.iface) { destination in
                MacPathIdentity.relayName.utf8CString.withUnsafeBytes {
                    destination.copyBytes(from: $0.prefix(destination.count - 1))
                }
            }
            let (handle, outcome) = engine.addLogicalPath(desc: &desc)
            let failRegistration = {
                self.queue.async {
                    self.state.hardSocketFailure(nowMs: self.nowMs(),
                                                 error: "logical relay path registration failed")
                    self.publishSnapshot()
                }
            }
            guard handle >= 0 else {
                failRegistration()
                return
            }
            // TRANSIENT_FAIL means the slot is stored and tick recovery will
            // retry activation. Removing it here stranded ACK'd sessions
            // because pathActivationPending then blocked a second add.
            switch outcome {
            case MQVPN_ADD_PATH_OK, MQVPN_ADD_PATH_TRANSIENT_FAIL:
                break
            default:
                engine.removePath(handle)
                failRegistration()
                return
            }
            self.queue.async {
                if self.stopped || !self.state.attachLogicalPath(handle) {
                    engine.perform { engine.removePath(handle) }
                    return
                }
                _ = engine.perform { engine.connectIfNeeded() }
                self.publishSnapshot()
            }
        }
        if !queued {
            state.hardSocketFailure(nowMs: nowMs(), error: "mqvpn engine is unavailable")
        }
    }

    private func feedEngine(handle: mqvpn_path_handle_t, payload: Data) {
        let peer = serverPeer
        _ = engine.perform { [engine] in
            var storage = peer.storage
            withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    engine.socketRecv(handle, payload, $0, peer.len)
                }
            }
        }
    }

    private func sendFromCore(path: mqvpn_path_handle_t, packet: Data) -> Int {
        guard coreSendsEnabled else { return -Int(ENODEV) }
        return queue.sync { () -> Int in
            guard coreSendsEnabled, !stopped, state.snapshot.pathHandle == path,
                  state.snapshot.active else {
                return -Int(ENODEV)
            }
            let result = sendFrame(type: MQVPN_RELAY_DATA_TO_SERVER, payload: packet, nowMs: nowMs())
            if case .sent = result { return packet.count }
            return result.errnoValue
        }
    }

    private enum SendResult {
        case sent
        case again
        case failed(Int)

        var errnoValue: Int {
            switch self {
            case .sent: return 0
            case .again: return -Int(EAGAIN)
            case let .failed(code): return -code
            }
        }
    }

    private func sendFrame(type: mqvpn_relay_message_type_t, payload: Data,
                           nowMs: UInt64) -> SendResult {
        guard let nwTransport, nwTransport.isOpen else {
            state.recordSendFailure()
            recordSocketFailure("relay transport is unavailable")
            return .failed(Int(EIO))
        }
        guard let datagram = state.encode(type: type, payload: payload, nowMs: nowMs) else {
            state.recordSendFailure()
            // A caller contract violation must not erase an otherwise
            // authenticated relay. Valid xquic output fits the codec ceiling;
            // report an oversized datagram back to the core as EMSGSIZE.
            if payload.count > Int(MQVPN_RELAY_MAX_PAYLOAD_SIZE) {
                publishSnapshot()
                return .failed(Int(EMSGSIZE))
            }
            recordSocketFailure("relay frame encoding failed")
            return .failed(Int(EIO))
        }
        switch nwTransport.send(datagram) {
        case .sent:
            state.recordSuccessfulSend(type: type, datagramLength: datagram.count)
            return .sent
        case .again:
            state.recordSendAgain()
            return .again
        case let .failed(code):
            state.recordSendFailure()
            recordSocketFailure("relay send failed: \(String(cString: strerror(code)))")
            return .failed(Int(code))
        }
    }

    private func recordSocketFailure(_ message: String) {
        let handle = state.detachLogicalPath()
        removeEnginePath(handle)
        state.hardSocketFailure(nowMs: nowMs(), error: message)
        macRelayLog.error("\(message, privacy: .public)")
        publishSnapshot()
    }

    private func removeEnginePath(_ handle: mqvpn_path_handle_t?) {
        guard let handle else { return }
        _ = engine.perform { [engine] in engine.removePath(handle) }
    }

    /// Runs on the binder queue but never blocks it. A callback which passed
    /// the lifecycle gate immediately before Stop can still be waiting in
    /// `queue.sync`; returning lets that callback drain, then lets the tick
    /// thread run this cleanup closure. Completion is dispatched only from
    /// that tick-thread closure, after both teardown operations executed.
    private func clearEngineRelayHooks(pathHandle: mqvpn_path_handle_t?,
                                       completion: @escaping () -> Void) {
        let queued = engine.perform { [engine] in
            if let pathHandle { engine.removePath(pathHandle) }
            engine.onLogicalPathSend = nil
            Self.finish(completion)
        }
        guard queued else {
            // No tick thread exists (for example Stop before engine.start).
            // The callback has not been observed by a client and can be
            // cleared directly; no success is fabricated.
            engine.onLogicalPathSend = nil
            completion()
            return
        }
    }

    private var coreSendsEnabled: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return acceptsCoreSends
    }

    private func setCoreSendsEnabled(_ enabled: Bool) {
        lifecycleLock.lock()
        acceptsCoreSends = enabled
        lifecycleLock.unlock()
    }

    private static func finish(_ completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: completion)
    }

    /// Binder-queue-only fanout. Every Stop issued while the tick-thread
    /// cleanup fence is pending shares this point; none can report success
    /// before the logical path and callback are actually gone.
    private func finishStopWaiters() {
        guard !teardownComplete else { return }
        teardownComplete = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { Self.finish(waiter) }
    }

    private func publishSnapshot() {
        onSnapshot?(state.snapshot)
    }

    private func randomSessionID() -> UInt64 {
        // Zero is the relay codec's "no session" sentinel, hence the loop.
        var value: UInt64 = 0
        while value == 0 {
            arc4random_buf(&value, MemoryLayout<UInt64>.size)
        }
        return value
    }

    private func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private static func localIPv4Addresses() -> [String] {
        MacLANInterfaceEnumerator.localIPv4Addresses()
    }
}
