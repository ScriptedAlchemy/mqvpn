#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 mp0rta and mqvpn contributors
# Host-compile the pure Foundation logic + assertions and run on macOS. Mirrors
# the clock_shim_host_test.c precedent (logic tests need no simulator). The
# file that carries top-level test statements MUST be named main.swift.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SHARED="$DIR/../Shared"
APP="$DIR/../App"
TMPD="$(mktemp -d)"
OUT="$TMPD/hosttests"
trap 'rm -rf "$TMPD"' EXIT
clang -c -o "$TMPD/mqvpn_clock_shim.o" "$SHARED/mqvpn_clock_shim.c" \
    -I"$ROOT/include"
clang -c -o "$TMPD/reorder_layout_shim.o" "$DIR/../PacketTunnel/reorder_layout_shim.c" \
    -I"$ROOT/include" -I"$ROOT/src"
XQUIC_BUILD_DIR="$(sed -n 's/^XQUIC_BUILD_DIR:BOOL=//p' "$ROOT/build/CMakeCache.txt")"
if [[ -z "$XQUIC_BUILD_DIR" || ! -f "$XQUIC_BUILD_DIR/libxquic.dylib" ]]; then
    echo "missing native xquic build from $ROOT/build/CMakeCache.txt" >&2
    exit 1
fi
swiftc -o "$OUT" \
    -import-objc-header "$DIR/../PacketTunnel/BridgingHeader.h" \
    -I"$ROOT/include" -I"$ROOT/src" -I"$SHARED" \
    "$SHARED/PoCConfig.swift" \
    "$SHARED/ServerSettings.swift" \
    "$SHARED/ServerResolve.swift" \
    "$SHARED/ReorderSettings.swift" \
    "$SHARED/HybridSettings.swift" \
    "$SHARED/ProviderMessage.swift" \
    "$SHARED/TunnelLifecycle.swift" \
    "$SHARED/OperatingMode.swift" \
    "$SHARED/RelaySettings.swift" \
    "$SHARED/RelayBonjour.swift" \
    "$SHARED/RelayRuntimeState.swift" \
    "$SHARED/LiveActivityRateSampler.swift" \
    "$SHARED/LiveActivityContent.swift" \
    "$APP/ReorderIngest.swift" \
    "$DIR/../PacketTunnel/MqvpnEngine.swift" \
    "$TMPD/mqvpn_clock_shim.o" "$TMPD/reorder_layout_shim.o" \
    -L"$ROOT/build" -L"$XQUIC_BUILD_DIR" -lmqvpn "$ROOT/build/libmqvpn.a" -lxquic \
    -Xlinker -rpath -Xlinker "$ROOT/build" \
    -Xlinker -rpath -Xlinker "$XQUIC_BUILD_DIR" \
    "$DIR/main.swift"
"$OUT"
