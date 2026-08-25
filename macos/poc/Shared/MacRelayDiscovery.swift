// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import Darwin

struct MacRelayEndpoint: Equatable {
    let host: String
    let port: Int
}

/// Pure picker used by Start and the dashboard. Bonjour may publish several
/// records. After the Mac IPv4 tunnel comes up, the iPhone ULA stops answering
/// neighbor discovery while link-local on Wi‑Fi stays reachable. Prefer a
/// scoped `fe80::` address. The public mqvpn server stays IPv4.
enum MacRelayDiscovery {
    static func choose(_ endpoints: [MacRelayEndpoint]) -> MacRelayEndpoint? {
        let valid = endpoints.filter { (1...65_535).contains($0.port) }
        if let scoped = valid.first(where: {
            isLinkLocalIPv6($0.host) && interfaceName(for: $0) != nil
        }) {
            return scoped
        }
        if let linkLocal = valid.first(where: { isLinkLocalIPv6($0.host) }) {
            return linkLocal
        }
        if let routedIPv6 = valid.first(where: { isIPv6($0.host) }) {
            return routedIPv6
        }
        return valid.first { isIPv4($0.host) }
    }

    /// Link-local `ipString` values include `%iface`. Use that scope when
    /// binding the relay UDP socket instead of guessing from IPv4 subnets.
    static func interfaceName(for endpoint: MacRelayEndpoint) -> String? {
        let parts = endpoint.host.split(separator: "%", maxSplits: 1,
                                        omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let name = String(parts[1])
        return name.isEmpty ? nil : name
    }

    static func statusText(enabled: Bool, endpoint: MacRelayEndpoint?) -> String {
        guard enabled else { return "optional — not configured" }
        guard let endpoint else { return "No iPhone relay found on this LAN" }
        return "iPhone relay detected at \(endpoint.host):\(endpoint.port)"
    }

    static func isIPv4(_ text: String) -> Bool {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { UInt8($0) != nil }
    }

    static func numericHost(_ text: String) -> String {
        String(text.split(separator: "%", maxSplits: 1,
                          omittingEmptySubsequences: false).first ?? Substring(text))
    }

    static func isIPv6(_ text: String) -> Bool {
        var addr = in6_addr()
        return numericHost(text).withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    static func isLinkLocalIPv6(_ text: String) -> Bool {
        guard isIPv6(text) else { return false }
        return numericHost(text).lowercased().hasPrefix("fe80:")
    }

    /// PacketTunnel cannot always resolve `*.local` via getaddrinfo. Use the
    /// records already attached to a resolved NetService instead.
    static func ipv4(fromSockaddr data: Data) -> String? {
        ipString(fromSockaddr: data, family: AF_INET)
    }

    static func ipv6(fromSockaddr data: Data) -> String? {
        ipString(fromSockaddr: data, family: AF_INET6)
    }

    static func ipString(fromSockaddr data: Data) -> String? {
        ipv6(fromSockaddr: data) ?? ipv4(fromSockaddr: data)
    }

    private static func ipString(fromSockaddr data: Data, family: Int32) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= MemoryLayout<sockaddr>.size else { return nil }
            let actual = Int32(raw.load(as: sockaddr.self).sa_family)
            guard actual == family else { return nil }
            if family == AF_INET {
                guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var addr = raw.load(as: sockaddr_in.self).sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: buf)
            }
            guard raw.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
            let sin6 = raw.load(as: sockaddr_in6.self)
            var addr = sin6.sin6_addr
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            var text = String(cString: buf)
            if sin6.sin6_scope_id != 0 {
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(sin6.sin6_scope_id, &name) != nil {
                    text += "%" + String(cString: name)
                }
            }
            return text
        }
    }

    static func choose(port: Int, addresses: [Data]) -> MacRelayEndpoint? {
        choose(addresses.compactMap { ipString(fromSockaddr: $0) }.map {
            MacRelayEndpoint(host: $0, port: port)
        })
    }
}
