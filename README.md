# QuitDelay

QuitDelay is a native macOS menu-bar utility that prevents accidental Command–Q quits. Pressing Command–Q shows a progress overlay; releasing either key before the configured delay cancels the quit. Holding the shortcut for the full delay sends Command–Q only to the application that was focused when the hold began.

## Install the signed release

**[Download the latest signed release from GitHub](../../releases/latest)**

Official release builds are signed with Apple Developer ID, notarized by Apple, and have the notarization ticket stapled to the app. If a release is not yet available—or if you prefer to build and sign the code yourself—follow the local build instructions below.

1. Download `QuitDelay-vX.Y.Z.zip` and its `.sha256` file from the release assets.
2. Optionally verify the download from the directory containing both files:

   ```sh
   shasum -a 256 -c QuitDelay-vX.Y.Z.zip.sha256
   ```

3. Extract the ZIP and move `QuitDelay.app` to `/Applications`.
4. Open QuitDelay. Approve the requested permissions in **System Settings → Privacy & Security** when macOS prompts.
5. If macOS requests a relaunch after Input Monitoring approval, quit and open QuitDelay again.

QuitDelay is an agent app: it has no Dock icon. Use its hourglass icon in the macOS menu bar to change the hold delay, enable Launch on Boot, open Settings, or quit QuitDelay.

## Build and self-sign locally

Local builds require macOS 14 or later and Xcode 15 or later.

### Sign with your Apple development identity

This is the recommended approach for development because the app keeps a stable signing identity across builds, which makes macOS privacy permissions and Launch on Boot more reliable.

1. Clone this repository using GitHub's **Code** menu, then open the project:

   ```sh
   cd quit-delay
   open QuitDelay.xcodeproj
   ```

2. In Xcode, select the **QuitDelay** project, then the **QuitDelay** app target.
3. Open **Signing & Capabilities**, enable **Automatically manage signing**, and choose your development team.
4. Select the **QuitDelay** scheme with **My Mac** as the destination, then press Run.
5. Approve Accessibility/Input Monitoring access when prompted.

Xcode signs this build with your Apple Development identity. It is suitable for your own Macs, but it is not a Developer ID-notarized build and should not be redistributed as an official release.

### Ad-hoc sign without a developer account

For temporary local testing, build a universal Release app with an ad-hoc signature:

```sh
xcodebuild -project QuitDelay.xcodeproj \
  -scheme QuitDelay \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath DerivedData \
  build \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM=
```

The app will be at `DerivedData/Build/Products/Release/QuitDelay.app`. Ad-hoc builds are not notarized and are only intended for your own Mac. Because their identity can change between builds, macOS may request privacy approval again; use the signed GitHub release or a consistent Apple Development identity for regular use.

## Development

1. Clone the repository and open `QuitDelay.xcodeproj`.
2. Configure your development team under **Signing & Capabilities**.
3. Build and run the **QuitDelay** scheme on **My Mac**.
4. Grant the requested privacy permissions and manually verify both paths:

   - Releasing Command–Q early dismisses the overlay without quitting the focused app.
   - Holding Command–Q through the configured delay quits only the app that was focused when the hold began.

5. With multiple displays attached, verify the overlay appears on the display containing the focused app window.

Run all unit tests without requiring a test signing identity:

```sh
xcodebuild -project QuitDelay.xcodeproj \
  -scheme QuitDelay \
  -destination 'platform=macOS' \
  test \
  CODE_SIGNING_ALLOWED=NO
```

Run Xcode's static analyzer:

```sh
xcodebuild -project QuitDelay.xcodeproj \
  -scheme QuitDelay \
  -destination 'platform=macOS' \
  analyze \
  CODE_SIGNING_ALLOWED=NO
```

The main source areas are:

- `QuitDelay/App`: app and menu-bar lifecycle
- `QuitDelay/Input`: global Command–Q event interception and replay
- `QuitDelay/Core`: settings and hold-to-quit state machine
- `QuitDelay/UI`: settings window, overlay, and multi-display placement
- `QuitDelay/Services`: privacy permission and Launch on Boot integration
- `QuitDelayTests`: state-machine, settings, event, and display tests

## Publish a maintainer release

The release script runs the tests, builds a universal `arm64`/`x86_64` archive, signs it with Developer ID, notarizes and staples it, verifies it with Gatekeeper, and uploads the ZIP and its SHA-256 checksum to GitHub Releases.

Before the first release:

1. Install a valid **Developer ID Application** certificate and its private key in Keychain Access under **My Certificates**.
2. Save notarization credentials in the login Keychain. This command prompts for credentials without putting them in the repository:

   ```sh
   xcrun notarytool store-credentials QuitDelay
   ```

3. Commit and push a clean `main` branch, then run:

   ```sh
   scripts/release.sh 1.0.0
   ```

Use `--draft` or `--prerelease` after the version when needed. `NOTARY_PROFILE`, `SIGNING_IDENTITY`, and `BUILD_NUMBER` can override their detected/default values; set `SKIP_TESTS=1` only when the tests have already run against the exact commit being released.

The script validates the signing credentials, notarization profile, and repository state before building.
