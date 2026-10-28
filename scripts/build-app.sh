#!/bin/zsh
# Builds "SuZu Media Utils.app" into ./dist. Needs models/compiled/ArcFaceR50.mlmodelc (see README → Models).
#
# Updates (Sparkle): the app checks SPARKLE_FEED_URL once a day and installs updates signed with the EdDSA key whose
# public half is SPARKLE_PUBLIC_KEY (private half: login keychain, see scripts/release.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="SuZu Media Utils"
VERSION="${VERSION:-0.8.37}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/dinhkhanh/suzu-media-utils/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-SRLHhBqtlIsBvuqpk/ONBFaAS629idQVYwoebgfGd/E=}"
swift build -c release --product SuZuMediaUtils
# The rsync behind "Upload to Team NAS" (NASUpload); macOS's own is openrsync and can't do it. Built once, cached.
scripts/build-rsync.sh
APP="dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
cp .build/release/SuZuMediaUtils "$APP/Contents/MacOS/$NAME"
cp .build/rsync/bin/rsync "$APP/Contents/Helpers/rsync"
cp -R models/compiled/ArcFaceR50.mlmodelc "$APP/Contents/Resources/"
# Edit & Export's body-parts model is not in the app (600 MB in every update): the app downloads it once into
# Application Support (scripts/publish-model.sh puts it on GitHub).
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sparkle ships as a framework next to the binary; the binary looks for it in ../Frameworks.
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>dk.dinhkhanh.suzumediautils</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSNetworkVolumesUsageDescription</key><string>SuZu Media Utils reads photos and videos from folders on your NAS.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>SuZu Media Utils reads photos and videos from folders you add.</string>
    <key>NSDesktopFolderUsageDescription</key><string>SuZu Media Utils reads photos and videos from folders you add.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>SuZu Media Utils reads photos and videos from folders you add.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>SuZu Media Utils reads photos and videos from external drives.</string>
    <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST
# SIGN_IDENTITY set (scripts/release.sh): Developer ID with hardened runtime and a secure timestamp, as notarization
# requires. Otherwise an ad-hoc signature so macOS still remembers folder permissions between launches.
# Sparkle's pieces are signed inside out first (its XPC services keep their own entitlements), then the app.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign() { codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$@"; }
else
  sign() { codesign --force --preserve-metadata=entitlements --sign - "$@"; }
fi
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP/Contents/Helpers/rsync"
sign "$APP"
echo "built $APP"
