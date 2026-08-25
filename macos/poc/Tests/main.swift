// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

// The production changes these provider-plan tests catch are: installing a
// full-tunnel route before server authentication, omitting either physical
// endpoint exclusion, applying the wrong address/DNS/MTU, failing to bound an
// established all-path outage, or reporting Stop before transport teardown.
let networkPlan = MacProviderNetworkPlan(
    assignedAddress: "10.77.77.10", assignedPrefix: 24, mtu: 1_382,
    serverIPv4: "208.69.79.206", relayIPv4: "192.168.1.42")
check(networkPlan.includedRoutes == [MacIPv4Route(address: "0.0.0.0", prefix: 0)],
      "the authenticated Mac tunnel includes exactly the IPv4 default route")
check(networkPlan.excludedRoutes == [
    MacIPv4Route(address: "208.69.79.206", prefix: 32),
    MacIPv4Route(address: "192.168.1.42", prefix: 32),
], "the public server and iPhone LAN peer receive exact /32 exclusions")
check(networkPlan.assignedAddress == "10.77.77.10" &&
      networkPlan.subnetMask == "255.255.255.0" && networkPlan.mtu == 1_382 &&
      networkPlan.dnsServers == ["1.1.1.1", "8.8.8.8"],
      "the server address, prefix, MTU, and explicit tunnel DNS survive planning")
let directOnlyPlan = MacProviderNetworkPlan(
    assignedAddress: "10.77.77.10", assignedPrefix: 24, mtu: 1_382,
    serverIPv4: "208.69.79.206", relayIPv4: nil)
check(directOnlyPlan.excludedRoutes == [MacIPv4Route(address: "208.69.79.206", prefix: 32)],
      "direct-only planning still excludes the public server and never requires a relay")
let relayKey = Data(repeating: 0x5a, count: 32).base64EncodedString()
check((try? MacRelaySettings.startConfiguration(from: nil)) == nil &&
      (try? MacRelaySettings.startConfiguration(from: [:])) == nil,
      "absent Mac relay keys stay direct-only")
do {
    _ = try MacRelaySettings.startConfiguration(from: ["macRelayEnabled": true])
    check(false, "an enabled but incomplete relay configuration must fail Start")
} catch {
    check((error as NSError).code == 20,
          "an enabled but incomplete relay configuration fails closed")
}
let parsedRelay = try? MacRelaySettings.startConfiguration(from: [
    "macRelayEnabled": true, "macRelayHost": "192.168.1.42",
    "macRelayPort": 5443, "macRelayKey": relayKey,
])
check(parsedRelay?.host == "192.168.1.42" && parsedRelay?.isValid == true,
      "a complete enabled Mac relay configuration is accepted")

var startupTimeout = MacProviderLifecycle()
check(startupTimeout.begin(nowMs: 0) == .none && !startupTimeout.settingsRequested,
      "starting probes does not request Network Extension routes")
check(startupTimeout.activePathCountChanged(1, nowMs: 100) == .none &&
      !startupTimeout.settingsRequested,
      "a locally active path alone cannot install routes before server authentication")
check(startupTimeout.startupTimerFired(nowMs: 10_000) == .failStart &&
      !startupTimeout.settingsRequested,
      "startup expiry fails before any default route was requested")

var lifecycle = MacProviderLifecycle()
check(lifecycle.begin(nowMs: 0) == .none,
      "provider startup begins in preflight without applying settings")
check(lifecycle.tunnelConfigurationReady() == .applyNetworkSettings &&
      lifecycle.settingsRequested,
      "real tunnel configuration is the sole settings-install gate")
check(lifecycle.networkSettingsApplied(error: false) == .completeStart &&
      lifecycle.isEstablished,
      "successful Network Extension settings complete Start")
check(lifecycle.activePathCountChanged(0, nowMs: 1_000) ==
      .beginRecovery(deadlineMs: 6_000),
      "all-path loss starts the exact five-second fail-open window")
