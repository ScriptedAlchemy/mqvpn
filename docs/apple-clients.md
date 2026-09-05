# Apple clients

The development apps in `ios/poc` and `macos/poc` use Network Extension VPN
profiles. The macOS app does not run the privileged CLI or edit system routes
through shell commands. Both clients share configuration and engine code from
`ios/poc/Shared` and `ios/poc/PacketTunnel`.

## Build and signing

Build the native libraries with `./ios/build-ios.sh` or `./macos/build-macos.sh`.
Copy the corresponding `poc/Config.example.xcconfig` to `poc/Config.xcconfig`
and supply your development team and server configuration. Keep credentials
in this ignored file, not in the project or documentation.

Generate the selected project:

```sh
xcodegen --spec ios/poc/project.yml
# or
xcodegen --spec macos/poc/project.yml
```

Open the generated project in Xcode and configure signing for the app and
every embedded extension. The checked-in projects still contain fork-specific
bundle IDs and signing settings; replace those with identifiers and profiles
owned by your team. iOS also embeds a Live Activity widget extension.
Do not replace an installed macOS app while its tunnel is running: installing
a new bundle can terminate the packet-tunnel process.

## VPN and relay modes

In iOS **VPN** mode, the phone owns the mqvpn connection and can use Wi-Fi and
cellular paths. In **Mac Relay** mode, the Mac owns the connection; the phone
forwards its opaque QUIC datagrams between the local LAN and the configured
server over cellular. It is not a general-purpose router or proxy.

Keep both devices on the same LAN. Configure the same Base64-encoded 32-byte
relay key on both devices, distinct from the server authentication key. The
Mac app discovers the phone through `_mqvpn-relay._udp` Bonjour; no relay IP
is required. Bonjour advertises an endpoint, not credentials. The CLI uses
an explicit endpoint instead; see the [relay configuration](../README.md#macos-iphone-cellular-relay).

**Max Throughput** is the default scheduling preference; **Low Latency** uses
MinRTT. Hybrid STREAM traffic can be spread across paths with QUIC reassembly.
Raw TCP needs the negotiated reorder shim to avoid flow pinning. Neither
preference guarantees that combined speed will exceed the faster single path.

In iOS VPN mode, **Multipath → Flows per interface** selects one to four UDP
flows on each radio. Existing profiles keep four. Save while disconnected;
the next Start uses the new count. Four per radio fits the core's eight local
path slots without crowding out the other radio. This is independent of the
number of files or HTTP connections in an uploader.

The relay runs in the packet-tunnel extension, independently of the foreground
app. Live Activity updates are separate: the app publishes measured counters
while runnable. The optional silent-audio keepalive is off by default, is not
needed for relay forwarding, and does not guarantee background execution.
There is no APNs update path. A stale Island display is not proof of a stopped
relay; check current path counters and tunnel state.

## Validation

```sh
bash ios/poc/Tests/run-host-tests.sh
bash macos/poc/Tests/run-host-tests.sh
ctest --test-dir build --output-on-failure
```

Host tests do not establish physical-device connectivity. On signed builds,
verify Start/Stop restores normal connectivity, discovery and authentication
succeed, and relay loss/recovery does not strand the Mac. Compare direct-only,
relay-only, and combined transfers against the same endpoint and workload.
Use byte deltas over elapsed time, not cumulative counters, to measure each
path's contribution. Record units explicitly: multiply MB/s by eight to get Mbps.

Historical measurements live in `docs/report`; they are not current deployment
receipts. The site-specific CT212 runbook is in `deploy/proxmox/ct212-notes.txt`.
