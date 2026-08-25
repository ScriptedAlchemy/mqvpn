// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owned, by-value resolved server address. The addrinfo pointer is never
/// retained (freeaddrinfo runs before return); mqvpn_client_set_server_addr
/// copies these bytes immediately, so there is no lifetime hazard.
struct ResolvedServerAddress {
    var storage: sockaddr_storage
    var len: socklen_t
}

/// Resolve host+port to an IPv4 sockaddr. AF_INET only (iOS PoC path fds and
/// the assigned tunnel address are v4). Returns nil on empty/whitespace host
/// (getaddrinfo("") resolves to 127.0.0.1 — must self-guard), resolver failure,
/// or a non-v4 / unexpected-length result.
func resolveServer(_ host: String, _ port: Int) -> ResolvedServerAddress? {
    resolveAddress(host, port, family: AF_INET)
}

/// Resolve a local relay endpoint over either IP family. The public mqvpn
/// server remains IPv4-only; this is used only for the Bonjour LAN hop.
func resolveRelayEndpoint(_ host: String, _ port: Int) -> ResolvedServerAddress? {
    ResolvedServerAddress.fromIPLiteral(host, port: port)
        ?? resolveAddress(host, port, family: AF_UNSPEC)
}

private func resolveAddress(_ host: String, _ port: Int,
                            family: Int32) -> ResolvedServerAddress? {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var hints = addrinfo()
    hints.ai_family = family
    hints.ai_socktype = SOCK_DGRAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(trimmed, String(port), &hints, &res) == 0, let first = res else { return nil }
    defer { freeaddrinfo(res) }

    var current: UnsafeMutablePointer<addrinfo>? = first
    while let ai = current {
        defer { current = ai.pointee.ai_next }
        let length = ai.pointee.ai_addrlen
        guard let addr = ai.pointee.ai_addr,
              (ai.pointee.ai_family == AF_INET || ai.pointee.ai_family == AF_INET6),
              length <= socklen_t(MemoryLayout<sockaddr_storage>.size) else { continue }
        var out = ResolvedServerAddress(storage: sockaddr_storage(), len: length)
        withUnsafeMutableBytes(of: &out.storage) { dst in
            dst.baseAddress!.copyMemory(from: addr, byteCount: Int(length))
        }
        return out
    }
    return nil
}

extension ResolvedServerAddress {
    /// PacketTunnel must not depend on getaddrinfo for a Bonjour numeric peer.
    /// `fe80::1%en1` keeps `sin6_scope_id` so connect stays on Wi‑Fi.
    static func fromIPLiteral(_ host: String, port: Int) -> ResolvedServerAddress? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (1...65_535).contains(port) else { return nil }
        let parts = trimmed.split(separator: "%", maxSplits: 1,
                                  omittingEmptySubsequences: false)
        let literal = parts.first.map(String.init) ?? trimmed
        let zone = parts.count == 2 ? String(parts[1]) : nil
        var out = ResolvedServerAddress(storage: sockaddr_storage(), len: 0)
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = in_port_t(UInt16(port).bigEndian)
        if literal.withCString({ inet_pton(AF_INET, $0, &sin.sin_addr) }) == 1 {
            out.len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutableBytes(of: &out.storage) { dst in
                withUnsafeBytes(of: sin) { src in dst.copyMemory(from: src) }
            }
            return out
        }
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_port = in_port_t(UInt16(port).bigEndian)
        if let zone {
            let index = zone.withCString { if_nametoindex($0) }
            if index != 0 { sin6.sin6_scope_id = index }
        }
        if literal.withCString({ inet_pton(AF_INET6, $0, &sin6.sin6_addr) }) == 1 {
            out.len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutableBytes(of: &out.storage) { dst in
                withUnsafeBytes(of: sin6) { src in dst.copyMemory(from: src) }
            }
            return out
        }
        return nil
    }

    /// Numeric IP literal for the owned sockaddr. IPv6 link-local addresses
    /// include their interface scope so a later socket connect is unambiguous.
    var ipString: String? {
        var sa = storage
        let family = Int32(sa.ss_family)
        return withUnsafeBytes(of: &sa) { raw -> String? in
            switch family {
            case AF_INET:
                let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
                var addr = sin.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: buf)
            case AF_INET6:
                let sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee
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
            default:
                return nil
            }
        }
    }
}
