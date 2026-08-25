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
            let data = withUnsafeBytes(of: &copy) { Data($0.prefix(Int(length))) }
            return RelayPeerIdentity(data)
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
    private var idleTimer: DispatchSourceTimer?
    private var lanFD: Int32 = -1
    private var serverFD: Int32 = -1
    private var lanSource: DispatchSourceRead?
    private var serverSource: DispatchSourceRead?
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
        wifi.pathUpdateHandler = { [weak self] path in
            guard let self, !self.stopped else { return }
            let interface = path.status == .satisfied
                ? path.availableInterfaces.first(where: { $0.type == .wifi }) : nil
            self.reconcileInterfaces(wifi: interface,
                                     cellular: self.currentCellularInterface())
        }
        cellular.pathUpdateHandler = { [weak self] path in
            guard let self, !self.stopped else { return }
            let interface = path.status == .satisfied
                ? path.availableInterfaces.first(where: { $0.type == .cellular }) : nil
            self.reconcileInterfaces(wifi: self.currentWifiInterface(),
                                     cellular: interface)
        }
        wifiMonitor = wifi
        cellularMonitor = cellular
        // Store both before start: either handler may run immediately.
        wifi.start(queue: queue)
        cellular.start(queue: queue)
    }

    private static func networkType(_ interfaceClass: RelayInterfaceClass) -> NWInterface.InterfaceType {
        switch interfaceClass {
        case .wifi: return .wifi
        case .cellular: return .cellular
        }
    }

    private func currentWifiInterface() -> NWInterface? {
        guard let path = wifiMonitor?.currentPath, path.status == .satisfied else { return nil }
        return path.availableInterfaces.first { $0.type == .wifi }
    }

    private func currentCellularInterface() -> NWInterface? {
        guard let path = cellularMonitor?.currentPath, path.status == .satisfied else { return nil }
        return path.availableInterfaces.first { $0.type == .cellular }
    }

    private func reconcileInterfaces(wifi: NWInterface?, cellular: NWInterface?) {
        let actions = state.updateInterfaces(wifi: wifi?.name, cellular: cellular?.name)
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
            default:
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
            self.reconcileInterfaces(wifi: self.currentWifiInterface(),
                                     cellular: self.currentCellularInterface())
            self.publishSnapshot()
        }
        timer.resume()
        idleTimer = timer
    }

    private func configureSocket(_ fd: Int32, interface: NWInterface) -> Bool {
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
        return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex,
                          socklen_t(MemoryLayout<UInt32>.size)) == 0
    }

    private func openLANSocket(interface: NWInterface) {
        closeLANSocket()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0, configureSocket(fd, interface: interface) else {
            if fd >= 0 { close(fd) }
            state.recordError("Wi-Fi relay socket unavailable")
            _ = state.updateInterfaces(wifi: nil,
                                       cellular: state.snapshot.cellularInterface)
            publishSnapshot()
            return
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(settings.listenPort).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            state.recordError("Wi-Fi relay listen failed")
            _ = state.updateInterfaces(wifi: nil,
                                       cellular: state.snapshot.cellularInterface)
            publishSnapshot()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainLANSocket() }
        source.resume()
        lanFD = fd
        lanSource = source
        state.recordError(nil)
        relayLog.notice("LAN listener ready interface=\(interface.name, privacy: .public)")
    }

    private func openServerSocket(interface: NWInterface) {
        closeServerSocket()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0, configureSocket(fd, interface: interface) else {
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
        relayLog.notice("server socket ready interface=\(interface.name, privacy: .public)")
    }

    private func closeLANSocket() {
        lanSource?.setEventHandler {}
        lanSource?.cancel()
        lanSource = nil
        if lanFD >= 0 { close(lanFD); lanFD = -1 }
    }

    private func closeServerSocket() {
        serverSource?.setEventHandler {}
        serverSource?.cancel()
        serverSource = nil
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
    }

    private func execute(_ actions: [RelayStateAction]) {
        for action in actions {
            switch action {
            case .closeWifi: closeLANSocket()
            case .closeCellular: closeServerSocket()
            case .sendHelloAck(let sessionID): sendToMac(type: MQVPN_RELAY_HELLO_ACK,
                                                          sessionID: sessionID,
                                                          payload: Data())
            case .forwardToFixedServer(let payload): forwardToServer(payload)
            case .openWifi, .openCellular, .drop: break
            }
        }
    }

    private func drainLANSocket() {
        guard lanFD >= 0 else { return }
        // Receive the complete UDP datagram before validation. A max-sized
        // buffer would truncate an oversized packet to a potentially valid
        // authenticated prefix, hiding the forbidden trailing bytes.
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            var peerStorage = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peerStorage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(lanFD, &buffer, buffer.count, 0, $0, &peerLength)
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
        let decodeResult = key.withUnsafeBytes { keyBytes in
            datagram.withUnsafeBytes { bytes in
                mqvpn_relay_decode(
                    keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count,
                    MQVPN_RELAY_MAC_TO_IPHONE, nil, &decoded)
            }
        }
        guard decodeResult == MQVPN_RELAY_OK else {
            state.recordError("Relay authentication or frame validation failed")
            return
        }

        let type = swiftFrameType(decoded.type)
        guard let type else { return }

        let permittedFromMac = type == .hello || type == .dataToServer || type == .keepalive
        let validControlPayload = (type != .hello && type != .keepalive) || decoded.payload_length == 0

        var replayAccepted = false
        if permittedFromMac, validControlPayload,
           type == .hello, state.activeSessionID == nil {
            var fresh = mqvpn_replay_window_t()
            replayAccepted = mqvpn_replay_window_accept(&fresh, decoded.sequence) == MQVPN_RELAY_OK
            if replayAccepted { replayWindow = fresh }
        } else if permittedFromMac, validControlPayload,
                  state.activeSessionID == decoded.session_id,
                  state.activePeer == peer.identity {
            replayAccepted = mqvpn_replay_window_accept(&replayWindow, decoded.sequence) == MQVPN_RELAY_OK
        }

        let payload: Data
        if decoded.payload_length == 0 {
            payload = Data()
        } else {
            payload = Data(bytes: decoded.payload, count: decoded.payload_length)
        }
        let inbound = RelayInboundFrame(
            type: type, sessionID: decoded.session_id, sequence: decoded.sequence,
            payload: payload, peer: peer.identity, authenticated: true,
            replayAccepted: replayAccepted)
        let hadSession = state.activeSessionID != nil
        let actions = state.handleMacFrame(inbound, now: Date().timeIntervalSince1970)
        if !hadSession, state.activeSessionID != nil {
            peerAddress = peer
        }
        let dropped = actions.contains { action in
            if case .drop = action { return true }
            return false
        }
        if !dropped {
            state.recordLanReceive(datagram.count)
        }
        execute(actions)
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
        if sent == payload.count {
            state.recordServerSend(sent)
        } else if sent >= 0 {
            state.recordError("Cellular server partial datagram")
            closeServerSocket()
            _ = state.updateInterfaces(wifi: state.snapshot.listenerInterface,
                                       cellular: nil)
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

    private func sendToMac(type: mqvpn_relay_message_type_t,
                           sessionID: UInt64, payload: Data) {
        guard lanFD >= 0, var peer = peerAddress else { return }
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
                    sendto(lanFD, $0.baseAddress, outputLength, 0, address, peer.length)
                }
            }
        }
        if sent == outputLength {
            state.recordLanSend(sent)
        } else if sent >= 0 {
            state.recordError("Wi-Fi relay partial datagram")
            closeLANSocket()
            _ = state.updateInterfaces(wifi: nil,
                                       cellular: state.snapshot.cellularInterface)
            eraseSessionSecurityState()
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
            footprint: Self.physicalFootprint(), paths: [], seq: snapshotSequence,
            operatingMode: .macRelay, relay: relay)
        snapshotLock.lock()
        latest = snapshot
        snapshotLock.unlock()
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
