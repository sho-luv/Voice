# Voice

## What This Is

Voice is a privacy-first macOS speech-to-text app by Faraday Soft (Enfrosec LLC). Press fn, talk, release — transcribed text is pasted into whatever app you're using. All processing happens locally using whisper.cpp. No cloud, no data collection, no accounts. Sold as a one-time $29 purchase via LemonSqueezy.

## Core Value

Local-only, instant dictation that works everywhere on macOS — press a key, speak, text appears. Privacy is non-negotiable.

## Requirements

### Validated

- ✓ fn push-to-talk recording — existing (v3.0)
- ✓ POPO lock-on dictation mode — existing (v3.0)
- ✓ Local whisper.cpp transcription — existing (v3.0)
- ✓ Menu bar icon with recording overlay — existing (v3.0)
- ✓ Paste-to-active-app via clipboard — existing (v3.0)
- ✓ Settings window (General, AI, Transcription) — existing (v3.1)
- ✓ Multi-provider AI cleanup (OpenAI, Anthropic, Ollama) — existing (v3.1)
- ✓ Bundled whisper model (large-v3-turbo-q5_0) — existing (v3.2)
- ✓ Bundled whisper-cli in app bundle — existing (v3.2)
- ✓ Configurable hotkey (fn, Right Option, Right Command) — existing (v3.1)
- ✓ Sound feedback (recording start/stop) — existing (v3.0)
- ✓ Model download from Settings — existing (v3.1)

### Active

- [ ] Replace `rec` (sox) with native AVFoundation recording — eliminate external dependency
- [ ] Microphone input device selector in Settings — let user choose which mic
- [ ] Waveform animation overlay during recording — visual voice feedback
- [ ] Transcription history with search — review past dictations
- [ ] Voice commands ("scratch that", "new paragraph", "select all") — hands-free editing
- [ ] Target app indicator in overlay — show which app will receive text
- [ ] Custom dictionary/words in Settings — improve accuracy for domain terms
- [ ] File transcription (Cmd+O) — transcribe audio/video files
- [ ] History window (Cmd+H) — browse and re-use past transcriptions
- [ ] Developer ID code signing + notarization — distribute signed DMGs
- [ ] Auto-restart on accessibility permission change — like Wispr Flow
- [ ] First-launch onboarding — guide non-technical users through permissions
- [ ] LemonSqueezy license key validation — gate app after trial period

### Out of Scope

- App Store distribution — requires sandboxing which breaks accessibility/hotkey features
- iOS/Android/Windows/Linux — future milestone, not v1
- Real-time streaming transcription — whisper.cpp works on complete audio files
- Meeting recorder (ScreenCaptureKit) — complex feature, defer to later milestone
- VAD (voice activity detection) — nice-to-have, not critical for v1
- Cloud transcription fallback — contradicts privacy-first positioning

## Context

- **Business**: Enfrosec LLC (Texas), DBA Faraday Soft. Apple Developer Program enrolled (Team ID: MWW7M2563A)
- **Distribution**: Signed + notarized DMG via faradaysoft.com, payments via LemonSqueezy ($29 one-time)
- **Architecture**: Single-file Swift app (Voice.swift, ~2230 lines), compiled with swiftc, no Xcode project
- **Key dependency to remove**: Still uses `/opt/homebrew/bin/rec` (sox) for audio recording — must replace with AVFoundation for self-contained app
- **Code signing lesson**: Every rebuild changes CDHash, invalidating TCC accessibility permission. Need stable signing identity or auto-restart pattern
- **Competitive landscape**: Wispr Flow ($200/yr, cloud-based despite "privacy" claims), MacWhisper ($69), VoiceInk ($40). Voice is smallest (4.2MB without model), cheapest, and truly local
- **Lost work**: Previous session had AVFoundation recording, waveform overlay, transcription history, voice commands, and more — all lost via accidental `git checkout`. This project rebuilds those features properly with commits after each phase

## Constraints

- **No Xcode**: Build with swiftc directly — keeps it simple, no project file complexity
- **Single file**: Voice.swift monolith — may need to split if it grows past ~3000 lines
- **Privacy**: Zero network requests unless user explicitly enables AI cleanup
- **Self-contained**: App bundle must include everything (whisper-cli, dylibs, model) — no homebrew dependencies at runtime
- **macOS only**: Target macOS 13+ (Ventura and later)
- **Accessibility permission**: Required for global hotkey — UX must handle permission flow gracefully

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Single-file Swift app | Simplicity, no Xcode overhead, fast iteration | ✓ Good |
| whisper.cpp via CLI | Avoids C bridging complexity, bundled binary works | ✓ Good |
| fn as default hotkey | Universal key, doesn't conflict with shortcuts | ✓ Good |
| $29 one-time pricing | Undercuts all competitors, simple value prop | — Pending |
| LemonSqueezy for payments | MoR handles taxes/compliance, license keys built in | — Pending |
| Developer ID (not App Store) | App Store requires sandbox which breaks accessibility | ✓ Good |
| large-v3-turbo-q5_0 as default model | Best accuracy/speed tradeoff, 574MB quantized | ✓ Good |
| Replace sox with AVFoundation | Eliminates external dependency, enables mic selector | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-24 after initialization*
