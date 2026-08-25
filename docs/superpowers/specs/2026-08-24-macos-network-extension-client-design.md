# macOS Network Extension Client Design

## Goal

Replace the root-run macOS CLI user experience with a small macOS app and a
real `NETunnelProviderManager` VPN profile, matching the architecture used by
the installed Speedify app. The Mac owns one mqvpn session with a directly
bound physical path and an optional authenticated iPhone cellular relay path.

## Scope

The first shipping target is a development-signed macOS app with an embedded
packet-tunnel app extension. This is the quickest real Network Extension path
for this Mac and Apple team. Direct distribution with a Developer ID system
extension, notarization, login launch, and App Store packaging are deferred.

The existing CLI remains available for diagnostics, but the app never invokes
it and never runs `route`, `networksetup`, or `pfctl`.

## Product surface

- One macOS SwiftUI window with Start, Stop, status, direct/relay path rows,
  current rates, and the latest concrete error.
- One system VPN profile named `mqvpn` created and selected only by this app.
- Server and relay settings reuse the current iOS model and values.
- No account system, discovery, menu-bar helper, launch daemon, or automatic
  manipulation of Mullvad, Tailscale, or Speedify profiles.

Bundle identifiers:

- App: `com.zackjackson.mqvpn.mac`
- Provider: `com.zackjackson.mqvpn.mac.PacketTunnel`

## Architecture

```text
Mac applications
  -> Network Extension packetFlow
  -> one MqvpnEngine / one QUIC client
       -> direct UDP path bound to Wi-Fi or Ethernet
       -> logical relay path over LAN UDP to iPhone
            -> iPhone cellular UDP to 208.69.79.206:443
```

The containing app uses `NETunnelProviderManager` to create, save, load, start,
stop, and observe its own VPN profile. The provider uses
`NEPacketTunnelProvider`, `packetFlow`, and `setTunnelNetworkSettings`.

The provider reuses the existing Apple-native engine, path binder, TLS trust,
Hybrid TCP lane, and portable C relay codec. The core callback-backed path API
is exposed through `MqvpnEngine`; a Mac-specific Swift relay binder owns the LAN
socket and calls the shared C codec. Swift does not reimplement HMAC or replay
validation.

## Start and route safety

The provider starts physical direct-path probing and the authenticated relay
HELLO/ACK preflight before installing a default tunnel route. The first real
server-capable path may be direct or relay. `startTunnel` resolves successfully
only after mqvpn authentication returns tunnel configuration and Network
Extension applies it.

Network settings use:

- IPv4 default included route.
- Explicit tunnel DNS servers `1.1.1.1` and `8.8.8.8`.
- Server-provided IPv4 address and MTU.
- `/32` excluded routes for the resolved public server and iPhone LAN address.
- `includeAllNetworks = false`, `enforceRoutes = false`, and
  `excludeLocalNetworks = true`.

Provider sockets are bound to concrete physical interfaces. The system owns
route and DNS transactions; Stop or extension failure removes them without a
root cleanup script.

## Path failure behavior

The provider observes authoritative libmqvpn path events. If at least one path
survives, the VPN remains connected. If all server-capable paths disappear, it
sets `reasserting = true` and starts a five-second recovery window. Recovery
clears reasserting. Expiry calls `cancelTunnelWithError`, allowing Network
Extension to restore ordinary Internet access. The default behavior is
fail-open after the bounded recovery window; a kill switch is out of scope.

The app shows `.connected` only when the system reports it. Stop completes only
at `.disconnected` and is safe to repeat.

## Relay behavior and telemetry

The Mac relay binder:

- Rejects a relay endpoint equal to any local Mac address.
- Binds a connected UDP socket to the selected LAN interface.
- Sends authenticated HELLO frames before adding a logical mqvpn path.
- Adds the callback-backed path only after a valid HELLO_ACK.
- Feeds authenticated DATA_TO_MAC payloads to the matching core path handle.
- Reopens its socket and starts a fresh session after hard failure.
- Erases key, replay, and session state on Stop.

Telemetry distinguishes HELLO sent, raw LAN datagram received, authentication
accepted/rejected, ACK received, and forwarded bytes. A mere listener or sent
HELLO is never labeled active.

## VPN coexistence

Only mqvpn's own manager is read or changed. Other VPN profiles are preserved.
Performance tests disconnect other full-tunnel VPNs first; mqvpn does not nest
inside Mullvad, Speedify, or a Tailscale exit node. Private ZeroFS validation
uses the server-side `10.77.77.55:8080` alias rather than requiring concurrent
Tailscale routing.

## Signing and deployment

Both targets use team `5NDMQZP6KR` and the `packet-tunnel-provider` Network
Extension entitlement, matching the installed Speedify app-extension pattern.
The containing app embeds the provider. Xcode creates or downloads macOS
development provisioning profiles for both bundle identifiers. A signed build,
embedded-extension validation, and visible VPN profile are required before any
live route test.

## Acceptance

1. Direct-only Start shows the mqvpn VPN profile connected, GT egress, and a
   clean Stop restores the previous Internet path.
2. Starting with no usable server path fails without installing a default
   tunnel route.
3. The LAN preflight proves HELLO, raw receive, authentication, and ACK before
   marking relay active.
4. One server client shows direct and relay paths contributing bytes.
5. Direct loss survives through relay; relay loss survives through direct.
6. Losing both paths disconnects within the bounded recovery window and
   ordinary Internet returns without toggling Wi-Fi.
7. Fixed-condition direct-only, relay-only, and combined Mac tests show the
   combined median at least 1.05 times the faster single path, with each path
   contributing at least five percent and 32 MiB during a 60-second download.
8. `ws://10.77.77.55:8080/ws/9p` is reachable and the resumed ZeroFS audiobook
   upload produces a durable destination receipt.

