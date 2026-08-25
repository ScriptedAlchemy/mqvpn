// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// Provider-to-app relay telemetry. `isReady` means both physical sides exist
/// and one Mac has authenticated; merely binding a LAN port is never surfaced
/// as a bonded/ready path.
struct RelaySnapshot: Codable, Equatable {
    let wifiAvailable: Bool
    let cellularAvailable: Bool
    let authenticatedSession: Bool
    let listenerInterface: String?
    let cellularInterface: String?
    let lanRxBytes: UInt64
    let lanTxBytes: UInt64
    let serverRxBytes: UInt64
    let serverTxBytes: UInt64
    let lastAuthenticated: Double?
    let error: String?

    var isReady: Bool {
        wifiAvailable && cellularAvailable && authenticatedSession
    }

    static let stopped = RelaySnapshot(
        wifiAvailable: false, cellularAvailable: false,
        authenticatedSession: false, listenerInterface: nil,
        cellularInterface: nil, lanRxBytes: 0, lanTxBytes: 0,
        serverRxBytes: 0, serverTxBytes: 0,
        lastAuthenticated: nil, error: nil)
}

enum RelayDashboard {
    static func statusLabel(tunnelStatus: TunnelStatus,
                            snapshot: TunnelSnapshot?) -> String {
        guard tunnelStatus == .connected || tunnelStatus == .reasserting else {
            return tunnelStatus == .connecting ? "Relay starting" : "Relay stopped"
        }
        return snapshot?.relay?.isReady == true ? "Relay ready" : "Relay waiting"
    }
}

/// Pure description of the settings applied by relay mode. The provider maps
/// this to NetworkExtension types; host tests can enforce the security
/// boundary without depending on NetworkExtension.
struct RelayNetworkPlan: Equatable {
    let includedIPv4Routes: [String]
    let dnsServers: [String]

    static let nonRouting = RelayNetworkPlan(includedIPv4Routes: [], dnsServers: [])
}

enum RelayInterfaceClass: Equatable {
    case wifi
    case cellular
}

struct RelaySocketPlan: Equatable {
    let lanListener: RelayInterfaceClass
    let fixedServer: RelayInterfaceClass

    static let fixed = RelaySocketPlan(lanListener: .wifi, fixedServer: .cellular)
}

struct RelayPeerIdentity: Equatable {
    let bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }
}

enum RelayFrameType: Equatable {
    case hello
    case helloAck
    case dataToServer
    case dataToMac
    case keepalive
}

struct RelayInboundFrame: Equatable {
    let type: RelayFrameType
    let sessionID: UInt64
    let sequence: UInt64
    let payload: Data
    let peer: RelayPeerIdentity
    /// Set only after the shared C codec validates the HMAC and direction.
    let authenticated: Bool
    /// Set only after the shared C replay window accepts the sequence.
    let replayAccepted: Bool
}

enum RelayDropReason: Equatable {
    case authentication
    case unavailable
    case replay
    case session
    case peer
    case messageType
    case payload
}

/// Effects emitted by the pure state machine and executed by RelayEngine on
/// its serial queue. The server-forwarding action intentionally contains no
/// address: the production socket is connected once to the configured server,
/// making arbitrary destinations unrepresentable.
enum RelayStateAction: Equatable {
    case openWifi(String)
    case closeWifi
    case openCellular(String)
    case closeCellular
    case sendHelloAck(sessionID: UInt64)
    case forwardToFixedServer(Data)
    case drop(RelayDropReason)
}

struct RelaySessionState {
    private let idleTimeout: Double
    private var wifiInterface: String?
    private var cellularInterface: String?
    private var sessionID: UInt64?
    private var peer: RelayPeerIdentity?
    private var lastAuthenticated: Double?
    private var lanRxBytes: UInt64 = 0
    private var lanTxBytes: UInt64 = 0
    private var serverRxBytes: UInt64 = 0
    private var serverTxBytes: UInt64 = 0
    private var error: String?

