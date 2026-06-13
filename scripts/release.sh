#!/usr/bin/env bash
#
# Build + sign + notarize + staple + (Sparkle) sign + publish a Weft beta.
#
# Native macOS app (Xcode), distributed as a Developer ID-notarized DMG via
# GitHub Releases on newtheyork-pixel/weft-releases. Mirrors the Electron app's
# release.sh, but uses raw Apple tooling instead of electron-builder.
#
#   Usage:  scripts/release.sh
#   Setup:  see RELEASE.md  (copy scripts/.env.signing.example -> scripts/.env.signing)
#
# Prereqs (one-time):
#   - Developer ID Application cert in the login keychain (team PW2VT56789)
#   - scripts/.env.signing filled in (Apple ID + app-specific password + team)
#   - GH_TOKEN with contents:write on newtheyork-pixel/weft-releases
#   - sudo xcodebuild -license accept   (notarytool is blocked otherwise)
#   - For Sparkle updates: Sparkle's `generate_appcast` on PATH + an EdDSA key
#     in the keychain (see RELEASE.md "Sparkle"). The script auto-detects these;
#     without them it ships a notarized DMG with no appcast (fine for a first cut).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; [ -n "${2:-}" ] && printf '  %s\n' "$2" >&2; exit 1; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
info() { printf '\033[36m•\033[0m %s\n' "$1"; }

RELEASES_REPO="newtheyork-pixel/weft-releases"
SCHEME="Weft"
PROJECT="Weft.xcodeproj"
BUILD_DIR="$ROOT/build/release"
ARCHIVE="$BUILD_DIR/Weft.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

echo "── Weft beta release ────────────────────────────────────────"

# 1. Credentials.
[ -f scripts/.env.signing ] || fail "No scripts/.env.signing" "Copy scripts/.env.signing.example and fill it in (see RELEASE.md)."
# shellcheck disable=SC1091
set -a; source scripts/.env.signing; set +a
: "${APPLE_TEAM_ID:?set in scripts/.env.signing}"
: "${APPLE_ID:?set in scripts/.env.signing}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?set in scripts/.env.signing}"
: "${GH_TOKEN:?export a token with contents:write on $RELEASES_REPO}"
ok "Signing env + GH_TOKEN present (team $APPLE_TEAM_ID)"

# 2. Toolchain preflight.
xcrun --find notarytool >/dev/null 2>&1 || fail "notarytool missing" "Run: sudo xcodebuild -license accept"
security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
  || fail "No 'Developer ID Application' cert in the keychain" "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
command -v gh >/dev/null 2>&1 || fail "gh (GitHub CLI) not installed"
ok "notarytool + Developer ID cert + gh ready"

# 3. Version (single source of truth: the project's MARKETING_VERSION).
VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')"
[ -n "$VERSION" ] || fail "Could not read MARKETING_VERSION from the project"
# CFBundleVersion drives Sparkle's "is this newer?" check, so it MUST increase
# every release. Derive it from the commit count (monotonic) instead of trusting
# a hand-bumped CURRENT_PROJECT_VERSION — a frozen build number = Sparkle never
# offers the update. (Each release has new commits in practice.)
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
TAG="v$VERSION"
UPDATES="$BUILD_DIR/updates"      # Sparkle scans ONLY this dir (zip, no DMG)
DMG="$BUILD_DIR/Weft-$VERSION.dmg"
ZIP="$UPDATES/Weft-$VERSION.zip"  # the appcast enclosure
info "Releasing Weft $VERSION (build $BUILD_NUM, $TAG)"

# 4. Clean build → archive → export (Developer ID, hardened runtime).
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR" "$UPDATES"
info "Archiving (Release)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" archive \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" MARKETING_VERSION="$VERSION" >/dev/null
info "Exporting Developer ID app…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/exportOptions.plist -exportPath "$EXPORT_DIR" >/dev/null
APP="$EXPORT_DIR/Weft.app"
[ -d "$APP" ] || fail "Export produced no Weft.app"
ok "Built + signed $APP"

# 5. Package a DMG (app + Applications symlink).
info "Building DMG…"
STAGE="$BUILD_DIR/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Weft" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
ok "DMG: $DMG"

