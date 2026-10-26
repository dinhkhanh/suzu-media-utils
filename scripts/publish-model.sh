#!/bin/zsh
# Puts Edit & Export's body-parts model (models/compiled/BodyParts.mlmodelc, see README → Models) on GitHub as a
# release of its own, which the app downloads once into Application Support. Never marked latest: the update feed
# is at releases/latest. A changed model gets a new number N; then set BodyPartsModel's source, sha256 and
# downloadSize to what this prints.
#
# usage: N=1 scripts/publish-model.sh
set -euo pipefail
cd "$(dirname "$0")/.."
N="${N:?set N, the model's number}"
ZIP="dist/BodyParts-$N.zip"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent models/compiled/BodyParts.mlmodelc "$ZIP"
gh release create "models-bodyparts-$N" "$ZIP" --latest=false --title "Body-parts model $N" --notes \
  "Edit & Export's body-parts model, downloaded by the app (not an app release).

Meta's Sapiens 0.3B body-part segmentation (Goliath), converted to Core ML with tools/convert_sapiens.py.
Licence: CC BY-NC 4.0 (https://github.com/facebookresearch/sapiens), non-commercial use only."
echo "sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "size   $(stat -f %z "$ZIP")"
