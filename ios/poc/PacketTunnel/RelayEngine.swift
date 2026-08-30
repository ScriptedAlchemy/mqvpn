// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import Network
import Darwin
import os

private let relayLog = Logger(subsystem: "mqvpn.poc", category: "relay")

/// Constrained LAN-to-cellular forwarder for Mac-owned mqvpn QUIC datagrams.
///
/// All mutable relay state and socket I/O is confined to `queue`. The LAN
/// frame contains no destination and the server socket is UDP-connected once
/// to the configured endpoint, so arbitrary forwarding is impossible by
/// construction. Authentication and replay validation use the shared C codec
/// before `RelaySessionState` is allowed to mutate.
final class RelayEngine {
    private static let maxDatagramSize = Int(MQVPN_RELAY_HEADER_SIZE) +
        Int(MQVPN_RELAY_MAX_PAYLOAD_SIZE) + Int(MQVPN_RELAY_TAG_SIZE)
    private struct PeerAddress {
        var storage: sockaddr_storage
        let length: socklen_t

        var identity: RelayPeerIdentity {
            var copy = storage
            return withUnsafeBytes(of: &copy) { raw in
                guard length >= MemoryLayout<sockaddr>.size else {
                    return RelayPeerIdentity(Data(raw.prefix(Int(length))))
                }
                let family = Int32(raw.load(as: sockaddr.self).sa_family)
                if family == AF_INET, length >= MemoryLayout<sockaddr_in>.size {
                    let addr = raw.load(as: sockaddr_in.self)
                    var ip = addr.sin_addr
                    let address = withUnsafeBytes(of: &ip) { Data($0) }
                    return RelayPeerIdentity.endpoint(family: 4, portNetworkOrder: addr.sin_port,
                                                      address: address)
                }
                if family == AF_INET6, length >= MemoryLayout<sockaddr_in6>.size {
                    let addr = raw.load(as: sockaddr_in6.self)
                    var ip = addr.sin6_addr
                    let address = withUnsafeBytes(of: &ip) { Data($0) }
                    return RelayPeerIdentity.endpoint(family: 6, portNetworkOrder: addr.sin6_port,
                                                      address: address)
                }
                return RelayPeerIdentity(Data(raw.prefix(Int(length))))
            }
        }
    }

    private let settings: RelaySettings
    private let serverAddress: ResolvedServerAddress
    private let key: Data
    private let queue = DispatchQueue(label: "mqvpn.relay")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let snapshotLock = NSLock()

    private var state = RelaySessionState(idleTimeout: 15)
    private var replayWindow = mqvpn_replay_window_t()
    private var peerAddress: PeerAddress?
    private var outboundSequence: UInt64 = 1
    private var wifiMonitor: NWPathMonitor?
    private var cellularMonitor: NWPathMonitor?
    private var interfaceProbeInFlight = false
    private var idleTimer: DispatchSourceTimer?
    private var lanFD: Int32 = -1
    private var lan6FD: Int32 = -1
    private var serverFD: Int32 = -1
    private var lanSource: DispatchSourceRead?
    private var lan6Source: DispatchSourceRead?
    private var serverSource: DispatchSourceRead?
    private let bonjourAdvertiser = RelayBonjourAdvertiser()
    private var latest: TunnelSnapshot
    private var snapshotSequence: UInt64 = 0
    private var startedAt: Double?
    private var stopped = false

