// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation

/// Relay authentication is intentionally separate from the mqvpn server PSK.
/// Only a canonical Base64 value decoding to exactly 32 bytes is accepted.
struct RelaySettings: Equatable {
    let keyBase64: String
    let listenPort: Int

    private enum Key {
        static let relayKey = "relayKey"
        static let listenPort = "relayListenPort"
    }

    static let emptyDraft = RelaySettings(keyBase64: "", listenPort: 5443)

    init(keyBase64: String, listenPort: Int) {
        self.keyBase64 = keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        self.listenPort = listenPort
    }

    init?(providerConfiguration: [String: Any]?) {
        guard let dict = providerConfiguration,
              let key = dict[Key.relayKey] as? String,
              let portNumber = dict[Key.listenPort] as? NSNumber,
              let port = ReorderSettings.exactInt(portNumber) else {
            return nil
        }
        self.init(keyBase64: key, listenPort: port)
        guard isValid else { return nil }
    }

    var decodedKey: Data? {
        guard let data = Data(base64Encoded: keyBase64), data.count == 32 else {
            return nil
        }
        return data
    }

    var isValid: Bool {
        decodedKey != nil && (1...65_535).contains(listenPort)
    }

    func toProviderConfiguration() -> [String: Any] {
        [Key.relayKey: keyBase64, Key.listenPort: NSNumber(value: listenPort)]
    }
}

enum RelayStartGuard {
    static func canStart(mode: OperatingMode, server: ServerSettings?,
                         relay: RelaySettings?) -> Bool {
        guard server?.isValid == true else { return false }
        switch mode {
        case .vpn:
            return true
        case .macRelay:
            return relay?.isValid == true
        }
    }
}
