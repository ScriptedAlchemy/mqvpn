# macOS Network Extension client — 2026-08-24 acceptance

Historical measurements for the build below; unchecked items are not a current
task list. See [Apple clients](../apple-clients.md) for validation guidance.

Branch: `codex/lan-relay`  
Workspace: `/Volumes/bigssd/projects/mqvpn`  
HEAD: `5c3a32d` plus uncommitted Bonjour / IPv6 LAN-relay work  
Team: `5NDMQZP6KR`  
App: `com.zackjackson.mqvpn.mac`  
Provider: `com.zackjackson.mqvpn.mac.PacketTunnel`  
iPhone: Zack iPhone 17 Pro Max, UDID `00008150-001E2D282E87801C`

Host tests and CTest are not Task 6 evidence. This report records physical
receipts only.

## Product constraints that stayed true

- One Mac-owned mqvpn session. The iPhone is a LAN-to-cellular relay, not a
  second client.
- Relay authentication is only `src/relay_protocol.c` HMAC. Bonjour publishes
  address and port, never the key.
- Default IPv4 routes are installed only after `tunnel_config_ready`.
- `includeAllNetworks` / `excludeLocalNetworks` / `enforceRoutes` stay on
  `NETunnelProviderProtocol`, not on tunnel settings.
- The public server remains IPv4 (`208.69.79.206:443`). The Mac↔iPhone hop
  may be IPv6.
- The IPv4 overlay must not claim `::/0`. That blackholes AAAA and, after
  HELLO/ACK, makes the iPhone ULA return `No route to host`.
- Reinstalling `/Applications/MqvpnMac.app` unloads the running packet-tunnel
  process. Do not rebuild over a live Task 6 session.

## Proven on the physical LAN

| Gate | Result | Receipt |
|---|---|---|
| Other full-tunnel VPNs disconnected | Speedify and Tailscale were Disconnected during runs | `scutil --nc list` |
| Visible mqvpn profile | Profile `1FC034C4-2D09-478D-8881-ABEF9568781A` exists | `scutil --nc list` |
| Bonjour auto-discovery | No typed relay IP. Dashboard reports detected host:port | `_mqvpn-relay._udp` on app + provider |
| HELLO / ACK before default routes | Authenticated on the live LAN before `setTunnelNetworkSettings` | Codex Task 6 run |
| Direct GT egress | `api.ipify.org` returned `208.69.79.206`; default via `utun13`; assigned `10.77.77.23` | curl + `scutil --nc status mqvpn` |
| Tunnel gateway | `ping 10.77.77.1` 0% loss, ~112 ms | ICMP |
| One client, two paths (transient) | Server showed path 0 + path 1; session held >37 s | Codex + CT 212 status |
| Relay then dropped | After settings apply, ULA ND failed (`No route to host`); server left path 0 only | Codex + `ping6` |
| Link-local still live | `fe80::c91:b241:f238:d0bb%en1` 0% loss while ULA ND died | `dns-sd` + `ping6` |
| ZeroFS HTTP alias | `http://10.77.77.55:8080/` → **200** while the tunnel was up | curl |
| ZeroFS WebSocket | `ws://10.77.77.55:8080/ws/9p` → **101 Switching Protocols** | curl upgrade |
| Rebuild kills VPN | Signed reinstall at 02:14:45 terminated the extension; not a relay bug | Codex |

## Code now installed for the remaining relay hole

The installed Mac Release at 02:29:28 prefers a **scoped link-local** Bonjour
address over ULA/IPv4, keeps `%en1` on the sockaddr, does not install `::/0`,
and does not unbind the relay socket on a transient `getifaddrs` miss.

Mac and iOS host tests pass. That is not Task 6 evidence.

## Still open (physical only)

- [ ] Failed-Start with the server unreachable: no default route installed
- [ ] Direct-loss, relay-loss, then both-loss fail-open (ordinary Internet after 5 s)
- [ ] Three 60 s reps each of direct-only, relay-only, and combined; medians,
      per-path bytes, CPU, drops
- [ ] Combined median ≥ `1.05 * max(single paths)` and each path ≥ 5% plus 32 MiB
- [ ] ZeroFS uploader `zerofs upload ws://10.77.77.55:8080/ws/9p … --jobs 1 --resume`
      to completion with a destination receipt
- [ ] Clean Stop restoration after the next successful two-path hold
- [ ] Dynamic Island: start from the real relay/VPN runtime, real counters,
      background updates, end on Stop (extension build alone is not enough)

Peering is out of lane.

## How to finish the open gates

1. Leave this checkout. Do not start a second `xcodebuild` on
   `macos/DerivedData-signed` over a live profile.
2. Confirm the iPhone Mac Relay shows **RELAY READY** (both LAN and cellular
   sockets). Bonjour publishes only then.
3. Start the Mac profile once. Dashboard should show `fe80::…%en1`, not
   `192.168.1.42` and not the ULA.
4. On CT 212: `mqvpn --status --control-port 9090` must show one client and
   two active paths, with both byte counters moving.
5. Run the 60 s benches and the ZeroFS resume upload only after that hold.
6. Record numbers in this file; then commit the report.
