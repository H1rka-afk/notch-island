#!/bin/bash
# Builds a universal (Apple silicon + Intel) Ovira.app and the release
# archive Notch-Island-v<version>.zip. Used by GitHub Actions; the same file
# list and frameworks as «Установить Notch Island.command».
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SRC="$ROOT/Source"
INSTALLER="$ROOT/Установить Notch Island.command"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Info.plist")"
OUT="$ROOT/build"
APP="$OUT/Ovira.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/NotchIsland.icns" "$APP/Contents/Resources/NotchIsland.icns"
for ICON in IconDark.png IconLight.png; do
  [[ -f "$SRC/$ICON" ]] && cp "$SRC/$ICON" "$APP/Contents/Resources/$ICON"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The exact sources and frameworks of the installer.
FILES=()
while IFS= read -r name; do FILES+=("$SRC/$name"); done < <(
  grep -o '"\$SRC/[A-Za-z0-9]*\.swift"' "$INSTALLER" | sed 's/"\$SRC\///; s/"//')
FRAMEWORKS=()
while IFS= read -r fw; do FRAMEWORKS+=(-framework "$fw"); done < <(
  grep -o -- '-framework [A-Za-z]*' "$INSTALLER" | awk '{print $2}' | awk '!seen[$0]++')
echo "Notch Island $VERSION: ${#FILES[@]} files, ${#FRAMEWORKS[@]} framework flags"
xcrun swiftc --version

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CORES="$(sysctl -n hw.ncpu)"
for ARCH in arm64 x86_64; do
  echo "== $ARCH"
  xcrun --sdk macosx swiftc -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -O -wmo -num-threads "$CORES" \
    -parse-as-library "${FRAMEWORKS[@]}" "${FILES[@]}" -o "$OUT/NotchIsland-$ARCH"
done
lipo -create "$OUT/NotchIsland-arm64" "$OUT/NotchIsland-x86_64" -output "$APP/Contents/MacOS/NotchIsland"
chmod +x "$APP/Contents/MacOS/NotchIsland"
# Temporary signature only; every Mac re-signs with its own persistent one.
codesign --force --sign - "$APP"

# The release archive: the usual installer folder plus the ready-made app.
PKG="$OUT/Notch-Island-Installer-v$VERSION"
mkdir -p "$PKG/Prebuilt"
cp -R "$SRC" "$ROOT/Tests" "$PKG/"
cp "$INSTALLER" "$ROOT"/*.txt "$PKG/"
for extra in "$ROOT"/*.command; do cp "$extra" "$PKG/"; done
ditto "$APP" "$PKG/Prebuilt/Ovira.app"
(cd "$OUT" && ditto -c -k --keepParent "Notch-Island-Installer-v$VERSION" "Notch-Island-v$VERSION.zip")
ls -lh "$OUT/Notch-Island-v$VERSION.zip"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "version=$VERSION" >> "$GITHUB_OUTPUT"; fi
