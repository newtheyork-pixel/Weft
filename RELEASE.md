# Releasing Weft (native macOS beta)

Weft ships as a **Developer ID-signed, notarized DMG** published to GitHub
Releases on `newtheyork-pixel/weft-releases`. The website's `/api/download`
serves the newest release, so publishing a higher version makes it the public
download automatically.

- **Not** the Mac App Store / TestFlight: the app runs with the App Sandbox
  **off** (proctoring enumerates processes, displays, VMs), which the store forbids.
- **Floor: macOS 26.1+** (the app uses current SwiftUI APIs). Anyone on older
  macOS can't run it.
- Current version: `0.3.0` (set via `MARKETING_VERSION` in the project; it clears
  the old Electron `0.2.22` so it becomes the download).

## One-time setup

1. **Developer ID Application certificate** in your login keychain (team
   `PW2VT56789`) — the same one your Electron releases use. Verify:
   `security find-identity -v -p codesigning | grep "Developer ID Application"`.
2. **Signing creds:** `cp scripts/.env.signing.example scripts/.env.signing` and
   fill in `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, `GH_TOKEN`
   (same values as the Electron app's `.env.signing`). It's gitignored.
3. **Xcode license:** `sudo xcodebuild -license accept` (notarytool needs it).

## Cut a beta

```bash
# bump MARKETING_VERSION first (both Debug+Release in the project), then:
scripts/release.sh
```

Only bump the human version (`MARKETING_VERSION`). The build number
(`CFBundleVersion`, which is what Sparkle actually compares to decide "newer?")
is set automatically by the script from the git commit count, so it always
increases — don't hand-edit `CURRENT_PROJECT_VERSION`.

The script: archives Release → exports a Developer ID app → builds a DMG →
notarizes + staples both the DMG and the app → publishes a **pre-release** tag
(`v<version>`) to `weft-releases`. If Sparkle is set up (below), it also signs a
`.zip` and updates the appcast. It's safe to run before Sparkle exists — it just
ships the DMG.

**Verify the beta** on a clean Mac (or after download): the DMG opens with no
Gatekeeper warning, and (after mounting) `spctl -a -vvv -t exec /Volumes/Weft/Weft.app`
should say `accepted` (`-t exec` is the check for an app bundle; `-t install` is
for installer packages).

---

## Activating Sparkle (in-app auto-update)

Three of these steps need Xcode / your keychain, so they're not scripted. Until
the package is added, leave the Updater code out so the build stays green.

### 1. Add the Sparkle package (Xcode)
File → Add Package Dependencies → `https://github.com/sparkle-project/Sparkle`
→ "Up to Next Major" from `2.6.0` → add **Sparkle** to the **Weft** target.

### 2. Get Sparkle's CLI tools on PATH
Download the Sparkle release tarball from
`https://github.com/sparkle-project/Sparkle/releases`, and copy its `bin/`
tools onto your PATH:
```bash
sudo cp bin/generate_keys bin/sign_update bin/generate_appcast /usr/local/bin/
```

### 3. Generate the EdDSA signing key (once)
```bash
generate_keys          # stores the private key in your login keychain
                       # and prints the public key (base64) — copy it.
```

### 4. Info.plist keys
Add to `Weft/Info.plist`:
```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/newtheyork-pixel/weft-releases/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>PASTE_THE_PUBLIC_KEY_FROM_generate_keys</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

### 5. Wire the updater (add `Weft/Updater.swift` after step 1, then build)
```swift
import SwiftUI
import Sparkle

/// Sparkle updater wrapper. Crucially blocks update checks while a student is in
/// the locked exam, so an update can never interrupt or relaunch mid-test.
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()
    private(set) lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    var examInProgress = false
    // Sparkle 2's real gate: throwing here blocks the check (scheduled OR manual).
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if examInProgress {
            throw NSError(domain: "Weft", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Updates are paused during an exam."])
        }
    }
}
```
In `WeftApp.swift`, start it and add a menu item:
```swift
init() { _ = UpdaterController.shared.controller }   // starts the updater
// inside .commands:
CommandGroup(after: .appInfo) {
    Button("Check for Updates…") {
        UpdaterController.shared.controller.updater.checkForUpdates()
    }
}
```
And gate it on the exam: set `UpdaterController.shared.examInProgress = true` in
`AppState.enterExam()` and `false` in `finishExam()` / `submitExam`.

### 6. If signing complains about Sparkle's XPC services
Only if export/notarization errors on Sparkle's helpers, add a
`Weft/Weft.entitlements` with `com.apple.security.cs.disable-library-validation`
= true and set `CODE_SIGN_ENTITLEMENTS = Weft/Weft.entitlements` in the project.
A non-sandboxed Developer ID app usually does **not** need this.

Once 1–5 are done, `scripts/release.sh` auto-detects `generate_appcast`, signs the
zip, and publishes/updates the appcast on the `weft-releases` default branch — the
stable URL `SUFeedURL` points at.

## Notes
- **Existing Electron installs won't auto-migrate** (they poll `latest-mac.yml`;
  native uses the Sparkle appcast). New downloaders get native; current Electron
  testers re-download once.
- Promote a beta to "latest" by un-checking pre-release on the GitHub release, or
  keep it pre-release while testing.
