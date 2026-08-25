// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Darwin
import Foundation
import Security
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
    private var fd: Int32 = -1
    private var transportGeneration: UInt64 = 0
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var stopped = true
    private var teardownStarted = false
    private var teardownComplete = false
    private var stopWaiters: [() -> Void] = []
    private var acceptsCoreSends = false
    /// Network-byte-order local UDP port from the first successful bind.
    /// Reopen must reuse it so the iPhone's authenticated peer identity still matches.
    private var pinnedLocalPort: in_port_t = 0
    /// Exact local address from the first connect. Bind-to-any plus a later
    /// default-route change can pick utun as the source and break the iPhone peer.
    private var pinnedLocalAddress = sockaddr_storage()
    private var pinnedLocalAddressLength: socklen_t = 0

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
        // The callback is synchronous on mqvpn's tick thread. Socket ownership
        // stays on `queue`, so it uses a bounded serial hop—not an unbound
        // socket and never a root-run adapter.
        engine.onLogicalPathSend = { [weak self] path, packet in
            self?.sendFromCore(path: path, packet: packet) ?? -Int(ENODEV)
        }
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
            } else if self.fd >= 0 {
                macRelayLog.error("relay connect refresh after routes failed: \(self.errnoMessage(), privacy: .public)")
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.stopped, !self.teardownStarted else { return }
            self.stopped = false
            self.setCoreSendsEnabled(true)
            self.startTimer()
            guard self.openTransport() else {
                self.recordSocketFailure("open relay socket failed: \(self.errnoMessage())")
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
                recordSocketFailure("reopen relay socket failed: \(errnoMessage())")
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
        guard state.beginSession(sessionID: randomSessionID(), nowMs: nowMs()) == .started else {
            recordSocketFailure("relay session initialization failed")
            return
        }
        _ = sendFrame(type: MQVPN_RELAY_HELLO, payload: Data(), nowMs: nowMs())
    }

    private var endpointFamily: Int32 {
        var storage = relayEndpoint.storage
        return withUnsafeBytes(of: &storage) { Int32($0.load(as: sockaddr.self).sa_family) }
    }

    private func scopedEndpoint() -> (sockaddr_storage, socklen_t) {
        var storage = relayEndpoint.storage
        let index = if_nametoindex(interfaceName)
        if endpointFamily == AF_INET6, index != 0 {
            withUnsafeMutableBytes(of: &storage) { raw in
                raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self)
                    .pointee.sin6_scope_id = index
            }
        }
        return (storage, relayEndpoint.len)
    }

    private func openTransport() -> Bool {
        let family = endpointFamily
        guard family == AF_INET || family == AF_INET6 else { return false }
        let socketFD = socket(family, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return false }
        let flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(socketFD)
            return false
        }
        _ = fcntl(socketFD, F_SETNOSIGPIPE, 1)
        var bufferSize: Int32 = 1 << 20
        _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDBUF, &bufferSize,
                       socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &bufferSize,
                       socklen_t(MemoryLayout<Int32>.size))
        let index = if_nametoindex(interfaceName)
        guard index != 0 else { close(socketFD); return false }
        var boundIndex = index
        let bound: Int32
        if family == AF_INET6 {
            bound = setsockopt(socketFD, IPPROTO_IPV6, IPV6_BOUND_IF, &boundIndex,
                               socklen_t(MemoryLayout<UInt32>.size))
        } else {
            bound = setsockopt(socketFD, IPPROTO_IP, IP_BOUND_IF, &boundIndex,
                               socklen_t(MemoryLayout<UInt32>.size))
        }
        guard bound == 0 else {
            close(socketFD)
            return false
        }
        guard bindPinnedLocalPort(socketFD) else {
            close(socketFD)
            return false
        }
        var endpoint = scopedEndpoint()
        let connected = withUnsafePointer(to: &endpoint.0) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, endpoint.1)
            }
        }
        guard connected == 0 else { close(socketFD); return false }
        rememberLocalPort(socketFD)
        fd = socketFD
        transportGeneration &+= 1
        let generation = transportGeneration
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.drainSocket(socketFD, generation: generation) }
        source.resume()
        readSource = source
        return true
    }

    @discardableResult
    private func refreshConnectedRouteLocked() -> Bool {
        guard fd >= 0, !stopped, !teardownStarted else { return false }
        var endpoint = scopedEndpoint()
        return withUnsafePointer(to: &endpoint.0) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, endpoint.1)
            }
        } == 0
    }

    private func bindPinnedLocalPort(_ socketFD: Int32) -> Bool {
        guard pinnedLocalPort != 0 else { return true }
        var reuse: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse,
                       socklen_t(MemoryLayout<Int32>.size))
        if MacRelaySourcePin.shouldBindExactSource(pinnedAddressLength: pinnedLocalAddressLength) {
            var address = pinnedLocalAddress
            let exactBindSucceeded = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, pinnedLocalAddressLength)
                }
            } == 0
            if MacRelaySourcePin.shouldClearPinAfterBindFailure(exactBindAttempted: true,
                                                                bindSucceeded: exactBindSucceeded) {
                pinnedLocalAddress = sockaddr_storage()
                pinnedLocalAddressLength = 0
            }
            if exactBindSucceeded {
                return true
            }
        }
        if endpointFamily == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = pinnedLocalPort
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            } == 0
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = pinnedLocalPort
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private func rememberLocalPort(_ socketFD: Int32) {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard ok == 0 else { return }
        if MacRelaySourcePin.shouldReplacePin(existingAddressLength: pinnedLocalAddressLength,
                                              newAddressLength: length) {
            pinnedLocalAddress = storage
            pinnedLocalAddressLength = length
        }
        let family = Int32(storage.ss_family)
        if family == AF_INET6 {
            let port = withUnsafeBytes(of: &storage) {
                $0.load(as: sockaddr_in6.self).sin6_port
            }
            if port != 0 { pinnedLocalPort = port }
        } else if family == AF_INET {
            let port = withUnsafeBytes(of: &storage) {
                $0.load(as: sockaddr_in.self).sin_port
            }
            if port != 0 { pinnedLocalPort = port }
        }
    }

    private func closeTransport() {
        // Invalidate the captured token before closing. Darwin can reuse a
        // descriptor number immediately; fd equality alone is not enough to
        // distinguish a stale read event from a newly opened socket.
        transportGeneration &+= 1
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func drainSocket(_ socketFD: Int32, generation: UInt64) {
        guard MacRelayTransportGeneration.accepts(
            capturedGeneration: generation, currentGeneration: transportGeneration,
            capturedFD: socketFD, currentFD: fd, stopped: stopped) else { return }
        var bytes = [UInt8](repeating: 0,
                             count: Int(MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE +
                                        MQVPN_RELAY_TAG_SIZE))
        while true {
            guard MacRelayTransportGeneration.accepts(
                capturedGeneration: generation, currentGeneration: transportGeneration,
                capturedFD: socketFD, currentFD: fd, stopped: stopped) else { return }
            let received = recv(socketFD, &bytes, bytes.count, 0)
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                recordSocketFailure("relay recv failed: \(errnoMessage())")
                break
            }
            if received == 0 { break }
            processInbound(Data(bytes.prefix(Int(received))))
        }
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
            // TRANSIENT_FAIL means the slot is stored and tick recovery will
            // retry activation. Removing it here stranded ACK'd sessions
            // because pathActivationPending then blocked a second add.
            guard handle >= 0 else {
                self.queue.async {
                    self.state.hardSocketFailure(nowMs: self.nowMs(),
                                                 error: "logical relay path registration failed")
                    self.publishSnapshot()
                }
                return
            }
            switch outcome {
            case MQVPN_ADD_PATH_OK, MQVPN_ADD_PATH_TRANSIENT_FAIL:
                break
            case MQVPN_ADD_PATH_PERMANENT_FAIL:
                engine.removePath(handle)
                self.queue.async {
                    self.state.hardSocketFailure(nowMs: self.nowMs(),
                                                 error: "logical relay path registration failed")
                    self.publishSnapshot()
                }
                return
            default:
                engine.removePath(handle)
                self.queue.async {
                    self.state.hardSocketFailure(nowMs: self.nowMs(),
                                                 error: "logical relay path registration failed")
                    self.publishSnapshot()
                }
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
        guard fd >= 0 else {
            state.recordSendFailure()
            recordSocketFailure("relay socket is unavailable")
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
        var sent = datagram.withUnsafeBytes {
            Darwin.send(fd, $0.baseAddress, datagram.count, 0)
        }
        if sent < 0, MacRelaySendRecovery.shouldRefreshRoute(errno),
           refreshConnectedRouteLocked() {
            sent = datagram.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress, datagram.count, 0)
            }
        }
        if sent == datagram.count {
            state.recordSuccessfulSend(type: type, datagramLength: datagram.count)
            return .sent
        }
        if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            state.recordSendAgain()
            return .again
        }
        let code = sent < 0 ? errno : EIO
        state.recordSendFailure()
        recordSocketFailure("relay send failed: \(String(cString: strerror(code)))")
        return .failed(Int(code))
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
        var value: UInt64 = 0
        while value == 0 {
            if SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt64>.size, &value) != errSecSuccess {
                arc4random_buf(&value, MemoryLayout<UInt64>.size)
            }
        }
        return value
    }

    private func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private func errnoMessage() -> String {
        String(cString: strerror(errno))
    }

    private static func localIPv4Addresses() -> [String] {
        MacLANInterfaceEnumerator.localIPv4Addresses()
    }
}
