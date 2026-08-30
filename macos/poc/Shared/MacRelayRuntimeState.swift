// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Darwin
import Foundation

/// The observable relay state. It intentionally contains no secret material.
struct MacRelayRuntimeSnapshot: Equatable {
    let started: Bool
    let active: Bool
    let sessionID: UInt64?
    let pathHandle: mqvpn_path_handle_t?
    let sendAttempts: UInt64
    let sendAgain: UInt64
    let sendFailures: UInt64
    let helloAttempts: UInt64
    let helloSent: UInt64
    let rawReceived: UInt64
    let authAccepted: UInt64
    let authRejected: UInt64
    let ackReceived: UInt64
    let lanTxBytes: UInt64
    let lanRxBytes: UInt64
    let dataToMacBytes: UInt64
    let hardFailures: UInt64
    let lastError: String?

    static let stopped = MacRelayRuntimeSnapshot(
        started: false, active: false, sessionID: nil, pathHandle: nil,
        sendAttempts: 0, sendAgain: 0, sendFailures: 0, helloAttempts: 0,
        helloSent: 0, rawReceived: 0, authAccepted: 0, authRejected: 0,
        ackReceived: 0, lanTxBytes: 0, lanRxBytes: 0, dataToMacBytes: 0,
        hardFailures: 0, lastError: nil)
}

enum MacRelayDrop: Equatable {
    case authentication
    case direction
    case session
    case replay
    case malformed
    case messageType
}

enum MacRelayInboundAction: Equatable {
    case none
    case activateLogicalPath
    case echoKeepalive(Data)
    case deliverToCore(Data, mqvpn_path_handle_t)
    case drop(MacRelayDrop)
}

enum MacRelaySessionStartResult: Equatable {
    case started
    case rejected
}

/// Pure single-queue state and portable relay-codec boundary for the macOS
/// binder. Socket I/O and libmqvpn calls live outside this type; every frame
/// is encoded/decoded by the shared C implementation rather than Swift HMAC.
struct MacRelayRuntimeState {
    private static let helloRetryMs: UInt64 = 1_000
    private static let idleProbeMs: UInt64 = 5_000
    private static let reopenDelayMs: UInt64 = 1_000

    private var key: Data?
    private let idleTimeoutMs: UInt64
    private var started = false
    private var active = false
    private var pathActivationPending = false
    private var sessionID: UInt64?
    private var lastSessionID: UInt64?
    private var pathHandle: mqvpn_path_handle_t?
    private var txSequence: UInt64 = 0
    private var rxReplay = mqvpn_replay_window_t()
    private var lastHelloMs: UInt64?
    private var lastAuthenticatedMs: UInt64?
    private var lastProbeMs: UInt64?
    private var lastFailureMs: UInt64?
    private var hardFailure = false
    private var sendAttempts: UInt64 = 0
    private var sendAgain: UInt64 = 0
    private var sendFailures: UInt64 = 0
    private var helloAttempts: UInt64 = 0
    private var helloSent: UInt64 = 0
    private var rawReceived: UInt64 = 0
    private var authAccepted: UInt64 = 0
    private var authRejected: UInt64 = 0
    private var ackReceived: UInt64 = 0
    private var lanTxBytes: UInt64 = 0
    private var lanRxBytes: UInt64 = 0
    private var dataToMacBytes: UInt64 = 0
    private var hardFailures: UInt64 = 0
    private var lastError: String?

    init(key: Data, idleTimeoutMs: UInt64 = 15_000) {
        self.key = key.count == Int(MQVPN_RELAY_KEY_SIZE) ? key : nil
        self.idleTimeoutMs = idleTimeoutMs
    }

    var canEncode: Bool { key != nil && started && sessionID != nil }

    /// Reopen and idle recovery must keep the iPhone's live lease. A new
    /// random session is rejected as `.session` until that 15s lease expires.
    func resumeSessionID() -> UInt64? {
        sessionID ?? lastSessionID
    }

    var snapshot: MacRelayRuntimeSnapshot {
        MacRelayRuntimeSnapshot(
            started: started, active: active, sessionID: sessionID,
            pathHandle: pathHandle, sendAttempts: sendAttempts, sendAgain: sendAgain,
            sendFailures: sendFailures, helloAttempts: helloAttempts,
            helloSent: helloSent, rawReceived: rawReceived,
            authAccepted: authAccepted, authRejected: authRejected,
            ackReceived: ackReceived, lanTxBytes: lanTxBytes, lanRxBytes: lanRxBytes,
            dataToMacBytes: dataToMacBytes, hardFailures: hardFailures,
            lastError: lastError)
    }

