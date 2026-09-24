#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# engine/build.sh — Build libvoiceengine.a: whisper.cpp (whisper + parakeet)
# and llama.cpp statically linked against ONE shared ggml.
#
# Usage:
#   engine/build.sh            # build if sources/pins changed, else no-op
#   engine/build.sh --clean    # wipe build output and rebuild
#
# Output:
#   engine/build/libvoiceengine.a
#
# Why one ggml: Homebrew's whisper-cpp vendors its own ggml (0.9.x) while
# llama.cpp links Homebrew's ggml (a different version). Loading both into
# one process gives two copies of ggml's global backend/Metal state. Building
# both projects from pinned sources against llama.cpp's ggml avoids that and
# lets the app link everything statically — no dylibs, no helper binaries.
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

for tool in cmake git clang++ libtool; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: ${tool} not found (brew install cmake / xcode-select --install)" >&2
        exit 1
    fi
done

STAMP_VALUE="${WHISPER_TAG} ${LLAMA_TAG} $(shasum -a 256 "${ENGINE_DIR}/VoiceEngine.cpp" "${ENGINE_DIR}/VoiceEngine.h" "$0" | shasum -a 256 | cut -d' ' -f1)"
if [[ -f "${OUT_LIB}" && -f "${STAMP}" && "$(cat "${STAMP}")" == "${STAMP_VALUE}" ]]; then
    echo "Engine up to date: ${OUT_LIB}"
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

mkdir -p "${DEPS_DIR}" "${BUILD_DIR}/obj"
fetch whisper.cpp https://github.com/ggml-org/whisper.cpp "${WHISPER_TAG}"
fetch llama.cpp   https://github.com/ggml-org/llama.cpp   "${LLAMA_TAG}"

# --- llama.cpp + ggml (static, Metal shaders embedded) ---
# BLAS is off: every model runs fully on Metal, and Accelerate's cblas entry
# points require macOS 13.3 (they would crash on 13.0-13.2). OpenMP is off so
# a build machine with libomp installed can't add a dynamic dependency.
# GGML_NATIVE=OFF + explicit arch keeps the binary portable across M1..M4
# rather than tuned to the build machine.
echo "Building llama.cpp ${LLAMA_TAG} + ggml..."
LLAMA_BUILD="${BUILD_DIR}/llama"
cmake -S "${DEPS_DIR}/llama.cpp" -B "${LLAMA_BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_CURL=OFF \
    -DLLAMA_OPENSSL=OFF \
    > "${BUILD_DIR}/llama-configure.log"
cmake --build "${LLAMA_BUILD}" -j "$(sysctl -n hw.ncpu)" --target llama > "${BUILD_DIR}/llama-build.log"

# --- whisper + parakeet sources against llama.cpp's ggml headers ---
echo "Building whisper.cpp ${WHISPER_TAG} (whisper + parakeet)..."
CXXFLAGS=(-std=c++17 -O3 -DNDEBUG -arch arm64 -mmacosx-version-min="${MACOS_MIN}")
INCLUDES=(
    -I"${DEPS_DIR}/whisper.cpp/include"
    -I"${DEPS_DIR}/whisper.cpp/src"
    -I"${DEPS_DIR}/llama.cpp/include"
    -I"${DEPS_DIR}/llama.cpp/ggml/include"
)
OBJ="${BUILD_DIR}/obj"
clang++ "${CXXFLAGS[@]}" "${INCLUDES[@]}" -DWHISPER_VERSION="\"${WHISPER_TAG#v}\"" \
    -c "${DEPS_DIR}/whisper.cpp/src/whisper.cpp" -o "${OBJ}/whisper.o"
clang++ "${CXXFLAGS[@]}" "${INCLUDES[@]}" -DPARAKEET_VERSION="\"${WHISPER_TAG#v}\"" \
    -c "${DEPS_DIR}/whisper.cpp/src/parakeet.cpp" -o "${OBJ}/parakeet.o"
clang++ "${CXXFLAGS[@]}" "${INCLUDES[@]}" -Wall -Wextra \
    -c "${ENGINE_DIR}/VoiceEngine.cpp" -o "${OBJ}/VoiceEngine.o"

# --- Merge into one archive ---
rm -f "${OUT_LIB}"
libtool -static -no_warning_for_no_symbols -o "${OUT_LIB}" \
    "${OBJ}/whisper.o" "${OBJ}/parakeet.o" "${OBJ}/VoiceEngine.o" \
    "${LLAMA_BUILD}/src/libllama.a" \
    "${LLAMA_BUILD}/ggml/src/libggml.a" \
    "${LLAMA_BUILD}/ggml/src/libggml-base.a" \
    "${LLAMA_BUILD}/ggml/src/libggml-cpu.a" \
    "${LLAMA_BUILD}/ggml/src/ggml-metal/libggml-metal.a" \
    2>&1 | grep -v 'same member name' || true

echo "${STAMP_VALUE}" > "${STAMP}"
echo "Built ${OUT_LIB} ($(du -h "${OUT_LIB}" | cut -f1))"
