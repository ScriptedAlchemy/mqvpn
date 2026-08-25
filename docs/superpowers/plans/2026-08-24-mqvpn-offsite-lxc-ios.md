# Offsite mqvpn LXC and Physical iPhone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision a real offsite mqvpn server in Proxmox CT 212 and install its source-built iOS Network Extension client on the user's physical iPhone, with verified Wi-Fi and cellular paths.

**Architecture:** CT 212 is an unprivileged Debian 12 guest on private bridge `vmbr1`; the Proxmox host persistently DNATs public UDP 443 to the guest while retaining the host's existing SNAT model. The iPhone is the single bonding client and uses separately bound Wi-Fi and cellular sockets; the Mac supplies build/signing and may supply the Wi-Fi uplink, but does not participate in the bond.

**Tech Stack:** Proxmox VE 9.2.10, unprivileged LXC, Debian 12, iptables, systemd, mqvpn v0.15.1 or the verified current stable release, Xcode 26.6, XcodeGen, CMake, Ninja, Swift, NetworkExtension, physical iOS 26.6 device.

**Spec:** `docs/superpowers/specs/2026-08-24-mqvpn-offsite-lxc-ios-design.md`

## Global Constraints

- CT 212: Debian 12, unprivileged, 2 vCPU, 1 GiB RAM, 8 GiB local disk, `10.10.10.212/24`, gateway `10.10.10.1`, autostart enabled.
- Pass `/dev/net/tun` with Proxmox `dev0`; do not enable nesting, privileged mode, Docker, or globally unconfined AppArmor.
- Public service is UDP 443 at `208.69.79.206`; do not expose TCP 443 or TCP 9090.
- Tunnel subnet is `10.77.77.0/24`; Hybrid is enabled on server and client; reorder remains disabled initially.
- The real PSK must not appear in task output, plan files, source control, generated Xcode project settings, or memory.
- A simulator, mock tunnel, disconnected adapter, or fabricated success is not physical-iPhone evidence.
- This workspace is not a Git repository. Replace commit checkpoints with timestamped remote backups and independently verified task receipts.

---

### Task 1: Provision and validate CT 212

**Files:**
- Create through Proxmox: `/etc/pve/lxc/212.conf`
- Create through Proxmox: `local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst`

**Interfaces:**
- Consumes: Proxmox node `tor-sm2124bt-htr-5-4`, bridge `vmbr1`, storage `local`
- Produces: running unprivileged CT 212 reachable at `10.10.10.212`, with `/dev/net/tun`

- [ ] **Step 1: Recheck collision-free identity immediately before creation**

Run on the host:

```bash
test ! -e /etc/pve/lxc/212.conf
! ping -c 1 -W 1 10.10.10.212
! ss -H -lun 'sport = :443' | grep .
```

Expected: all three commands succeed without identifying an existing target.

- [ ] **Step 2: Download the exact Debian 12 template if absent**

```bash
pveam update
pveam download local debian-12-standard_12.12-1_amd64.tar.zst
```

Expected: `pveam list local` contains the exact Debian 12 template.

- [ ] **Step 3: Create the unprivileged container**

```bash
pct create 212 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname mqvpn-server \
  --ostype debian \
  --arch amd64 \
  --unprivileged 1 \
  --cores 2 \
  --memory 1024 \
  --swap 512 \
  --rootfs local:8 \
  --net0 name=eth0,bridge=vmbr1,firewall=1,ip=10.10.10.212/24,gw=10.10.10.1,type=veth \
  --onboot 1 \
  --features nesting=0 \
  --start 0
pct set 212 --dev0 /dev/net/tun
pct start 212
```

Expected: `pct status 212` reports `running`.

- [ ] **Step 4: Verify all container invariants**

```bash
pct config 212
pct exec 212 -- test -c /dev/net/tun
pct exec 212 -- ip -4 addr show dev eth0
pct exec 212 -- ping -c 2 1.1.1.1
```

Expected: unprivileged is 1, nesting is 0, resources and IP match the design, TUN exists, and outbound Internet works.

### Task 2: Install and configure mqvpn

