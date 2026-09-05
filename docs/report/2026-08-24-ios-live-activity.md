# iOS per-interface Live Activity implementation report

Historical build report, not current runtime guidance. The provider-update
assumption below was superseded by the app-process publisher in `45342fc`.
See [Apple clients](../apple-clients.md) for current limitations.

Branch: `codex/ios-live-activity`  
Worktree: `/Volumes/bigssd/projects/mqvpn-live-activity`  
Base: `e50ef34`

## Commits

- `a424b08` — derive truthful per-interface rates from production counters
- `faa8b9f` — ActivityKit lifecycle, provider reporter, and WidgetKit surfaces
- `ad6d104` — label non-compact rates explicitly as Mbps
- `1f47e3d` — ignore XcodeGen's generated widget Info.plist
- `15db8d2` — fail stale surfaces closed, select exact-mode activities, and
  move best-effort ActivityKit cleanup after deterministic transport teardown

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
- App Stop ends the activity immediately. A provider-only system/error Stop
  schedules best-effort cleanup after transport teardown. If Live Activities
  are disabled or ActivityKit has no foreground-created activity, the provider
  logs that state and does not fabricate one.
- Activity selection is mode-exact. A VPN reporter cannot update a relay
  activity (or vice versa), and each foreground start removes crash duplicates
  and activities left behind by a mode switch.
- ActivityKit staleness clears rates from every presentation. Compact and
  minimal Dynamic Island views turn gray/show `--`, and VoiceOver reports
  stale data rather than repeating the last sampled Mbps.
- Provider Stop finishes relay sockets or engine/path teardown first. It then
  cancels the reporter and schedules unawaited ActivityKit cleanup; ActivityKit
  cannot delay the Network Extension Stop completion.
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
- Host coverage includes counter reset/stall/removal, stale presentation
  policy, exact-mode duplicate and mode-switch selection, and transport-before-
  ActivityKit Stop ordering.

## ActivityKit support boundary

Apple documents that standard activities start from the foreground app and
that an app may update or end them while running in the background. It also
defines `Activity.activities` as the app's current Live Activities:

- <https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities>
- <https://developer.apple.com/documentation/activitykit/activity>
- <https://developer.apple.com/documentation/activitykit/activity/activities>

The current iOS SDK does not mark `Activity.activities`, `update`, or `end` as
unavailable to application extensions, and the PacketTunnel target compiles
them with application-extension-only checking enabled. However, Apple's public
documentation does not explicitly guarantee that a Network Extension process
sees and updates an activity requested by its containing app. The implementation
therefore logs the foreground request, exact-mode provider lookup, successful
provider update call, and post-transport cleanup scheduling. These logs improve
the physical test receipt but do not replace it.

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
2. With the mqvpn app backgrounded, provider logs show an exact-mode activity
   lookup and `provider Live Activity update completed`.
3. Lock Screen and Dynamic Island show changing `en0` and `pdp_ip0` rates from
   a real transfer in VPN mode and Mac Relay mode.
4. Removing an interface or waiting past `staleDate` marks it offline/stale
   instead of retaining a rate on compact or minimal presentations.
5. Pressing Stop removes the Live Activity immediately, with provider logs
   showing transport `STOP_FINISHED` before ActivityKit cleanup scheduling.

Until that device test is complete, build integration is verified but runtime
ActivityKit behavior from the Network Extension is not claimed as proven.