    init(idleTimeout: Double = 15) {
        self.idleTimeout = idleTimeout
    }

    var activeSessionID: UInt64? { sessionID }
    var activePeer: RelayPeerIdentity? { peer }

    var snapshot: RelaySnapshot {
        RelaySnapshot(
            wifiAvailable: wifiInterface != nil,
            cellularAvailable: cellularInterface != nil,
            authenticatedSession: sessionID != nil,
            listenerInterface: wifiInterface,
            cellularInterface: cellularInterface,
            lanRxBytes: lanRxBytes, lanTxBytes: lanTxBytes,
            serverRxBytes: serverRxBytes, serverTxBytes: serverTxBytes,
            lastAuthenticated: lastAuthenticated, error: error)
    }

    @discardableResult
    mutating func updateInterfaces(wifi: String?, cellular: String?) -> [RelayStateAction] {
        var actions: [RelayStateAction] = []
        if wifi != wifiInterface {
            if wifiInterface != nil { actions.append(.closeWifi) }
            wifiInterface = wifi
            clearSession()
            if let wifi { actions.append(.openWifi(wifi)) }
        }
        if cellular != cellularInterface {
            if cellularInterface != nil { actions.append(.closeCellular) }
            cellularInterface = cellular
            if let cellular { actions.append(.openCellular(cellular)) }
        }
        return actions
    }

    mutating func handleMacFrame(_ frame: RelayInboundFrame, now: Double) -> [RelayStateAction] {
        guard frame.authenticated else { return [.drop(.authentication)] }

        switch frame.type {
        case .hello:
            guard wifiInterface != nil, cellularInterface != nil else {
                return [.drop(.unavailable)]
            }
            guard frame.payload.isEmpty else { return [.drop(.payload)] }
            if let current = sessionID {
                guard current == frame.sessionID else { return [.drop(.session)] }
                guard peer == frame.peer else { return [.drop(.peer)] }
            }
            guard frame.replayAccepted else { return [.drop(.replay)] }
            if sessionID == nil {
                sessionID = frame.sessionID
                peer = frame.peer
            }
            lastAuthenticated = now
            error = nil
            return [.sendHelloAck(sessionID: frame.sessionID)]

        case .dataToServer, .keepalive:
            guard sessionID == frame.sessionID else { return [.drop(.session)] }
            guard peer == frame.peer else { return [.drop(.peer)] }
            guard frame.replayAccepted else { return [.drop(.replay)] }
            if frame.type == .keepalive && !frame.payload.isEmpty {
                return [.drop(.payload)]
            }
            lastAuthenticated = now
            error = nil
            if frame.type == .dataToServer {
                return [.forwardToFixedServer(frame.payload)]
            }
            return []

        case .helloAck, .dataToMac:
            return [.drop(.messageType)]
        }
    }

    @discardableResult
    mutating func expireIfIdle(now: Double) -> Bool {
        guard let lastAuthenticated,
              now - lastAuthenticated > idleTimeout else { return false }
        clearSession()
        return true
    }

    mutating func recordLanReceive(_ count: Int) {
        if count > 0 { lanRxBytes &+= UInt64(count) }
    }

    mutating func recordLanSend(_ count: Int) {
        if count > 0 { lanTxBytes &+= UInt64(count) }
    }

    mutating func recordServerReceive(_ count: Int) {
        if count > 0 { serverRxBytes &+= UInt64(count) }
    }

    mutating func recordServerSend(_ count: Int) {
        if count > 0 { serverTxBytes &+= UInt64(count) }
    }

    mutating func recordError(_ message: String?) {
        error = message
    }

    mutating func stop() -> [RelayStateAction] {
        var actions: [RelayStateAction] = []
        if wifiInterface != nil { actions.append(.closeWifi) }
        if cellularInterface != nil { actions.append(.closeCellular) }
        self = RelaySessionState(idleTimeout: idleTimeout)
        return actions
    }

    private mutating func clearSession() {
        sessionID = nil
        peer = nil
        lastAuthenticated = nil
    }
}
