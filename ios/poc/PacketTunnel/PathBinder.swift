// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import Network

/// Owns path sockets and their lifecycle. One instance per tunnel session.
/// Mobile path model: add + remove only (no drop/reactivate — those are the
/// desktop lifecycle). `slots` is confined to the tick thread: every mutation
/// AND read happens inside `engine.perform{}`. DispatchSource handlers never
/// touch it — they capture their own fd/handle at creation time.
final class PathBinder {
    /// A cancellation handler runs on `monitorQueue`, while removal decisions
    /// run on the engine tick thread. This one-shot bridge lets a provider
    /// wait until both close(fd) and the tick-thread `fdClosed` notification
    /// have happened before it destroys the core.
    private final class CancellationGate {
        private let lock = NSLock()
        private var completion: (() -> Void)?

        func setCompletion(_ completion: @escaping () -> Void) {
            lock.lock()
            self.completion = completion
            lock.unlock()
        }

        func finish() {
            lock.lock()
            let completion = self.completion
            self.completion = nil
            lock.unlock()
            completion?()
        }
    }

    private struct PathSlot {
        var handle: mqvpn_path_handle_t
        var fd: Int32
        var source: DispatchSourceRead
        var ifname: String
        var ifindex: UInt32
        let cancellationGate: CancellationGate
    }
    private let engine: MqvpnEngine
    private let interfaceTypes: [NWInterface.InterfaceType]
    /// One entry per (interface, replica). Replicas exist because consumer
    /// uplinks shape PER FLOW: measured on this link, one outer UDP flow
    /// tops out near 5-10 Mbps while two independent tunnels running at once
    /// reach ~21 Mbps combined. Every replica is a separate socket with its
    /// own source port, so each earns its own allowance and the QUIC
    /// scheduler stripes across all of them.
    struct PathKey: Hashable {
        let type: NWInterface.InterfaceType
        let replica: Int
    }
    private var slots: [PathKey: PathSlot] = [:]  // tick-thread confined
    /// Outer flows per physical interface. Four doubled throughput (5 -> 11
    /// Mbps measured) with both radios still attached. Eight starved the
    /// cellular path entirely: Wi-Fi is probed first and its replicas
    /// consumed the whole negotiated path-ID grant, so pdp_ip0 got nothing.
    /// A second radio is worth far more than a fifth flow on the first, so
    /// this stays at 4 until a raised grant is confirmed on the wire.
    private static let replicasPerInterface = 4
    private var monitors: [NWInterface.InterfaceType: NWPathMonitor] = [:]
    private var pollTimer: Timer?   // tick-thread confined
    /// Consecutive unsatisfied probe results per interface. A single stale
    /// delivery from the path daemon (documented above as stalling inside NE
    /// providers) used to tear down a carrying path instantly; the QUIC
    /// layer already evicts genuinely dead paths, so removal here waits for
    /// the daemon to say no three times in a row. Tick-thread confined.
    private var unsatisfiedStreak: [NWInterface.InterfaceType: Int] = [:]
    /// A reconcile walk is a chain across interfaces; these keep concurrent
    /// triggers from restarting it and starving the later interfaces.
    private var walkInFlight = false
    private var walkPendingRetrigger = false
    private static let removalStreak = 3
    private let monitorQueue = DispatchQueue(label: "mqvpn.poc.pathmon")

    init(engine: MqvpnEngine,
         interfaceTypes: [NWInterface.InterfaceType] = [.wifi, .cellular]) {
        self.engine = engine
        self.interfaceTypes = interfaceTypes.reduce(into: []) { ordered, type in
            if !ordered.contains(type) { ordered.append(type) }
        }
    }

