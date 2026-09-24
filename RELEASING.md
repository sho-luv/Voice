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

The DMG contains only the app (~8 MB). Models are downloaded by the app on first launch.

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

## Shipping a release

1. Make sure `main` is green in CI and you've tested the app locally
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
   (`{"version": "3.3", "url": "<DMG download URL>"}`), which lives in the
   `sho-luv/faradaysoft.com` repo along with the website's download links.

## Troubleshooting

| Failure | Usual cause |
|---------|-------------|
| Tag/version mismatch | Tag doesn't equal `CFBundleShortVersionString`. Fix `Info.plist` or re-tag. |
| Missing secrets | One of the secrets above is unset (the job lists which). |
| Certificate import | Bad `.p12` or password, or `VOICE_CODESIGN_IDENTITY` doesn't match the certificate. |
| Notarization | Wrong Apple ID, team ID or app-specific password, or Apple rejected the submission (see the notarytool log in the job output). |
| DMG packaging | Reproduce locally with `./create-dmg.sh`. |
