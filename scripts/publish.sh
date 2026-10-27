#!/bin/zsh
# Tags the version, pushes, and creates the GitHub release with the zip, the dmg and the update feed from
# scripts/release.sh. Installed apps read the feed at releases/latest/download/appcast.xml, so this is the update.
#
# usage: VERSION=0.6.3 NOTES=notes.md scripts/publish.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:?set VERSION}"
NOTES="${NOTES:?set NOTES to a markdown file with the release notes}"
ZIP="dist/SuZu-Media-Utils-$VERSION.zip"
DMG="dist/SuZu-Media-Utils-$VERSION.dmg"
for f in "$ZIP" "$DMG" dist/appcast.xml; do [[ -f "$f" ]] || { echo "missing $f (run scripts/release.sh)"; exit 1; }; done
[[ -s "$NOTES" ]] || { echo "$NOTES is missing or empty"; exit 1; }
# The feed must carry this version and its notes (installed apps show them when they update).
python3 -I -c 'import re,sys; v=sys.argv[1]; items=re.findall(r"<item>.*?</item>", open("dist/appcast.xml").read(), re.S); sys.exit(0 if any(f"shortVersionString>{v}<" in i and "<description" in i for i in items) else 1)' "$VERSION" \
  || { echo "dist/appcast.xml has no notes for $VERSION (VERSION=$VERSION NOTES=$NOTES scripts/appcast.sh)"; exit 1; }

git push origin HEAD
git tag -a "v$VERSION" -m "SuZu Media Utils $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$DMG" dist/appcast.xml --title "SuZu Media Utils $VERSION" --notes-file "$NOTES"
echo "Published v$VERSION"
