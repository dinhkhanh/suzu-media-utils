#!/bin/zsh
# Signed + notarized release in ./dist:
#   SuZu-Media-Utils-<version>.zip   what the app's updater downloads
#   SuZu-Media-Utils-<version>.dmg   drag-to-Applications installer for people installing by hand
#   appcast.xml                      the update feed (this version, its release notes), signed with the Sparkle key
# Then scripts/publish.sh tags the version and uploads the three to GitHub.
#
# One-time setup:
#   xcrun notarytool store-credentials suzu-notary --apple-id <you@example.com> --team-id KJ8A3B7BM7
#     (an app-specific password from appleid.apple.com → Sign-In and Security → App-Specific Passwords)
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys      # Sparkle key in the login keychain (once per studio;
#     back it up with `generate_keys -x sparkle-key.txt`; the public half is in scripts/build-app.sh)
#
# usage: VERSION=0.6.3 NOTES=notes.md scripts/release.sh   (the same notes file scripts/publish.sh takes)
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM_ID="KJ8A3B7BM7"
PROFILE="${NOTARY_PROFILE:-suzu-notary}"
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: GCE MEDIA AND SOFTWARE TECHNOLOGY COMPANY LIMITED ($TEAM_ID)}"
export VERSION="${VERSION:?set VERSION}"
# Release notes are required: they are the update window's changelog (checked now, not after notarizing).
export NOTES="${NOTES:?set NOTES to a markdown file with the release notes}"
[[ -s "$NOTES" ]] || { echo "$NOTES is missing or empty"; exit 1; }
NAME="SuZu Media Utils"
APP="dist/$NAME.app"
ZIP="dist/SuZu-Media-Utils-$VERSION.zip"
DMG="dist/SuZu-Media-Utils-$VERSION.dmg"

scripts/build-app.sh
codesign --verify --strict --verbose=2 "$APP"

echo "Notarizing the app (usually 1–5 minutes)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
# Re-zip so the stapled ticket travels with the app (works offline on the target Mac).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"

echo "Making the disk image…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
echo "Notarizing the disk image…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

scripts/appcast.sh
echo "Release: $ZIP, $DMG, dist/appcast.xml"
