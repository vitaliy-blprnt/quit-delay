# QuitDelay

QuitDelay is a native macOS menu-bar utility that prevents accidental Command–Q quits. Pressing Command–Q shows a progress overlay; releasing either key before the configured delay cancels the quit. Holding the shortcut for the full delay sends Command–Q only to the application that was focused when the hold began.

## Requirements

- macOS 14 or later
- Xcode 15 or later
- Accessibility/Input Monitoring approval when macOS prompts for it

## Build and run

1. Open `QuitDelay.xcodeproj` in Xcode.
2. Select your development team under **Signing & Capabilities** so the app keeps a stable identity.
3. Select the **QuitDelay** scheme and run it.
4. Approve the requested privacy permissions in **System Settings → Privacy & Security**. If macOS asks for a relaunch after Input Monitoring approval, quit and run QuitDelay again.

QuitDelay runs as an agent app: it has no Dock icon and is controlled through its hourglass icon in the menu bar.

## Verification

Run the unit tests from Xcode, or from Terminal:

```sh
xcodebuild -project QuitDelay.xcodeproj \
  -scheme QuitDelay \
  -destination 'platform=macOS' \
  test
```

For Launch on Boot, use a consistently signed build. Moving a release build to `/Applications` before enabling the option gives macOS the most stable registration path.

## Publish a release

The release script runs the tests, builds a universal `arm64`/`x86_64` archive, signs it with Developer ID, notarizes and staples it, verifies it with Gatekeeper, and uploads the ZIP and its SHA-256 checksum to the public GitHub repository.

Before the first release:

1. Install a valid **Developer ID Application** certificate and its private key in Keychain Access under **My Certificates**.
2. Save notarization credentials in the login Keychain. This command prompts for the Apple ID, team ID, and app-specific password without putting the password in the repository:

   ```sh
   xcrun notarytool store-credentials QuitDelay
   ```

3. Make sure GitHub CLI is using the repository owner:

   ```sh
   gh auth switch --hostname github.com --user vitaliy-blprnt
   gh auth status --hostname github.com
   ```

4. Commit and push a clean `main` branch, then run:

   ```sh
   scripts/release.sh 1.0.0
   ```

Use `--draft` or `--prerelease` after the version when needed. `NOTARY_PROFILE`, `SIGNING_IDENTITY`, and `BUILD_NUMBER` can override their detected/default values; set `SKIP_TESTS=1` only when the tests have already run against the exact commit being released.

The script intentionally stops before building if the Developer ID private key, notarization profile, active `vitaliy-blprnt` GitHub login, public repository, clean working tree, or pushed commit is missing.
