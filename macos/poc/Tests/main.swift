// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

let key = Data(repeating: 0x5a, count: Int(MQVPN_RELAY_KEY_SIZE))
let session: UInt64 = 0x0102_0304_0506_0708

// The production changes that these tests catch are: emitting a HELLO only
// once, accepting unauthenticated/wrong-direction/wrong-session/replayed
// frames, marking a listener active before an ACK, forwarding DATA before a
// logical path exists, retaining credentials after Stop, or treating a local
// address as a safe relay endpoint.
var state = MacRelayRuntimeState(key: key, idleTimeoutMs: 15_000)
check(state.beginSession(sessionID: session, nowMs: 100) == .started,
      "a fresh nonzero session starts")
let hello = state.encode(type: MQVPN_RELAY_HELLO, payload: Data(), nowMs: 100)
check(hello != nil && state.snapshot.helloSent == 1 && !state.snapshot.active,
      "initial HELLO uses the shared codec but does not activate the relay")
check(state.shouldRetryHello(nowMs: 1_099) == false &&
      state.shouldRetryHello(nowMs: 1_100),
      "unacknowledged HELLO is retried after one second")

func phoneFrame(_ type: mqvpn_relay_message_type_t,
                sessionID: UInt64 = session,
                sequence: UInt64,
                payload: Data = Data(),
                signingKey: Data = key,
                direction: mqvpn_relay_direction_t = MQVPN_RELAY_IPHONE_TO_MAC) -> Data {
    var out = [UInt8](repeating: 0,
                       count: Int(MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE +
                                  MQVPN_RELAY_TAG_SIZE))
    var length = 0
    let rc = signingKey.withUnsafeBytes { keyBytes in
        payload.withUnsafeBytes { payloadBytes in
            mqvpn_relay_encode(
                keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), type, direction,
                sessionID, sequence,
                payloadBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), payload.count,
                &out, out.count, &length)
        }
    }
    precondition(rc == MQVPN_RELAY_OK)
    return Data(out.prefix(length))
}

let badTag = phoneFrame(MQVPN_RELAY_HELLO_ACK, sequence: 1,
                        signingKey: Data(repeating: 0xa5, count: Int(MQVPN_RELAY_KEY_SIZE)))
check(state.receive(badTag, nowMs: 101) == .drop(.authentication) &&
      state.snapshot.authRejected == 1 && !state.snapshot.active,
      "invalid HMAC is rejected before activation")

let wrongDirection = phoneFrame(MQVPN_RELAY_HELLO_ACK, sequence: 1,
                                direction: MQVPN_RELAY_MAC_TO_IPHONE)
check(state.receive(wrongDirection, nowMs: 102) == .drop(.direction),
      "MAC-to-iPhone datagrams are rejected on the inbound relay socket")
let wrongSession = phoneFrame(MQVPN_RELAY_HELLO_ACK, sessionID: session + 1, sequence: 1)
check(state.receive(wrongSession, nowMs: 103) == .drop(.session),
      "a valid but wrong session cannot take over the relay")

let ack = phoneFrame(MQVPN_RELAY_HELLO_ACK, sequence: 2)
check(state.receive(ack, nowMs: 104) == .activateLogicalPath &&
      state.snapshot.ackReceived == 1 && state.snapshot.authAccepted == 1 &&
      !state.snapshot.active,
      "only a valid HELLO_ACK requests logical-path registration")
let beforeAttach = phoneFrame(MQVPN_RELAY_DATA_TO_MAC, sequence: 3, payload: Data([9, 8, 7]))
check(state.receive(beforeAttach, nowMs: 104) == .drop(.messageType),
      "DATA_TO_MAC cannot reach the core before logical-path registration")
check(state.attachLogicalPath(44) && state.snapshot.active && state.snapshot.pathHandle == 44,
      "relay becomes active only after the engine accepts its callback path")

let toMac = phoneFrame(MQVPN_RELAY_DATA_TO_MAC, sequence: 4, payload: Data([9, 8, 7]))
check(state.receive(toMac, nowMs: 105) == .deliverToCore(Data([9, 8, 7]), 44) &&
      state.snapshot.dataToMacBytes == 3,
      "authenticated DATA_TO_MAC is delivered to the matching logical path")
check(state.receive(toMac, nowMs: 106) == .drop(.replay),
      "duplicate authenticated data is rejected by the shared replay window")

state.hardSocketFailure(nowMs: 107, error: "ECONNRESET")
check(state.snapshot.hardFailures == 1 && !state.snapshot.active &&
      state.shouldReopenSocket(nowMs: 1_106) == false &&
      state.shouldReopenSocket(nowMs: 1_107),
      "hard socket failure removes its path and waits one second before reopen")
check(state.beginSession(sessionID: session + 2, nowMs: 1_107) == .started &&
      state.snapshot.sessionID == session + 2 && state.snapshot.pathHandle == nil,
      "reopen starts a fresh session with no inherited logical path")

let expiredACK = phoneFrame(MQVPN_RELAY_HELLO_ACK, sessionID: session + 2, sequence: 1)
check(state.receive(expiredACK, nowMs: 1_108) == .activateLogicalPath && state.attachLogicalPath(45),
      "new session can authenticate after reopen")
check(state.expireIfIdle(nowMs: 16_108) == false &&
      state.expireIfIdle(nowMs: 16_109),
      "relay expires only after the full fifteen-second authenticated idle window")
check(!state.snapshot.active && state.snapshot.pathHandle == nil,
      "expiry removes the logical callback path")

check(MacRelayEndpointSafety.isLocalEndpoint("192.168.1.20",
                                              localIPv4Addresses: ["192.168.1.20"]),
      "relay endpoint equal to a local address is rejected")
check(!MacRelayEndpointSafety.isLocalEndpoint("192.168.1.42",
                                               localIPv4Addresses: ["192.168.1.20"]),
      "a distinct LAN peer remains eligible")
check(MacRelayTransportGeneration.accepts(capturedGeneration: 7, currentGeneration: 7,
                                          capturedFD: 12, currentFD: 12, stopped: false) &&
      !MacRelayTransportGeneration.accepts(capturedGeneration: 7, currentGeneration: 8,
                                           capturedFD: 12, currentFD: 12, stopped: false) &&
      !MacRelayTransportGeneration.accepts(capturedGeneration: 8, currentGeneration: 8,
                                           capturedFD: 12, currentFD: 12, stopped: true),
      "stale or stopped DispatchSource events are rejected before they can reuse an fd")

state.stop()
check(state.snapshot == .stopped && !state.canEncode,
      "Stop clears active/session/replay state and erases the relay key")

if failures != 0 {
    print("macOS relay host tests: \(failures) failure(s)")
    exit(1)
}
print("macOS relay host tests: PASS")