**Files:**
- Create in CT: `/etc/mqvpn/server.conf`
- Create in CT: `/etc/systemd/system/mqvpn-server.service`
- Create in CT: mqvpn binary and NAT helper installed by the verified official installer
- Create locally: a macOS Keychain generic-password item named `mqvpn-ct212-auth-key`

**Interfaces:**
- Consumes: CT 212 with TUN and outbound Internet
- Produces: loopback-controlled mqvpn server listening on UDP 443 with Hybrid enabled

- [ ] **Step 1: Install required Debian packages**

```bash
pct exec 212 -- sh -ceu 'apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl iproute2 iptables procps jq'
```

Expected: package installation exits zero.

- [ ] **Step 2: Download and verify the official installer**

Download `install.sh` and `SHA256SUMS` from the same current stable GitHub release. Verify `sha256sum -c` for `install.sh` inside CT 212 before execution.

Expected: the installer checksum is `OK`; abort on any mismatch.

- [ ] **Step 3: Install and start mqvpn**

```bash
bash /root/install.sh --start --port 443 --subnet 10.77.77.0/24 --enable-control 9090
```

Expected: the installer exits zero and creates `/etc/mqvpn/server.conf` plus an enabled service.

- [ ] **Step 4: Enable Hybrid without duplicating the section**

If `[Hybrid]` is absent, append:

```ini
[Hybrid]
Enabled = true
```

If it exists, set its `Enabled` property to `true`. Restart `mqvpn-server`.

Expected: exactly one `[Hybrid]` section exists and the service restarts successfully.

- [ ] **Step 5: Store the PSK without emitting it**

Read the `[Auth]` key inside CT 212 into a pipe and create/update the local Login Keychain item `mqvpn-ct212-auth-key` with account `208.69.79.206`. Do not echo the key or enable shell tracing.

Expected: `security find-generic-password -s mqvpn-ct212-auth-key` succeeds without requesting secret output.

- [ ] **Step 6: Verify server-local state**

```bash
systemctl is-enabled mqvpn-server
systemctl is-active mqvpn-server
ss -H -lunp 'sport = :443'
ss -H -ltnp 'sport = :9090'
ip addr show mqvpn0
sysctl net.ipv4.ip_forward
iptables -t nat -S POSTROUTING
mqvpn --status --control-port 9090
```

Expected: service enabled/active, UDP 443 listening, TCP 9090 bound only to 127.0.0.1, `mqvpn0` present, forwarding equals 1, and tunnel masquerade exists.

### Task 3: Add persistent public UDP forwarding and firewall policy

**Files:**
- Back up and modify on host: `/etc/network/interfaces`
- Create on host: `/etc/pve/firewall/212.fw`
- Back up and modify on host: `/etc/pve/firewall/cluster.fw`

**Interfaces:**
- Consumes: mqvpn server at `10.10.10.212:443/UDP`
- Produces: public endpoint `208.69.79.206:443/UDP`; no public TCP control surface

- [ ] **Step 1: Save timestamped task-owned backups**

Copy `/etc/network/interfaces` and `/etc/pve/firewall/cluster.fw` to `/root/codex-audit-backups/mqvpn-ct212-<UTC timestamp>/`, preserving modes.

Expected: `cmp` proves each backup equals its source before modification.

- [ ] **Step 2: Create the CT firewall file**

Create `/etc/pve/firewall/212.fw`:

```ini
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
log_level_in: nolog
log_level_out: nolog
macfilter: 1
ipfilter: 1

[RULES]
IN ACCEPT -i net0 -p udp -dport 443 -log nolog # public-mqvpn
IN ACCEPT -i net0 -source 10.10.10.1 -p icmp -log nolog # host-health
```

Expected: `pve-firewall compile` exits zero.

- [ ] **Step 3: Allow public UDP 443 through the node firewall**

Add one task-owned cluster rule:

```text
IN ACCEPT -i enp65s0f0 -p udp -dport 443 -log nolog # mqvpn-ct212-public
```

Expected: firewall compile succeeds and no TCP 443/9090 accept rule exists.

- [ ] **Step 4: Add idempotent persistent DNAT and forward hooks to `vmbr1`**

Add exact `post-up`/`post-down` rules for:

