// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MqvpnLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        MqvpnSpeedLiveActivity()
    }
}

struct MqvpnSpeedLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MqvpnNetworkActivityAttributes.self) { context in
            LockScreenSpeedView(context: context)
                .activityBackgroundTint(.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let wifi = LiveActivityDisplayPolicy.visible(context.state.wifi,
                                                         isStale: context.isStale)
            let cellular = LiveActivityDisplayPolicy.visible(context.state.cellular,
                                                             isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    InterfaceSpeedView(kind: .wifi,
                                       content: wifi,
                                       isStale: context.isStale,
                                       compact: false)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    InterfaceSpeedView(kind: .cellular,
                                       content: cellular,
                                       isStale: context.isStale,
                                       compact: false)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StatusView(phase: context.state.phase,
                               isStale: context.isStale)
                }
            } compactLeading: {
                InterfaceSpeedView(kind: .wifi,
                                   content: wifi,
                                   isStale: context.isStale,
                                   compact: true)
            } compactTrailing: {
                InterfaceSpeedView(kind: .cellular,
                                   content: cellular,
                                   isStale: context.isStale,
                                   compact: true)
            } minimal: {
                MinimalInterfacesView(wifi: wifi, cellular: cellular,
                                      isStale: context.isStale)
            }
            .keylineTint(.green)
        }
    }
}

private struct LockScreenSpeedView: View {
    let context: ActivityViewContext<MqvpnNetworkActivityAttributes>

    var body: some View {
        let wifi = LiveActivityDisplayPolicy.visible(context.state.wifi,
                                                     isStale: context.isStale)
        let cellular = LiveActivityDisplayPolicy.visible(context.state.cellular,
                                                         isStale: context.isStale)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(context.attributes.mode == "macRelay" ? "mqvpn relay" : "mqvpn VPN",
                      systemImage: "link")
                    .font(.headline)
                Spacer()
                StatusView(phase: context.state.phase, isStale: context.isStale)
            }
            HStack(spacing: 12) {
                InterfaceSpeedView(kind: .wifi,
                                   content: wifi,
                                   isStale: context.isStale,
                                   compact: false)
                Divider().overlay(.white.opacity(0.25))
                InterfaceSpeedView(kind: .cellular,
                                   content: cellular,
                                   isStale: context.isStale,
                                   compact: false)
            }
        }
        .padding()
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
    }
}

private enum DisplayInterfaceKind {
    case wifi
    case cellular

    var tint: Color { self == .wifi ? .green : .blue }
}

private struct InterfaceSpeedView: View {
    let kind: DisplayInterfaceKind
    let content: LiveActivityInterfaceContent?
    let isStale: Bool
    let compact: Bool

    private var icon: String {
        kind == .wifi ? "wifi" : "antenna.radiowaves.left.and.right"
    }

    private var label: String {
        kind == .wifi ? "Wi-Fi" : "Cellular"
    }

    var body: some View {
        HStack(spacing: compact ? 3 : 7) {
            Image(systemName: icon)
                .foregroundStyle(content == nil ? Color.secondary : kind.tint)
            VStack(alignment: compact ? .trailing : .leading, spacing: 1) {
                if !compact {
                    Text(content?.interfaceName ?? label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(rateText)
                    .font(compact ? .caption2.monospacedDigit() : .headline.monospacedDigit())
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isStale
            ? LiveActivityDisplayPolicy.accessibilityState(isStale: true,
                                                           interfaceAvailable: false)
            : Self.accessibilityRate(content?.megabitsPerSecond,
                                     available: content != nil))
    }

    private var rateText: String {
        let rate = content?.megabitsPerSecond
        guard let rate else { return "--" }
        if compact {
            if rate < 10 { return String(format: "%.1fM", rate) }
            return String(format: "%.0fM", rate)
        }
        if rate < 10 { return String(format: "%.1f Mbps", rate) }
        return String(format: "%.0f Mbps", rate)
    }

    private static func accessibilityRate(_ rate: Double?, available: Bool) -> String {
        guard available else { return "offline" }
        guard let rate else { return "sampling" }
        return String(format: "%.1f megabits per second", rate)
    }
}

private struct MinimalInterfacesView: View {
    let wifi: LiveActivityInterfaceContent?
    let cellular: LiveActivityInterfaceContent?
    let isStale: Bool

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "wifi")
                .foregroundStyle(wifi == nil ? Color.secondary : Color.green)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(cellular == nil ? Color.secondary : Color.blue)
        }
        .font(.caption2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("mqvpn interfaces")
        .accessibilityValue(isStale ? "stale data" :
            "Wi-Fi \(wifi == nil ? "offline" : "active"), cellular \(cellular == nil ? "offline" : "active")")
    }
}

private struct StatusView: View {
    let phase: LiveActivityPhase
    let isStale: Bool

    var body: some View {
        Text(isStale ? "Stale" : phase.label)
            .font(.caption)
            .foregroundStyle(isStale || phase == .unavailable ? Color.orange : Color.secondary)
            .accessibilityLabel("mqvpn status")
            .accessibilityValue(isStale ? "stale data" : phase.label)
    }
}

private extension LiveActivityPhase {
    var label: String {
        switch self {
        case .connecting: return "Connecting"
        case .waiting: return "Waiting"
        case .active: return "Active"
        case .stopping: return "Stopping"
        case .unavailable: return "Unavailable"
        }
    }
}