check(lifecycle.activePathCountChanged(1, nowMs: 5_999) == .endRecovery &&
      lifecycle.isEstablished,
      "a recovered path before the deadline clears reasserting")
check(lifecycle.activePathCountChanged(0, nowMs: 8_000) ==
      .beginRecovery(deadlineMs: 13_000) &&
      lifecycle.recoveryTimerFired(nowMs: 12_999) == .none &&
      lifecycle.recoveryTimerFired(nowMs: 13_000) == .cancelTunnel,
      "an unrecovered five-second outage cancels the tunnel")

var failedSettings = MacProviderLifecycle()
_ = failedSettings.begin(nowMs: 0)
_ = failedSettings.tunnelConfigurationReady()
check(failedSettings.networkSettingsApplied(error: true) == .failStart,
      "a settings failure cannot become a connected VPN")

var stopping = MacProviderLifecycle()
_ = stopping.begin(nowMs: 0)
check(stopping.beginStop() == [.relay, .direct, .snapshot, .engine] &&
      stopping.beginStop().isEmpty,
      "Stop is idempotent and orders relay before direct, snapshot, and engine")

let snapshotStore = MacProviderSnapshotStore()
let providerSnapshot = MacProviderSnapshot(
    timestamp: 123, clientState: 4, connectedSince: 100, footprint: 4_096,
    reasserting: false, lastError: nil,
    paths: [MacProviderPathSnapshot(name: "en1", status: 1,
                                    txBytes: 10, rxBytes: 20)], relay: nil)
snapshotStore.publish(providerSnapshot)
check(snapshotStore.read() == providerSnapshot,
      "the arbitrary app-message thread reads the latest immutable provider snapshot")
check((try? MacProviderSnapshot.decode(providerSnapshot.encoded())) == providerSnapshot,
      "the Mac provider snapshot has one round-trippable app-message wire format")
snapshotStore.clear()
check(snapshotStore.read() == nil,
      "Stop clears stale app-facing state instead of presenting a disconnected session as live")

let lanCandidates = [
    MacLANInterfaceCandidate(name: "en5", kind: .wiredEthernet,
                             address: "192.168.1.20", netmask: "255.255.255.0"),
    MacLANInterfaceCandidate(name: "en1", kind: .wifi,
                             address: "192.168.1.195", netmask: "255.255.255.0"),
    MacLANInterfaceCandidate(name: "en9", kind: .wifi,
                             address: "10.0.0.2", netmask: "255.255.255.0"),
]
check(MacLANInterfaceSelector.select(relayIPv4: "192.168.1.42",
                                     candidates: lanCandidates) == "en1",
      "the live Wi-Fi subnet is preferred over wired Ethernet for iPhone relay LAN traffic")
check(MacLANInterfaceSelector.select(relayIPv4: "172.16.0.4",
                                     candidates: lanCandidates) == nil,
      "relay preflight fails honestly when no live local subnet reaches the iPhone")

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
check(hello != nil && state.snapshot.helloAttempts == 1 && state.snapshot.helloSent == 0 &&
      state.snapshot.lanTxBytes == 0 && !state.snapshot.active,
      "encoding a HELLO records an attempt but never claims a kernel send")
state.recordSendAgain()
check(state.snapshot.sendAgain == 1 && state.snapshot.helloSent == 0 &&
      state.snapshot.lanTxBytes == 0,
      "EAGAIN is surfaced separately and does not inflate byte counters")
state.recordSuccessfulSend(type: MQVPN_RELAY_HELLO, datagramLength: hello!.count)
check(state.snapshot.helloSent == 1 && state.snapshot.lanTxBytes == UInt64(hello!.count),
      "only a full socket send contributes HELLO and LAN byte counters")
let attemptedData = state.encode(type: MQVPN_RELAY_DATA_TO_SERVER, payload: Data([1]), nowMs: 101)
state.recordSendFailure()
check(attemptedData != nil && state.snapshot.sendAttempts == 2 &&
      state.snapshot.sendFailures == 1 && state.snapshot.lanTxBytes == UInt64(hello!.count),
      "hard send failure remains distinct from a successful encoded datagram")
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

