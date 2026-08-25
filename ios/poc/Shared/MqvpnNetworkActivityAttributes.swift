// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import ActivityKit

@available(iOS 16.1, *)
struct MqvpnNetworkActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivityContentState

    /// Static, non-sensitive label used only to distinguish VPN from relay.
    let mode: String
}
