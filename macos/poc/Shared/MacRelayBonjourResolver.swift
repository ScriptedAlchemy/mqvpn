// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// Synchronous Bonjour lookup for PacketTunnel Start. Network.framework browse
/// missed services the host `dns-sd` already saw; Foundation Bonjour plus the
/// A records on the resolved service is the path that works in the extension.
enum MacRelayBonjourResolver {
    static func resolve(timeout: TimeInterval = 3.0) -> MacRelayEndpoint? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = ServiceLookup().resolve(timeout: timeout)
            done.signal()
        }
        thread.start()
        _ = done.wait(timeout: .now() + timeout + 1)
        return box.value
    }

    static func endpoint(from service: NetService) -> MacRelayEndpoint? {
        let port = service.port
        if let chosen = MacRelayDiscovery.choose(port: port,
                                                 addresses: service.addresses ?? []) {
            return chosen
        }
        guard var host = service.hostName, !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard let resolved = resolveRelayEndpoint(host, port),
              let ip = resolved.ipString else { return nil }
        return MacRelayDiscovery.choose([MacRelayEndpoint(host: ip, port: port)])
    }

    private final class Box: @unchecked Sendable {
        var value: MacRelayEndpoint?
    }

    private final class ServiceLookup: NSObject,
        NetServiceBrowserDelegate, NetServiceDelegate {
        private let browser = NetServiceBrowser()
        private var services: [NetService] = []
        private var result: MacRelayEndpoint?
        private var deadline = Date()

        func resolve(timeout: TimeInterval) -> MacRelayEndpoint? {
            deadline = Date().addingTimeInterval(max(0.1, timeout))
            browser.includesPeerToPeer = false
            browser.delegate = self
            browser.searchForServices(ofType: MqvpnRelayBonjour.serviceTypeWithDot,
                                      inDomain: MqvpnRelayBonjour.domain)
            while result == nil, Date() < deadline {
                _ = RunLoop.current.run(mode: .default,
                                        before: min(deadline, Date().addingTimeInterval(0.05)))
            }
            stop()
            return result
        }

        private func stop() {
            browser.stop()
            browser.delegate = nil
            services.forEach {
                $0.stop()
                $0.delegate = nil
            }
            services.removeAll()
        }

        func netServiceBrowser(_ browser: NetServiceBrowser,
                               didFind service: NetService,
                               moreComing: Bool) {
            services.append(service)
            service.delegate = self
            service.resolve(withTimeout: max(0.1, deadline.timeIntervalSinceNow))
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            guard let chosen = MacRelayBonjourResolver.endpoint(from: sender) else { return }
            result = chosen
            browser.stop()
        }
    }
}

/// Continuous dashboard discovery. Authentication remains the relay HMAC;
/// Bonjour publishes only the iPhone's LAN address and UDP listen port.
final class MacRelayBonjourBrowser: NSObject,
    NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var endpoints: [ObjectIdentifier: MacRelayEndpoint] = [:]
    var onChange: ((MacRelayEndpoint?) -> Void)?

    func start() {
        stop()
        browser.includesPeerToPeer = false
        browser.delegate = self
        browser.searchForServices(ofType: MqvpnRelayBonjour.serviceTypeWithDot,
                                  inDomain: MqvpnRelayBonjour.domain)
    }

    func stop() {
        browser.stop()
        browser.delegate = nil
        services.forEach {
            $0.stop()
            $0.delegate = nil
        }
        services.removeAll()
        endpoints.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        endpoints.removeValue(forKey: ObjectIdentifier(service))
        services.removeAll { $0 === service }
        publishSelection()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let chosen = MacRelayBonjourResolver.endpoint(from: sender) else { return }
        endpoints[ObjectIdentifier(sender)] = chosen
        publishSelection()
    }

    func netService(_ sender: NetService,
                    didNotResolve errorDict: [String: NSNumber]) {
        endpoints.removeValue(forKey: ObjectIdentifier(sender))
        publishSelection()
    }

    private func publishSelection() {
        let sorted = endpoints.values.sorted {
            ($0.host, $0.port) < ($1.host, $1.port)
        }
        onChange?(MacRelayDiscovery.choose(sorted))
    }
}