// ── Real UDP binder lifecycle ──
// This is intentionally a real localhost UDP peer, not a socket mock. The
// production binder binds lo0, sends its C-codec HELLO, receives a separately
// C-codec-authenticated ACK, registers a real logical core path, and then
// proves that Stop's completion observes engine-hook removal and key erasure.
func loopbackListener() -> (fd: Int32, port: Int)? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
        close(fd); return nil
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { close(fd); return nil }
    var actual = sockaddr_in()
    var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &actualLength)
        }
    }
    guard named == 0 else { close(fd); return nil }
    return (fd, Int(UInt16(bigEndian: actual.sin_port)))
}

func waitUntil(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return predicate()
}

if let listener = loopbackListener(),
   let relayAddress = resolveServer("127.0.0.1", listener.port),
   let serverAddress = resolveServer("127.0.0.1", listener.port) {
    let peerQueue = DispatchQueue(label: "mqvpn.mac.relay.hosttest.peer")
    var phoneSequence: UInt64 = 1
    let peerSource = DispatchSource.makeReadSource(fileDescriptor: listener.fd, queue: peerQueue)
    peerSource.setEventHandler {
        var bytes = [UInt8](repeating: 0,
                             count: Int(MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE +
                                        MQVPN_RELAY_TAG_SIZE))
        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(listener.fd, &bytes, bytes.count, 0, $0, &peerLength)
            }
        }
        guard count > 0 else { return }
        var frame = mqvpn_relay_frame_t()
        let decoded = key.withUnsafeBytes { keyBytes in
            mqvpn_relay_decode(keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                bytes, Int(count), MQVPN_RELAY_MAC_TO_IPHONE,
                                nil, &frame)
        }
        guard decoded == MQVPN_RELAY_OK, frame.type == MQVPN_RELAY_HELLO else { return }
        var ack = [UInt8](repeating: 0,
                          count: Int(MQVPN_RELAY_HEADER_SIZE + MQVPN_RELAY_MAX_PAYLOAD_SIZE +
                                     MQVPN_RELAY_TAG_SIZE))
        var ackLength = 0
        let encoded = key.withUnsafeBytes { keyBytes in
            mqvpn_relay_encode(keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                MQVPN_RELAY_HELLO_ACK, MQVPN_RELAY_IPHONE_TO_MAC,
                                frame.session_id, phoneSequence, nil, 0,
                                &ack, ack.count, &ackLength)
        }
        guard encoded == MQVPN_RELAY_OK else { return }
        phoneSequence &+= 1
        _ = withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(listener.fd, ack, ackLength, 0, $0, peerLength)
            }
        }
    }
    peerSource.setCancelHandler { close(listener.fd) }
    peerSource.resume()

    let beforeStartEngine = MqvpnEngine()
    let beforeStartBinder = MacRelayBinder(engine: beforeStartEngine,
                                           relayEndpoint: relayAddress,
                                           serverPeer: serverAddress,
                                           interfaceName: "lo0", relayKey: key,
                                           localIPv4Addresses: [])!
    let beforeStartStop = DispatchSemaphore(value: 0)
    beforeStartBinder.stop {
        check(beforeStartBinder.snapshot() == .stopped && beforeStartEngine.onLogicalPathSend == nil,
              "stop-before-start erases the key state and clears the engine callback")
        beforeStartStop.signal()
    }
    check(beforeStartStop.wait(timeout: .now() + 2) == .success,
          "stop-before-start supplies a real completion boundary")

    let liveEngine = MqvpnEngine()
    let liveServer = ServerSettings(host: "127.0.0.1", port: listener.port,
                                    serverName: "", authKey: "host-test", insecure: true)
    liveEngine.start(server: liveServer, serverAddr: serverAddress)
    let liveBinder = MacRelayBinder(engine: liveEngine, relayEndpoint: relayAddress,
                                    serverPeer: serverAddress, interfaceName: "lo0",
                                    relayKey: key, localIPv4Addresses: [])!
    liveBinder.start()
    check(waitUntil({ liveBinder.snapshot().active }),
          "real interface-bound UDP HELLO/ACK activates the logical relay path")
    let activeSnapshot = liveBinder.snapshot()
    check(activeSnapshot.helloSent >= 1 && activeSnapshot.lanTxBytes > 0 &&
          activeSnapshot.ackReceived >= 1,
          "real full UDP send, ACK, and non-secret counters agree")
    let capturedSend = liveEngine.onLogicalPathSend
    let raceStarted = DispatchSemaphore(value: 0)
    let raceFinished = DispatchSemaphore(value: 0)
    if let capturedSend, let activeHandle = activeSnapshot.pathHandle {
        DispatchQueue.global(qos: .userInitiated).async {
            raceStarted.signal()
            _ = capturedSend(activeHandle, Data([0x42]))
            raceFinished.signal()
        }
        _ = raceStarted.wait(timeout: .now() + 1)
    } else {
        check(false, "active relay exposes its production logical-send callback")
    }
    // Hold the real engine tick thread before calling Stop twice. Both calls
    // therefore queue behind one actual pending cleanup fence, making an
    // early second completion observable rather than timing-dependent.
    let tickEntered = DispatchSemaphore(value: 0)
    let releaseTick = DispatchSemaphore(value: 0)
    check(liveEngine.perform {
        tickEntered.signal()
        _ = releaseTick.wait(timeout: .now() + 2)
    }, "host test can place a real tick-thread fence before concurrent Stop")
    check(tickEntered.wait(timeout: .now() + 1) == .success,
          "engine tick thread reached the concurrent Stop fence")
    let firstStop = DispatchSemaphore(value: 0)
    let secondStop = DispatchSemaphore(value: 0)
    let completionLock = NSLock()
    var completionObservedLiveHook = false
    let callers = DispatchGroup()
    for done in [firstStop, secondStop] {
        callers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            liveBinder.stop {
                let clean = liveBinder.snapshot() == .stopped && liveEngine.onLogicalPathSend == nil
                completionLock.lock()
                completionObservedLiveHook = completionObservedLiveHook || !clean
                completionLock.unlock()
                done.signal()
            }
            callers.leave()
        }
    }
    callers.wait()
    _ = liveBinder.snapshot() // drains both stop jobs while the tick fence is held
    check(firstStop.wait(timeout: .now()) == .timedOut &&
          secondStop.wait(timeout: .now()) == .timedOut,
          "neither concurrent Stop completion runs before the shared tick cleanup fence")
    releaseTick.signal()
    check(firstStop.wait(timeout: .now() + 3) == .success &&
          secondStop.wait(timeout: .now() + 3) == .success,
          "all concurrent Stop callers complete after one tick-thread teardown")
    completionLock.lock()
    let completionWasEarly = completionObservedLiveHook
    completionLock.unlock()
    check(!completionWasEarly,
          "each Stop completion observes erased state and a cleared engine callback")
    check(raceFinished.wait(timeout: .now() + 1) == .success,
          "a concurrent real logical send cannot deadlock Stop teardown")
    if let capturedSend, let activeHandle = activeSnapshot.pathHandle {
        check(capturedSend(activeHandle, Data([0x43])) == -Int(ENODEV),
              "a callback captured before Stop fails closed without queueing behind teardown")
    }
    let engineStop = DispatchSemaphore(value: 0)
    _ = liveEngine.perform {
        liveEngine.shutdown()
        engineStop.signal()
    }
    check(engineStop.wait(timeout: .now() + 2) == .success,
          "engine remains safe to shut down after relay completion")
    peerSource.cancel()
} else {
    check(false, "real UDP relay lifecycle fixture binds a loopback listener")
}

if failures != 0 {
    print("macOS relay host tests: \(failures) failure(s)")
    exit(1)
}
print("macOS relay host tests: PASS")
