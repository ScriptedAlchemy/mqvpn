// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import SwiftUI

@main
struct MqvpnMacApp: App {
    @StateObject private var controller = TunnelController()

    var body: some Scene {
        WindowGroup {
            DashboardView(controller: controller)
        }
    }
}
