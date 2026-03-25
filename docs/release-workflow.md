# Release Workflow Checklist

This is the short checklist version of the release process.

For the full explanation of what the system does, why it exists, and how GitHub Actions handles releases, see [RELEASING.md](/Users/sho_luv/home/projects/mine/voice/RELEASING.md).

## Pre-Release

- [ ] release changes are merged to `main`
- [ ] CI is green
- [ ] GitHub release secrets are configured
- [ ] I know the target version number

## Versioning

- [ ] update `CFBundleShortVersionString` in [Info.plist](/Users/sho_luv/home/projects/mine/voice/Info.plist)
- [ ] update `CFBundleVersion` in [Info.plist](/Users/sho_luv/home/projects/mine/voice/Info.plist)
- [ ] confirm the Git tag will match the version exactly, with a leading `v`

Example:

- app version: `3.3`
- tag: `v3.3`

## Ship It

```bash
git checkout main
git pull --ff-only
git add Info.plist
git commit -m "Release 3.3"
git push origin main
git tag v3.3
git push origin v3.3
```

## What GitHub Does

After the tag is pushed, GitHub Actions will:

1. verify the tag matches `Info.plist`
2. import the signing certificate
3. configure notarization
4. build the DMG
5. sign, notarize, and staple the release artifact
6. publish a GitHub Release with the DMG attached

## Verify

- [ ] `Release` workflow passed in GitHub Actions
- [ ] GitHub Release exists
- [ ] DMG is attached to the release
- [ ] DMG downloads successfully
- [ ] app launches successfully on macOS

## Dry Run

Use GitHub `Actions` > `Release` > `Run workflow` when you want to test the pipeline without publishing a tagged release.