```bash
iptables -t nat -C PREROUTING -i enp65s0f0 -p udp --dport 443 -j DNAT --to-destination 10.10.10.212:443
iptables -C FORWARD -i enp65s0f0 -o vmbr1 -p udp -d 10.10.10.212 --dport 443 -m conntrack --ctstate NEW -j ACCEPT
```

Use `-I` when the `-C` check fails and exact `-D ... || true` post-down counterparts. Do not reload or bounce `enp65s0f0` or `vmbr1`.

Expected: `/etc/network/interfaces` parses with `ifquery --check vmbr1` and existing guest connectivity remains intact.

- [ ] **Step 5: Apply only the two live task-owned rules and reload firewall policy**

Insert the exact DNAT and FORWARD rules once, then reload Proxmox firewall policy.

Expected: `iptables-save` contains one copy of each task-owned rule and `pve-firewall status` is enabled/running.

- [ ] **Step 6: Prove public packet delivery**

Record the DNAT counter, send UDP from the Mac to `208.69.79.206:443`, and re-read the counter. Optionally capture one packet inside CT 212 without recording payload.

Expected: the task-owned rule counter increases and the packet reaches `10.10.10.212:443`.

### Task 4: Restart and exposure verification

**Files:**
- Verify only; no new files

**Interfaces:**
- Consumes: completed server and forwarding configuration
- Produces: persistence and negative-exposure evidence

- [ ] **Step 1: Restart CT 212**

```bash
pct reboot 212
pct exec 212 -- systemctl is-active mqvpn-server
```

Expected: container returns and service is active.

- [ ] **Step 2: Re-run server invariants after restart**

Verify TUN, `mqvpn0`, forwarding, masquerade, UDP 443, loopback-only 9090, and status API.

Expected: every Task 2 Step 6 invariant still holds.

- [ ] **Step 3: Verify public negative exposure**

From the Mac, probe TCP 443 and TCP 9090 and inspect host/container listeners.

Expected: neither TCP port is publicly reachable; UDP 443 delivery still increments the DNAT counter.

### Task 5: Build and sign the upstream iOS client

**Files:**
- Create: `/Volumes/bigssd/projects/mqvpn/` from the official upstream repository
- Modify: `/Volumes/bigssd/projects/mqvpn/ios/poc/project.yml`
- Modify: `/Volumes/bigssd/projects/mqvpn/ios/poc/App/MqvpnPoCApp.swift`
- Create: `/Volumes/bigssd/projects/mqvpn/ios/poc/Config.xcconfig`
- Generate: `/Volumes/bigssd/projects/mqvpn/ios/poc/MqvpnPoC.xcodeproj`

**Interfaces:**
- Consumes: server endpoint, Keychain-held PSK, Apple team `5NDMQZP6KR`, physical device UDID `00008150-001E2D282E87801C`
- Produces: signed MqvpnPoC app containing a signed PacketTunnel extension, with no embedded real PSK

- [ ] **Step 1: Recheck source path ownership and clone upstream recursively**

If `/Volumes/bigssd/projects/mqvpn` exists, stop and inventory its branch, HEAD, and dirty paths before reuse. Otherwise clone `https://github.com/mp0rta/mqvpn.git` with all submodules and record the exact commit.

Expected: clean checkout at a recorded upstream commit with initialized submodules.

- [ ] **Step 2: Build native iOS libraries**

```bash
./ios/build-ios.sh
```

Expected: arm64 iPhone static libraries are staged under `ios/build` and the command exits zero.

- [ ] **Step 3: Run host-side iOS tests**

```bash
bash ios/poc/Tests/run-host-tests.sh
```

Expected: all host tests pass; do not continue on failure.

- [ ] **Step 4: Replace maintainer-owned bundle identifiers**

Replace `com.mp0rta.mqvpnpoc` with `com.zackjackson.mqvpn` in `ios/poc/project.yml` and `ios/poc/App/MqvpnPoCApp.swift` only.

Expected: recursive grep finds no maintainer bundle identifier and the app/extension/provider references remain consistent.

- [ ] **Step 5: Create non-secret build settings**

Create `Config.xcconfig` from the example with:

