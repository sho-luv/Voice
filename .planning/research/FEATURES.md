# Feature Landscape: macOS Dictation Apps

**Domain:** Push-to-talk local speech-to-text dictation (macOS)
**Researched:** 2026-03-24
**Scope:** Competitive analysis of Wispr Flow, SuperWhisper, VoiceInk, MacWhisper, WhisperNotes, Sotto, and emerging apps for a $29 local-only dictation product

---

## Table Stakes

Features users expect as baseline. Missing = product feels broken or incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Push-to-talk global hotkey | Every competitor has it; Apple Dictation has it | Low | Voice already ships this (fn, right option, right command) |
| Works in every app | Users dictate into Slack, email, terminal, browsers — not one app | Medium | Voice already does this via accessibility + clipboard fallback |
| Instant paste at cursor | Users expect text to appear where cursor is | Medium | Fragile (see CONCERNS.md); must be robust |
| Visual recording indicator | Users need confirmation they're being recorded | Low | Waveform overlay is now standard (not a spinner); Voice has basic overlay but no waveform |
| Audio feedback (start/stop sounds) | Prevents silent recording confusion | Low | Voice already ships this |
| Filler word removal / AI cleanup | "Um", "uh", repeated words — all competitors handle this | Medium | Voice ships this (v3.1) via OpenAI/Anthropic/Ollama |
| Multiple Whisper model sizes | Fast small vs. accurate large — power users want to choose | Low | Voice ships this (download from Settings) |
| Privacy-first local processing | Non-negotiable for privacy segment; table stakes for this product category | Low | Voice's core identity; already ships |
| No subscription required | Subscription fatigue is real; users ask for one-time purchase specifically | Low | Voice ships at $29 one-time |
| Microphone input selector | Users have headsets, external mics, built-in — must choose | Low-Med | Missing in Voice; noted in CONCERNS.md as blocking |
| Language selection | English-only blocks international users; 100+ languages is Whisper's strength | Low | Missing in Voice (hardcoded to "en") |
| Model download progress | 574MB downloads take minutes; "Downloading..." with no progress is unacceptable UX | Low | Missing in Voice; noted in CONCERNS.md |
| Error recovery / timeout | If transcription hangs, users must relaunch — unacceptable for a paid tool | Medium | Missing in Voice; whisper-cli hang has no timeout |

**Verdict on Voice v3.2:** Roughly 7 of 13 table stakes are met. The four highest-priority gaps are: waveform indicator, microphone selector, language selection, and error recovery.

---

## Differentiators

Features that create competitive advantage. Users don't always expect them, but they generate word-of-mouth and reduce churn.

| Feature | Value Proposition | Complexity | Competitors With It | Notes |
|---------|-------------------|------------|---------------------|-------|
| Transcription history with search | Re-paste earlier dictations; users lose text constantly | Medium | SuperWhisper, OpenWhispr, MacWhisper | Voice had this in lost session; high-value, low-friction to add |
| Per-app context / Power Mode | Different AI prompt for Slack vs. email vs. code — adjusts tone automatically | High | VoiceInk (Power Mode), SuperWhisper (modes), Wispr Flow | VoiceInk's #1 differentiator; reads active app/URL via accessibility APIs |
| Custom vocabulary / dictionary | Domain terms, proper nouns, brand names — "Kubernetes" not "communities" | Medium | SuperWhisper, Wispr Flow, Aqua Voice (800 words), Sotto | Directly addresses #1 user frustration with Whisper accuracy |
| Voice commands ("scratch that", "new paragraph") | Hands-free editing without touching keyboard | High | Wispr Flow (Command Mode), SuperWhisper | Wispr Flow charges extra for this (Pro tier); differentiated if local |
| File transcription (audio/video import) | Journalists, podcasters, students transcribe recordings | Medium | MacWhisper (primary use case), SuperWhisper, WhisperNotes | Already in Voice's active requirements; low-conflict with push-to-talk UX |
| Waveform overlay (animated, not static) | Users feel heard; distinguishes recording state from idle; 2025 standard | Low | VocaType (4 styles), PulseScribe, Dictar, macOS Tahoe native | Voice has static overlay; animated waveform is table stakes by late 2025 |
| POPO lock-on mode | Long-form dictation without holding key — useful for documents, emails | Low-Med | Few competitors do this well | Voice already ships this; differentiated, worth marketing |
| First-launch onboarding | Non-technical users abandon at the permission screen | Medium | Wispr Flow, SuperWhisper have polished onboarding | Currently missing; gates paid user conversion |
| License key / trial gating | Without it, app is effectively free forever — no revenue | Low-Med | Standard for paid indie apps | Missing; blocks monetization |
| Dynamic thread count (CPU auto-detect) | Transcription speed scales to the machine; removes hardcoded 8-thread limit | Low | Not explicitly marketed by competitors, but good hygiene | 1-line fix in Voice (use ProcessInfo.processInfo.activeProcessorCount) |
| Keychain storage for API keys | Users storing keys in Wispr Flow discovered them in plaintext plist — real concern | Low | Likely most competitors | Straightforward fix; privacy-claiming app must do this |
| Target app indicator in overlay | Shows "pasting into: Notion" — confirms correct destination | Low | Wispr Flow shows destination in UI | Small trust-builder; was in Voice's active requirements |

