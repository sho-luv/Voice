# Releasing Voice

Releases are built, signed, notarized and published by GitHub Actions
(`.github/workflows/release.yml`) when a `v*` tag is pushed.

## How it works

- **Version:** `CFBundleShortVersionString` in `Info.plist` is the single source of truth.
  The workflow refuses a tag that doesn't match it (`v3.3` requires `3.3`).
- **CI** (`ci.yml`, every push and PR): shell syntax, plist lint, and a Swift typecheck.
- **Release** (`release.yml`, on tag): imports the signing certificate, runs `./create-dmg.sh`
  (builds the engine and app, signs with hardened runtime, notarizes, staples), uploads the
  DMG as an artifact, and publishes a GitHub Release with it attached. Release notes are
  generated from merged PRs using the categories in `.github/release.yml`.
- **Dry run:** Actions > Release > Run workflow builds everything without publishing.

The DMG contains only the app (~12 MB universal). Models are downloaded by the app on first launch.

## Required repository secrets

| Secret | Value |
|--------|-------|
| `VOICE_CODESIGN_IDENTITY` | e.g. `Developer ID Application: Leon Johnson (MWW7M2563A)` |
| `VOICE_BUILD_CERTIFICATE_P12_BASE64` | `base64 -i certificate.p12 \| pbcopy` |
| `VOICE_BUILD_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `VOICE_NOTARY_APPLE_ID` | Apple ID used for notarization |
| `VOICE_NOTARY_TEAM_ID` | Apple Developer team ID |
| `VOICE_NOTARY_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |

Set them under Settings > Secrets and variables > Actions.

## Pre-release battery

Run all of it before tagging. It takes about ten minutes and covers everything 3.4 did.

```bash
# 1. CI gates, locally (same commands as ci.yml)
plutil -lint Info.plist && for f in *.sh engine/build.sh; do bash -n "$f"; done
swiftc -parse-as-library -target arm64-apple-macos14.0 -typecheck Voice.swift SpeechEngine.swift ModelDownload.swift \
  Design/*.swift Views/*.swift Support/*.swift -import-objc-header Voice-Bridging-Header.h -I engine \
  -framework Cocoa -framework ApplicationServices -framework UserNotifications -framework AVFoundation \
  -framework CoreAudio -framework SwiftUI -framework SceneKit

# 2. Engine, headless, on generated speech (English with fillers, plus one other language)
say -o en.aiff "um so I was thinking we should uh meet tomorrow, no wait, let's meet on Thursday"
afconvert -f WAVE -d LEI16@16000 -c 1 en.aiff en.wav
./Voice.app/Contents/MacOS/Voice --selftest en.wav          # expect fillers gone, guardrail "accepted"
arch -x86_64 ./Voice.app/Contents/MacOS/Voice --selftest en.wav   # Intel slice under Rosetta (universal build)

# 3. Universal build, signature, size
VOICE_UNIVERSAL=1 ./build-app.sh && lipo -info Voice.app/Contents/MacOS/Voice
codesign --verify --deep --strict Voice.app && du -sh Voice.app     # expect ~12 MB fat, ~7 MB single arch

# 4. Every screen, every theme, every mic (look at the contact sheet, don't guess)
for t in midnight paper electric hazard; do for s in home onboarding look support overlay; do
  ./Voice.app/Contents/MacOS/Voice -screen $s -theme $t -shot shots/$s-$t.png; done; done

# 5. Live, on the real app (quit the installed copy first; same bundle id)
./Voice.app/Contents/MacOS/Voice > voice.log 2>&1 &          # NSLog lines land in voice.log
swiftc -O tools/fnseq.swift -o build/fnseq                    # synthetic fn presses (terminal needs Accessibility)
# Route audio away from headphones for the acoustic part: set Voice's mic to the built-in
# (defaults write com.faradaysoft.voice micDeviceUID -string BuiltInMicrophoneDevice) and speak with
# `say -a "MacBook Pro Speakers" "..."` while fn is held. Then `defaults delete ... micDeviceUID`.
open -a TextEdit                                              # a document to receive the text
build/fnseq down 300; say -a "MacBook Pro Speakers" "push to talk works"; build/fnseq 400 up   # push-to-talk
build/fnseq down 60 up 150 down 60 up; say -a "MacBook Pro Speakers" "hands free works"; build/fnseq down 60 up
build/fnseq down 900 esc 200 up                               # Escape cancels: nothing typed
grep "Voice:" voice.log    # expect: event tap created, engine started, saved transcript, AX inject succeeded
open "voice://thanks"      # supporter badge + THANK YOU moment; then `defaults delete com.faradaysoft.voice supporter supportedAt`

# 6. Idle cost: no window, window open, window closed again
top -l 3 -s 2 -pid $(pgrep -x Voice) -stats cpu,mem           # expect ~1% / ~3% / ~1% and memory released on close
```

Results for 4.0 on 2026-10-08: all green. Push-to-talk, hands-free (6/6 double-taps), Escape, transcript
save, Accessibility injection, Spanish under Rosetta, 7.2 MB single-arch / 12 MB universal.

## Shipping a release

1. Make sure `main` is green in CI and you've run the battery above
   (`./install.sh`, then dictate; `Voice --selftest file.wav` checks the engine headless).
2. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, commit, push.
3. Tag and push:
   ```bash
   git tag v3.3
   git push origin v3.3
   ```
4. When the workflow finishes, download the DMG from the release and check it:
   ```bash
   spctl --assess --type open --context context:primary-signature -v Voice-3.3.dmg
   ```
   Then install it and dictate once.
5. Update the update feed. "Check for Updates" reads `https://faradaysoft.com/appcast.json`
   (`{"version": "4.0", "url": "<DMG download URL>", "minimumSystemVersion": "14.0", "notes": "..."}`),
   which lives in the `sho-luv/faradaysoft.com` repo along with the website's download links.
   Keep `minimumSystemVersion` equal to `LSMinimumSystemVersion`: from 4.0 on, a Mac below it is
   told the update needs a newer macOS instead of being offered a DMG it can't open (3.4 and
   earlier ignore the field).

## Troubleshooting

| Failure | Usual cause |
|---------|-------------|
| Tag/version mismatch | Tag doesn't equal `CFBundleShortVersionString`. Fix `Info.plist` or re-tag. |
| Missing secrets | One of the secrets above is unset (the job lists which). |
| Certificate import | Bad `.p12` or password, or `VOICE_CODESIGN_IDENTITY` doesn't match the certificate. |
| Notarization | Wrong Apple ID, team ID or app-specific password, or Apple rejected the submission (see the notarytool log in the job output). |
| DMG packaging | Reproduce locally with `./create-dmg.sh`. |
