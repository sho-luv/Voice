### 2026-04-20
- **Transcription-quality overhaul** (Voice 3.2.2 / 3.2.3)
  - Peak audio normalization before whisper — target −3 dBFS, up to 20× gain, skips silent clips. Huge accuracy win on quiet/mumbled speech
  - Context-biased whisper `--prompt` — active app name + window title + user vocabulary fed to whisper as decoder bias
  - New "Custom vocabulary" field in Settings → AI (names, acronyms, technical terms) — prepended to whisper prompt
  - Beam size bumped from default 5 → 8 — meaningfully better on ambiguous audio
- **Crash-safe audio pipeline**
  - Added `VoiceExceptionCatcher` ObjC shim (bridging header wired into install.sh + create-dmg.sh)
  - Wrapped all 3 `installTap` sites — mic disconnect / format mismatch no longer SIGABRTs
  - Watchdog timeouts on whisper (60s) and llama (20s) — UI can't wedge in "Transcribing" forever
- **Polished DMG installer**
  - Replaced `hdiutil makehybrid` with `create-dmg` CLI tool
  - Background PNG + arrow + Voice.app at (175,190) + Applications drop target at (485,190) — no more empty-box mystery
- **Model downsize**: 3.2.3 swapped Qwen 1.5B → 0.5B. DMG went from 1.5GB (3.2.2) to 902MB
- **Voicebox research**: evaluated github.com/louisbarrett/voicebox — nothing to steal wholesale, adopted only the NSException catcher shim pattern
- **Releases shipped**: Voice-3.2.2.dmg (1.5GB, Qwen 1.5B) then Voice-3.2.3.dmg (902MB, Qwen 0.5B), both signed + notarized + stapled, live at downloads.faradaysoft.com. Website + appcast.json updated to 3.2.3

### 2026-03-27
- **Wispr Flow competitive teardown** — extracted and analyzed their full Electron app (v1.4.642):
  - 100% cloud transcription (gRPC to grpc.wisprflow.com, Baseten GPU inference) — no local models
  - Electron + React + Zustand + SQLite/Sequelize stack, 414MB total (mostly Chromium bloat)
  - Swift helper app for native accessibility, keyboard, clipboard (same DelayedClipboardProvider pattern we use)
  - Supabase auth, Stripe billing, PostHog + Sentry + Segment analytics (heavy telemetry)
  - Features: command mode, instruct mode, lens/OCR, voice profiles, scratchpad, focus mode, custom dictionary
  - Key vulnerabilities: no offline use, 6-min session cap, 10s transcription timeout, subscription fatigue
- **Self-contained DMG** — Voice-3.2.1.dmg now bundles everything needed to run on a fresh Mac:
  - whisper-cli binary + all 6 dylibs (libwhisper, libggml, libggml-base, libggml-cpu, libggml-blas, libggml-metal)
  - ggml-large-v3-turbo-q5_0.bin whisper model (547MB) bundled in Resources
  - Fixed dylib install name IDs — were pointing to /opt/homebrew absolute paths, now use @executable_path/../Frameworks/
  - Fixed dylib cross-references for Homebrew absolute paths
  - Total DMG size: 513MB (signed, notarized, stapled)
- **create-dmg.sh improvements:**
  - Bundles whisper model from ~/Library/Application Support/Voice/Models/ into app Resources
  - Rewrites dylib IDs (install_name_tool -id) in addition to cross-references
  - Uses hdiutil makehybrid + convert (no volume mount required — avoids TCC/Full Disk Access issues)
  - Ejects stale Voice volumes before DMG creation
- **Auto-download fallback** — added ModelDownloadWindowController to Voice.swift:
  - If whisper model not found in bundle or Application Support, shows progress window and downloads from Hugging Face
  - Progress bar with MB done/total, retry button on failure
  - One-time download, subsequent launches find existing model
