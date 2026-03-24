---
status: investigating
trigger: "recording-too-short"
created: 2026-03-24
updated: 2026-03-24
---

## Current Focus
<!-- OVERWRITE on each update - reflects NOW -->

hypothesis: Tap callback either not firing at all, OR firing but producing 0-length converted buffers. Root cause unknown — needs observability data from debug logging.
test: Added NSLog to startRecording (engine start success + format), tap callback (first 3 calls with frameLength), and stopRecording (audioDataSize). Rebuilt and relaunched. Need user to attempt a recording.
expecting: Logs will show either:
  - "engine.start() FAILED" → mic permission denied
  - "tap#1 bufFrames=0" → tap fires but no data (permission issue or aggregate device)
  - No tap logs at all → tap never fires (engine started but not delivering audio)
  - "tap#1 bufFrames=4096" but "converted frameLength=0" → converter bug
  - "stopRecording audioDataSize=0" with no tap logs → tap never called
next_action: User needs to attempt recording, then read logs with: log show --predicate 'eventMessage CONTAINS "Voice:"' --last 2m

## Symptoms
<!-- Written during gathering, then IMMUTABLE -->

expected: Hold fn, speak, release — transcribed text appears
actual: "Recording too short" error every time. WAV files are 44 bytes (empty).
errors: "Recording too short" overlay message
reproduction: Hold fn for 5+ seconds, speak clearly, release fn. Happens consistently.
started: During Phase 02 execution. Recording was working earlier in the session.

## Eliminated
<!-- APPEND only - prevents re-investigating -->

- hypothesis: LicenseManager canRecord gate blocking recording
  evidence: canRecord gate shows expiry modal, not "recording too short" message. Trial start date is set.
  timestamp: 2026-03-24

- hypothesis: Recording pipeline code was changed in Phase 02 (code regression)
  evidence: Diff of Phase 01 vs current startRecording() is identical (minus dealloc delay). Phase 01 recording was verified working.
  timestamp: 2026-03-24

- hypothesis: entitlements missing audio-input
  evidence: codesign -d confirms com.apple.security.device.audio-input=true in deployed app
  timestamp: 2026-03-24

## Evidence
<!-- APPEND only - facts discovered -->

- timestamp: 2026-03-24T00:00:00Z
  checked: debug file from prior session
  found: WAV files are 44 bytes (header only). Tap likely not firing OR producing 0 frames. Only Bluetooth headphones work. Phantom CADefaultDeviceAggregate device in picker.
  implication: Audio data not being written

- timestamp: 2026-03-24T18:20:00Z
  checked: UserDefaults for com.faradaysoft.voice
  found: micDeviceUID = "AC-BF-71-E2-7B-E0:input" (Bluetooth headphones UID). trialStartDate set (within trial). onboardingComplete = true.
  implication: A specific mic device is selected. If Bluetooth headphones are not connected, code falls back to system default.

- timestamp: 2026-03-24T18:20:00Z
  checked: TCC microphone permission via tccutil reset
  found: tccutil reset ran 4 times (4 different TCC entries for com.faradaysoft.voice). Permission reset to notDetermined.
  implication: App will need to re-request mic permission. IMPORTANT: I ran tccutil reset in this session — this may have made the situation worse.

- timestamp: 2026-03-24T18:25:00Z
  checked: Phase 01 startRecording code vs current
  found: Recording pipeline is IDENTICAL between Phase 01 (working) and current (broken). No code regression in the pipeline itself.
  implication: Bug is environmental, not a code regression in the recording path.

- timestamp: 2026-03-24T18:28:00Z
  checked: Voice app signs with "Voice Dev" cert (ad-hoc fallback)
  found: Voice Dev cert used, TeamIdentifier=not set. Each build gets a new code signature.
  implication: TCC permission may need to be re-granted after each build. The multiple tccutil resets suggest the user was fighting this.

## Resolution
<!-- OVERWRITE as understanding evolves -->

root_cause: INVESTIGATING — need debug log output
fix:
verification:
files_changed: []
