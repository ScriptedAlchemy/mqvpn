# iOS per-interface Live Activity implementation report

Branch: `codex/ios-live-activity`  
Worktree: `/Volumes/bigssd/projects/mqvpn-live-activity`  
Base: `e50ef34`

## Commits

- `a424b08` — derive truthful per-interface rates from production counters
- `faa8b9f` — ActivityKit lifecycle, provider reporter, and WidgetKit surfaces
- `ad6d104` — label non-compact rates explicitly as Mbps
- `1f47e3d` — ignore XcodeGen's generated widget Info.plist

## Shipping path

- The foreground app requests one standard Live Activity immediately before
  `startVPNTunnel()`, as required by ActivityKit's foreground-start contract.
- The running packet-tunnel provider discovers and updates that activity every
  two seconds. VPN mode reads `SnapshotCache`'s real active `en0`/`pdp_ip*`
  path byte counters. Mac Relay mode reads the real LAN and fixed-server socket
  counters in `RelaySnapshot`.
- Rates are byte deltas divided by provider elapsed time, then display-only
  EWMA smoothing is applied. A new/reset/stalled counter is shown as sampling,
  a missing interface is removed immediately, and each update becomes stale
  after six seconds.
- App Stop and provider Stop both end the activity immediately. If Live
  Activities are disabled or ActivityKit has no foreground-created activity,
  the provider logs that state and does not fabricate one.
- The embedded `MqvpnLiveActivity` WidgetKit extension supplies Lock Screen,
  expanded, compact, and minimal Dynamic Island presentations with interface
  icons, accessibility labels, and no endpoint, key, or traffic content.
- No App Group or separate shared storage was added; ActivityKit is the real
  app/provider-to-system-widget boundary.

## Verification

- `bash ios/poc/Tests/run-host-tests.sh` — `host tests: ALL PASS`.
- Clean arm64 Release build with generated project and unsigned generic device
  target — `BUILD SUCCEEDED` for the app, PacketTunnel, and
  MqvpnLiveActivity targets.
- Product audit confirmed both embedded extension executables, the
  `com.apple.widgetkit-extension` extension point, app Live Activity keys, and
  ActivityKit/WidgetKit linkage.

The pre-existing Swift 6 sendability warnings in `PacketTunnelProvider`, the
static-library alignment warning, and existing app-orientation warning remain;
this lane introduced no Release build error.

## Provisioning and physical-device gate

The signed Release build is not yet possible on this Mac CLI state. Xcode
reported no signed-in account and no development provisioning profile for the
new bundle ID `com.zackjackson.mqvpn.LiveActivity`. Existing local profiles
cover only `com.zackjackson.mqvpn` and its PacketTunnel extension.

Before physical installation, sign in to the paid team in Xcode and let
automatic signing create/download the widget-extension profile. Then install
the merged Release build on the physical iPhone and verify:

1. Start creates one Live Activity while the app is foregrounded.
2. Lock Screen and Dynamic Island show changing `en0` and `pdp_ip0` rates from
   a real transfer in VPN mode and Mac Relay mode.
3. Removing an interface marks it offline/stale instead of retaining a rate.
4. Pressing Stop removes the Live Activity immediately.

Until that device test is complete, build integration is verified but runtime
ActivityKit behavior from the Network Extension is not claimed as proven.
