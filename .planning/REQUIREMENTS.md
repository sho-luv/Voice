# Requirements: Voice

**Defined:** 2026-03-24
**Core Value:** Local-only, instant dictation that works everywhere on macOS — press a key, speak, text appears. Privacy is non-negotiable.

## v1 Requirements

### Audio

- [x] **AUD-01**: App records audio using AVAudioEngine instead of external sox/rec
- [x] **AUD-02**: User can select microphone input device from Settings
- [x] **AUD-03**: App handles Bluetooth/AirPods mic gracefully (detect zero-buffer, show warning)
- [x] **AUD-04**: App detects active app and adjusts AI cleanup prompt per-app context

### Visual

- [x] **VIS-01**: Recording overlay shows animated waveform bars responding to voice levels
- [x] **VIS-02**: Recording overlay shows which app will receive the transcribed text

### Distribution

- [ ] **DIST-01**: App is signed with Developer ID and DMG is notarized
- [ ] **DIST-02**: First launch guides user through accessibility and microphone permissions
- [ ] **DIST-03**: App auto-restarts when accessibility permission is toggled
- [ ] **DIST-04**: App validates LemonSqueezy license key (gate after trial period)

### History & Editing

- [ ] **HIST-01**: Transcriptions are stored locally and searchable (History window, Cmd+H)
- [ ] **HIST-02**: User can add custom dictionary words to improve transcription accuracy
- [ ] **HIST-03**: Voice commands ("scratch that", "new paragraph", "select all") work during dictation
- [ ] **HIST-04**: User can transcribe audio/video files via Cmd+O

## v2 Requirements

### Platform Expansion

- **PLAT-01**: iOS version with same core functionality
- **PLAT-02**: Android version
- **PLAT-03**: Windows version
- **PLAT-04**: Linux version

### Advanced Features

- **ADV-01**: Meeting recorder using ScreenCaptureKit
- **ADV-02**: VAD (voice activity detection) for auto-start/stop
- **ADV-03**: Real-time streaming transcription
- **ADV-04**: Multi-language support with auto-detection

## Out of Scope

| Feature | Reason |
|---------|--------|
| App Store distribution | Requires sandboxing which breaks accessibility/hotkey features |
| Cloud transcription | Contradicts privacy-first positioning |
| Real-time streaming | whisper.cpp works on complete audio files; would require different engine |
| Meeting recorder | High complexity (ScreenCaptureKit), defer to v2 |
| VAD integration | Nice-to-have, not blocking for v1 launch |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| AUD-01 | Phase 1 | Complete |
| AUD-02 | Phase 1 | Complete |
| AUD-03 | Phase 1 | Complete |
| AUD-04 | Phase 1 | Complete |
| VIS-01 | Phase 1 | Complete |
| VIS-02 | Phase 1 | Complete |
| DIST-01 | Phase 2 | Pending |
| DIST-02 | Phase 2 | Pending |
| DIST-03 | Phase 2 | Pending |
| DIST-04 | Phase 2 | Pending |
| HIST-01 | Phase 3 | Pending |
| HIST-02 | Phase 3 | Pending |
| HIST-03 | Phase 3 | Pending |
| HIST-04 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 14 total
- Mapped to phases: 14
- Unmapped: 0

---
*Requirements defined: 2026-03-24*
*Last updated: 2026-03-24 after roadmap creation*
