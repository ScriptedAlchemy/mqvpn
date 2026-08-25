// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Darwin
import Foundation
import SystemConfiguration

/// One Darwin scrape for on-link Wi-Fi/Ethernet candidates and local IPv4
/// addresses. The selector, not this enumerator, chooses the relay interface.
enum MacLANInterfaceEnumerator {
    static func onLinkInterface(reaching relayHost: String) -> String? {
        MacLANInterfaceSelector.interfaceName(reaching: relayHost, candidates: candidates())
    }

    static func localIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        for cursor in sequence(first: list, next: { $0.pointee.ifa_next }) {
            guard let address = cursor.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  let text = ipv4Text(address)
            else { continue }
            addresses.append(text)
        }
        return addresses
    }

    static func candidates() -> [MacLANInterfaceCandidate] {
        let kinds = Dictionary(uniqueKeysWithValues: (SCNetworkInterfaceCopyAll() as NSArray)
            .compactMap { $0 as! SCNetworkInterface? }
            .compactMap { interface -> (String, MacLANInterfaceKind)? in
                guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
                else { return nil }
                if type == kSCNetworkInterfaceTypeIEEE80211 as String { return (name, .wifi) }
                if type == kSCNetworkInterfaceTypeEthernet as String { return (name, .wiredEthernet) }
                return nil
            })
        guard !kinds.isEmpty else { return [] }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [] }
        defer { freeifaddrs(list) }
        var candidates: [MacLANInterfaceCandidate] = []
        for cursor in sequence(first: list, next: { $0.pointee.ifa_next }) {
            let entry = cursor.pointee
            guard let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
                  (entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  netmask.pointee.sa_family == sa_family_t(AF_INET),
                  let name = String(validatingUTF8: entry.ifa_name), let kind = kinds[name],
                  let ip = ipv4Text(address), let mask = ipv4Text(netmask)
            else { continue }
            candidates.append(MacLANInterfaceCandidate(name: name, kind: kind,
                                                       address: ip, netmask: mask))
        }
        return candidates
    }

    private static func ipv4Text(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var storage = sockaddr_storage()
        memcpy(&storage, address, Int(address.pointee.sa_len))
        var sin = withUnsafeBytes(of: &storage) {
            $0.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
        }
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sin.sin_addr, &output, socklen_t(output.count)) != nil else {
            return nil
        }
        return String(cString: output)
    }
}
