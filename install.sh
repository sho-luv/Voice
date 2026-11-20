#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# install.sh — Build, sign and install Voice to /Applications, with a LaunchAgent.
#
# Usage: ./install.sh [--dry-run] [--force]
#   --dry-run   run the regression guard and say what would happen; build and change nothing
#   --force     skip the regression guard
#
# Regression guard: build-app.sh stamps each build with its commit (VoiceGitCommit,
# "-dirty" when tracked files had uncommitted changes). Before building, and so before
# /Applications is touched, the installed app's commit must be HEAD or an ancestor of
# HEAD, so the new build has everything the old one had. If it isn't (installed from
# another branch or another clone), it stops with exit code 3 and lists the commits that
# would be lost; --force overrides. An installed app with no stamp (built before stamping
# existed) can't be checked: it warns and goes ahead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"
BUILD_APP_DIR="${SCRIPT_DIR}/build.noindex/Voice.app"
# VOICE_INSTALL_APP_DIR is for testing the guard against a fake installed app; leave it unset.
INSTALL_APP_DIR="${VOICE_INSTALL_APP_DIR:-/Applications/Voice.app}"
BUNDLE_ID="com.faradaysoft.voice"
LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_PATH="${LAUNCH_AGENT_DIR}/com.faradaysoft.voice.plist"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

FORCE=0
DRY_RUN=0
for ARG in "$@"; do
    case "${ARG}" in
        --force) FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "usage: ./install.sh [--dry-run] [--force]" >&2; exit 2 ;;
    esac
done

echo "=== Voice Installer ==="

key() { /usr/libexec/PlistBuddy -c "Print :$1" "$2/Contents/Info.plist" 2>/dev/null || true; }
build_line() {
    echo "$(key CFBundleShortVersionString "$1") · $(key VoiceGitCommit "$1") · $(key VoiceGitBranch "$1") · built $(key VoiceBuildDate "$1")"
}

# Regression guard: runs before the build, so before the installed app is quit or replaced.
guard() {
    local head inst_commit inst n lost
    command -v git >/dev/null || { echo "Error: git not found (the regression guard needs it)" >&2; exit 1; }
    head="$(git rev-parse --short HEAD)"
    git diff --quiet HEAD -- || head="${head}-dirty"
    echo "building:        ${head} · $(git rev-parse --abbrev-ref HEAD)"
    if [[ "${FORCE}" -eq 1 ]]; then echo "guard: skipped (--force)"; return 0; fi
    if [[ ! -d "${INSTALL_APP_DIR}" ]]; then echo "guard: no ${INSTALL_APP_DIR}; nothing to compare"; return 0; fi
    inst_commit="$(key VoiceGitCommit "${INSTALL_APP_DIR}")"
    if [[ -z "${inst_commit}" ]]; then
        echo "WARNING: the installed Voice ($(key CFBundleShortVersionString "${INSTALL_APP_DIR}")) has no build stamp"
        echo "         (built before stamping existed), so it can't be checked; proceeding."
        return 0
    fi
    inst="${inst_commit%-dirty}"
    echo "installed build: $(build_line "${INSTALL_APP_DIR}")"
    stop() {
        {
            echo ""
            echo "STOPPED: the installed Voice has work this build does not."
            echo "  installed: commit ${inst_commit}, branch $(key VoiceGitBranch "${INSTALL_APP_DIR}"), built $(key VoiceBuildDate "${INSTALL_APP_DIR}")"
            echo "  this build: commit ${head} on $(git rev-parse --abbrev-ref HEAD)"
            echo "$1"
            echo "  Nothing was built and /Applications was not touched. To go ahead: merge that work into this branch,"
            echo "  or rerun with --force to replace the installed app anyway (its extra commits will not be in the new app)."
        } >&2
        exit 3
    }
    if ! git cat-file -e "${inst}^{commit}" 2>/dev/null; then
        stop "  commit ${inst} is not in this repository (${SCRIPT_DIR}): it was built from another clone or from commits that were never fetched here."
    elif git merge-base --is-ancestor "${inst}" HEAD; then
        n="$(git rev-list --count "${inst}..HEAD")"
        if [[ "${n}" -eq 0 ]]; then
            echo "guard: ok, same commit as installed"
        else
            echo "guard: ok, ${n} new commit(s) since the installed build:"
            git log --oneline "${inst}..HEAD" | head -10 | sed 's/^/  /'
        fi
        if [[ "${inst_commit}" == *-dirty ]]; then
            echo "WARNING: the installed build (${inst_commit}) had uncommitted changes that can't be checked."
            echo "         Make sure that work was committed; anything left uncommitted is not in this build."
        fi
    else
        lost="$(git log --oneline "HEAD..${inst}" | head -20 | sed 's/^/    /')"
        stop "  commits in the installed build that this build lacks ($(git rev-list --count "HEAD..${inst}")):
${lost}"
    fi
}

guard
if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "dry run: would build ${BUILD_APP_DIR}, sign it, replace ${INSTALL_APP_DIR}, write the LaunchAgent and launch it"
    exit 0
fi

# --- Dependencies ---
echo "Checking dependencies..."

if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew not found. Install from https://brew.sh" >&2
    exit 1
fi

# cmake builds the statically linked speech engine (engine/build.sh).
if ! command -v cmake &>/dev/null; then
    echo "Installing cmake..."
    brew install cmake
