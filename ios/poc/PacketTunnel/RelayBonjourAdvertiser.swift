// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import os

private let advertiserLog = Logger(subsystem: "mqvpn.poc", category: "relay-bonjour")

/// Advertises the LAN relay listen port while the iPhone listener is bound.
/// TXT records are empty — the Mac authenticates with the shared relay key.
final class RelayBonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var desiredPort: Int?

    func start(port: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.desiredPort = port
            if let existing = self.service, existing.port == port { return }
            self.stopService()
            let next = NetService(domain: MqvpnRelayBonjour.domain,
                                  type: MqvpnRelayBonjour.serviceTypeWithDot,
                                  name: MqvpnRelayBonjour.instanceName,
                                  port: Int32(port))
            next.includesPeerToPeer = false
            next.delegate = self
            next.publish()
            self.service = next
            advertiserLog.notice("relay Bonjour publish requested port=\(port, privacy: .public)")
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.desiredPort = nil
            self?.stopService()
        }
    }

    private func stopService() {
        service?.stop()
        service?.delegate = nil
        service = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard desiredPort == Int(sender.port) else {
            sender.stop()
            return
        }
        advertiserLog.notice("relay Bonjour published port=\(sender.port, privacy: .public)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        advertiserLog.error("relay Bonjour publish failed \(String(describing: errorDict), privacy: .public)")
    }
}
