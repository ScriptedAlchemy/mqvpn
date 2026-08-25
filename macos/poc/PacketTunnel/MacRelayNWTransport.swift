// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Darwin
import Foundation
import Network
import os.log

private let nwTransportLog = Logger(subsystem: "mqvpn.mac", category: "relay.nw")

/// Network.framework datagram transport for the Mac -> iPhone LAN relay hop.
///
/// This replaces a hand-rolled UDP socket that pinned its exact local address
/// so the iPhone's peer identity would keep matching. That pin was only ever
/// necessary because the relay protocol could not migrate a peer; now that an
/// authenticated HELLO is challenged for return routability, the transport is
/// free to rebind and Network.framework can own that decision.
///
/// All callbacks are delivered on the queue supplied to `open`, which is the
/// binder's serial queue, so relay state stays confined exactly as before.
final class MacRelayNWTransport {
    enum SendOutcome {
        case sent
        case again
        case failed(Int32)
    }

    private let endpoint: NWEndpoint
    private let interfaceName: String
    private let queue: DispatchQueue

    private var connection: NWConnection?
    /// Incremented on every connection object. A completion or receive handler
    /// captured for a torn-down connection must not touch current state.
    private var generation: UInt64 = 0
    private var outstandingBytes = 0
    private var closed = true

    private var onDatagram: ((Data) -> Void)?
    private var onRebind: (() -> Void)?
    private var onFailure: ((String) -> Void)?

    var isOpen: Bool { connection != nil && !closed }

    /// Fails when the resolved relay address cannot be expressed as an
    /// `NWEndpoint`, which keeps a malformed configuration from silently
    /// falling back to an unscoped or wrong-family connection.
    init?(relayEndpoint: ResolvedServerAddress, interfaceName: String, queue: DispatchQueue) {
        guard let endpoint = Self.makeEndpoint(relayEndpoint, interfaceName: interfaceName) else {
            return nil
        }
        self.endpoint = endpoint
        self.interfaceName = interfaceName
        self.queue = queue
    }

    // MARK: - Lifecycle

    func open(onDatagram: @escaping (Data) -> Void,
              onRebind: @escaping () -> Void,
              onFailure: @escaping (String) -> Void) -> Bool {
        self.onDatagram = onDatagram
        self.onRebind = onRebind
        self.onFailure = onFailure
        closed = false
        return start()
    }

