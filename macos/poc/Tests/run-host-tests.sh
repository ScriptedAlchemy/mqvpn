#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 mp0rta and mqvpn contributors
# Runs the real portable C relay codec through the macOS relay state machine.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
IOS="$ROOT/ios/poc"
TMPD="$(mktemp -d)"
OUT="$TMPD/hosttests"
trap 'rm -rf "$TMPD"' EXIT
clang -c -o "$TMPD/mqvpn_clock_shim.o" "$IOS/Shared/mqvpn_clock_shim.c" \
    -I"$ROOT/include"
clang -c -o "$TMPD/reorder_layout_shim.o" "$IOS/PacketTunnel/reorder_layout_shim.c" \
    -I"$ROOT/include" -I"$ROOT/src"
XQUIC_BUILD_DIR="$(sed -n -E 's/^XQUIC_BUILD_DIR:[^=]+=//p' "$ROOT/build/CMakeCache.txt")"
BORINGSSL_BUILD_DIR="$(sed -n -E 's/^BORINGSSL_BUILD_DIR:[^=]+=//p' "$ROOT/build/CMakeCache.txt")"
if [[ -z "$XQUIC_BUILD_DIR" || ! -f "$XQUIC_BUILD_DIR/libxquic.dylib" ]]; then
    echo "missing native xquic build from $ROOT/build/CMakeCache.txt" >&2
    exit 1
fi
if [[ -z "$BORINGSSL_BUILD_DIR" || ! -f "$BORINGSSL_BUILD_DIR/libcrypto.a" ]]; then
    echo "missing native BoringSSL build from $ROOT/build/CMakeCache.txt" >&2
    exit 1
fi
swiftc -o "$OUT" \
    -import-objc-header "$IOS/PacketTunnel/BridgingHeader.h" \
    -I"$ROOT/include" -I"$ROOT/src" -I"$IOS/Shared" \
    "$IOS/Shared/PoCConfig.swift" \
    "$IOS/Shared/ServerSettings.swift" \
    "$IOS/Shared/ServerResolve.swift" \
    "$IOS/Shared/ReorderSettings.swift" \
    "$IOS/Shared/HybridSettings.swift" \
    "$IOS/Shared/OperatingMode.swift" \
    "$IOS/Shared/TunnelLifecycle.swift" \
    "$IOS/Shared/RelayRuntimeState.swift" \
    "$IOS/Shared/ProviderMessage.swift" \
    "$IOS/PacketTunnel/MqvpnEngine.swift" \
    "$ROOT/macos/poc/Shared/MacRelayRuntimeState.swift" \
    "$ROOT/macos/poc/PacketTunnel/MacRelayBinder.swift" \
    "$TMPD/mqvpn_clock_shim.o" "$TMPD/reorder_layout_shim.o" \
    "$DIR/main.swift" \
    -L"$ROOT/build" -L"$XQUIC_BUILD_DIR" -lmqvpn "$ROOT/build/libmqvpn.a" -lxquic \
    "$BORINGSSL_BUILD_DIR/libssl.a" "$BORINGSSL_BUILD_DIR/libcrypto.a" \
    -framework Security -framework CoreFoundation -lc++ \
    -Xlinker -rpath -Xlinker "$ROOT/build" \
    -Xlinker -rpath -Xlinker "$XQUIC_BUILD_DIR"
"$OUT"
