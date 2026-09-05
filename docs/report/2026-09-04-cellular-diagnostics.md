# Cellular contribution investigation, 2026-09-04

Historical deployment receipt and traffic samples, not a live status page.

## Verified topology

The Mac mqvpn profile was disconnected and Tailscale was connected. CT212
had one authenticated mqvpn client, and the paired iPhone had a running
PacketTunnel process. No ZeroFS service or configuration was changed.

## Reporting defect and cleanup

xquic retained 16 historical path records, of which eight were active. The
server copied the first eight into its bounded public status structure,
including four closed paths, hiding later active paths and their WLB weights.
The CLI also printed the array index instead of the actual path ID.

The server now shares one selection helper between status and reinjection
statistics: active paths first, then initializing/validating paths, then
historical paths when capacity permits. Public structure sizes and JSON fields
are unchanged. CLI path IDs now agree with the JSON and transport logs.
Historical connection totals still include all recorded paths.

## Measurements

Header-only tcpdump accounting over 20 seconds, UDP payload bytes, tunnel
peers only (not internet egress on UDP 443):

| Peer | Before upload Mbps | Before download Mbps | After upload Mbps | After download Mbps |
| --- | ---: | ---: | ---: | ---: |
| 75.226.181.66 | 15.609 | 1.107 | 0.038 | 0.214 |
| 174.227.62.74 | 2.834 | 0.309 | 0.021 | 0.163 |

The second peer is the presumed phone cellular path; the first is also the
Mac's current public endpoint. Device interface-to-path mapping was not
available through iPhone syslog: libimobiledevice did not discover the device
and Apple's log collection required unavailable local sudo authentication.
CoreDevice did confirm the running iPhone app/PacketTunnel.

The before upload split is about 15% on the second peer; after is about 35%
upload and 43% download. **These are different live workloads, not an A/B
capacity benchmark or proof of a throughput improvement.**

Before restart, closed historical paths reported 4–5.6 second RTTs. Those
values cannot diagnose the current cellular link. After reconnect, all eight
current paths were active at 100–121 ms RTT and their weights totaled 100%.
The client reauthenticated automatically following the server restart.

CT212 had about 55 MiB used RAM, no CPU quota throttling, and zero eth0 drops.
The UDP receive-buffer error counter was 580 over the container lifetime;
both packet captures reported zero capture drops. No active evidence justified
changing MTU, congestion-control weights, or container resource allocation.
The deployed xquic WLB source matches the local fork. Hybrid STREAM data already
uses per-packet scheduling; raw TCP datagrams retain flow affinity unless
reorder-based bonding is enabled. No scheduler behavior was changed here.

## Deployment and verification

- Built inside Debian 12 CT212 at `/root/mqvpn-cellular-20260904/build` using
  existing xquic/BoringSSL/lwIP dependencies.
- Existing Linux suite: 35/35 passed. New selection regression plus status and
  control-socket tests passed after adding the new Linux test registration.
- Selection regression passed on macOS; standalone status suite passed 30/30.
- Installed binary SHA-256:
  `c55c80c06d69b50405c182ce16af6e6ecd7fcf24a35eb3fc393ed8404e28bd08`.
- Rollback: `/usr/local/bin/mqvpn.pre-cellular-stats-20260904`.
- `mqvpn-server` and its existing `mqvpn-zerofs-alias` unit were active after
  deployment; the latter was restarted only because it follows mqvpn's lifecycle.

Remaining acceptance: a sustained iPhone speed test with concurrent per-path
sampling, then comparable Wi-Fi-only and cellular-only tests. Do not infer
available cellular capacity from a light-demand traffic share.