    init(settings: RelaySettings, serverAddress: ResolvedServerAddress) {
        precondition(settings.isValid)
        self.settings = settings
        self.serverAddress = serverAddress
        self.key = settings.decodedKey!
        self.latest = .relayStopped(timestamp: Date().timeIntervalSince1970)
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.startedAt = Date().timeIntervalSince1970
            self.installMonitors()
            self.installIdleTimer()
            self.publishSnapshot()
        }
    }

    /// Synchronous, idempotent teardown. Because every source targets the same
    /// serial queue, cancelling and closing here cannot race a read handler.
    func stop() {
        onQueueSync {
            guard !stopped else { return }
            stopped = true
            wifiMonitor?.cancel()
            cellularMonitor?.cancel()
            wifiMonitor = nil
            cellularMonitor = nil
            idleTimer?.cancel()
            idleTimer = nil
            let actions = state.stop()
            execute(actions)
            eraseSessionSecurityState()
            startedAt = nil
            publishSnapshot()
        }
    }

    func readSnapshot() -> TunnelSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return latest
    }

    private func onQueueSync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() }
        else { queue.sync(execute: body) }
    }

    private func installMonitors() {
        let plan = RelaySocketPlan.fixed
        let wifi = NWPathMonitor(requiredInterfaceType: Self.networkType(plan.lanListener))
        let cellular = NWPathMonitor(requiredInterfaceType: Self.networkType(plan.fixedServer))
        wifi.pathUpdateHandler = { [weak self] _ in self?.probeInterfaces() }
        cellular.pathUpdateHandler = { [weak self] _ in self?.probeInterfaces() }
        wifiMonitor = wifi
        cellularMonitor = cellular
        // Store both before start: either handler may run immediately.
        wifi.start(queue: queue)
        cellular.start(queue: queue)
        probeInterfaces()
    }

    private static func networkType(_ interfaceClass: RelayInterfaceClass) -> NWInterface.InterfaceType {
        switch interfaceClass {
        case .wifi: return .wifi
        case .cellular: return .cellular
        }
    }

    /// Persistent NWPathMonitor deliveries are triggers only. Device evidence
    /// showed both deliveries and currentPath can remain stale for minutes in
    /// a packet-tunnel provider, so every trigger creates bounded one-shot
    /// monitors whose first delivery is the fresh interface truth.
    private func probeInterfaces() {
        guard !stopped, !interfaceProbeInFlight else { return }
        interfaceProbeInFlight = true
        var wifiResult: NWInterface?
        var cellularResult: NWInterface?
        var pending = 2
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            pending -= 1
            guard pending == 0 else { return }
            self.interfaceProbeInFlight = false
            guard !self.stopped else { return }
            self.reconcileInterfaces(wifi: wifiResult, cellular: cellularResult)
        }
        probeInterface(.wifi) { interface in
            wifiResult = interface
            finish()
        }
        probeInterface(.cellular) { interface in
            cellularResult = interface
            finish()
        }
    }

    private func probeInterface(_ type: NWInterface.InterfaceType,
                                completion: @escaping (NWInterface?) -> Void) {
        let probe = NWPathMonitor(requiredInterfaceType: type)
        var fired = false
        probe.pathUpdateHandler = { path in
            guard !fired else { return }
            fired = true
            probe.cancel()
            probe.pathUpdateHandler = nil
            let interface = path.status == .satisfied
                ? path.availableInterfaces.first(where: { $0.type == type }) : nil
            completion(interface)
        }
        probe.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) {
            guard !fired else { return }
            fired = true
            probe.cancel()
            probe.pathUpdateHandler = nil
            completion(nil)
        }
    }

    private func reconcileInterfaces(wifi: NWInterface?, cellular: NWInterface?) {
        let relay = state.snapshot
        let effectiveWiFi = RelayInterfaceObservation.effective(
            observed: wifi?.name, current: relay.listenerInterface,
            socketReady: lanFD >= 0 || lan6FD >= 0)
        let effectiveCellular = RelayInterfaceObservation.effective(
            observed: cellular?.name, current: relay.cellularInterface,
            socketReady: serverFD >= 0)
        let actions = state.updateInterfaces(wifi: effectiveWiFi,
                                             cellular: effectiveCellular)
        for action in actions {
            switch action {
            case .openWifi:
                if let wifi { openLANSocket(interface: wifi) }
            case .openCellular:
                if let cellular { openServerSocket(interface: cellular) }
            case .closeWifi:
                closeLANSocket()
                eraseSessionSecurityState()
            case .closeCellular:
                closeServerSocket()
            case .sendHelloAck, .sendPathChallenge, .forwardToFixedServer, .drop:
                break
            }
        }
        publishSnapshot()
    }

    private func installIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if self.state.expireIfIdle(now: Date().timeIntervalSince1970) {
                self.eraseSessionSecurityState()
                relayLog.notice("authenticated relay session expired")
            }
            self.probeInterfaces()
            self.publishSnapshot()
        }
        timer.resume()
        idleTimer = timer
    }

    private func configureSocket(_ fd: Int32, interface: NWInterface, family: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        var bufferSize: Int32 = 1 << 20
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize,
                       socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize,
                       socklen_t(MemoryLayout<Int32>.size))
        var interfaceIndex = UInt32(interface.index)
        if family == AF_INET6 {
            return setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &interfaceIndex,
                              socklen_t(MemoryLayout<UInt32>.size)) == 0
        }
        return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex,
                          socklen_t(MemoryLayout<UInt32>.size)) == 0
    }

    private func openLANSocket(interface: NWInterface) {
        closeLANSocket()
        let v4 = bindLAN(family: AF_INET, interface: interface)
        let v6 = bindLAN(family: AF_INET6, interface: interface)
        guard v4 || v6 else {
            state.recordError("Wi-Fi relay socket unavailable")
            _ = state.updateInterfaces(wifi: nil,
                                       cellular: state.snapshot.cellularInterface)
            publishSnapshot()
            return
        }
        state.recordError(nil)
        refreshAdvertisement()
        relayLog.notice("LAN listener ready interface=\(interface.name, privacy: .public) v4=\(v4) v6=\(v6)")
    }

    private func bindLAN(family: Int32, interface: NWInterface) -> Bool {
        let fd = socket(family, SOCK_DGRAM, 0)
        guard fd >= 0, configureSocket(fd, interface: interface, family: family) else {
            if fd >= 0 { close(fd) }
            return false
        }
        let bound: Bool
        if family == AF_INET6 {
            var v6only: Int32 = 1
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only,
                           socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(settings.listenPort).bigEndian)
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            } == 0
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(settings.listenPort).bigEndian)
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            } == 0
        }
        guard bound else {
            close(fd)
            return false
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainLANSocket(fd) }
        source.resume()
        if family == AF_INET6 {
            lan6FD = fd
            lan6Source = source
        } else {
            lanFD = fd
            lanSource = source
        }
        return true
    }

    private func openServerSocket(interface: NWInterface) {
        closeServerSocket()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0, configureSocket(fd, interface: interface, family: AF_INET) else {
            if fd >= 0 { close(fd) }
            state.recordError("Cellular relay socket unavailable")
            _ = state.updateInterfaces(wifi: state.snapshot.listenerInterface,
                                       cellular: nil)
            publishSnapshot()
            return
        }
        var storage = serverAddress.storage
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, serverAddress.len)
            }
        }
        guard result == 0 else {
            close(fd)
            state.recordError("Cellular server connect failed")
            _ = state.updateInterfaces(wifi: state.snapshot.listenerInterface,
                                       cellular: nil)
            publishSnapshot()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainServerSocket() }
        source.resume()
        serverFD = fd
        serverSource = source
        state.recordError(nil)
        refreshAdvertisement()
        relayLog.notice("server socket ready interface=\(interface.name, privacy: .public)")
    }

    private func closeLANSocket() {
        lanSource?.setEventHandler {}
        lanSource?.cancel()
        lanSource = nil
        lan6Source?.setEventHandler {}
        lan6Source?.cancel()
        lan6Source = nil
        if lanFD >= 0 { close(lanFD); lanFD = -1 }
        if lan6FD >= 0 { close(lan6FD); lan6FD = -1 }
        refreshAdvertisement()
    }

    private func closeServerSocket() {
        serverSource?.setEventHandler {}
        serverSource?.cancel()
        serverSource = nil
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        refreshAdvertisement()
    }

    private func refreshAdvertisement() {
        if RelayAdvertisementPolicy.shouldPublish(lanReady: lanFD >= 0 || lan6FD >= 0,
                                                  cellularReady: serverFD >= 0,
                                                  stopped: stopped) {
            bonjourAdvertiser.start(port: settings.listenPort)
        } else {
            bonjourAdvertiser.stop()
        }
    }

    private func execute(_ actions: [RelayStateAction], reply: PeerAddress? = nil) {
        for action in actions {
            switch action {
            case .closeWifi: closeLANSocket()
            case .closeCellular: closeServerSocket()
            case .sendHelloAck(let sessionID):
                sendToMac(type: MQVPN_RELAY_HELLO_ACK, sessionID: sessionID,
                          payload: Data(), destination: reply)
            case .sendPathChallenge(let nonce):
                guard let sessionID = state.activeSessionID else { break }
                sendToMac(type: MQVPN_RELAY_KEEPALIVE, sessionID: sessionID,
                          payload: nonce, destination: reply)
            case .forwardToFixedServer(let payload):
                forwardToServer(payload)
            case .openWifi, .openCellular, .drop:
                break
            }
        }
    }

    private func drainLANSocket(_ socketFD: Int32) {
        // Receive the complete UDP datagram before validation. A max-sized
        // buffer would truncate an oversized packet to a potentially valid
        // authenticated prefix, hiding the forbidden trailing bytes.
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            var peerStorage = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peerStorage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, &buffer, buffer.count, 0, $0, &peerLength)
                }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    state.recordError("Wi-Fi relay receive failed")
                    closeLANSocket()
                    _ = state.updateInterfaces(wifi: nil,
                                               cellular: state.snapshot.cellularInterface)
                    eraseSessionSecurityState()
                }
                break
            }
            guard count > 0 else { break }
            let datagram = Data(buffer.prefix(count))
            let peer = PeerAddress(storage: peerStorage, length: peerLength)
            processLANDatagram(datagram, peer: peer)
        }
        publishSnapshot()
    }

    private func processLANDatagram(_ datagram: Data, peer: PeerAddress) {
        var decoded = mqvpn_relay_frame_t()
        var payload = Data()
        let decodeResult = key.withUnsafeBytes { keyBytes in
            datagram.withUnsafeBytes { bytes -> mqvpn_relay_result_t in
                let result = mqvpn_relay_decode(
                    keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count,
                    MQVPN_RELAY_MAC_TO_IPHONE, nil, &decoded)
                // decoded.payload aliases `bytes` (relay_protocol.h contract)
                // and dies with this closure — copy it before returning.
                if result == MQVPN_RELAY_OK, decoded.payload_length > 0 {
                    payload = Data(bytes: decoded.payload, count: decoded.payload_length)
                }
                return result
            }
        }
        guard decodeResult == MQVPN_RELAY_OK else {
            return
        }

        let type = swiftFrameType(decoded.type)
        guard let type else { return }

        let permittedFromMac = type == .hello || type == .dataToServer || type == .keepalive
        let validControlPayload: Bool
        switch type {
        case .hello:
            validControlPayload = decoded.payload_length == 0
        case .keepalive:
            validControlPayload = decoded.payload_length == 0 ||
                decoded.payload_length == RelayPathChallenge.nonceSize
        case .helloAck, .dataToServer, .dataToMac:
            validControlPayload = true
        }

        var replayAccepted = false
        if permittedFromMac, validControlPayload,
           RelayReplayEligibility.mayCheck(type: type,
                                           sessionID: decoded.session_id,
                                           activeSessionID: state.activeSessionID,
                                           peer: peer.identity,
                                           activePeer: state.activePeer,
                                           pendingPeer: state.pendingPeer) {
            if state.activeSessionID == nil {
                var fresh = mqvpn_replay_window_t()
                replayAccepted = mqvpn_replay_window_accept(&fresh, decoded.sequence) == MQVPN_RELAY_OK
                if replayAccepted { replayWindow = fresh }
            } else {
                replayAccepted = mqvpn_replay_window_accept(&replayWindow, decoded.sequence) == MQVPN_RELAY_OK
            }
        }

        let inbound = RelayInboundFrame(
            type: type, sessionID: decoded.session_id, sequence: decoded.sequence,
            payload: payload, peer: peer.identity, authenticated: true,
            replayAccepted: replayAccepted)
        let actions = state.handleMacFrame(inbound, now: Date().timeIntervalSince1970)
        let dropped = actions.contains { action in
            if case .drop = action { return true }
            return false
        }
        if !dropped {
            state.recordLanReceive(datagram.count)
            if shouldCommitSocketPeer(actions: actions, reply: peer) {
                peerAddress = peer
            }
        }
        execute(actions, reply: peer)
    }

    private func swiftFrameType(_ type: mqvpn_relay_message_type_t) -> RelayFrameType? {
        switch type {
        case MQVPN_RELAY_HELLO: return .hello
        case MQVPN_RELAY_HELLO_ACK: return .helloAck
        case MQVPN_RELAY_DATA_TO_SERVER: return .dataToServer
        case MQVPN_RELAY_DATA_TO_MAC: return .dataToMac
        case MQVPN_RELAY_KEEPALIVE: return .keepalive
        default: return nil
        }
    }

    private func forwardToServer(_ payload: Data) {
        guard serverFD >= 0 else {
            state.recordError("Cellular path unavailable")
            return
        }
        let sent = payload.withUnsafeBytes { bytes in
            send(serverFD, bytes.baseAddress, bytes.count, 0)
        }
        // UDP send is all-or-nothing: a nonnegative return is the whole datagram.
        if sent >= 0 {
            state.recordServerSend(sent)
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            state.recordError("Cellular server send failed")
            closeServerSocket()
            _ = state.updateInterfaces(wifi: state.snapshot.listenerInterface,
                                       cellular: nil)
        }
    }

    private func drainServerSocket() {
        guard serverFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            let count = recv(serverFD, &buffer, buffer.count, 0)
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    state.recordError("Cellular server receive failed")
                    closeServerSocket()
                    _ = state.updateInterfaces(wifi: state.snapshot.listenerInterface,
                                               cellular: nil)
                }
                break
            }
            guard count > 0 else { break }
            guard count <= Int(MQVPN_RELAY_MAX_PAYLOAD_SIZE) else {
                state.recordError("Server datagram exceeds relay limit")
                continue
            }
            state.recordServerReceive(count)
            guard let sessionID = state.activeSessionID else { continue }
            sendToMac(type: MQVPN_RELAY_DATA_TO_MAC, sessionID: sessionID,
                      payload: Data(buffer.prefix(count)))
        }
        publishSnapshot()
    }

    private func lanSocket(for peer: PeerAddress) -> Int32 {
        var copy = peer.storage
        let family = withUnsafeBytes(of: &copy) { Int32($0.load(as: sockaddr.self).sa_family) }
        return family == AF_INET6 ? lan6FD : lanFD
    }

    private func shouldCommitSocketPeer(actions: [RelayStateAction],
                                        reply: PeerAddress) -> Bool {
        guard state.activePeer == reply.identity else { return false }
        for action in actions {
            if case .sendPathChallenge = action { return false }
        }
        return true
    }

    private func sendToMac(type: mqvpn_relay_message_type_t,
                           sessionID: UInt64, payload: Data,
                           destination: PeerAddress? = nil) {
        guard var peer = destination ?? peerAddress else { return }
        let socketFD = lanSocket(for: peer)
        guard socketFD >= 0 else { return }
        var output = [UInt8](repeating: 0, count: Self.maxDatagramSize)
        var outputLength = 0
        let sequence = outboundSequence
        outboundSequence &+= 1
        let result = key.withUnsafeBytes { keyBytes in
            payload.withUnsafeBytes { payloadBytes in
                mqvpn_relay_encode(
                    keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), type,
                    MQVPN_RELAY_IPHONE_TO_MAC, sessionID, sequence,
                    payloadBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), payload.count,
                    &output, output.count, &outputLength)
            }
        }
        guard result == MQVPN_RELAY_OK else {
            state.recordError("Relay frame encoding failed")
            return
        }
        let sent = withUnsafePointer(to: &peer.storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                output.withUnsafeBytes {
                    sendto(socketFD, $0.baseAddress, outputLength, 0, address, peer.length)
                }
            }
        }
        // UDP sendto is all-or-nothing: a nonnegative return is the whole datagram.
        if sent >= 0 {
            state.recordLanSend(sent)
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            state.recordError("Wi-Fi relay send failed")
            closeLANSocket()
            _ = state.updateInterfaces(wifi: nil,
                                       cellular: state.snapshot.cellularInterface)
            eraseSessionSecurityState()
        }
    }

    private func eraseSessionSecurityState() {
        replayWindow = mqvpn_replay_window_t()
        peerAddress = nil
        outboundSequence = 1
    }

    private func publishSnapshot() {
        snapshotSequence &+= 1
        let now = Date().timeIntervalSince1970
        let relay = state.snapshot
        let snapshot = TunnelSnapshot(
            timestamp: now, clientState: -1, connectedSince: startedAt,
            footprint: SnapshotCache.physFootprint(), paths: [], seq: snapshotSequence,
            operatingMode: .macRelay, relay: relay)
        snapshotLock.lock()
        latest = snapshot
        snapshotLock.unlock()
    }
}
