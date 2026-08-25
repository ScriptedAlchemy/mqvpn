// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Darwin
import Foundation

extension MacProviderRelaySnapshot {
    init(_ snapshot: MacRelayRuntimeSnapshot) {
        started = snapshot.started
        active = snapshot.active
        helloSent = snapshot.helloSent
        rawReceived = snapshot.rawReceived
        authAccepted = snapshot.authAccepted
        authRejected = snapshot.authRejected
        ackReceived = snapshot.ackReceived
        lanTxBytes = snapshot.lanTxBytes
        lanRxBytes = snapshot.lanRxBytes
        dataToMacBytes = snapshot.dataToMacBytes
        sendAgain = snapshot.sendAgain
        sendFailures = snapshot.sendFailures
        hardFailures = snapshot.hardFailures
        lastError = snapshot.lastError
    }
}

/// Lock-protected one-way handoff from the engine tick thread to arbitrary
/// app-message threads. It contains values only; readers never touch libmqvpn.
final class MacProviderSnapshotStore {
    private let lock = NSLock()
    private var latest: MacProviderSnapshot?

    func publish(_ snapshot: MacProviderSnapshot) {
        lock.lock()
        latest = snapshot
        lock.unlock()
    }

    func read() -> MacProviderSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }
}

/// Tick-thread snapshot producer for the macOS packet-tunnel provider.
final class SnapshotCache {
    private let engine: MqvpnEngine
    private let store = MacProviderSnapshotStore()
    private let metadataLock = NSLock()
    private var relay: MacProviderRelaySnapshot?
    private var isReasserting = false
    private var lastError: String?
    private var timer: Timer?
    private var connectedSince: Double?

    init(engine: MqvpnEngine) {
        self.engine = engine
    }

    func start() {
        collect()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.collect()
        }
        RunLoop.current.add(timer, forMode: .default)
        self.timer = timer
    }

    /// Tick-thread-only lifecycle stop, invoked before engine shutdown.
    func stop() {
        timer?.invalidate()
        timer = nil
        store.clear()
    }

    func read() -> MacProviderSnapshot? { store.read() }

    func updateRelay(_ snapshot: MacRelayRuntimeSnapshot) {
        metadataLock.lock()
        relay = MacProviderRelaySnapshot(snapshot)
        metadataLock.unlock()
    }

    func updateLifecycle(reasserting: Bool, error: String?) {
        metadataLock.lock()
        isReasserting = reasserting
        lastError = error
        metadataLock.unlock()
    }

    private func collect() {
        let state = engine.state()
        let now = Date().timeIntervalSince1970
        if state == MQVPN_STATE_ESTABLISHED {
            if connectedSince == nil { connectedSince = now }
        } else {
            connectedSince = nil
        }
        let paths = engine.paths().map { path -> MacProviderPathSnapshot in
            let name = withUnsafeBytes(of: path.name) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            return MacProviderPathSnapshot(name: name, status: Int32(path.status.rawValue),
                                           txBytes: path.bytes_tx, rxBytes: path.bytes_rx)
        }
        metadataLock.lock()
        let relay = relay
        let reasserting = isReasserting
        let error = lastError
        metadataLock.unlock()
        store.publish(MacProviderSnapshot(
            timestamp: now, clientState: Int32(state.rawValue),
            connectedSince: connectedSince, footprint: Self.physFootprint(),
            reasserting: reasserting, lastError: error, paths: paths, relay: relay))
    }

    private static func physFootprint() -> UInt64 {
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
