#!/usr/bin/env bash
#
# voice - Record speech, transcribe locally with whisper.cpp, copy to clipboard.
#
# Usage: voice [-m MODEL] [-s] [-k]
#   -m MODEL  Model name (default: small.en). File: ~/.local/share/whisper-models/ggml-MODEL.bin
#   -s        Silence-only mode (auto-stop on 3s silence, no Enter needed)
#   -k        Keep audio file after transcription
#

set -euo pipefail

# --- Defaults ---
MODEL_DIR="${HOME}/.local/share/whisper-models"
MODEL_NAME="small.en"
SILENCE_ONLY=false
KEEP_AUDIO=false
THREADS=8
SILENCE_DURATION="3.0"
AUDIO_FILE=""
REC_PID=""

# --- Parse flags ---
while getopts "m:skh" opt; do
    case "$opt" in
        m) MODEL_NAME="$OPTARG" ;;
        s) SILENCE_ONLY=true ;;
        k) KEEP_AUDIO=true ;;
        h)
            sed -n '3,10p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            sed -n '3,10p' "$0" | sed 's/^# \?//'
            exit 1
            ;;
    esac
done

STOP_FILE="/tmp/voice_stop_signal"
PID_FILE="/tmp/voice_rec.pid"

# --- Handle "voice stop" subcommand ---
shift $((OPTIND - 1))
if [[ "${1:-}" == "stop" ]]; then
    if [[ -f "$PID_FILE" ]]; then
        touch "$STOP_FILE"
        echo "Stopping recording..." >&2
    else
        echo "No recording in progress." >&2
    fi
    exit 0
fi

MODEL_FILE="${MODEL_DIR}/ggml-${MODEL_NAME}.bin"

# --- Preflight checks ---
if ! command -v whisper-cli &>/dev/null; then
    echo "Error: whisper-cli not found. Install with: brew install whisper-cpp" >&2
    exit 1
fi

if ! command -v rec &>/dev/null; then
    echo "Error: rec (sox) not found. Install with: brew install sox" >&2
    exit 1
fi

if [[ ! -f "$MODEL_FILE" ]]; then
    echo "Error: Model not found at ${MODEL_FILE}" >&2
    echo "Download it with:" >&2
    echo "  curl -L -o \"${MODEL_FILE}\" \\
    \"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin\"" >&2
    exit 1
fi

# --- Cleanup handler ---
cleanup() {
    # Kill recording process if still running
    if [[ -n "$REC_PID" ]] && kill -0 "$REC_PID" 2>/dev/null; then
        kill "$REC_PID" 2>/dev/null
        wait "$REC_PID" 2>/dev/null || true
    fi
    # Remove signal/PID files
    rm -f "$STOP_FILE" "$PID_FILE"
    # Remove temp audio file unless -k flag set
    if [[ "$KEEP_AUDIO" == false && -n "$AUDIO_FILE" && -f "$AUDIO_FILE" ]]; then
        rm -f "$AUDIO_FILE"
    elif [[ "$KEEP_AUDIO" == true && -n "$AUDIO_FILE" && -f "$AUDIO_FILE" ]]; then
        echo "Audio saved: ${AUDIO_FILE}" >&2
    fi
}
trap cleanup EXIT INT TERM

# --- Create temp audio file ---
AUDIO_FILE="$(mktemp /tmp/voice_XXXXXX.wav)"

# --- Audio indicators ---
beep_start() { afplay /System/Library/Sounds/Tink.aiff 2>/dev/null & }
beep_stop()  { afplay /System/Library/Sounds/Pop.aiff 2>/dev/null & }

# --- Clean up any stale signal file ---
rm -f "$STOP_FILE"

# --- Record audio ---
if [[ "$SILENCE_ONLY" == true ]]; then
    echo "🎙 Recording... (auto-stops after ${SILENCE_DURATION}s of silence)" >&2
    beep_start
    rec -r 16000 -c 1 -b 16 "$AUDIO_FILE" \
        silence 1 0.1 0.5% 1 "$SILENCE_DURATION" 0.5% 2>/dev/null
    beep_stop
else
    echo "🎙 Recording... (run 'voice stop' to finish)" >&2
    beep_start
    # Start recording in background (silence detection as fallback)
    rec -r 16000 -c 1 -b 16 "$AUDIO_FILE" \
        silence 1 0.1 0.5% 1 "$SILENCE_DURATION" 0.5% 2>/dev/null &
    REC_PID=$!
    echo "$REC_PID" > "$PID_FILE"

    # Wait for stop signal, Enter key, or rec to exit on its own
    while kill -0 "$REC_PID" 2>/dev/null; do
        if [[ -f "$STOP_FILE" ]]; then
            kill "$REC_PID" 2>/dev/null
            wait "$REC_PID" 2>/dev/null || true
            REC_PID=""
            break
        fi
        if read -r -t 0.3 2>/dev/null; then
            kill "$REC_PID" 2>/dev/null
            wait "$REC_PID" 2>/dev/null || true
            REC_PID=""
            break
        fi
    done
    REC_PID=""
    beep_stop
fi

# --- Validate recording ---
if [[ ! -s "$AUDIO_FILE" ]]; then
    echo "Error: No audio recorded." >&2
    exit 1
fi

DURATION=$(soxi -D "$AUDIO_FILE" 2>/dev/null || echo "0")
if (( $(echo "$DURATION < 0.5" | bc -l) )); then
    echo "Error: Recording too short (${DURATION}s). Try again." >&2
    exit 1
fi

echo "Transcribing ($(printf '%.1f' "$DURATION")s of audio)..." >&2

# --- Transcribe ---
TRANSCRIPT=$(whisper-cli \
    --model "$MODEL_FILE" \
    --file "$AUDIO_FILE" \
    --no-timestamps \
    --threads "$THREADS" \
    --language en \
    2>/dev/null)

# Clean up whisper output: remove leading/trailing whitespace and blank lines
TRANSCRIPT=$(echo "$TRANSCRIPT" | sed '/^$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [[ -z "$TRANSCRIPT" ]]; then
    echo "Error: Transcription returned empty result." >&2
    exit 1
fi

# --- Output ---
echo "$TRANSCRIPT"
echo -n "$TRANSCRIPT" | pbcopy
echo "(Copied to clipboard)" >&2
