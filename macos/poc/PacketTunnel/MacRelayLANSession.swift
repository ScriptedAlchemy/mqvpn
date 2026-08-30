// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// Owns the Mac relay binder, its current LAN interface, and the periodic
/// rebind monitor. The provider asks for a relay at a resolved peer; this
/// type keeps the transport-first stop fence when the interface moves.
final class MacRelayLANSession {
    typealias BinderFactory = (String) -> MacRelayBinder?
    typealias InterfacePicker = (String) -> String?

    private let queue: DispatchQueue
    private let pickInterface: InterfacePicker
    private var makeBinder: BinderFactory?
    private var binder: MacRelayBinder?
    private var interfaceName: String?
    private var timer: DispatchSourceTimer?
    var onUnavailable: (() -> Void)?

    init(queue: DispatchQueue, pickInterface: @escaping InterfacePicker) {
        self.queue = queue
        self.pickInterface = pickInterface
    }

    func start(relayIPv4: String, makeBinder: @escaping BinderFactory) -> Bool {
        self.makeBinder = makeBinder
        return install(relayIPv4: relayIPv4)
    }

    func armMonitor(relayIPv4: String, isStopping: @escaping () -> Bool) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, !isStopping() else { return }
            self.reconcile(relayIPv4: relayIPv4, isStopping: isStopping)
        }
        timer.resume()
        self.timer = timer
    }

    func cancelMonitor() {
        timer?.cancel()
        timer = nil
    }

    func refreshConnectedRoute(completion: @escaping () -> Void) {
        guard let binder else {
            completion()
            return
        }
        binder.refreshConnectedRoute(completion: completion)
    }

    func takeBinderForTeardown() -> MacRelayBinder? {
        let old = binder
        binder = nil
        interfaceName = nil
        return old
    }

    private func install(relayIPv4: String) -> Bool {
        guard let makeBinder,
              let interface = pickInterface(relayIPv4),
              let relay = makeBinder(interface)
        else { return false }
        binder = relay
        interfaceName = interface
        relay.start()
        return true
    }

    private func reconcile(relayIPv4: String, isStopping: @escaping () -> Bool) {
        guard MacRelayRebindPolicy.rebindTarget(current: interfaceName,
                                                desired: pickInterface(relayIPv4)) != nil
        else { return }
        let old = takeBinderForTeardown()
        let install: () -> Void = { [weak self] in
            self?.queue.async {
                guard let self, !isStopping(), self.binder == nil else { return }
                // install() re-picks the interface itself; landing on a
                // different live interface than the probe that triggered the
                // rebind is still a working binder. Only a failed install is
                // genuinely "unavailable".
                if !self.install(relayIPv4: relayIPv4) {
                    self.onUnavailable?()
                }
            }
        }
        if let old { old.stop(completion: install) } else { install() }
    }
}
