#!/bin/zsh
# Writes the update feed, dist/appcast.xml, for the zip scripts/release.sh made, with the release notes in it:
# what installed apps show in their update window. Run by scripts/release.sh; on its own to redo the feed (new
# notes) without notarizing again.
#
# usage: VERSION=0.6.3 NOTES=notes.md scripts/appcast.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:?set VERSION}"
NOTES="${NOTES:?set NOTES to a markdown file with the release notes (they go in the update window)}"
[[ -s "$NOTES" ]] || { echo "$NOTES is missing or empty"; exit 1; }
ZIP="dist/SuZu-Media-Utils-$VERSION.zip"
[[ -f "$ZIP" ]] || { echo "missing $ZIP (run scripts/release.sh)"; exit 1; }
DOWNLOAD_PREFIX="${SPARKLE_DOWNLOAD_PREFIX:-https://github.com/dinhkhanh/suzu-media-utils/releases/download/v$VERSION/}"

echo "Writing the update feed…"
rm -rf dist/appcast && mkdir -p dist/appcast
cp "$ZIP" dist/appcast/
# The notes as HTML next to the zip: generate_appcast puts them in the feed. Paragraphs and **bold** only.
python3 -I - "$NOTES" "dist/appcast/SuZu-Media-Utils-$VERSION.html" "$VERSION" <<'PY'
import html, re, sys
src, out, version = sys.argv[1:]
paras = [p.strip() for p in re.split(r"\n\s*\n", open(src, encoding="utf-8").read()) if p.strip() and p.strip() != "---"]
body = "".join("<p>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(" ".join(p.split()), quote=False)) + "</p>\n" for p in paras)
open(out, "w", encoding="utf-8").write(f"<h2>SuZu Media Utils {version}</h2>\n{body}")
PY
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/dinhkhanh/suzu-media-utils/releases/tag/v$VERSION" -o dist/appcast.xml dist/appcast
rm -rf dist/appcast
python3 -I -c 'import re,sys; v=sys.argv[1]; items=re.findall(r"<item>.*?</item>", open("dist/appcast.xml").read(), re.S); sys.exit(0 if any(f"shortVersionString>{v}<" in i and "<description" in i for i in items) else 1)' "$VERSION" || { echo "the feed has no release notes for $VERSION"; exit 1; }