    func start() {
        // One monitor per interface type: a single default NWPathMonitor only
        // reports the preferred path, so WiFi+cellular can never be held
        // simultaneously with it.
        //
        // The persistent monitors are TRIGGERS, not state sources. Their
        // update deliveries have been observed to stall for minutes inside
        // an NE provider (a WiFi-off unsatisfied arrived ~110 s late on
        // device), and a stalled monitor's currentPath is equally stale —
        // it only advances when a delivery lands. So every trigger funnels
        // into reconcile(), which probes FRESH state instead of trusting
        // the delivered snapshot.
        // Two passes: store every monitor in the dict BEFORE starting any.
        // A handler can fire the instant its monitor starts and hop
        // reconcile() onto the tick thread, which reads `monitors` — the
        // dict must not be concurrently mutated by this loop at that point.
        for type in interfaceTypes {
            let m = NWPathMonitor(requiredInterfaceType: type)
            m.pathUpdateHandler = { [weak self] _ in
                guard let self else { return }
                self.engine.perform { self.reconcile() }
            }
            monitors[type] = m
        }
        for (_, m) in monitors { m.start(queue: monitorQueue) }
        // Poll as the third trigger channel. Device measurement showed BOTH
        // event channels silent on a WiFi-off (monitor delivery stalled;
        // defaultPath unchanged because the tunnel stayed up via cellular),
        // leaving the dead path to server-side timeout. Probes read fresh
        // daemon state, so a 1 s cadence bounds off-detection at ~1-2 s
        // regardless of delivery stalls. Timer lives on the tick thread's
        // run loop (same pattern as the metrics collector).
        engine.perform { [weak self] in
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.reconcile()
            }
            RunLoop.current.add(t, forMode: .default)
            self?.pollTimer = t
        }
    }

    /// Re-derive add/remove state in configured order. Probes resolve
    /// asynchronously, so each probe only starts after the previous result
    /// was applied. The iOS default remains WiFi before cellular; macOS passes
    /// WiFi before wired Ethernet. This keeps first registration (and therefore
    /// the QUIC primary path) deterministic. Called on the tick
    /// thread from three trigger channels: persistent monitor deliveries,
    /// the provider's NEProvider.defaultPath KVO, and the 1 s poll timer.
    /// Overlapping triggers are safe: results funnel into
    /// addPath/removePath, whose guards make repeats no-ops.
    func reconcile() {
        guard !interfaceTypes.isEmpty, !monitors.isEmpty else { return }
        // One walk at a time. The walk is a chain — each interface is probed
        // in the previous one's completion — so a trigger arriving mid-walk
        // used to restart it at interface 0. With several replicas per
        // interface the first leg outlives the 1 s poll, and the restart
        // meant the SECOND interface was never reached at all: the phone
        // showed eight Wi-Fi flows and no cellular. Coalesce instead, and
        // remember that a trigger was missed so the next walk still runs.
        guard !walkInFlight else {
            walkPendingRetrigger = true
            return
        }
        walkInFlight = true
        reconcile(at: 0)
    }

    private func reconcile(at index: Int) {
        guard index < interfaceTypes.count else {
            walkInFlight = false
            if walkPendingRetrigger {
                walkPendingRetrigger = false
                reconcile()
            }
            return
        }
        probe(interfaceTypes[index]) { [weak self] in
            self?.reconcile(at: index + 1)
        }
    }

    /// One-shot fresh path lookup. A NEW NWPathMonitor registration always
    /// receives an initial update reflecting current daemon state on start,
    /// independent of any stalled long-lived monitor — that first delivery
    /// is taken as the truth, then the probe is cancelled. The probe object
    /// is kept alive by its own handler's capture until it fires.
    /// `then` runs on the tick thread after the result (or timeout) was
    /// applied.
    private func probe(_ type: NWInterface.InterfaceType,
                       then: (() -> Void)?) {
        let p = NWPathMonitor(requiredInterfaceType: type)
        var fired = false   // monitorQueue-confined (handler queue)
        p.pathUpdateHandler = { [weak self] path in
            guard !fired else { return }
            fired = true
            p.cancel()
            // Break the wrapper<->handler retain cycle: cancel() alone does
            // not release the stored Swift closure that keeps `p` alive.
            p.pathUpdateHandler = nil
            guard let self else { return }
            let iface = path.availableInterfaces.first { $0.type == type }
            self.engine.perform {   // hop to tick thread
                if path.status == .satisfied, let iface {
                    self.unsatisfiedStreak[type] = 0
                    for replica in 0 ..< Self.replicasPerInterface {
                        self.addPath(type: type, replica: replica, iface: iface)
                    }
                } else {
                    let streak = (self.unsatisfiedStreak[type] ?? 0) + 1
                    self.unsatisfiedStreak[type] = streak
                    if streak >= Self.removalStreak {
                        for replica in 0 ..< Self.replicasPerInterface {
                            self.removePath(key: PathKey(type: type, replica: replica))
                        }
                    }
                }
                then?()
            }
        }
        p.start(queue: monitorQueue)
        // The initial delivery is documented behavior but this file exists
        // because path-daemon deliveries can stall inside an NE provider —
        // bound the probe's lifetime; the next trigger simply re-probes.
        monitorQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard !fired else { return }
            fired = true
            p.cancel()
            p.pathUpdateHandler = nil
            if let self, let then { self.engine.perform { then() } }
        }
    }

    /// Socket preparation + registration. Runs on the tick thread.
    private func addPath(type: NWInterface.InterfaceType, replica: Int, iface: NWInterface) {
        let key = PathKey(type: type, replica: replica)
        if let existing = slots[key] {
            guard PathSlotRebind.shouldReplace(existingName: existing.ifname,
                                               existingIndex: existing.ifindex,
                                               incomingName: iface.name,
                                               incomingIndex: UInt32(iface.index))
            else { return }
            // Drop the stale fd first. `slots` is cleared synchronously so
            // the replacement can bind the new ifindex on this same probe.
            removePath(key: key)
        }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { log.error("socket() errno=\(errno)"); return }
        // 1. non-blocking (Darwin Swift imports fcntl with 3 args)
        let fl = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        // 2. Pre-set socket buffers. Darwin REJECTS oversize SO_SNDBUF/RCVBUF
        //    with ENOBUFS and keeps the previous value (no clamping like
        //    Linux); the core later requests 7 MiB ignoring the result, so
        //    this pre-set is what actually survives if that request fails.
        var buf: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        // 3. MANDATORY interface bind. Once the tunnel installs the default
        //    route, an unbound provider socket would route into the tunnel
        //    itself (self-capture) — binding is an invariant, not an option.
        var idx = UInt32(iface.index)
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx,
                         socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            log.error("IP_BOUND_IF(\(iface.name, privacy: .public)) errno=\(errno)")
            close(fd); return
        }
        // 4. bind(port 0) → 5. getsockname() → local addr into the descriptor
        var any = sockaddr_in()
        any.sin_family = sa_family_t(AF_INET)
        let rc = withUnsafePointer(to: &any) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { log.error("bind errno=\(errno)"); close(fd); return }
        var desc = mqvpn_path_desc_t()
        desc.struct_size = UInt32(MemoryLayout<mqvpn_path_desc_t>.size)
        desc.fd = fd
        withUnsafeMutableBytes(of: &desc.iface) { dst in
            iface.name.utf8CString.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(dst.count - 1))
            }
        }
        var lalen = socklen_t(128)
        withUnsafeMutableBytes(of: &desc.local_addr) { la in
            _ = getsockname(fd, la.baseAddress!.assumingMemoryBound(to: sockaddr.self), &lalen)
        }
        desc.local_addr_len = UInt32(lalen)
        // 6. register with the engine (we are on the tick thread already)
        let (handle, outcome) = engine.addPathFd(fd, desc: &desc)
        guard PathAddOutcomePolicy.keep(handle: handle, outcomeRaw: outcome.rawValue) else {
            // Not kept per PathAddOutcomePolicy. handle < 0: no slot was
            // granted (outcome is NOT written) and there is nothing to tell
            // the engine. handle >= 0 with a permanent rejection (outcome 2):
            // the engine slot must not stay occupied, so remove the handle
            // and report the fd close for the core's cleanup. Surface it
            // either way — this is exactly what the failover-flap gate
            // measures.
            log.error("add_path_fd failed iface=\(iface.name, privacy: .public) handle=\(handle)")
            if handle >= 0 { engine.removePath(handle) }
            close(fd)
            if handle >= 0 { engine.fdClosed(handle) }
            return
        }
        log.notice("add_path outcome=\(outcome.rawValue) iface=\(iface.name, privacy: .public)")
        // First successful path unlocks the connection (server addr + connect).
        engine.connectIfNeeded()
        // 7. Read source AFTER successful registration; the handler captures
        //    fd/handle (immutable). Datagrams arriving between add and resume
        //    just wait in the socket buffer.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: monitorQueue)
        let cancellationGate = CancellationGate()
        source.setEventHandler { [weak self] in
            self?.drainSocket(fd: fd, handle: handle)
        }
        source.setCancelHandler { [weak self] in
            // close(fd) must happen HERE: cancelling and closing synchronously
            // races an in-flight read handler against fd reuse (the classic
            // DispatchSource bug). After the close, hop to the tick thread to
            // report fd closure so the core can finish the slot's cleanup.
            close(fd)
            let queued = self?.engine.perform {
                self?.engine.fdClosed(handle)
                cancellationGate.finish()
            } ?? false
            if !queued { cancellationGate.finish() }
        }
        source.resume()
        slots[key] = PathSlot(handle: handle, fd: fd, source: source,
                               ifname: iface.name, ifindex: UInt32(iface.index),
                               cancellationGate: cancellationGate)
        log.notice("path added type=\(String(describing: type), privacy: .public) fd=\(fd) handle=\(handle)")
    }

    /// Failover teardown. Runs on the tick thread.
    /// Order: orderly engine removal first, then cancel (whose handler closes
    /// the fd and reports fd-closed back on the tick thread).
    private func removePath(key: PathKey,
                            closeCompletion: (() -> Void)? = nil) {
        let type = key.type
        guard let slot = slots.removeValue(forKey: key) else { return }
        if let closeCompletion { slot.cancellationGate.setCompletion(closeCompletion) }
        engine.removePath(slot.handle)
        slot.source.cancel()
        log.notice("path removed type=\(String(describing: type), privacy: .public) handle=\(slot.handle)")
    }

    /// Full teardown for stopTunnel. Runs on the tick thread. Runs
    /// removePath(key:) for every live slot, then cancels the monitors
    /// themselves (start() is the only other writer of `monitors`, on the
    /// caller's thread, so this is safe without extra synchronization).
    func stop(completion: @escaping () -> Void = {}) {
        pollTimer?.invalidate()
        pollTimer = nil
        let keys = Array(slots.keys)
        let group = DispatchGroup()
        for key in keys {
            group.enter()
            removePath(key: key) { group.leave() }
        }
        for (_, m) in monitors { m.cancel() }
        monitors.removeAll()
        guard !keys.isEmpty else {
            completion()
            return
        }
        // `group` drains only after every cancellation handler has closed its
        // fd and executed fdClosed on the engine tick thread. This is the
        // provider's transport-first shutdown boundary.
        group.notify(queue: monitorQueue) { [weak self] in
            guard let self else { completion(); return }
            if !self.engine.perform(completion) { completion() }
        }
    }

    /// Current (ifname, fd) per live slot, for GateMetrics' getsockopt
    /// snapshot. Tick-thread only, like all other `slots` access.
    func currentFds() -> [(String, Int32)] {
        slots.values.map { ($0.ifname, $0.fd) }
    }

    /// Drain readable datagrams; runs on monitorQueue, hops each datagram to
    /// the tick thread. Uses only its captured fd/handle — no shared state.
    private func drainSocket(fd: Int32, handle: mqvpn_path_handle_t) {
        var buf = [UInt8](repeating: 0, count: 65535)
        while true {
            var storage = sockaddr_storage()
            var slen = socklen_t(MemoryLayout<sockaddr_storage>.size)  // reset per datagram
            let n = withUnsafeMutablePointer(to: &storage) { sp in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &slen)
                }
            }
            if n <= 0 { break }  // EAGAIN → drained
            let data = Data(buf[0..<n])
            var peer = storage
            engine.perform {
                withUnsafePointer(to: &peer) { sp in
                    sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        self.engine.socketRecv(handle, data, sa, slen)
                    }
                }
            }
        }
    }
}