**Priority tier for Voice:**
1. **Quick wins with high impact:** Waveform overlay, transcription history, custom vocabulary, keychain API storage
2. **Meaningful differentiators:** Per-app context mode, voice commands (local-only, no Pro upsell)
3. **Business-critical but not user-visible:** License key gating, onboarding, code signing

---

## Anti-Features

Things to deliberately NOT build. These would dilute the product or contradict its positioning.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Cloud transcription fallback | Contradicts the entire privacy value prop; if local fails, say so clearly | Show clear error with actionable message (model missing, whisper crash) |
| Account/login system | Users chose this app to avoid accounts; adds infrastructure, friction, and a breach surface | LemonSqueezy license keys handle auth without persistent accounts |
| Continuous always-on listening (ambient mode) | Privacy disaster; users will not trust an app that listens without a hotkey | Keep push-to-talk as the mandatory activation model |
| App Store version | Requires sandbox, which breaks global hotkey and accessibility injection — technically impossible without major rewrites | Developer ID + notarized DMG is the right distribution path |
| Subscription pricing | Target segment explicitly rejects subscriptions; one-time $29 is a competitive advantage | Do not add tiers or subscriptions; one-time only |
| Meeting recorder (ScreenCaptureKit) | Completely different user job; complex permission surface; moves away from dictation identity | Defer indefinitely; not this product |
| Real-time streaming transcription | whisper.cpp is batch-based; faking real-time with partial commits causes quality degradation | Accept the post-recording transcription model; show waveform during recording to mask latency |
| Settings sprawl | SuperWhisper's #1 complaint is overwhelming configurability; "just pick good defaults" is user feedback | Expose ~8-10 settings max; sensible defaults for everything; advanced options hidden but accessible |
| Windows/Linux/iOS port | Dilutes macOS-native quality; the accessibility/hotkey architecture is deeply macOS-specific | macOS only; ship the Mac product well |
| Translation feature | Out of scope for dictation; adds LLM infrastructure; Wispr Flow charges premium for this | Transcribe in the user's language; don't translate |

---

## Feature Dependencies

```
License key gating
  → requires: LemonSqueezy integration, first-launch onboarding

First-launch onboarding
  → requires: Stable code signing (Developer ID + notarization)

Microphone selector
  → requires: AVFoundation migration (replace sox/rec dependency)

Per-app context mode
  → requires: Accessibility API (already used for text injection)
  → requires: Transcription history (context mode needs to re-process)

Voice commands ("scratch that")
  → requires: Transcription history (need to know what to scratch)
  → requires: Accessibility API (already used)

File transcription
  → requires: whisper-cli (already bundled)
  → independent of: push-to-talk recording pipeline

Custom vocabulary
  → independent of other features; pure whisper-cli flag pass-through (--prompt)

Waveform animation
  → requires: AVFoundation migration (AVAudioEngine provides level metering)
  → blocks: microphone selector (same migration)
```

---

## MVP Recommendation for Next Milestone

The existing app is functional but not yet sellable. These are the features needed before charging $29:

**Must ship (pre-launch):**
1. AVFoundation recording migration — unblocks microphone selector + waveform; fixes broken install path
2. Animated waveform overlay — table stakes by 2025 standard; visual polish users expect
3. Microphone input selector — table stakes; blocks professional users
4. Error recovery / transcription timeout — prevents "stuck in processing" soft-lock
5. First-launch onboarding with permission flow — non-technical users abandon without it
6. Developer ID code signing + notarization — required for distribution
7. LemonSqueezy license key validation — required for revenue

