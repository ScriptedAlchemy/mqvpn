#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 mp0rta and mqvpn contributors
# Build BoringSSL -> xquic (static) -> libmqvpn (static) for macOS arm64 and
# stage the archives under macos/build for the Network Extension client.
# Usage: ./macos/build-macos.sh [boringssl|xquic|mqvpn|all]   (default: all)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="${1:-all}"

MACOS_DEPLOYMENT_TARGET=13.0
MACOS_ARCH=arm64
OUT_DIR="$SCRIPT_DIR/macos/build"
mkdir -p "$OUT_DIR"

MAC_CMAKE_FLAGS=(
    -DCMAKE_SYSTEM_NAME=Darwin
    -DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCH
    -DCMAKE_OSX_SYSROOT=macosx
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET
    -DCMAKE_BUILD_TYPE=Release
    -GNinja
)

BSSL_DIR="$SCRIPT_DIR/third_party/xquic/third_party/boringssl"
BSSL_BUILD="$BSSL_DIR/build-macos"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/scripts/bssl_build_guard.sh"

if [ "$PHASE" = "boringssl" ] || [ "$PHASE" = "all" ]; then
    if [ ! -f "$BSSL_DIR/CMakeLists.txt" ]; then
        echo "ERROR: BoringSSL not found at $BSSL_DIR."
        echo "Run: git submodule update --init --recursive"
        exit 1
    fi
    echo "=== BoringSSL commit: $(git -C "$BSSL_DIR" rev-parse HEAD) ==="
    echo "=== Building BoringSSL (macOS arm64) ==="
    bssl_guard_build_dir "$BSSL_DIR" "$BSSL_BUILD"
    cmake -S "$BSSL_DIR" -B "$BSSL_BUILD" "${MAC_CMAKE_FLAGS[@]}"
    cmake --build "$BSSL_BUILD" --target ssl crypto
    bssl_stamp_build_dir "$BSSL_DIR" "$BSSL_BUILD"
fi

resolve_bssl_libs() {
    bssl_verify_build_dir "$BSSL_DIR" "$BSSL_BUILD" || exit 1
    if [ -f "$BSSL_BUILD/ssl/libssl.a" ]; then
        SSL_A="$BSSL_BUILD/ssl/libssl.a"; CRYPTO_A="$BSSL_BUILD/crypto/libcrypto.a"
    else
        SSL_A="$BSSL_BUILD/libssl.a"; CRYPTO_A="$BSSL_BUILD/libcrypto.a"
    fi
    [ -f "$SSL_A" ] || { echo "libssl.a not found under $BSSL_BUILD" >&2; exit 1; }
}

XQUIC_DIR="$SCRIPT_DIR/third_party/xquic"
XQUIC_BUILD="$XQUIC_DIR/build-macos"

if [ "$PHASE" = "xquic" ] || [ "$PHASE" = "all" ]; then
    echo "=== Building xquic (macOS, static) ==="
    resolve_bssl_libs
    cmake -S "$XQUIC_DIR" -B "$XQUIC_BUILD" "${MAC_CMAKE_FLAGS[@]}" \
        -DCMAKE_C_FLAGS=-Wno-unknown-warning-option \
        -DSSL_TYPE=boringssl \
        -DSSL_PATH="$BSSL_DIR" \
        -DSSL_INC_PATH="$BSSL_DIR/include" \
        -DSSL_LIB_PATH="$SSL_A;$CRYPTO_A" \
        -DXQC_ENABLE_BBR2=ON \
        -DXQC_ENABLE_UNLIMITED=ON \
        -DXQC_ENABLE_FEC=ON \
        -DXQC_ENABLE_XOR=ON \
        -DXQC_ENABLE_TESTING=OFF
    cmake --build "$XQUIC_BUILD" --target xquic-static
fi

MQVPN_BUILD="$SCRIPT_DIR/build-macos"

if [ "$PHASE" = "mqvpn" ] || [ "$PHASE" = "all" ]; then
    echo "=== Building libmqvpn (macOS, static) ==="
    rm -rf "$MQVPN_BUILD"
    cmake -S "$SCRIPT_DIR" -B "$MQVPN_BUILD" "${MAC_CMAKE_FLAGS[@]}" \
        -DANDROID_CROSS_COMPILE=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DXQUIC_BUILD_DIR="$XQUIC_BUILD" \
        -DBORINGSSL_BUILD_DIR="$BSSL_BUILD"
    cmake --build "$MQVPN_BUILD" --target mqvpn_lib

    echo "=== Staging artifacts to $OUT_DIR ==="
    resolve_bssl_libs
    cp "$MQVPN_BUILD/libmqvpn.a" "$OUT_DIR/"
    cp "$MQVPN_BUILD/liblwip_core.a" "$OUT_DIR/"
    cp "$XQUIC_BUILD/libxquic-static.a" "$OUT_DIR/"
    cp "$SSL_A" "$CRYPTO_A" "$OUT_DIR/"
    echo "=== Done ==="
    for a in libmqvpn.a liblwip_core.a libxquic-static.a libssl.a libcrypto.a; do
        [ -f "$OUT_DIR/$a" ] || { echo "missing staged archive: $a" >&2; exit 1; }
        lipo -info "$OUT_DIR/$a"
    done
fi
