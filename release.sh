#!/bin/bash
# Publie la version de Resources/Info.plist : compile, signe Developer ID, notarise, agrafe, archive, crée la release GitHub vX.Y.Z.
# Usage : ./release.sh   (NOTES="…")
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
TAG="v$VERSION"
[ -z "$(git status --porcelain)" ] || { echo "Modifications non commitées : commitez d'abord." >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG existe déjà : changez la version dans Resources/Info.plist." >&2; exit 1; }

WORK="$(mktemp -d)"
INSTALL_DIR="$WORK/build" ./build.sh
DIST="$WORK/notarized" /Volumes/SKYRIM/TOOLS/MAC/_tools/notarize_app.sh "$WORK/build/hdCLEANER.app"
ZIP="$WORK/hdCLEANER-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$WORK/notarized/hdCLEANER.app" "$ZIP"
git push origin main
gh release create "$TAG" "$ZIP" --title "hdCLEANER $VERSION" --notes "${NOTES:-Version $VERSION}"
rm -rf "$WORK"
echo "OK : release $TAG publiée"
