# Offsite mqvpn LXC and Physical iPhone Design

## Goal

Create a production mqvpn endpoint on the offsite GTHost Proxmox node and install the source-built mqvpn iOS client on the user's physical iPhone. The iPhone is the single mqvpn bonding client. It combines its Wi-Fi path with its own cellular path and sends traffic through the offsite server.

This design does not bond traffic originating on the Mac. The Mac may provide the iPhone's Wi-Fi uplink through Internet Sharing when the Mac has a non-Wi-Fi upstream.

## Confirmed live infrastructure

- Proxmox node: `tor-sm2124bt-htr-5-4`, reached administratively through `gthost-tor-pve-root`
- Proxmox: 9.2.10, kernel 7.0.14-11-pve
- Public IPv4: `208.69.79.206`
- Public interface: `enp65s0f0`
- Private bridge and gateway: `vmbr1`, `10.10.10.1/24`
- Available container identity: CT 212 at `10.10.10.212/24`
- Available public service port: UDP 443
- Storage: `local`
- Debian 12 template: `debian-12-standard_12.12-1_amd64.tar.zst`
- Host `/dev/net/tun` exists and Proxmox supports `dev[n]` passthrough
- The Proxmox firewall is enabled with inbound DROP and outbound ACCEPT

## Server architecture

Create CT 212 as `mqvpn-server` with:

- Debian 12
- Unprivileged LXC
- 2 vCPU
- 1 GiB RAM
- 8 GiB local disk
- Static IPv4 `10.10.10.212/24`, gateway `10.10.10.1`
- Start at boot enabled
- `/dev/net/tun` passed as `dev0`
- No nesting, privileged mode, Docker, or globally unconfined AppArmor profile

The existing host SNAT gives the container outbound Internet access. Persistent host DNAT forwards `208.69.79.206:443/UDP` to `10.10.10.212:443/UDP`. Matching forwarding rules permit only this inbound public service. The container firewall accepts UDP 443 and drops other unsolicited inbound traffic. mqvpn's unauthenticated control interface remains bound to `127.0.0.1:9090` inside the container and is never forwarded.

Install the current stable mqvpn release from the official GitHub release assets. Verify the downloaded installer against the release checksum or artifact digest before execution. Configure tunnel subnet `10.77.77.0/24`, enable Hybrid mode on the server, and leave the UDP reorder buffer disabled initially. Store the generated PSK securely without printing it into logs or task artifacts.

## iPhone architecture

Build the upstream mqvpn repository and its iOS Network Extension on the Mac. Use a user-owned bundle identifier and the user's Apple development team for both the application and PacketTunnel extension. Do not embed the real PSK in the generated project; configure it at runtime in the installed app.

Install and run the application on the user's connected physical iPhone. Enable the Packet Tunnel entitlement, Developer Mode, and VPN configuration as required. Disable competing packet-tunnel VPNs on the iPhone during mqvpn operation.

Configure the client to connect to public IPv4 `208.69.79.206`, UDP 443, using the generated PSK, self-signed-certificate insecure mode, Hybrid enabled, TCP Auto, and reorder disabled. The client must use separately bound Wi-Fi and cellular sockets.

## Verification gates

Server completion requires all of the following:

1. CT 212 is unprivileged, autostarts, has the specified resource limits, and has no nesting.
2. `/dev/net/tun` is a character device inside the container.
3. `mqvpn-server` is enabled and active after a restart.
4. UDP 443 listens in the container; `mqvpn0` exists; IPv4 forwarding is enabled.
5. Tunnel forwarding and masquerade rules exist.
6. The control interface listens only on loopback.
7. A packet sent to the public IPv4 on UDP 443 is observed reaching CT 212.
8. Host and container firewall behavior persists without exposing TCP 443 or TCP 9090.

Physical-iPhone completion requires all of the following:

1. The app and PacketTunnel extension are signed by the same valid team and installed on the connected physical iPhone.
2. The VPN connects to the public endpoint and the iPhone's observed egress IPv4 is `208.69.79.206`.
3. Both Wi-Fi and cellular paths appear live in the application or server status.
4. A running transfer survives Wi-Fi removal and Wi-Fi restoration.
5. A running transfer survives cellular removal and cellular restoration.
6. With both paths active, per-path counters prove that both interfaces carry traffic. Combined throughput is reported as measured and is not assumed to be exactly additive.

## Failure handling and rollback

If the unprivileged container cannot perform required network-namespace operations after removing only an accidental custom capability restriction, stop and replace it with a small Debian VM. Do not make the container privileged or disable AppArmor globally.

Before changing persistent host networking or firewall files, save timestamped local copies on the Proxmox host. Apply live DNAT and forwarding rules separately from persistence, verify each rule, and remove only the exact task-owned rules during rollback. If provisioning fails before the container holds user data, stop CT 212, remove the task-owned forwarding/firewall rules, and remove CT 212 only after confirming its identity and configuration.

If iOS signing or Network Extension provisioning is unavailable for the selected Apple team, stop with the concrete signing error. Do not substitute a simulator, mock tunnel, or disconnected demo as proof of installation.