**Ship soon after launch (v3.3):**
8. Language selection (remove "en" hardcode) — opens international market immediately
9. Transcription history with search — high retention value; was already built once
10. Custom vocabulary — addresses #1 Whisper accuracy complaint
11. Model download progress indicator — required UX for 574MB downloads
12. Keychain storage for API keys — privacy-claiming app must do this

**Competitive differentiators (v3.4+):**
13. Per-app context mode — VoiceInk's killer feature; doable with accessibility APIs already in use
14. Voice commands local (no Pro upsell) — differentiator vs. Wispr Flow which paywalls this
15. File transcription — expands use case; low integration complexity with existing whisper-cli

**Defer:**
- Target app indicator in overlay (nice-to-have trust signal)
- Dynamic thread count (1-line fix, do it opportunistically)
- Auto-restart on accessibility permission change (quality-of-life, not blocking)

---

## Competitive Positioning Summary

Voice competes in a crowded space where **accuracy and local processing are now commoditized**. The differentiators that generate purchases in 2026:

1. **Price:** $29 one-time vs. Wispr Flow ($200/yr), SuperWhisper (subscription hybrid), VoiceInk ($25-$49). Voice wins on price.
2. **Simplicity:** SuperWhisper's top complaint is settings overwhelm. Voice should ship with sane defaults and minimal configuration surface.
3. **True privacy:** Wispr Flow markets "privacy" but uses cloud. SuperWhisper and VoiceInk are genuinely local. Voice is genuinely local — lean into this with specific claims ("zero network requests", "no account required", "open to audit").
4. **One-time, no account:** Reddit/indie communities respond strongly to this. It's a stated preference, not just a nice-to-have.
5. **POPO mode:** No major competitor does long-form lock-on dictation cleanly. This is an undermarketed differentiator.

The gap Voice needs to close before launch is **polish and reliability** (waveform, onboarding, error recovery, signing), not features. Users will forgive missing per-app modes; they will not forgive a broken install or a hung transcription with no escape.

---

## Sources

- Wispr Flow feature set: [tldv.io Wispr Flow Review 2026](https://tldv.io/blog/wisprflow/) | [afadingthought.substack.com comparison](https://afadingthought.substack.com/p/best-ai-dictation-tools-for-mac) — MEDIUM confidence (verified across multiple sources)
- SuperWhisper features: [superwhisper.com](https://superwhisper.com/) | [voicetypingtools.com review](https://www.voicetypingtools.com/tools/superwhisper) — HIGH confidence (official site + review)
- VoiceInk features: [tryvoiceink.com](https://tryvoiceink.com/) | [GitHub Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) | [afadingthought.substack.com comparison](https://afadingthought.substack.com/p/best-ai-dictation-tools-for-mac) — HIGH confidence (official site + open source code)
- MacWhisper features and pricing: [goodsnooze.gumroad.com/l/macwhisper](https://goodsnooze.gumroad.com/l/macwhisper) | [opentools.ai](https://opentools.ai/tools/macwhisper) — HIGH confidence
- WhisperNotes: [whispernotes.app](https://whispernotes.app) — MEDIUM confidence
- Waveform UX as standard: [vocatype.com](https://vocatype.com/) | [pulsescribe.me](https://pulsescribe.me/) | [weesperneonflow.ai macOS Tahoe article](https://weesperneonflow.ai/en/blog/2025-10-27-voice-dictation-macos-tahoe-native-features-third-party-apps-2025/) — MEDIUM confidence (multiple sources agree)
- User pain points: [afadingthought.substack.com](https://afadingthought.substack.com/p/best-ai-dictation-tools-for-mac) | [zackproser.com best-mac-dictation-app-2026](https://zackproser.com/blog/best-mac-dictation-app-2026) | [resonant reddit summary](https://www.onresonant.com/resources/best-dictation-tools-reddit) — MEDIUM confidence
- Subscription fatigue / one-time pricing preference: Multiple review sites and community discussions — MEDIUM confidence
- Custom vocabulary as top user request: [machow2.com best dictation software](https://machow2.com/best-dictation-software-mac/) | whisper.cpp GitHub discussions — MEDIUM confidence
