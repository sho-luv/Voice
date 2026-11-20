#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# run.sh — transcribe every test set under a bench directory and print word error rates.
#
# Usage:
#   tools/bench/run.sh <bench-dir> <label> [Voice --bench flags, e.g. --prep old --whisper]
#
# <bench-dir> holds refs.json plus one folder of 16 kHz mono WAVs per test set.
# Output goes to <bench-dir>/<label>.tsv.

set -euo pipefail

BENCH_DIR="$1"
LABEL="$2"
shift 2
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VOICE="${VOICE_BIN:-${SCRIPT_DIR}/../../Voice.app/Contents/MacOS/Voice}"
SETS="${BENCH_SETS:-clean quiet quiet_click veryquiet tail_cut200 tail_cut400 head_cut250 noise10 noise5 hum_dc clipped padded}"

DIRS=()
for set in ${SETS}; do
    DIRS+=("${BENCH_DIR}/${set}")
done
"${VOICE}" --bench "$@" "${DIRS[@]}" > "${BENCH_DIR}/${LABEL}.tsv"
python3 "${SCRIPT_DIR}/wer.py" "${BENCH_DIR}/refs.json" "${BENCH_DIR}/${LABEL}.tsv"
