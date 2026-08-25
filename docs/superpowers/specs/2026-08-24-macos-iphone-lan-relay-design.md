# macOS Client with iPhone Cellular LAN Relay Design

## Goal

Let the existing macOS `mqvpn` CLI own one VPN session and aggregate two real
server-facing paths:

1. A direct Mac path over the Mac's normal Wi-Fi/Ethernet uplink.
2. A relayed path carried over the local Wi-Fi LAN to an iPhone, then sent by
   the iPhone over its cellular interface to the same mqvpn server.

The iPhone is a constrained UDP relay for the Mac-owned QUIC connection. It is
not a router, hotspot, second mqvpn client, general proxy, or source of Mac IP
packets.

## Product surface

Keep the first usable version intentionally small:

- macOS keeps the existing root-run CLI. No macOS GUI, login item, launchd
  service, account system, or automatic discovery is added.
- macOS configuration gains one optional `[Relay]` section with an iPhone LAN
  endpoint and a separate relay key file.
- The iOS app gains an operating-mode choice: `VPN` or `Mac Relay`.
- Relay mode reuses the existing server host, server port, Start/Stop controls,
  and status dashboard. It adds only a relay key and a LAN listen port.
- The user enters the iPhone's Wi-Fi address in the Mac config for v1. Bonjour,
  QR pairing, and roaming discovery are explicitly deferred.

## Existing components retained

- The Linux mqvpn server and its Hybrid TCP implementation are unchanged.
- The macOS CLI continues to own utun, default routes, DNS, the pf kill switch,
  direct UDP sockets, and the libmqvpn client.
- The iOS VPN mode continues to operate as a full-device packet tunnel.
- Direct physical mqvpn paths remain fd-backed. Only the relayed logical path
  uses the callback-backed path API.

## Traffic flow

```text
Mac application
  -> macOS utun
  -> Mac libmqvpn / one QUIC connection
       -> direct path: Mac Wi-Fi/Ethernet UDP -> GT server UDP 443
       -> relay path: authenticated LAN UDP -> iPhone Wi-Fi listener
                     -> iPhone cellular-bound UDP -> GT server UDP 443
                     <- server response over cellular
                     <- authenticated LAN UDP -> Mac callback path
  -> GT server decrypts the one client session
  -> Internet or private vmbr1 destination
```

The server must observe one client session with two path tuples. A second iOS
mqvpn client session is not aggregation and does not satisfy this design.

## Callback-backed libmqvpn path

The public API already describes an fd-less `ops path` and exposes
`send_packet`; the implementation must complete that contract.

- `mqvpn_client_add_path_fd_with_outcome(client, -1, desc, outcome)` is accepted
  only when a result-bearing send callback is present.
- Add an ABI-appended optional callback:

  ```c
  typedef ssize_t (*mqvpn_send_packet_ex_fn)(
      mqvpn_path_handle_t path,
      const uint8_t *packet,
      size_t length,
      const struct sockaddr *peer,
      socklen_t peer_length,
      void *user_context);
  ```

- Return `length` for success, `-EAGAIN` for temporary backpressure, and another
  negative errno value for a hard failure. Existing fd paths and the legacy
  void callback remain source/ABI compatible.
- xquic output for an ops path invokes this callback and accounts bytes against
  the correct logical path. It never calls `sendto(-1, ...)`.
- Relayed replies enter the existing
  `mqvpn_client_on_socket_recv(client, handle, packet, length, peer, peer_len)`
  API, preserving xquic path attribution.
- Missing callback, partial send, invalid handle, or hard callback failure fails
  closed and is observable in path state/counters.

## Relay wire protocol

LAN packets carry already encrypted mqvpn QUIC datagrams. The relay framing
adds authorization, integrity, direction, liveness, and replay protection; it
does not re-encrypt the QUIC payload.

Every datagram is:

```text
fixed v1 header | opaque QUIC payload | 16-byte authentication tag
```

The fixed, network-byte-order header contains:

- magic `MQR1`
- version `1`
- message type: `HELLO`, `HELLO_ACK`, `DATA_TO_SERVER`, `DATA_TO_MAC`, or
  `KEEPALIVE`
- direction bit
- 64-bit random session identifier
- 64-bit monotonically increasing sequence number
- 16-bit payload length
- reserved fields required to be zero

The tag is the first 16 bytes of HMAC-SHA256 over `header || payload`, using a
dedicated 32-byte relay key. The key is Base64 in the iOS configuration and in
a root-readable Mac key file; it is never accepted on a command line, written
to logs, stored in Proxmox Notes, or reused as the server authentication PSK.

Each direction has an independent 64-packet replay window. Frames with an
unknown version/type, invalid length, invalid tag, wrong direction, stale
session, replayed sequence, or payload exceeding the LAN datagram bound are
dropped. The codec is portable C and is linked by both Darwin and iOS so one
implementation owns the security boundary.

## Relay session lifecycle

- Mac generates a random session identifier and sends authenticated `HELLO`
  frames to the configured iPhone LAN endpoint.
- iPhone accepts one authenticated Mac session at a time and replies with
  `HELLO_ACK`.
- Only after the ACK does the Mac add/activate the logical mqvpn path.
- iPhone sends all `DATA_TO_SERVER` payloads to the single configured mqvpn
  server address and port over a socket bound to the cellular interface class.
  There is no destination field and no arbitrary forwarding.
