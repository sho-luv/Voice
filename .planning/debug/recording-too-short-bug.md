---
status: active
priority: high
created: 2026-03-24
phase: 02-distribution
blocks: phase-02 checkpoint verification
---

# Bug: Recording broken — "Recording too short" + no audio capture

## Symptoms

1. **"Recording too short"**: User holds fn for 5+ seconds, speaks clearly, releases fn. Overlay shows "Recording too short" error. Happens consistently.
2. **Waveform animation not working**: The overlay shows during recording but the voice waveform visualization doesn't animate.
3. **Microphone selection broken**: In Settings > microphone dropdown, only "Obsidian" (Bluetooth headphones) works. "System Default", "Sho_Luv Microphone", "MacBook Pro Microphone" all fail to capture audio.
4. **Phantom device**: "CADefaultDeviceAggregate-41613-0" appears in mic picker — this is an internal AVAudioEngine aggregate device that should NOT be listed. Its presence means AVAudioEngine is creating aggregate devices (happens when input/output sample rates mismatch).

**Root cause is likely**: Audio data is not being written to the WAV file. The file is created (44-byte header) but the AVAudioEngine tap callback isn't producing data, OR the mic device selection is failing silently.

## Context

This appeared during Phase 02 (distribution) execution. Recording WAS working earlier in the session (confirmed after WhisperMinimal.entitlements fix). Then stopped working — unclear exactly which change broke it.

User also removed and re-added Voice from Accessibility and Microphone permissions during testing, which may have left the app in a bad permission state.

## Additional Issues Found During Phase 2

### Crash: AVAudioEngine dealloc race (FIXED in 721016a)
- `EXC_BAD_ACCESS` in `objc_msgSend` on `AVAudioIOUnit` dispatch queue
- Happened 6 seconds after wake from sleep
- Cause: `audioEngine = nil` triggered dealloc while audio IO thread had in-flight callback
- Fix: Delay engine dealloc by 200ms in all 4 teardown paths (stopRecording, cancelRecording, stopPopo, cancelPopo)

### Freeze: AX polling false triggers (FIXED in 721016a)
- `AXIsProcessTrusted()` can flicker momentarily, triggering `relaunchSilently()`
- Fix: Debounce (3 consecutive checks, ~6s) + 10-second wake grace period

### whisper-cli dylib loading (FIXED in b6e4185)
- whisper-cli failed with "different Team IDs" under hardened runtime
- Fix: Added `disable-library-validation` to `WhisperMinimal.entitlements`

## Changes Made in This Session

1. **Wave 1 (02-01)**: Bundle ID → `com.faradaysoft.voice`, entitlements tightened, create-dmg.sh rewritten, install.sh updated
2. **Wave 2 (02-02)**: OnboardingWindowController (~500 lines), AX polling + relaunchSilently, startAccessibilityPolling in applicationDidFinishLaunching
3. **Wave 3 (02-03)**: LicenseManager (~490 lines), recording gated by `canRecord`, expiry modal, license tab
4. **Fixes**: WhisperMinimal entitlements, wake grace, AX debounce, AVAudioEngine dealloc race

## Key Investigation Areas

### 1. Audio data not being captured (MOST LIKELY)
The WAV files are 44 bytes (header only). The AVAudioEngine tap callback should write audio data but isn't.

**Check after a recording attempt:**
```bash
ls -la "$TMPDIR"voice_*.wav 2>/dev/null | tail -5
# Should be >> 44 bytes for any real recording. 44 = header only = no audio data
```

**Possible causes:**
- Mic permission not actually granted for new bundle ID `com.faradaysoft.voice`
- AVAudioEngine tap not firing (engine not started, or tap removed prematurely)
- Selected mic device UID in UserDefaults points to a stale/invalid device
- AVAudioConverter failing silently (format mismatch between hardware and target)

### 2. CADefaultDeviceAggregate phantom device
This device appears when AVAudioEngine creates an internal aggregate to bridge mismatched sample rates between input and output. It should be filtered out of the mic picker. Its presence confirms AVAudioEngine is involved in device management, but it's also a sign of sample rate issues.

**Check**: `grep -n "listInputDevices\|CADefaultDeviceAggregate\|inputDevices" Voice.swift`
- The mic listing function should filter out aggregate devices
- Check if this device existed before Phase 2 changes

### 3. Microphone device selection
Only Bluetooth headphones (Obsidian) work. Built-in mic and other options fail.

