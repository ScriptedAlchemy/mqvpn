// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: TunnelController
    @Environment(\.dismiss) private var dismiss

    @State private var hostText: String
    @State private var portText: String
    @State private var serverNameText: String
    @State private var pskText: String
    @State private var insecure: Bool
    @State private var relayEnabled: Bool
    @State private var relayKeyText: String
    @State private var hybridEnabled: Bool
    @State private var hybridMode: Int
    @State private var optimizeFor: Int

    init(controller: TunnelController) {
        self.controller = controller
        let server = controller.serverSettings ?? .emptyDraft
        _hostText = State(initialValue: server.host)
        _portText = State(initialValue: String(server.port))
        _serverNameText = State(initialValue: server.serverName)
        _pskText = State(initialValue: server.authKey)
        _insecure = State(initialValue: server.insecure)
        let relay = controller.relaySettings ??
            MacRelaySettings(enabled: false, host: "", port: 5443, keyBase64: "")
        _relayEnabled = State(initialValue: relay.enabled)
        _relayKeyText = State(initialValue: relay.keyBase64)
        _hybridEnabled = State(initialValue: controller.hybridSettings.enabled)
        _hybridMode = State(initialValue: controller.hybridSettings.tcpMode)
        _optimizeFor = State(initialValue: controller.schedulerSettings.policy)
    }

    private var serverDraft: ServerSettings {
        ServerSettings(host: hostText,
                       port: Int(portText.trimmingCharacters(in: .whitespaces)) ?? -1,
                       serverName: serverNameText, authKey: pskText, insecure: insecure)
    }

    private var relayDraft: MacRelaySettings {
        MacRelaySettings(enabled: relayEnabled,
                         host: "",
                         port: 5443,
                         keyBase64: relayKeyText)
    }

    private var hybridDraft: HybridSettings {
        HybridSettings(enabled: hybridEnabled, tcpMode: hybridMode)
    }

    private var schedulerDraft: SchedulerSettings {
        SchedulerSettings(policy: optimizeFor)
    }

    private var formValid: Bool {
        serverDraft.isValid && (!relayEnabled || relayDraft.isValid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server").font(.headline)
            TextField("Host", text: $hostText)
            TextField("Port", text: $portText)
            TextField("TLS server name", text: $serverNameText)
            SecureField("Auth key", text: $pskText)
            Toggle("Skip TLS verification", isOn: $insecure)
            Divider()
            Toggle("Bond iPhone cellular relay", isOn: $relayEnabled)
            Text(controller.relayDiscoveryText)
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField("Relay key (base64, 32 bytes)", text: $relayKeyText)
                .disabled(!relayEnabled)
            Divider()
            Picker(SchedulerSettings.pickerTitle, selection: $optimizeFor) {
                Text(SchedulerSettings.labelThroughput).tag(SchedulerSettings.maxThroughput)
                Text(SchedulerSettings.labelLatency).tag(SchedulerSettings.lowLatency)
            }
            Text("Applies on the next Start. Max Throughput learns path capacity from real traffic.")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("Hybrid TCP", isOn: $hybridEnabled)
            if hybridEnabled {
                Picker("TCP mode", selection: $hybridMode) {
                    Text("Auto").tag(HybridSettings.modeAuto)
                    Text("Stream").tag(HybridSettings.modeStream)
                    Text("Raw").tag(HybridSettings.modeRaw)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        await controller.save(server: serverDraft, relay: relayDraft,
                                              hybrid: hybridDraft, scheduler: schedulerDraft)
                        if controller.configError == nil { dismiss() }
                    }
                }
                .disabled(!formValid || !controller.isEditable || controller.isSaving)
            }
            if let error = controller.configError {
                Text(error).foregroundColor(.red).font(.caption)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}