- **Next:** Set up Cloudflare R2 for DMG hosting (GitHub Pages has 100MB file limit, can't host 513MB DMG)

### 2026-03-25
- Discovered faradaysoft.com blocked on corporate network (TikTok/USDS firewall) — categorized as "parked"
- Root cause: Palo Alto URL filtering classified the domain as "Parked" since it's new/low-traffic on GitHub Pages shared IPs
- Symantec/Bluecoat SiteReview already correctly categorized as "Technology/Internet" — no action needed
- Submitted recategorization request on Palo Alto (urlfiltering.paloaltonetworks.com) — change from "Parked" to "Computer and Internet Info". Confirmation received, review within 1 business day.
- **Palo Alto recategorization approved** — faradaysoft.com now "computer-and-internet-info" (DB version 20260325.20271). Corporate firewalls no longer block the site.
- Workflow for new domains: after launching a product website, check categorization at:
  - sitereview.bluecoat.com (Symantec/Broadcom)
  - urlfiltering.paloaltonetworks.com (Palo Alto — requires free account)
  - fortiguard.com/faq/wfrating (Fortinet)
  - zscaler.com/url-category-submission (Zscaler)
- Verified GitHub Release download works for private repo (v3.2.1 DMG, 2.0 MB, checksum valid) — requires authenticated access (gh CLI or collaborator)
- Created GitHub Releases v3.2 and v3.2.1 with DMG assets for download tracking
- Fixed Cloudflare DNS: changed store.faradaysoft.com from A record (3.33.235.208) to CNAME (custom.lemonsqueezy.com), DNS only
- LemonSqueezy store activation blocked — they requested a demo video and social media profiles (email from Vishnu, Mar 24). Store not yet activated.
- LemonSqueezy custom domain (store.faradaysoft.com) returns Cloudflare Error 1014 until store is activated and domain is registered on their end
- Switched website download links to direct DMG (Voice-3.2.1.dmg) hosted on faradaysoft.com; Subscribe button uses faradaysoft.lemonsqueezy.com fallback
- Researched payment alternatives: Stripe has official MCP server, lower fees (2.9%+$0.30 vs 5%+$0.50), and now offers merchant of record via Stripe Managed Payments (acquired LemonSqueezy in 2024). Considering migration to Stripe.

### 2026-03-24
- Removed remote AI provider integrations and API-key settings
- Simplified AI cleanup to the local Ollama path only
- Updated website and privacy copy to match local transcription behavior and license traffic

### 2026-03-07
- Added native Settings window (Cmd+, or menu bar > Settings...) with 3 tabs: General, AI, Transcription
- Settings singleton wrapping UserDefaults with typed properties and register(defaults:) for all preferences
- General tab: push-to-talk key selector (fn, Right Option, Left Option, Right Cmd), sounds toggle, auto-start on login, POPO timeout (1-30 min), clipboard restore toggle
- AI tab: enable/disable local AI cleanup, model field, Ollama install flow, test connection button
- Transcription tab: whisper model selector (small.en, medium.en, large-v3), download model button
- Added Ollama-based cleanup client for local post-processing
- Wired all settings into existing code: hotkey, sounds, POPO timeout, clipboard restore, whisper model, local AI cleanup
- Cached hotkey values on InputMonitor instance to avoid UserDefaults access inside CGEventTap callback (performance/stability)
- Fixed macOS window restoration issue: settings window appeared on relaunch. Applied multi-layered fix — NSQuitAlwaysKeepsWindows before app.run(), isRestorable=false on window, close windows on quit, delete saved state on launch
- Key discovery: recompiling the binary changes its hash, causing macOS TCC to revoke accessibility permission (CGEvent.tapCreate returns nil). Ad-hoc signing (codesign --sign -) uses hash-based identity that changes per compile.
- Solution: created self-signed "Voice Dev" code signing certificate with stable identity. TCC preserves accessibility permission across recompiles. install.sh updated to prefer "Voice Dev" cert with ad-hoc fallback.
- Critical permission workflow: app must NOT be running when granting accessibility — kill first, grant in System Settings, then launch
- Updated README with full Settings documentation, local AI cleanup, code signing certificate setup, troubleshooting guide

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
