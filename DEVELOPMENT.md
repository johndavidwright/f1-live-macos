# Developing F1 Live

Development requires macOS 14 or later and Apple Command Line Tools or Xcode with Swift 6.

## Build and test

```sh
swift run F1Live
./scripts/test.sh
./scripts/build-app.sh
open "dist/F1 Live.app"
```

`build-app.sh` produces a universal app containing native Apple-silicon and Intel executables. It defaults to ad-hoc signing. The Swift Testing suite runs through `swift test` with a full Xcode installation and in GitHub Actions; Command Line Tools alone can compile that suite but does not include Apple's test-bundle runner.

For a consistent app identity across rebuilds, install your Developer ID Application certificate and private key, then use the same signing identity for every build:

```sh
F1_CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-app.sh
```

`package-release.sh` also honors this environment variable. The build signs Sparkle's nested helpers and the app with hardened runtime and a secure timestamp. An invalid configured identity fails the build; it does not fall back to ad-hoc signing. This does not perform notarization or configure certificates in GitHub Actions, which still uses ad-hoc signing until a certificate is provisioned there. Sparkle's update-signing key is separate from an Apple Developer ID.

Ad-hoc signatures change identity with the executable, so Keychain may require approval again after a rebuild. Automatic credential reads suppress Keychain UI and leave live timing paused when approval is needed. **Settings → OpenF1 Live Timing → Authorize Saved Credentials** allows an interactive read and tests the saved account. Cancelling leaves the credentials untouched. The small `KeychainSupport` compatibility target scopes the legacy login-Keychain interaction flag to a synchronous read; modern `LAContext` flags alone do not protect existing file-based Keychain items from prompts.

## Package a release

Update `CFBundleShortVersionString` and the monotonically increasing `CFBundleVersion` in `Sources/F1Live/Resources/Info.plist`, then update `INSTALL.md` and `RELEASE_NOTES.md`.

```sh
./scripts/package-release.sh
./scripts/generate-appcast.sh
```

The packaging script creates a universal release ZIP, its SHA-256 checksum, and an app-only ZIP for Sparkle. The appcast script signs the update archive with the EdDSA key stored in the macOS Keychain under `dev.nocram.f1live.macos`.

Tag pushes run `.github/workflows/release.yml`. The workflow expects the exported Sparkle private key in the `SPARKLE_PRIVATE_KEY` repository secret and publishes the distribution ZIP, checksum, update ZIP, and signed appcast to GitHub Releases. Keep the private key out of the repository and retain a secure backup; installed copies rely on that key to authenticate future updates.
