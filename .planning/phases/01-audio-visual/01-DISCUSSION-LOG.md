# Phase 1: Audio + Visual - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-24
**Phase:** 01-audio-visual
**Areas discussed:** AVFoundation recording approach, Mic selector UX, Waveform overlay design, Active app context display

---

## AVFoundation Recording Approach

### Audio API Selection

| Option | Description | Selected |
|--------|-------------|----------|
| AVAudioEngine (Recommended) | Higher-level, real-time audio buffer callbacks for waveform, easy mic switching | ✓ |
| AVCaptureSession | Video/camera-oriented API, more boilerplate, no advantage for audio-only | |
| AudioQueue (low-level) | C-based CoreAudio API, maximum control but overkill | |

**User's choice:** AVAudioEngine
**Notes:** None

### WAV Format Handling

| Option | Description | Selected |
|--------|-------------|----------|
| Record PCM, write WAV header (Recommended) | Raw PCM buffers + minimal 44-byte WAV header | ✓ |
| Use AVAudioFile to write WAV | Higher-level but adds intermediate file write step | |
| You decide | Let Claude pick | |

**User's choice:** Record PCM, write WAV header
**Notes:** None

### Sox Fallback

| Option | Description | Selected |
|--------|-------------|----------|
| Remove entirely (Recommended) | Clean break, no Homebrew dependency | ✓ |
| Keep as hidden fallback | Silently fall back to rec if AVFoundation fails | |

**User's choice:** Remove entirely
**Notes:** None

### CLI Tool

| Option | Description | Selected |
|--------|-------------|----------|
| Leave CLI as-is for now | voice.sh keeps using sox, Phase 1 is GUI only | ✓ |
| Deprecate CLI | Mark voice.sh as deprecated | |
| You decide | Claude picks based on scope | |

**User's choice:** Leave CLI as-is
**Notes:** None

---

## Mic Selector UX

### Mic Location in UI

| Option | Description | Selected |
|--------|-------------|----------|
| Settings > General tab (Recommended) | Dropdown in existing General tab | |
| Settings > new Audio tab | Dedicated Audio tab for mic selection | ✓ |
| Menu bar dropdown | Quick-switch mic from menu bar icon | |

**User's choice:** Settings > new Audio tab
**Notes:** User preferred dedicated tab over cramming into General

### AirPods/Bluetooth Warning

| Option | Description | Selected |
|--------|-------------|----------|
| Overlay warning during recording (Recommended) | Show warning if audio buffer levels consistently zero | ✓ |
| Pre-recording device check | Test mic before recording starts | |
| Settings indicator only | Green/red dot in Settings | |

**User's choice:** Overlay warning during recording
**Notes:** None

### Live Device Updates

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, live updates (Recommended) | CoreAudio device change notifications | ✓ |
| Refresh on Settings open | Rebuild list on each Settings open | |

**User's choice:** Yes, live updates
**Notes:** None

### Mic Disappears

| Option | Description | Selected |
|--------|-------------|----------|
| Fall back to system default (Recommended) | Silently use default, note in Settings | ✓ |
| Block recording + notify | Refuse to record, show notification | |
| You decide | Claude picks matching existing patterns | |

**User's choice:** Fall back to system default
**Notes:** None

---

## Waveform Overlay Design

### Waveform Style

| Option | Description | Selected |
|--------|-------------|----------|
| Vertical bars (Recommended) | 5-7 vertical bars bouncing with amplitude | ✓ |
| Circular waveform | Pulsing/morphing circle or ring | |
| Horizontal waveform | Scrolling left-to-right waveform line | |

**User's choice:** Vertical bars
**Notes:** User later specified WhatsApp voice recording UI as the primary visual reference — compact rounded bars with smooth animation

### Color Scheme

| Option | Description | Selected |
|--------|-------------|----------|
| Match current overlay theme (Recommended) | Dark semi-transparent background, white/accent elements | ✓ |
| Green amplitude bars | Classic audio meter green | |
| You decide | Claude picks colors | |

**User's choice:** Match current overlay theme
**Notes:** None

### Overlay Position

| Option | Description | Selected |
|--------|-------------|----------|
| Keep current position (Recommended) | Floating window near menu bar | ✓ |
| Center of screen | More visibility but potentially distracting | |
| Near cursor/active window | Context-aware positioning | |

**User's choice:** Keep current position
**Notes:** None

### Recording Duration Timer

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, show timer (Recommended) | Elapsed time counter beside/below waveform | ✓ |
| No timer | Just the waveform, minimal | |
| You decide | Claude picks | |

**User's choice:** Yes, show timer
**Notes:** None

---

## Active App Context Display

### App Display Style

| Option | Description | Selected |
|--------|-------------|----------|
| App icon + name (Recommended) | 16-20px icon + app name in overlay | ✓ |
| App name only | Text only, no icon | |
| App icon only | Icon only, no text | |

**User's choice:** App icon + name
**Notes:** None

### Window Title Display

| Option | Description | Selected |
|--------|-------------|----------|
| App name only (Recommended) | Just app name, keep overlay clean | |
| App name + truncated title | App name + first ~20 chars of window title | |
| You decide | Claude picks | |

**User's choice:** Other — "Make the options able to change the way it looks"
**Notes:** User wants all display elements configurable in Settings

### WhatsApp-Inspired Style Confirmation

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, WhatsApp-inspired | Compact rounded bars, timer beside waveform | ✓ |
| WhatsApp feel, macOS look | Borrow animation energy, style as native macOS | |
| You decide | Claude adapts for macOS context | |

**User's choice:** Yes, WhatsApp-inspired
**Notes:** User explicitly referenced WhatsApp voice message recording UI as the visual target

### Overlay Configuration

| Option | Description | Selected |
|--------|-------------|----------|
| Show/hide app info toggle | Single toggle for app name + icon | |
| Multiple overlay options | Separate toggles for app name, icon, window title, timer | ✓ |
| No configuration needed | One fixed layout | |

**User's choice:** Multiple overlay options
**Notes:** None

---

## Claude's Discretion

- WAV header implementation details
- Exact number of waveform bars (5-7 range)
- Animation smoothing approach
- Overlay layout spacing and sizing

## Deferred Ideas

None — discussion stayed within phase scope
