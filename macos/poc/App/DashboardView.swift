// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import SwiftUI

struct DashboardView: View {
    @ObservedObject var controller: TunnelController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(controller.statusText.uppercased())
                    .font(.headline)
                Spacer()
                Button("Settings") { controller.showSettings = true }
            }
            if let error = controller.configError ?? controller.lastError {
                Text(error).foregroundColor(.red).font(.caption)
            }
            HStack(spacing: 12) {
                Button("Start") { controller.start() }
                    .disabled(!controller.isConnectable)
                Button("Stop") { controller.stop() }
                    .disabled(!controller.isStoppable)
            }
            if !controller.directRows.isEmpty {
                ForEach(controller.directRows) { direct in
                    labeledRow("Direct \(direct.pathID)",
                               "\(Self.rate(direct.megabitsPerSecond)) · \(direct.totalBytes) B")
                }
            } else {
                labeledRow("Direct", "waiting for a bound Wi-Fi or Ethernet path")
            }
            if let relay = controller.relayRow {
                labeledRow(relay.active ? "iPhone relay" : "iPhone relay (preflight)",
                           Self.rate(relay.mbps) +
                           (relay.lastError.map { " · \($0)" } ?? ""))
            } else {
                labeledRow("iPhone relay", "optional — not configured")
            }
            Spacer()
        }
        .padding()
        .frame(minWidth: 420, minHeight: 280)
        .task { await controller.loadOrCreateManager() }
        .sheet(isPresented: $controller.showSettings) {
            SettingsView(controller: controller)
        }
    }

    private func labeledRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
    }

    private static func rate(_ mbps: Double?) -> String {
        guard let mbps else { return "…" }
        return String(format: "%.2f Mbps", mbps)
    }
}