**Check**:
```bash
# What mic is currently selected?
defaults read com.faradaysoft.voice micDeviceUID 2>/dev/null

# Reset to system default
defaults delete com.faradaysoft.voice micDeviceUID 2>/dev/null
```

The recording code sets the mic via CoreAudio `AudioUnitSetProperty` — if this fails, it logs but continues with default. But if the default device itself has issues...

### 4. License gate
Wave 3 gates recording with `LicenseManager.shared.canRecord`. If trial is expired, recording is blocked — but it would show the expiry modal, not "Recording too short".

```bash
# Check trial state
defaults read com.faradaysoft.voice trialStartDate 2>/dev/null
defaults read com.faradaysoft.voice isLicensed 2>/dev/null

# Reset trial
defaults delete com.faradaysoft.voice trialStartDate 2>/dev/null
defaults delete com.faradaysoft.voice isLicensed 2>/dev/null
```

### 5. Waveform animation
The overlay waveform reads `currentAudioLevel` which is set in the tap callback. If the tap isn't firing, `currentAudioLevel` stays 0 → no animation. This is a symptom of #1, not a separate bug.

## Debug Steps

### Step 1: Quick state reset
```bash
killall Voice 2>/dev/null
defaults delete com.faradaysoft.voice micDeviceUID 2>/dev/null
defaults delete com.faradaysoft.voice trialStartDate 2>/dev/null
defaults delete com.faradaysoft.voice isLicensed 2>/dev/null
sleep 1; bash install.sh
```
Try recording. If it works → stale UserDefaults was the issue.

### Step 2: Add debug logging
Add NSLog statements to trace the recording pipeline:
```swift
// In startRecording(), after engine.start():
NSLog("Voice: recording started, engine running: %d, audioFile: %@", engine.isRunning, tempFile)

// In tap callback, first buffer:
if self.audioDataSize == 0 {
    NSLog("Voice: first audio buffer, frames: %d, handle nil: %d", Int(convertedBuffer.frameLength), self.audioFileHandle == nil)
}

// In stopRecording():
NSLog("Voice: stop recording, audioDataSize: %d, audioFile: %@", self.audioDataSize, self.audioFile ?? "nil")
```

Rebuild, attempt recording, check logs:
```bash
log show --predicate 'eventMessage CONTAINS "Voice:"' --last 1m
```

### Step 3: Check file sizes
```bash
# After a recording attempt
find "$TMPDIR" -name "voice_*.wav" -newer /tmp -ls 2>/dev/null
```

### Step 4: Bisect
If logging doesn't reveal the cause, bisect to find which commit broke recording:
```bash
# Test the pre-Phase-2 state
git stash
git checkout 3f43f88  # last commit before Phase 2 execution
bash install.sh
# Test recording
# Then return
git checkout main
git stash pop
```

## Code Locations

- `startRecording()`: search for `func startRecording()`
- `stopRecording()`: search for `func stopRecording()`
- Tap callback: search for `installTap(onBus: 0`
- "Recording too short": `grep -n "too short" Voice.swift`
- Mic device listing: `grep -n "listInputDevices" Voice.swift`
- File size check: `grep -n "1000\|fileSize\|audioDataSize" Voice.swift`
- License gate: `grep -n "canRecord" Voice.swift`
- Waveform animation: `grep -n "currentAudioLevel" Voice.swift`

## Git History (newest first)

```
1bb3ae2 docs(debug): document recording-too-short regression
721016a fix(02): AVAudioEngine dealloc race + AX polling debounce
0cc4129 docs(02-03): complete license enforcement plan
7368b5f feat(02-03): add LicenseManager, expiry modal, license tab, recording gate
b6e4185 fix(02): wake-safe AX polling + whisper-cli entitlements
297f7ae Merge branch 'worktree-agent-a0fffa63' (onboarding)
4ea7e2e docs(02-01): complete bundle-ID unification + production signing plan
99d5738 feat(02-01): production signing, notarization pipeline, DMG background
7a8a9ac feat(02-01): unify bundle ID to com.faradaysoft.voice + LaunchAgent migration
```

## Phase 2 Execution Status

- 02-01 (bundle ID + signing): Code complete, merged
- 02-02 (onboarding): Code complete, merged, checkpoint NOT verified
- 02-03 (licensing): Code complete, merged, checkpoint NOT verified
- Phase verification: NOT run (blocked by this bug)
- All three waves need human verification once recording works
