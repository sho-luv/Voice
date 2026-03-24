## Voice App — Open Issues

### Recording & Audio
- [ ] **Waveform doesn't animate** — Bubble overlay doesn't move/pulse when speaking (tested with Obsidian mic)
- [ ] **"Recording too short" on most mics** — Only Obsidian mic works; other mics produce 44-byte WAV files (header only, no audio data)
- [ ] **Double-tap POPO gives "recording too short"** — Entering hands-free mode via double-tap fn triggers the error immediately
- [ ] **POPO double-tap timing** — First tap starts recording then cancels it; second tap enters POPO but engine state may be dirty from the cancel

### UI / Settings
- [ ] **Buy button not tested** — Made it solid blue full-width in License tab, needs verification
- [ ] **Transcript history UI** — Previous nice implementation (NSTableView with Time/Transcription/App columns, search, copy, delete, export) was lost. Code recovered from conversation history — needs reimplementation
- [ ] **Transcription tab overlap** — Whisper model controls were overlapping tab bar (lowered y to 280, needs verification)

### Feature Gaps
- [ ] **Transcript history window** — Standalone `HistoryWindowController` with `TranscriptionRecord` model, JSON storage, menu bar "History" item. Recovered implementation ready to integrate.
- [ ] **install.sh output still says "Space+fn = POPO mode"** — Should say "Double-tap fn = Hands-free mode"