    @discardableResult
    mutating func beginSession(sessionID: UInt64, nowMs: UInt64) -> MacRelaySessionStartResult {
        guard key != nil, sessionID != 0 else { return .rejected }
        started = true
        active = false
        pathActivationPending = false
        pathHandle = nil
        if MacRelaySessionRenewal.shouldResetTransmitSequence(
            resuming: sessionID, previous: lastSessionID ?? self.sessionID) {
            txSequence = 0
            rxReplay = mqvpn_replay_window_t()
        }
        self.sessionID = sessionID
        lastSessionID = sessionID
        lastHelloMs = nil
        lastAuthenticatedMs = nowMs
        lastProbeMs = nowMs
        lastFailureMs = nil
        hardFailure = false
        lastError = nil
        return .started
    }

    mutating func encode(type: mqvpn_relay_message_type_t, payload: Data,
                         nowMs: UInt64) -> Data? {
        guard let key, let sessionID, started, payload.count <= Int(MQVPN_RELAY_MAX_PAYLOAD_SIZE)
        else { return nil }
        var datagram = [UInt8](repeating: 0,
                                count: Int(MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE +
                                           MQVPN_RELAY_TAG_SIZE))
        var datagramLength = 0
        let result = key.withUnsafeBytes { keyBytes in
            payload.withUnsafeBytes { payloadBytes in
                mqvpn_relay_encode(
                    keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), type,
                    MQVPN_RELAY_MAC_TO_IPHONE, sessionID, txSequence,
                    payloadBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), payload.count,
                    &datagram, datagram.count, &datagramLength)
            }
        }
        guard result == MQVPN_RELAY_OK else {
            lastError = "relay encode failed: \(result.rawValue)"
            return nil
        }
        txSequence &+= 1
        sendAttempts &+= 1
        if type == MQVPN_RELAY_HELLO {
            helloAttempts &+= 1
            lastHelloMs = nowMs
            lastProbeMs = nowMs
        }
        return Data(datagram.prefix(datagramLength))
    }

    /// Records the kernel boundary after `send` has written the entire frame.
    /// Encoding is an attempt only: byte counters must not claim that a packet
    /// crossed the LAN when the socket returned EAGAIN or a hard error.
    mutating func recordSuccessfulSend(type: mqvpn_relay_message_type_t,
                                       datagramLength: Int) {
        guard datagramLength > 0 else { return }
        lanTxBytes &+= UInt64(datagramLength)
        if type == MQVPN_RELAY_HELLO { helloSent &+= 1 }
    }

    mutating func recordSendAgain() {
        sendAgain &+= 1
    }

    mutating func recordSendFailure() {
        sendFailures &+= 1
    }

    mutating func receive(_ datagram: Data, nowMs: UInt64) -> MacRelayInboundAction {
        rawReceived &+= 1
        lanRxBytes &+= UInt64(datagram.count)
        guard let key, let expectedSession = sessionID, started else {
            authRejected &+= 1
            return .drop(.session)
        }
        var frame = mqvpn_relay_frame_t()
        var expected = expectedSession
        let result = key.withUnsafeBytes { keyBytes in
            datagram.withUnsafeBytes { bytes in
                mqvpn_relay_decode(
                    keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), datagram.count,
                    MQVPN_RELAY_IPHONE_TO_MAC, &expected, &frame)
            }
        }
        guard result == MQVPN_RELAY_OK else {
            authRejected &+= 1
            return .drop(dropReason(for: result))
        }
        guard mqvpn_replay_window_accept(&rxReplay, frame.sequence) == MQVPN_RELAY_OK else {
            authRejected &+= 1
            return .drop(.replay)
        }
        authAccepted &+= 1
        lastAuthenticatedMs = nowMs
        lastError = nil

        switch frame.type {
        case MQVPN_RELAY_HELLO_ACK:
            guard frame.payload_length == 0 else { return reject(.malformed) }
            ackReceived &+= 1
            guard !active, !pathActivationPending else { return .none }
            pathActivationPending = true
            return .activateLogicalPath
        case MQVPN_RELAY_DATA_TO_MAC:
            guard active, let pathHandle else { return reject(.messageType) }
            let payload = Data(bytes: frame.payload!, count: frame.payload_length)
            dataToMacBytes &+= UInt64(payload.count)
            return .deliverToCore(payload, pathHandle)
        case MQVPN_RELAY_KEEPALIVE:
            if frame.payload_length == 0 { return .none }
            guard frame.payload_length == 8, let payload = frame.payload else {
                return reject(.malformed)
            }
            return .echoKeepalive(Data(bytes: payload, count: 8))
        case MQVPN_RELAY_HELLO, MQVPN_RELAY_DATA_TO_SERVER:
            return reject(.messageType)
        default:
            return reject(.messageType)
        }
    }

    @discardableResult
    mutating func attachLogicalPath(_ handle: mqvpn_path_handle_t) -> Bool {
        guard started, sessionID != nil, handle >= 0, !hardFailure, pathActivationPending else {
            return false
        }
        pathHandle = handle
        active = true
        pathActivationPending = false
        return true
    }

    mutating func detachLogicalPath() -> mqvpn_path_handle_t? {
        let handle = pathHandle
        pathHandle = nil
        active = false
        pathActivationPending = false
        return handle
    }

    func shouldRetryHello(nowMs: UInt64) -> Bool {
        guard started, !active, !hardFailure, let lastHelloMs else { return false }
        return nowMs - lastHelloMs >= Self.helloRetryMs
    }

    func shouldProbeActiveRelay(nowMs: UInt64) -> Bool {
        guard active, !hardFailure, let lastProbeMs else { return false }
        return nowMs - lastProbeMs >= Self.idleProbeMs
    }

    /// HELLO is the path-validation analogue. After settings apply or a
    /// transport rebind, send one immediately so the iPhone can migrate the
    /// peer before idle expiry. A hard-failed or unstarted relay must not.
    func shouldHelloAfterRouteRefresh() -> Bool {
        sessionID != nil && started && !hardFailure
    }

    @discardableResult
    mutating func expireIfIdle(nowMs: UInt64) -> Bool {
        guard started, let lastAuthenticatedMs,
              nowMs - lastAuthenticatedMs > idleTimeoutMs else { return false }
        _ = detachLogicalPath()
        lastSessionID = sessionID ?? lastSessionID
        sessionID = nil
        rxReplay = mqvpn_replay_window_t()
        lastError = "relay authentication expired"
        return true
    }

    mutating func hardSocketFailure(nowMs: UInt64, error: String) {
        _ = detachLogicalPath()
        lastSessionID = sessionID ?? lastSessionID
        sessionID = nil
        rxReplay = mqvpn_replay_window_t()
        hardFailure = true
        lastFailureMs = nowMs
        hardFailures &+= 1
        lastError = error
    }

    func shouldReopenSocket(nowMs: UInt64) -> Bool {
        guard hardFailure, let lastFailureMs else { return false }
        return nowMs - lastFailureMs >= Self.reopenDelayMs
    }

    mutating func stop() {
        // No in-place key scrub: Data's copy-on-write means resetBytes would
        // zero a fresh copy while the original key bytes are freed unzeroed.
        self = MacRelayRuntimeState(key: Data(), idleTimeoutMs: idleTimeoutMs)
    }

    private mutating func reject(_ reason: MacRelayDrop) -> MacRelayInboundAction {
        authRejected &+= 1
        return .drop(reason)
    }

    private func dropReason(for result: mqvpn_relay_result_t) -> MacRelayDrop {
        switch result {
        case MQVPN_RELAY_ERR_WRONG_DIRECTION: return .direction
        case MQVPN_RELAY_ERR_WRONG_SESSION: return .session
        case MQVPN_RELAY_ERR_AUTH_FAILED: return .authentication
        default: return .malformed
        }
    }
}

enum MacRelaySessionRenewal {
    /// Continuing the same lease keeps the transmit sequence and replay
    /// window; a genuinely new session must reset both.
    static func shouldResetTransmitSequence(resuming: UInt64, previous: UInt64?) -> Bool {
        previous != resuming
    }
}

enum MacRelayEndpointSafety {
    static func isLocalEndpoint(_ endpoint: String, localIPv4Addresses: [String]) -> Bool {
        let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return localIPv4Addresses.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }
    }
}
