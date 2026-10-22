#!/bin/zsh
# Signed + notarized release: dist/SuZu-Media-Utils-<version>.zip, ready to copy to any Mac.
#
# One-time setup (stores notarization credentials in the login keychain under the profile "suzu-notary"):
#   xcrun notarytool store-credentials suzu-notary --apple-id <you@example.com> --team-id KJ8A3B7BM7
#   (it asks for an app-specific password from appleid.apple.com → Sign-In and Security → App-Specific Passwords)
#
# usage: VERSION=0.3 scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM_ID="KJ8A3B7BM7"
PROFILE="${NOTARY_PROFILE:-suzu-notary}"
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: GCE MEDIA AND SOFTWARE TECHNOLOGY COMPANY LIMITED ($TEAM_ID)}"
export VERSION="${VERSION:-0.3}"
NAME="SuZu Media Utils"
APP="dist/$NAME.app"
ZIP="dist/SuZu-Media-Utils-$VERSION.zip"

scripts/build-app.sh
codesign --verify --strict --verbose=2 "$APP"

echo "Notarizing (usually 1–5 minutes)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
# Re-zip so the stapled ticket travels with the app (works offline on the target Mac).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Release: $ZIP"
