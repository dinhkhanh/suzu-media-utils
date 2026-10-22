#!/bin/zsh
# Builds "SuZu Media Utils.app" into ./dist. Needs models/compiled/ArcFaceR50.mlmodelc (see README → Models).
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="SuZu Media Utils"
VERSION="${VERSION:-0.5.2}"
swift build -c release --product SuZuMediaUtils
APP="dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SuZuMediaUtils "$APP/Contents/MacOS/$NAME"
cp -R models/compiled/ArcFaceR50.mlmodelc "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
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
</dict>
</plist>
PLIST
# SIGN_IDENTITY set (scripts/release.sh): Developer ID with hardened runtime and a secure timestamp, as notarization
# requires. Otherwise an ad-hoc signature so macOS still remembers folder permissions between launches.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "built $APP"