- Replies from that connected cellular socket are wrapped as `DATA_TO_MAC` and
  returned only to the authenticated Mac LAN endpoint.
- Either side expires the relay after 15 seconds without authenticated data or
  keepalive traffic. Mac then removes the relay path while retaining its direct
  path and retries pairing with bounded backoff.
- Stop closes all LAN/cellular sockets and erases session/replay state.

## macOS integration

Example configuration:

```ini
[Relay]
Enabled = true
Endpoint = 192.168.1.195:5443
KeyFile = /etc/mqvpn/relay.key
Interface = en1
```

- `Endpoint` must be a numeric LAN IPv4 plus UDP port for v1.
- `KeyFile` must decode to exactly 32 bytes and must not be group/world
  readable.
- `Interface` is optional. When present, the LAN socket is bound to that
  interface; otherwise the route to the numeric endpoint selects the LAN path.
- The iPhone endpoint receives a scoped host-route exclusion outside utun and
  a narrow pf kill-switch allowance, just like the server endpoint exclusions.
- Relay startup counts as a second path only after authenticated HELLO/ACK.
- Relay loss removes only the relay path. Ctrl-C/SIGTERM still restores routes,
  DNS, pf state, and utun through existing cleanup.

## iOS relay mode

Relay mode runs inside the existing `NEPacketTunnelProvider` so it remains
alive in the background, but it must not capture iPhone application traffic.

- The provider applies a non-routing packet-tunnel configuration with no
  default included route and no DNS override.
- It does not instantiate `MqvpnEngine`, `PathBinder`, or a second mqvpn
  client.
- It opens a Wi-Fi-bound LAN UDP listener and a cellular-bound connected UDP
  socket to the configured server.
- If Wi-Fi or cellular is absent, the relay remains started but reports the
  missing side and does not fabricate an active path.
- Settings are fail-closed: relay mode cannot Start without valid server data,
  a 32-byte relay key, and a valid listen port.
- Dashboard state distinguishes `VPN connected` from `Relay ready`, displays
  LAN/cellular byte counters, and never labels a mere listener as a bonded path.

## Stop/disconnect correctness

The existing iOS Stop path must be corrected before relay mode builds on it.

- Manager loading selects only the configuration whose provider bundle ID
  exactly matches the current PacketTunnel extension. It never blindly uses
  `loadAllFromPreferences().first` and never deletes other VPN profiles.
- Stop is disabled when no matching manager exists or the manager is already
  down.
- A Stop request visibly transitions to `disconnecting`, observes
  `NEVPNStatusDidChange`, and reports success only at `.disconnected`.
- Provider teardown must always complete even when its engine was never
  created or its tick thread already exited. No checked continuation may be
  left unresumed.
- Physical acceptance requires the VPN route to disappear and a fresh egress
  check to stop showing the GT public IP.

## Private ZeroFS service alias

CT 212 already shares private bridge `10.10.10.0/24` with ZeroFS CT 198 and
can reach `10.10.10.55:8080` directly. Tailscale is unnecessary for this path.

- `10.77.77.55:8080` inside mqvpn DNATs to `10.10.10.55:8080`.
- The rule matches only packets entering `mqvpn0` from `10.77.77.0/24` and only
  TCP port 8080.
- Existing mqvpn SNAT makes CT 198 see source `10.10.10.212`, providing the
  return path.
- No public listener is added. Public exposure remains UDP 443 only.
- The Mac uploader uses `ws://10.77.77.55:8080/ws/9p`, avoiding the Mac's
  competing Tailscale host route for `10.10.10.55`.

## Security boundaries

- Relay PSK and server PSK are separate.
- Relay frames are authenticated before state mutation or forwarding.
- iPhone relay forwards only to the configured mqvpn server UDP endpoint.
- Mac pins both the server and iPhone LAN endpoint outside its utun.
- Proxmox control port 9090 remains loopback-only.
- Proxmox Notes contain topology and operational guidance but no secrets.
- Public UDP 443 remains a pre-auth QUIC/TLS parser and DoS surface; tunnel or
  private-network access still requires authentication.

## Performance and acceptance

The user-observed GT-host download samples on August 24, 2026 are:

- Wi-Fi: 9.63 and 10.4 MB/s.
- Cellular: 61.1 MB/s.
- Raw arithmetic ceiling: 70.7-71.5 MB/s before protocol overhead.

Therefore bonding can be about six to seven times faster than the current
Wi-Fi result, but only about 16-17 percent faster than the cellular sample.
The implementation must not promise more capacity than the measured inputs.

Acceptance uses three 60-second runs for Wi-Fi only, cellular relay only, and
both paths, against the same GT-host payload. A combined run passes only when:

- the server reports one client with two active paths;
- both per-path byte counters increase materially during the run;
- combined median download exceeds the faster single-path median by at least
  5 percent; and
- Stop/failover tests continue over the surviving path without reconnecting
  the Mac VPN.

The optimization loop records server/phone/Mac CPU, per-path RTT/loss/cwnd,
mqvpn0 qdisc drops, UDP socket errors, MTU, Hybrid selection, and application
throughput. MTU, reorder buffering, socket buffers, GRO, qdisc, and scheduler
weights are changed one variable at a time only after evidence identifies the
limiter.

## Deferred work

- macOS GUI/menu-bar app
- automatic LAN discovery or QR pairing
- multiple simultaneous relay phones
- general tailnet routing from CT 212
- relay of arbitrary destinations or non-mqvpn traffic
- App Store distribution
