# Releasing Voice

This document explains the release system for `Voice`: what it does, why it exists, and how to use it.

If you want the short operator checklist, see [docs/release-workflow.md](docs/release-workflow.md).

## Overview

The project now uses GitHub as the release control plane.

That means:

- source code lives in the repository
- GitHub Actions validates changes on push and pull request
- tagged versions produce signed release artifacts
- GitHub Releases becomes the distribution record for shipped versions

The release system is built around a few core files:

- [Info.plist](Info.plist)
  This is the source of truth for the app version.
- [create-dmg.sh](create-dmg.sh)
  This builds, signs, notarizes, and packages the app.
- [install.sh](install.sh)
  This is the local installer path for development and manual installs.
- [ci.yml](.github/workflows/ci.yml)
  This validates the repo on pushes and pull requests.
- [release.yml](.github/workflows/release.yml)
  This runs the release pipeline from Git tags.
- [.github/release.yml](.github/release.yml)
  This controls release note categorization.

## Why This Exists

Before this setup, releasing was too manual.

That caused a few common production problems:

- version drift between `Info.plist`, filenames, and GitHub
- release artifacts living in the working tree instead of in GitHub Releases
- no automatic verification that the app still typechecks before shipping
- signing and notarization steps depending on memory instead of a documented process

The current workflow fixes that by making GitHub responsible for the repeatable parts.

In practice, this gives you:

- a single version source of truth
- repeatable, auditable release builds
- fewer “did I forget a step?” failures
- a clean public release history on GitHub

## How The System Works

### 1. Version source of truth

The app version lives in [Info.plist](Info.plist).

Two fields matter:

- `CFBundleShortVersionString`
  Human-facing version, such as `3.3`
- `CFBundleVersion`
  Build number, currently kept aligned with the release version

The release workflow reads the version directly from `Info.plist`.
The DMG filename is derived from that same value.

That means you do not manually edit a version string in multiple places anymore.

### 2. Continuous integration

[ci.yml](.github/workflows/ci.yml) runs on:

- pushes to `main`
- pull requests

It performs lightweight validation:

- shell syntax checks for the scripts
- plist validation
- Swift typecheck for `Voice.swift`

This workflow is there to catch obvious breakage before you cut a release.

### 3. Release workflow

[release.yml](.github/workflows/release.yml) runs on:

- pushes to tags matching `v*`
- manual `workflow_dispatch`

For a real tagged release, it does the following:

1. checks out the repository
2. reads the version from `Info.plist`
3. verifies the Git tag matches the app version
4. verifies that required GitHub secrets are configured
5. installs build dependencies on the macOS runner
6. imports the signing certificate into a temporary keychain
7. configures Apple notarization credentials
8. runs [create-dmg.sh](create-dmg.sh)
9. uploads the generated DMG as a workflow artifact
10. publishes a GitHub Release and attaches the DMG

### 4. Manual dispatch

The `workflow_dispatch` path exists so you can test the pipeline without creating a public release tag first.

This is useful for:

- validating the GitHub runner setup
- testing certificate import
- testing notarization wiring
- catching packaging issues before an actual release

Only a tag push publishes a GitHub Release.

### 5. Release note generation

GitHub release notes are automatically generated and grouped using [.github/release.yml](.github/release.yml).

If you use labels such as:

- `feature`
- `enhancement`
- `fix`
- `bug`
- `docs`
- `ci`
- `chore`
- `refactor`

GitHub will group the release notes more cleanly.

## Signing And Notarization

macOS distribution has stricter requirements than a normal ZIP upload.

For a production-quality release, the app should be:

- code signed with a Developer ID certificate
- notarized by Apple
- stapled so the notarization ticket travels with the artifact

That is why the release workflow needs secrets and Apple credentials.

The workflow uses:

- a `.p12` certificate exported from your signing identity
- the certificate password
- Apple notarization credentials

These are stored as GitHub Actions secrets so they are available to the runner but do not live in the repository.

## Required GitHub Secrets

The release workflow requires these repository secrets:

- `VOICE_CODESIGN_IDENTITY`
  Example: `Developer ID Application: Faraday Soft (MWW7M2563A)`
- `VOICE_BUILD_CERTIFICATE_P12_BASE64`
  Base64-encoded `.p12` certificate
- `VOICE_BUILD_CERTIFICATE_PASSWORD`
  Password for the `.p12`
- `VOICE_NOTARY_APPLE_ID`
  Apple ID used for notarization
- `VOICE_NOTARY_TEAM_ID`
  Apple Developer team ID
- `VOICE_NOTARY_APP_SPECIFIC_PASSWORD`
  App-specific password for notarization

GitHub path:

1. Open the repository.
2. Go to `Settings`.
3. Go to `Secrets and variables`.
4. Open `Actions`.
5. Add or update the secrets above.

To generate the base64 certificate value locally:

```bash
base64 -i /path/to/certificate.p12 | pbcopy
```

## Standard Release Procedure

This is the normal production release flow.