    private func start() -> Bool {
        let parameters = NWParameters.udp
        parameters.prohibitedInterfaceTypes = MacRelayTransportPolicy.prohibitedInterfaceTypes
        // Keeping the same local port across a rebind is a courtesy to the
        // iPhone's peer cache, not a correctness requirement any more.
        parameters.allowLocalEndpointReuse = true
        if let interface = Self.interface(named: interfaceName) {
            parameters.requiredInterface = interface
        } else {
            // Without an NWInterface the type filter still keeps us off utun.
            nwTransportLog.notice("relay interface \(self.interfaceName, privacy: .public) not yet enumerated")
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        generation &+= 1
        let captured = generation
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state, generation: captured)
        }
        // Apple's documented migration pattern is make-before-break: stand up a
        // replacement and only then cancel the original. For a connectionless
        // relay hop there is no handshake to preserve, so a restart is enough.
        connection.betterPathUpdateHandler = { [weak self] better in
            guard better else { return }
            self?.rebind(reason: "better path", generation: captured)
        }
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, captured == self.generation else { return }
            nwTransportLog.debug("relay path changed status=\(String(describing: path.status), privacy: .public)")
            self.onRebind?()
        }
        connection.viabilityUpdateHandler = { viable in
            // Network.framework deliberately keeps unviable connections alive
            // because they may recover, so this is a signal, not a teardown.
            guard !viable else { return }
            nwTransportLog.notice("relay connection reported not viable")
        }
        connection.start(queue: queue)
        receiveNext(on: connection, generation: captured)
        return true
    }

    func close() {
        closed = true
        generation &+= 1
        connection?.cancel()
        connection = nil
        outstandingBytes = 0
        onDatagram = nil
        onRebind = nil
        onFailure = nil
    }

    /// Tear down and re-establish. Used for an explicit route refresh after the
    /// tunnel installs its default route, and for a better-path event.
    @discardableResult
    func rebind(reason: String, generation captured: UInt64? = nil) -> Bool {
        if let captured, captured != generation { return false }
        guard !closed else { return false }
        nwTransportLog.notice("relay transport rebinding: \(reason, privacy: .public)")
        connection?.cancel()
        connection = nil
        outstandingBytes = 0
        let restarted = start()
        if restarted { onRebind?() }
        return restarted
    }

    // MARK: - Data

    func send(_ datagram: Data) -> SendOutcome {
        guard let connection, !closed else { return .failed(EIO) }
        if MacRelayTransportPolicy.shouldApplyBackpressure(outstandingBytes: outstandingBytes,
                                                          pendingBytes: datagram.count) {
            return .again
        }
        let captured = generation
        outstandingBytes += datagram.count
        connection.send(content: datagram, completion: .contentProcessed { [weak self] error in
            self?.completeSend(bytes: datagram.count, error: error, generation: captured)
        })
        // UDP has no delivery signal; a synchronous success here matches what
        // Darwin.send reported. Real failures arrive on the completion above.
        return .sent
    }

    private func completeSend(bytes: Int, error: NWError?, generation captured: UInt64) {
        guard captured == generation, !closed else { return }
        outstandingBytes = max(0, outstandingBytes - bytes)
        guard let error else { return }
        if MacRelayTransportPolicy.isRecoverableRouteError(error) {
            rebind(reason: "route error \(error)", generation: captured)
            return
        }
        onFailure?("relay send failed: \(error)")
    }

    private func receiveNext(on connection: NWConnection, generation captured: UInt64) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, captured == self.generation, !self.closed else { return }
            if let content, !content.isEmpty {
                self.onDatagram?(content)
            }
            if let error {
                if MacRelayTransportPolicy.isRecoverableRouteError(error) {
                    self.rebind(reason: "receive route error \(error)", generation: captured)
                } else {
                    self.onFailure?("relay receive failed: \(error)")
                }
                return
            }
            self.receiveNext(on: connection, generation: captured)
        }
    }

    private func handleState(_ state: NWConnection.State, generation captured: UInt64) {
        guard captured == generation, !closed else { return }
        switch state {
        case .ready:
            nwTransportLog.notice("relay transport ready on \(self.interfaceName, privacy: .public)")
            onRebind?()
        case let .failed(error):
            onFailure?("relay transport failed: \(error)")
        case let .waiting(error):
            // Waiting means no usable path yet. Report it without tearing the
            // authenticated relay session down; the binder's timer retries.
            nwTransportLog.notice("relay transport waiting: \(String(describing: error), privacy: .public)")
        case .cancelled, .preparing, .setup:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Endpoint construction

    static func interface(named name: String) -> NWInterface? {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        return monitor.currentPath.availableInterfaces.first { $0.name == name }
    }

    /// Build a scoped `NWEndpoint` from the resolved sockaddr. IPv6 link-local
    /// relay addresses only route when they carry the LAN interface scope.
    static func makeEndpoint(_ address: ResolvedServerAddress,
                             interfaceName: String) -> NWEndpoint? {
        var storage = address.storage
        let family = withUnsafeBytes(of: &storage) { Int32($0.load(as: sockaddr.self).sa_family) }
        if family == AF_INET {
            let sin = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in.self) }
            var raw = sin.sin_addr
            let bytes = withUnsafeBytes(of: &raw) { Data($0) }
            guard let host = IPv4Address(bytes),
                  let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: sin.sin_port)) else {
                return nil
            }
            return .hostPort(host: .ipv4(host), port: port)
        }
        if family == AF_INET6 {
            let sin6 = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in6.self) }
            var raw = sin6.sin6_addr
            guard let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: sin6.sin6_port)) else {
                return nil
            }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count)) != nil else {
                return nil
            }
            // NWPathMonitor.currentPath is empty until a monitor starts, so a
            // synchronous interface lookup cannot supply a reliable scope.
            // Network's parser accepts the standard numeric zone suffix and
            // carries it into the endpoint without DNS or a monitor race.
            guard let host = IPv6Address("\(String(cString: text))%\(interfaceName)") else {
                return nil
            }
            return .hostPort(host: .ipv6(host), port: port)
        }
        return nil
    }
}
