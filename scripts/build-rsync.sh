#!/bin/zsh
# Builds the rsync the app ships (Contents/Helpers/rsync) from the official source, into .build/rsync/bin/rsync.
#
# macOS 15 replaced rsync with openrsync (protocol 29, "rsync 2.6.9 compatible"), which lacks --info=progress2,
# --partial-dir and most of what NASUpload drives, so the app brings its own. It is built with OpenSSL, xxhash,
# zstd, lz4 and IDN off: then it links nothing but macOS's own libraries, so the hardened-runtime signature has nothing to object
# to, and it works on any Mac without Homebrew. MD5 and the delta algorithm still work (rsync's own code); the
# transfer is over ssh, which does the encryption.
#
# Cached: nothing happens when .build/rsync/bin/rsync is already this version. Run with CLEAN=1 to rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

RSYNC_VERSION="${RSYNC_VERSION:-3.5.1}"
# From the release at https://github.com/RsyncProject/rsync/releases/tag/v3.5.1; cross-checked against
# Homebrew's formula (Formula/r/rsync.rb) on 2026-10-28.
RSYNC_SHA256="${RSYNC_SHA256:-c55f9c9dc10fb8bec397b399a0fdded53cc9a2d8e30891bb0d63724d25c37bef}"
URL="https://github.com/RsyncProject/rsync/releases/download/v$RSYNC_VERSION/rsync-$RSYNC_VERSION.tar.gz"

ROOT=".build/rsync"
SRC="$ROOT/src"
BIN="$ROOT/bin/rsync"
TARBALL="$SRC/rsync-$RSYNC_VERSION.tar.gz"
TREE="$SRC/rsync-$RSYNC_VERSION"

if [[ "${CLEAN:-}" == "1" ]]; then rm -rf "$ROOT"; fi
if [[ -x "$BIN" ]] && "$BIN" --version 2>/dev/null | head -1 | grep -q "rsync  version $RSYNC_VERSION "; then
  echo "rsync $RSYNC_VERSION already built: $BIN"
  exit 0
fi

mkdir -p "$SRC" "$ROOT/bin"
if [[ ! -f "$TARBALL" ]]; then
  echo "downloading $URL"
  curl -fsSL -o "$TARBALL" "$URL"
fi
echo "$RSYNC_SHA256  $TARBALL" | shasum -a 256 -c -

rm -rf "$TREE"
tar xzf "$TARBALL" -C "$SRC"
(
  cd "$TREE"
  # Apple Silicon only, like the app. Add "-arch x86_64" to both flags for a universal build.
  ./configure --disable-openssl --disable-xxhash --disable-zstd --disable-lz4 --disable-md2man --disable-idn --disable-debug \
    CFLAGS="-O2 -arch arm64 -mmacosx-version-min=15.0" LDFLAGS="-arch arm64" > ../configure-$RSYNC_VERSION.log 2>&1
  make -j"$(sysctl -n hw.ncpu)" > ../make-$RSYNC_VERSION.log 2>&1
)
cp "$TREE/rsync" "$BIN"
strip "$BIN"

# Only macOS's own libraries (/usr/lib: libSystem, libiconv, libcharset): anything else would be a Homebrew
# library the signed app can't load on another Mac.
if otool -L "$BIN" | tail -n +2 | grep -v '^\s*/usr/lib/' | grep -q '/'; then
  echo "rsync links something outside /usr/lib:"; otool -L "$BIN"; exit 1
fi
"$BIN" --version | head -1
echo "built $BIN"