```xcconfig
DEVELOPMENT_TEAM = 5NDMQZP6KR
MQVPN_POC_SERVER_HOST = 208.69.79.206
MQVPN_POC_SERVER_PORT = 443
MQVPN_POC_SERVER_NAME =
MQVPN_POC_AUTH_KEY = changeme
MQVPN_POC_TLS_INSECURE = 1
```

Preserve the example's existing bulk URL setting.

Expected: the real PSK is absent from the file and generated project.

- [ ] **Step 6: Generate and inspect the Xcode project**

```bash
cd ios/poc
xcodegen generate
xcodebuild -project MqvpnPoC.xcodeproj -list
```

Expected: both MqvpnPoC and PacketTunnel targets exist and use the intended identifiers/team.

- [ ] **Step 7: Build for the physical device with automatic provisioning**

Use destination `id=00008150-001E2D282E87801C`, team `5NDMQZP6KR`, and `-allowProvisioningUpdates`.

Expected: build succeeds with valid development provisioning for both targets. If the phone is offline, ask the user to connect, unlock, and trust it; do not substitute a simulator.

### Task 6: Install and configure the physical iPhone

**Files:**
- Install built app bundle on physical device; no source changes expected

**Interfaces:**
- Consumes: signed app bundle, connected/unlocked iPhone, Keychain-held PSK
- Produces: active iOS VPN configuration connected to the public mqvpn server

- [ ] **Step 1: Confirm physical route and developer readiness**

Use `xcrun devicectl list devices` and `xcrun devicectl device info details` for the exact UDID.

Expected: device state is available, Developer Mode is enabled, and pairing/trust is valid.

- [ ] **Step 2: Install and launch the built app**

Use `xcrun devicectl device install app` followed by `xcrun devicectl device process launch` for `com.zackjackson.mqvpn`.

Expected: install and launch both succeed on the physical iPhone.

- [ ] **Step 3: Configure runtime credentials and endpoint**

Through the real app UI, configure public host `208.69.79.206`, UDP port 443, blank TLS server name, Keychain-held PSK, insecure enabled, reorder disabled, Hybrid enabled, and TCP Auto. Never place the PSK in UI automation logs or screenshots.

Expected: saved settings re-open with the non-secret fields matching and the secret field populated/masked.

- [ ] **Step 4: Connect and approve the VPN configuration**

Connect through the app and complete the iOS system VPN approval on the phone.

Expected: the app reports connected and the server control API reports one authenticated client.

### Task 7: Verify real two-path behavior

**Files:**
- Verify only; no new files

**Interfaces:**
- Consumes: active physical-iPhone VPN, Wi-Fi and cellular enabled
- Produces: truthful routing, failover, and per-path traffic receipts

- [ ] **Step 1: Verify exit IPv4**

Open an IP-check endpoint on the iPhone through the active VPN.

Expected: observed IPv4 is exactly `208.69.79.206`.

- [ ] **Step 2: Verify both path identities**

Inspect app dashboard and server control status.

Expected: separate Wi-Fi and cellular path entries are live, typically `en0` and `pdp_ip0`.

- [ ] **Step 3: Verify cellular failover and Wi-Fi recovery**

During a sustained iPhone transfer, disable Wi-Fi, verify continued bytes through cellular, then restore Wi-Fi and verify its path returns without VPN reconnection.

Expected: transfer survives and both state transitions are visible.

- [ ] **Step 4: Verify Wi-Fi failover and cellular recovery**

During a sustained transfer, disable cellular data, verify continued bytes through Wi-Fi, then restore cellular and verify its path returns.

Expected: transfer survives and both state transitions are visible.

- [ ] **Step 5: Verify aggregation evidence**

With both paths enabled, run a large transfer and compare per-path byte counters before and after.

Expected: both counters increase. Report measured combined rate without claiming exact addition or attributing unused-path capacity.

- [ ] **Step 6: Final durability receipt**

Recheck CT autostart, service enabled/active, public UDP delivery, control isolation, app installation, physical-device identity, exit IPv4, and both-path status.

Expected: every server and iPhone completion gate in the approved spec has direct evidence or is explicitly reported as blocked with its concrete cause.
