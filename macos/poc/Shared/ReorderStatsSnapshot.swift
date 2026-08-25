// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

struct ReorderStatsSnapshot {
    let delivered: UInt64
    let gapCount: UInt64
    let gapFilled: UInt64
    let gapTimeout: UInt64
    let ackDemote: UInt64
    let bufferedP50Ms: Double
    let bufferedP99Ms: Double
}