### Step 1. Merge release-ready changes to `main`

Before cutting a release:

- make sure the intended changes are already merged
- make sure CI is green
- make sure the release secrets are configured in GitHub

### Step 2. Update the version

Edit [Info.plist](Info.plist):

- set `CFBundleShortVersionString`
- set `CFBundleVersion`

Example:

- `CFBundleShortVersionString = 3.3`
- `CFBundleVersion = 3.3`

### Step 3. Commit the version bump

```bash
git checkout main
git pull --ff-only
git add Info.plist
git commit -m "Release 3.3"
git push origin main
```

### Step 4. Create the release tag

The tag must match `CFBundleShortVersionString`, with a leading `v`.

Example:

- app version: `3.3`
- tag: `v3.3`

Commands:

```bash
git tag v3.3
git push origin v3.3
```

### Step 5. Let GitHub Actions build the release

After the tag is pushed:

- the `Release` workflow runs automatically
- the workflow builds the DMG
- the workflow signs and notarizes it
- the workflow publishes a GitHub Release

### Step 6. Verify the release

After the workflow completes:

1. open `Actions` and confirm the job passed
2. open `Releases` and confirm the new release exists
3. download the DMG
4. open it on macOS
5. confirm the app launches and Gatekeeper accepts it

Optional local checks:

```bash
spctl --assess --type open --context context:primary-signature -v Voice-3.3.dmg
codesign --verify --deep --strict --verbose=2 Voice.app
```

## Dry Run Procedure

Use this when you want to test the pipeline before publishing a release.

GitHub path:

1. Open `Actions`
2. Select `Release`
3. Click `Run workflow`

Use this for:

- testing GitHub runner setup
- validating the build process
- checking secret wiring
- verifying the notarization profile setup

Remember:

- `workflow_dispatch` is a pipeline test
- tag pushes are the actual release trigger

## Tag Rules

The release workflow enforces a simple versioning rule:

- `GITHUB_REF_NAME` without the leading `v` must equal `CFBundleShortVersionString`

Examples:

- valid: `v3.3` with `CFBundleShortVersionString = 3.3`
- invalid: `v3.3.1` with `CFBundleShortVersionString = 3.3`

This is intentional. It prevents accidental mismatches between the shipped artifact and the GitHub release tag.

## Common Failure Modes

### Tag/version mismatch

Symptom:

- the release job fails near the start with a version mismatch error

Cause:

- `Info.plist` and the pushed tag do not match

Fix:

1. decide which version is correct
2. update `Info.plist` or recreate the tag
3. push the corrected tag

### Missing secrets

Symptom:

- the release job fails in the secret validation step

Cause:

- one or more required GitHub secrets were not configured

Fix:

1. add the missing secret in GitHub Actions settings
2. re-run the workflow or push a corrected tag

### Certificate import failure

Symptom:

- the release workflow fails while importing the signing certificate

Cause:

- the `.p12` is invalid
- the password is wrong
- the configured signing identity does not match the imported certificate

Fix:

1. re-export the `.p12`
2. verify the password
3. confirm `VOICE_CODESIGN_IDENTITY` matches the certificate name
4. update the repository secrets

### Notarization failure

Symptom:

- signing succeeds, but notarization fails

Cause:

- Apple ID credentials are wrong
- the app-specific password is wrong
- team ID is wrong
- notarization service rejects the submission

Fix:

1. verify `VOICE_NOTARY_APPLE_ID`
2. verify `VOICE_NOTARY_TEAM_ID`
3. regenerate `VOICE_NOTARY_APP_SPECIFIC_PASSWORD` if needed
4. re-run the workflow

### DMG packaging failure

Symptom:

- the release workflow fails during `create-dmg.sh`

Cause:

- missing Homebrew dependency
- signing issue
- notarization issue
- local packaging logic regression

Fix:

1. inspect the failing GitHub Actions step logs
2. reproduce locally with `./create-dmg.sh`
3. fix the underlying script or environment issue

## Day-To-Day Development Versus Release

It helps to separate normal development from shipping.

Normal development uses:

- branch work
- pull requests
- CI validation
- local installs with [install.sh](install.sh)

Releases use:

- a version bump in `Info.plist`
- a pushed Git tag
- the GitHub `Release` workflow
- GitHub Releases as the artifact record

That separation is deliberate. It keeps shipping logic stable and auditable.

## Recommended Habits

- treat `Info.plist` as the only version source
- use PR labels so GitHub release notes stay readable
- run `workflow_dispatch` if you change release infrastructure
- avoid storing built DMGs in the repository
- use GitHub Releases as the canonical artifact location

## Quick Checklist

- [ ] release changes are merged to `main`
- [ ] CI passed
- [ ] GitHub release secrets are configured
- [ ] `Info.plist` version is updated
- [ ] version bump is committed and pushed
- [ ] matching `vX.Y.Z` tag is pushed
- [ ] `Release` workflow passed
- [ ] GitHub Release exists with DMG attached
- [ ] DMG was downloaded and tested on macOS
