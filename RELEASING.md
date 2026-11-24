# Releasing Taptone

A release is a notarized `Taptone-X.Y.Z-macos.zip` with a `SHA256SUMS` on a GitHub release at [theiskaa/taptone](https://github.com/theiskaa/taptone/releases), plus the `taptone` cask in [theiskaa/homebrew-tap](https://github.com/theiskaa/homebrew-tap), so that this works:

```sh
brew install --cask theiskaa/tap/taptone
```

Releases are cut on your Mac with `scripts/release.sh`. There is no release workflow in CI, so the signing certificate and notary credentials never leave your keychain.

## One-time setup

1. **Developer ID certificate.** The keychain needs a *Developer ID Application* identity. Check with:

   ```sh
   security find-identity -v -p codesigning
   ```

   The default is `Developer ID Application: Ismayil Shahverdiyev (A474HM679A)`. Set `SIGN_IDENTITY` to use another.

2. **Notary profile.** Create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security, App-Specific Passwords), then store it in the keychain as the `taptone-notary` profile:

   ```sh
   xcrun notarytool store-credentials taptone-notary --apple-id <your Apple ID> --team-id A474HM679A
   ```

   An App Store Connect API key works too: `--key AuthKey_XXXX.p8 --key-id <key ID> --issuer <issuer ID>` in place of `--apple-id` and `--team-id`. Set `NOTARY_PROFILE` to use another profile name.

3. **A public repository.** Homebrew and browsers can't download assets from a private repository's releases, so the preflight stops until `theiskaa/taptone` is public.

4. **GitHub access.** `gh auth login` as an account that can push to `theiskaa/taptone` and `theiskaa/homebrew-tap`. Set `TAP` to publish the cask to another tap.

The first release adds `Casks/taptone.rb` to the tap from [packaging/taptone.rb](packaging/taptone.rb). Later releases change only its `version` and `sha256`, so make any other cask edits in both places.

## Cutting a release

1. In [CHANGELOG.md](CHANGELOG.md), move the entries under `## [Unreleased]` into a new `## [X.Y.Z] - Unreleased` section. The release publishes that section as its notes and replaces `Unreleased` with the date.
2. Commit, and push `main`.
3. Rehearse it. This builds, signs, zips and checks everything locally, writes `dist/notes.md` and `dist/taptone.rb`, lists what the real run would stop on, and publishes nothing:

   ```sh
   make release-dry-run VERSION=X.Y.Z
   ```

4. Release:

   ```sh
   make release VERSION=X.Y.Z       # same as scripts/release.sh X.Y.Z
   ```

## What the release does

1. **Preflight.** It stops unless you're on a clean `main` that matches `origin/main`, `vX.Y.Z` exists neither here nor on `origin`, `gh` is signed in, the repository is public, you can push to the tap, CHANGELOG.md has a `## [X.Y.Z]` section, the signing identity is in the keychain, and the notary profile works. A missing profile prints the `store-credentials` command above.
2. **Version.** It sets `CFBundleShortVersionString` to `X.Y.Z` and raises `CFBundleVersion` by one in [App/Info.plist](App/Info.plist), dates the changelog heading, and commits `chore: release X.Y.Z`.
3. **Checks.** `swift test`.
4. **Build and sign.** `scripts/build-app.sh release --universal --hardened` builds an arm64 and x86_64 app and signs it with Developer ID, the hardened runtime, a secure timestamp, and [App/Taptone.entitlements](App/Taptone.entitlements). It checks that the signature names the identity, the runtime flag, and a timestamp.
5. **Notarize.** It zips the app with `ditto -c -k --keepParent`, submits it with `xcrun notarytool submit --wait`, prints Apple's log if it isn't accepted, staples the ticket to the app, and zips it again as `dist/Taptone-X.Y.Z-macos.zip`. Then it writes `dist/SHA256SUMS`.
6. **Check the archive.** It extracts the zip and checks the checksum, `codesign --verify --strict --deep`, the entitlements, the version and build in Info.plist, the stapled ticket, and `spctl --assess --type execute`.
7. **Publish.** It writes `dist/notes.md` (install lines plus the changelog section), tags `vX.Y.Z`, pushes `main` and the tag, and runs `gh release create` with the zip and `SHA256SUMS`.
8. **Cask.** `scripts/update-cask.sh X.Y.Z` reads the checksum from the published `SHA256SUMS`, then commits and pushes the cask to the tap.