fi

# The app needs neither whisper-cli nor sox; the optional `voice` CLI does.
if [[ -f "${SCRIPT_DIR}/voice.sh" ]]; then
    if ! command -v whisper-cli &>/dev/null; then
        echo "Installing whisper-cpp for the voice CLI..."
        brew install whisper-cpp
    fi
    if ! command -v rec &>/dev/null; then
        echo "Installing sox for the voice CLI..."
        brew install sox
    fi
fi

# --- Build app (models are downloaded by the app on first launch) ---
"${SCRIPT_DIR}/build-app.sh"

# Sign with stable identity so macOS TCC keeps accessibility permission across recompiles.
# Priority: $VOICE_CODESIGN_IDENTITY > any Developer ID Application > Voice Dev > ad-hoc
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGN_CERT="${VOICE_CODESIGN_IDENTITY:-$(printf '%s\n' "${IDENTITIES}" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -z "$SIGN_CERT" ]] && printf '%s\n' "${IDENTITIES}" | grep -q '"Voice Dev"'; then
    SIGN_CERT="Voice Dev"
fi

if [[ -n "$SIGN_CERT" ]]; then
    codesign --force --sign "${SIGN_CERT}" --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/Voice.entitlements" \
        "${BUILD_APP_DIR}"
    echo "App bundle signed (${SIGN_CERT}) at ${BUILD_APP_DIR}"
else
    codesign --force --sign - --options runtime --entitlements "${SCRIPT_DIR}/Voice.entitlements" "${BUILD_APP_DIR}"
    echo "App bundle ad-hoc signed at ${BUILD_APP_DIR}"
    echo "Note: You may need to re-grant Accessibility permission after recompiling."
fi

# --- Install to /Applications ---
# Quit every running copy (the installed one, or one started from a build folder) so the
# new build is the one that holds the hotkey.
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f '/Voice\.app/Contents/MacOS/Voice$' >/dev/null || break
    sleep 0.5
done
pkill -f '/Voice\.app/Contents/MacOS/Voice$' 2>/dev/null || true
rm -rf "${INSTALL_APP_DIR}"
ditto "${BUILD_APP_DIR}" "${INSTALL_APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${INSTALL_APP_DIR}"
"${LSREGISTER}" -f "${INSTALL_APP_DIR}" || true
echo "Installed to ${INSTALL_APP_DIR}"

# --- One copy ---
# Drop every other path LaunchServices has for the bundle ID (the build folder, copies in the
# Trash, which Finder re-registers), then report what Spotlight and LaunchServices still list.
# Nothing is deleted.
registered() {
    "${LSREGISTER}" -dump 2>/dev/null | awk -v want="${BUNDLE_ID}" '
        /^-----/ { if (id == want && p != "") print p; id = ""; p = "" }
        /^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); p = $0 }
        /^identifier:/ { sub(/^identifier: */, ""); id = $0 }
        END { if (id == want && p != "") print p }' | sort -u
}
while IFS= read -r path; do
    [[ -z "${path}" || "${path}" == "${INSTALL_APP_DIR}" ]] && continue
    "${LSREGISTER}" -u "${path}" >/dev/null 2>&1 || true
    echo "unregistered extra copy from LaunchServices: ${path}"
done < <(registered)
extra=0
echo "Spotlight (mdfind) copies of ${BUNDLE_ID}:"
while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    if [[ "${path}" == "${INSTALL_APP_DIR}" ]]; then echo "  ${path}"; else echo "  ${path}   <-- EXTRA copy (not removed)"; extra=1; fi
done < <(mdfind "kMDItemCFBundleIdentifier == '${BUNDLE_ID}'")
echo "LaunchServices registrations of ${BUNDLE_ID}:"
while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    if [[ "${path}" == "${INSTALL_APP_DIR}" ]]; then echo "  ${path}"; else echo "  ${path}   <-- EXTRA registration"; extra=1; fi
done < <(registered)
if [[ "${extra}" -eq 0 ]]; then echo "one copy: ok"; else echo "one copy: see EXTRA lines above (move them to the Trash in Finder if unwanted, then rerun)"; fi

# --- Install voice CLI tool ---
VOICE_SH="${SCRIPT_DIR}/voice.sh"
if [[ -f "$VOICE_SH" ]]; then
    mkdir -p "${HOME}/bin"
    ln -sf "$VOICE_SH" "${HOME}/bin/voice"
    echo "Symlinked voice CLI to ~/bin/voice"
fi

# --- LaunchAgent (start on login) ---
mkdir -p "${LAUNCH_AGENT_DIR}"
cat > "${LAUNCH_AGENT_PATH}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.faradaysoft.voice</string>
    <key>Program</key>
    <string>${INSTALL_APP_DIR}/Contents/MacOS/Voice</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
echo "LaunchAgent installed (starts on login)"

# --- Launch ---
echo "Launching Voice..."
open "${INSTALL_APP_DIR}"
echo "now installed:   $(build_line "${INSTALL_APP_DIR}")"

echo ""
echo "=== Done ==="
echo "  Hold fn        = Push-to-talk (record while held)"
echo "  Double-tap fn  = Hands-free mode (lock-on dictation, tap fn to stop)"
echo "  Escape         = Cancel recording"
echo "  Menu bar: waveform icon"
echo ""
echo "First use: macOS will prompt for Accessibility and Microphone permissions -- grant both."
