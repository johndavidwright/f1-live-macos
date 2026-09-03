# Developing F1 Live

Development requires macOS 14 or later and Apple Command Line Tools or Xcode with Swift 6.

## Build and test

```sh
swift run F1Live
./scripts/test.sh
./scripts/build-app.sh
open "dist/F1 Live.app"
```

`build-app.sh` produces an ad-hoc-signed universal app containing native Apple-silicon and Intel executables. The Swift Testing suite runs through `swift test` with a full Xcode installation and in GitHub Actions; Command Line Tools alone can compile that suite but does not include Apple's test-bundle runner.

## Package a release

Update `CFBundleShortVersionString` and the monotonically increasing `CFBundleVersion` in `Sources/F1Live/Resources/Info.plist`, then update `INSTALL.md` and `RELEASE_NOTES.md`.

```sh
./scripts/package-release.sh
./scripts/generate-appcast.sh
```

The packaging script creates a universal release ZIP, its SHA-256 checksum, and an app-only ZIP for Sparkle. The appcast script signs the update archive with the EdDSA key stored in the macOS Keychain under `dev.nocram.f1live.macos`.

Tag pushes run `.github/workflows/release.yml`. The workflow expects the exported Sparkle private key in the `SPARKLE_PRIVATE_KEY` repository secret and publishes the distribution ZIP, checksum, update ZIP, and signed appcast to GitHub Releases. Keep the private key out of the repository and retain a secure backup; installed copies rely on that key to authenticate future updates.
