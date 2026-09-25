#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# build-app.sh — Compile Voice and assemble an unsigned Voice.app.
#
# Usage:
#   ./build-app.sh
#   VOICE_BUNDLE_MODELS=1 ./build-app.sh    # also copy installed models into the bundle
#   VOICE_UNIVERSAL=1 ./build-app.sh        # universal arm64 + x86_64 (Intel) app
#
# Shared by install.sh (local install) and create-dmg.sh (release). Signing is
# left to the caller. The speech/cleanup engine is linked statically, so the
# bundle is just the executable, Info.plist and icon — no helper binaries,
# no dylibs. Models are downloaded (and SHA-256 verified) by the app on first
# launch unless VOICE_BUNDLE_MODELS=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${SCRIPT_DIR}/Voice.app/Contents"
MODEL_DIR="${HOME}/Library/Application Support/Voice/Models"
MACOS_MIN="13.0"

"${SCRIPT_DIR}/engine/build.sh"

if [[ "${VOICE_UNIVERSAL:-0}" == "1" ]]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

# swiftc builds one arch per invocation; for a universal app compile each and
# lipo the executables. The linker picks the matching slice from the fat engine.
compile_arch() { # arch outfile
    swiftc -O -parse-as-library -target "$1-apple-macos${MACOS_MIN}" -o "$2" \
        "${SCRIPT_DIR}/Voice.swift" \
        "${SCRIPT_DIR}/SpeechEngine.swift" \
        "${SCRIPT_DIR}/VoiceExceptionCatcher.m" \
        -import-objc-header "${SCRIPT_DIR}/Voice-Bridging-Header.h" \
        -I"${SCRIPT_DIR}/engine" \
        -L"${SCRIPT_DIR}/engine/build" -lvoiceengine -lc++ \
        -framework Cocoa -framework ApplicationServices \
        -framework UserNotifications -framework AVFoundation \
        -framework CoreAudio -framework Metal -framework Accelerate \
        -Xlinker -x \
        -Xlinker -dead_strip
}

echo "Compiling Voice (${ARCHS[*]})..."
if [[ "${#ARCHS[@]}" -eq 1 ]]; then
    compile_arch "${ARCHS[0]}" "${SCRIPT_DIR}/Voice"
else
    slices=()
    for arch in "${ARCHS[@]}"; do
        compile_arch "${arch}" "${SCRIPT_DIR}/Voice-${arch}"
        slices+=("${SCRIPT_DIR}/Voice-${arch}")
    done
    lipo -create -output "${SCRIPT_DIR}/Voice" "${slices[@]}"
    rm -f "${slices[@]}"
fi

echo "Creating app bundle..."
rm -rf "${SCRIPT_DIR}/Voice.app"
mkdir -p "${APP_DIR}/MacOS" "${APP_DIR}/Resources"
cp "${SCRIPT_DIR}/Voice" "${APP_DIR}/MacOS/Voice"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Info.plist"
cp "${SCRIPT_DIR}/Voice.icns" "${APP_DIR}/Resources/Voice.icns"

if [[ "${VOICE_BUNDLE_MODELS:-0}" == "1" ]]; then
    # File names must match ModelCatalog in SpeechEngine.swift.
    for model in ggml-parakeet-tdt-0.6b-v3-q4_0.bin qwen2.5-1.5b-instruct-q4_0.gguf; do
        if [[ ! -f "${MODEL_DIR}/${model}" ]]; then
            echo "Error: VOICE_BUNDLE_MODELS=1 but ${model} is not in ${MODEL_DIR}" >&2
            echo "  Launch Voice once to download it." >&2
            exit 1
        fi
        echo "  Bundling ${model} ($(du -h "${MODEL_DIR}/${model}" | cut -f1))"
        cp "${MODEL_DIR}/${model}" "${APP_DIR}/Resources/"
    done
fi

echo "Built ${SCRIPT_DIR}/Voice.app ($(du -sh "${SCRIPT_DIR}/Voice.app" | cut -f1))"
