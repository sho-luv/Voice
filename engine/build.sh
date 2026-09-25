#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# engine/build.sh — Build libvoiceengine.a: whisper.cpp (whisper + parakeet)
# and llama.cpp statically linked against ONE shared ggml.
#
# Usage:
#   engine/build.sh              # build for the host arch (fast; dev default)
#   VOICE_UNIVERSAL=1 engine/build.sh   # universal arm64 + x86_64 (releases)
#   engine/build.sh --clean      # wipe build output and rebuild
#
# Output:
#   engine/build/libvoiceengine.a  (fat when VOICE_UNIVERSAL=1)
#
# Per arch: the arm64 slice runs on Apple's Metal GPU; the x86_64 (Intel)
# slice has no Metal and runs on the CPU with AVX2/FMA, which every
# Ventura-capable Intel Mac supports. Both link one static ggml — no dylibs.
#
# Why one ggml: Homebrew's whisper-cpp and llama.cpp vendor different ggml
# versions; loading both would give two copies of ggml's global backend state.
# Building both from pinned sources against llama.cpp's ggml avoids that.
#
# Requirements: cmake, git, Xcode Command Line Tools.

set -euo pipefail

WHISPER_TAG="v1.9.4"
LLAMA_TAG="b11151"

ENGINE_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_DIR="${ENGINE_DIR}/.deps"
BUILD_DIR="${ENGINE_DIR}/build"
OUT_LIB="${BUILD_DIR}/libvoiceengine.a"
STAMP="${BUILD_DIR}/.stamp"
MACOS_MIN="13.0"

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf "${BUILD_DIR}"
fi

if [[ "${VOICE_UNIVERSAL:-0}" == "1" ]]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

for tool in cmake git clang++ libtool lipo; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: ${tool} not found (brew install cmake / xcode-select --install)" >&2
        exit 1
    fi
done

STAMP_VALUE="${WHISPER_TAG} ${LLAMA_TAG} ${ARCHS[*]} $(shasum -a 256 "${ENGINE_DIR}/VoiceEngine.cpp" "${ENGINE_DIR}/VoiceEngine.h" "$0" | shasum -a 256 | cut -d' ' -f1)"
if [[ -f "${OUT_LIB}" && -f "${STAMP}" && "$(cat "${STAMP}")" == "${STAMP_VALUE}" ]]; then
    echo "Engine up to date: ${OUT_LIB} (${ARCHS[*]})"
    exit 0
fi

fetch() { # name url tag
    local dir="${DEPS_DIR}/$1"
    if [[ -d "${dir}/.git" ]] && [[ "$(git -C "${dir}" describe --tags --exact-match 2>/dev/null)" == "$3" ]]; then
        return
    fi
    rm -rf "${dir}"
    echo "Fetching $1 $3..."
    git clone --quiet --depth 1 --branch "$3" "$2" "${dir}"
}

mkdir -p "${DEPS_DIR}"
fetch whisper.cpp https://github.com/ggml-org/whisper.cpp "${WHISPER_TAG}"
fetch llama.cpp   https://github.com/ggml-org/llama.cpp   "${LLAMA_TAG}"

INCLUDES=(
    -I"${DEPS_DIR}/whisper.cpp/include"
    -I"${DEPS_DIR}/whisper.cpp/src"
    -I"${DEPS_DIR}/llama.cpp/include"
    -I"${DEPS_DIR}/llama.cpp/ggml/include"
)

# Build a single-arch libvoiceengine into $BUILD_DIR/<arch>/libvoiceengine.a
build_arch() { # arch
    local arch="$1"
    local adir="${BUILD_DIR}/${arch}"
    local llama="${adir}/llama"
    local obj="${adir}/obj"
    mkdir -p "${obj}"

    # ggml backend differs per arch: Metal on Apple Silicon, AVX2 CPU on Intel.
    local backend_flags=()
    if [[ "${arch}" == "arm64" ]]; then
        backend_flags=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16)
    else
        backend_flags=(-DGGML_METAL=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON)
    fi

    echo "Building llama.cpp ${LLAMA_TAG} + ggml (${arch})..."
    cmake -S "${DEPS_DIR}/llama.cpp" -B "${llama}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="${arch}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_BLAS=OFF \
        -DGGML_OPENMP=OFF \
        -DGGML_NATIVE=OFF \
        "${backend_flags[@]}" \
        -DLLAMA_BUILD_COMMON=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TOOLS=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        -DLLAMA_CURL=OFF \
        -DLLAMA_OPENSSL=OFF \
        > "${adir}/llama-configure.log"
    cmake --build "${llama}" -j "$(sysctl -n hw.ncpu)" --target llama > "${adir}/llama-build.log"

    echo "Building whisper.cpp ${WHISPER_TAG} (whisper + parakeet, ${arch})..."
    local cxxflags=(-std=c++17 -O3 -DNDEBUG -arch "${arch}" -mmacosx-version-min="${MACOS_MIN}")
    clang++ "${cxxflags[@]}" "${INCLUDES[@]}" -DWHISPER_VERSION="\"${WHISPER_TAG#v}\"" \
        -c "${DEPS_DIR}/whisper.cpp/src/whisper.cpp" -o "${obj}/whisper.o"
    clang++ "${cxxflags[@]}" "${INCLUDES[@]}" -DPARAKEET_VERSION="\"${WHISPER_TAG#v}\"" \
        -c "${DEPS_DIR}/whisper.cpp/src/parakeet.cpp" -o "${obj}/parakeet.o"
    clang++ "${cxxflags[@]}" "${INCLUDES[@]}" -Wall -Wextra \
        -c "${ENGINE_DIR}/VoiceEngine.cpp" -o "${obj}/VoiceEngine.o"

    local libs=(
        "${obj}/whisper.o" "${obj}/parakeet.o" "${obj}/VoiceEngine.o"
        "${llama}/src/libllama.a"
        "${llama}/ggml/src/libggml.a"
        "${llama}/ggml/src/libggml-base.a"
        "${llama}/ggml/src/libggml-cpu.a"
    )
    [[ -f "${llama}/ggml/src/ggml-metal/libggml-metal.a" ]] && libs+=("${llama}/ggml/src/ggml-metal/libggml-metal.a")

    rm -f "${adir}/libvoiceengine.a"
    libtool -static -no_warning_for_no_symbols -o "${adir}/libvoiceengine.a" "${libs[@]}" \
        2>&1 | grep -v 'same member name' || true
}

for arch in "${ARCHS[@]}"; do
    build_arch "${arch}"
done

# Merge per-arch libraries into one (fat) archive.
rm -f "${OUT_LIB}"
if [[ "${#ARCHS[@]}" -eq 1 ]]; then
    cp "${BUILD_DIR}/${ARCHS[0]}/libvoiceengine.a" "${OUT_LIB}"
else
    lipo -create -output "${OUT_LIB}" \
        "${BUILD_DIR}/arm64/libvoiceengine.a" "${BUILD_DIR}/x86_64/libvoiceengine.a"
fi

echo "${STAMP_VALUE}" > "${STAMP}"
echo "Built ${OUT_LIB} (${ARCHS[*]}, $(du -h "${OUT_LIB}" | cut -f1))"