# 6. Notarize, then staple BOTH the DMG and the .app (so the Sparkle zip's app
#    carries its own ticket and launches offline without a Gatekeeper stall).
info "Notarizing (this can take a few minutes)…"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" \
  --wait || fail "Notarization failed" "Check the submission log: xcrun notarytool log <id> ..."
xcrun stapler staple "$DMG" || fail "Could not staple the DMG"
xcrun stapler staple "$APP" || fail "Could not staple the app bundle"
# Authoritative Gatekeeper check is on the APP (what actually launches), via
# -t exec. `spctl -t open` on a stapled-but-unsigned DMG gives false negatives;
# the DMG's own ticket is already proven by the stapler validation above.
if ! spctl -a -t exec -vv "$APP" 2>/dev/null; then
  fail "Gatekeeper rejected the signed app" "Re-check signing/notarization."
fi
ok "Notarized + stapled + Gatekeeper-accepted"

# 7. Sparkle (optional, auto-detected): zip the notarized app + EdDSA-sign it.
#    The zip is the appcast enclosure; its download URL is this tag's asset URL.
HAVE_APPCAST=0
if command -v generate_appcast >/dev/null 2>&1; then
  info "Sparkle detected — building + signing appcast…"
  ditto -c -k --keepParent "$APP" "$ZIP"   # the stapled app, into $UPDATES only
  # generate_appcast scans $UPDATES (zip only — the DMG is NOT here, so it can't
  # be mistaken for an enclosure), EdDSA-signs each archive with the key in the
  # keychain, and writes appcast.xml with enclosure URLs at the tag's assets.
  generate_appcast "$UPDATES" \
    --download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/$TAG/"
  [ -f "$UPDATES/appcast.xml" ] && HAVE_APPCAST=1 && ok "appcast.xml signed" \
    || info "generate_appcast wrote no appcast (check the EdDSA key)"
else
  info "Sparkle tools not on PATH — shipping the DMG only (no appcast this run)."
fi

# 8. Publish the binaries to the GitHub release (pre-release = clearly a beta).
ASSETS=("$DMG"); [ "$HAVE_APPCAST" = 1 ] && ASSETS+=("$ZIP")
info "Publishing $TAG to $RELEASES_REPO…"
if gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "${ASSETS[@]}" --repo "$RELEASES_REPO" --clobber
else
  # Full (Latest) release, not a pre-release: the website's /api/download serves
  # the newest NON-prerelease, and the product call is "replace the download"
  # with the native build. "(beta)" in the title conveys beta status.
  gh release create "$TAG" "${ASSETS[@]}" --repo "$RELEASES_REPO" \
    --title "Weft $VERSION (beta)" \
    --notes "Native macOS beta. Requires macOS 26.1 or later. Universal (Apple silicon + Intel)."
fi

# 9. Publish the appcast to a STABLE url (the repo's default branch), which is
#    what SUFeedURL points at:
#    https://raw.githubusercontent.com/newtheyork-pixel/weft-releases/main/appcast.xml
if [ "$HAVE_APPCAST" = 1 ]; then
  info "Committing appcast.xml to $RELEASES_REPO default branch…"
  TMP="$(mktemp -d)"
  git clone --depth 1 "https://x-access-token:$GH_TOKEN@github.com/$RELEASES_REPO.git" "$TMP/r" >/dev/null 2>&1 \
    || fail "Could not clone $RELEASES_REPO to publish the appcast"
  cp "$UPDATES/appcast.xml" "$TMP/r/appcast.xml"
  git -C "$TMP/r" add appcast.xml
  if git -C "$TMP/r" diff --cached --quiet; then
    info "appcast.xml unchanged — feed already current"
  else
    git -C "$TMP/r" -c user.name="Weft release" -c user.email="newtheyork@gmail.com" \
      commit -m "appcast: Weft $VERSION" >/dev/null
    # A failed push means the Sparkle feed silently didn't update — hard fail.
    git -C "$TMP/r" push >/dev/null 2>&1 \
      || fail "Pushed binaries but FAILED to publish appcast.xml" "Users won't see the update until the feed updates. Re-run or push appcast.xml manually."
    ok "appcast.xml published (Sparkle feed updated)"
  fi
  rm -rf "$TMP"
fi
echo ""
ok "Released $TAG → https://github.com/$RELEASES_REPO/releases/tag/$TAG"
info "The website download (/api/download) serves the newest release automatically."
