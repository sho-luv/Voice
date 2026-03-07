### 2026-03-07
- Added native Settings window (Cmd+, or menu bar > Settings...) with 3 tabs: General, AI, Transcription
- Settings singleton wrapping UserDefaults with typed properties and register(defaults:) for all preferences
- General tab: push-to-talk key selector (fn, Right Option, Left Option, Right Cmd), sounds toggle, auto-start on login, POPO timeout (1-30 min), clipboard restore toggle
- AI tab: enable/disable AI cleanup, provider selector (Ollama/OpenAI/Anthropic), model field, API key (secure field, hidden for Ollama), test connection button
- Transcription tab: whisper model selector (small.en, medium.en, large-v3), download model button
- Added AIClient protocol with OllamaClient (refactored), OpenAIClient, and AnthropicClient implementations
- Wired all settings into existing code: hotkey, sounds, POPO timeout, clipboard restore, whisper model, AI provider routing
- Cached hotkey values on InputMonitor instance to avoid UserDefaults access inside CGEventTap callback (performance/stability)
- Fixed macOS window restoration issue: settings window appeared on relaunch. Applied multi-layered fix — NSQuitAlwaysKeepsWindows before app.run(), isRestorable=false on window, close windows on quit, delete saved state on launch
- Key discovery: recompiling the binary changes its hash, causing macOS TCC to revoke accessibility permission (CGEvent.tapCreate returns nil). Ad-hoc signing (codesign --sign -) uses hash-based identity that changes per compile.
- Solution: created self-signed "Voice Dev" code signing certificate with stable identity. TCC preserves accessibility permission across recompiles. install.sh updated to prefer "Voice Dev" cert with ad-hoc fallback.
- Critical permission workflow: app must NOT be running when granting accessibility — kill first, grant in System Settings, then launch
- Updated README with full Settings documentation, AI providers, code signing certificate setup, troubleshooting guide

### 2026-03-06
- Rewrote VoiceMic v1.0 → Voice v3.0 (complete rewrite, ~1100 lines)
- CGEventTap for fn key push-to-talk (replaced Carbon Cmd+L hotkey)
- Space+fn POPO lock mode for continuous dictation
- Floating overlay window showing recording/transcribing/done/error states
- Text injection: AX API for regular apps, clipboard Cmd+V for terminals
- Key bug fix: terminal apps (iTerm2, Terminal) falsely accept AX injection — `AXUIElementSetAttributeValue` returns success but silently ignores the value. Added terminal bundle ID detection to skip AX and use clipboard paste directly.
- Key bug fix: CGEventTap was intercepting self-posted Cmd+V events. Fixed by temporarily disabling the event tap during paste simulation.
- Implemented delayed clipboard rendering via NSPasteboardItemDataProvider (matching Wispr Flow's approach) for reliable paste
- Ollama AI cleanup of transcription with graceful fallback
- AppContext tone adaptation per active app
- Paste Last menu item
- Renamed throughout: VoiceMic → Voice, bundle ID com.local.voice
- Cleaned up test files (diagnose.swift, paste_test*.swift)
- Committed working state at b97daa0
