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
    @State private var relayHostText: String
    @State private var relayPortText: String
    @State private var relayKeyText: String

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
        _relayHostText = State(initialValue: relay.host)
        _relayPortText = State(initialValue: String(relay.port))
        _relayKeyText = State(initialValue: relay.keyBase64)
    }

    private var serverDraft: ServerSettings {
        ServerSettings(host: hostText,
                       port: Int(portText.trimmingCharacters(in: .whitespaces)) ?? -1,
                       serverName: serverNameText, authKey: pskText, insecure: insecure)
    }

    private var relayDraft: MacRelaySettings {
        MacRelaySettings(enabled: relayEnabled,
                         host: relayHostText,
                         port: Int(relayPortText.trimmingCharacters(in: .whitespaces)) ?? -1,
                         keyBase64: relayKeyText)
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
            TextField("iPhone host", text: $relayHostText)
                .disabled(!relayEnabled)
            TextField("Relay port", text: $relayPortText)
                .disabled(!relayEnabled)
            SecureField("Relay key (base64, 32 bytes)", text: $relayKeyText)
                .disabled(!relayEnabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        await controller.save(server: serverDraft, relay: relayDraft)
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