## When a step fails

- **Before publishing (steps 1 to 6):** fix the problem and run the same command again. A rerun finds its own `chore: release X.Y.Z` commit on top of `origin/main` and reuses it instead of bumping again.
- **The cask (step 8):** the release is out. Retry just the cask with:

  ```sh
  scripts/update-cask.sh X.Y.Z            # TAP=owner/homebrew-tap for another tap
  scripts/update-cask.sh --dry-run X.Y.Z  # render it into dist/taptone.rb from the local build instead
  ```

  It does nothing when the cask already names X.Y.Z.
- **After the tag was pushed but `gh release create` failed:** a rerun stops because the tag exists. Finish by hand with the files that are still in `dist/`:

  ```sh
  gh release create vX.Y.Z dist/Taptone-X.Y.Z-macos.zip dist/SHA256SUMS --repo theiskaa/taptone \
      --verify-tag --title "Taptone X.Y.Z" --notes-file dist/notes.md
  scripts/update-cask.sh X.Y.Z
  ```

## Verifying a release

```sh
cd "$(mktemp -d)"
gh release download vX.Y.Z --repo theiskaa/taptone
shasum -a 256 -c SHA256SUMS
ditto -x -k Taptone-X.Y.Z-macos.zip .
codesign --verify --strict --deep --verbose=2 Taptone.app
codesign -dvv Taptone.app 2>&1 | grep -E 'Authority=Developer ID|flags=.*runtime|Timestamp'
codesign -d --entitlements - Taptone.app      # only com.apple.security.device.audio-input
xcrun stapler validate Taptone.app
spctl --assess --type execute -vv Taptone.app # accepted, source=Notarized Developer ID
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Taptone.app/Contents/Info.plist
```

Then through Homebrew:

```sh
brew update
brew install --cask theiskaa/tap/taptone
brew audit --cask --online theiskaa/tap/taptone
```

Finally, on a Mac with a Force Touch trackpad, open the installed app, allow system audio access, play something, and check that **Open Taptone** follows the bass and the trackpad plays it. This is the one check that only the notarized build can give: it runs with the hardened runtime that local builds don't use. Its signature also differs from a `make install` build's, so macOS asks for system audio access again the first time.

## Signing and entitlements

Local builds (`make install`, `make app`) are unchanged: they sign with your Apple Development certificate, or ad hoc without one, and don't use the hardened runtime. Only `--hardened`, which the release uses, adds it.

The hardened runtime is required for notarization. Taptone takes one entitlement under it, `com.apple.security.device.audio-input`. Apple documents it as letting the app "record audio using the built-in microphone and access audio input using Core Audio", and Taptone reads system audio as the input stream of a private aggregate device built on a Core Audio process tap. Apple's [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) sample ships with the hardened runtime and this entitlement. That sample can also add real input devices to its aggregate, so it isn't proof the tap alone needs it, but leaving it out risks a notarized build that captures only silence. It doesn't open the microphone: Taptone has no `NSMicrophoneUsageDescription` and never adds an input device. The system audio prompt itself comes from `NSAudioCaptureUsageDescription` in Info.plist, the only requirement Apple's tap documentation names.

`com.apple.security.cs.disable-library-validation` is not needed. Library validation only allows libraries signed by Apple or by the app's own team, and `/System/Library/PrivateFrameworks/MultitouchSupport.framework` is Apple's. A Developer ID, hardened-runtime test binary loads it and resolves `MTActuatorCreateFromDeviceID` and `MTActuationActuate`.
