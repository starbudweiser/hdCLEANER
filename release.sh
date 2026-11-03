#!/bin/bash
# Publie la version de Resources/Info.plist : compile, signe Developer ID, notarise, agrafe, archive, crée la release GitHub vX.Y.Z.
# L'appli installée se met à jour toute seule depuis cette release (Updater.swift commun, _tools/shared).
# Usage : ./release.sh   (notes : _tools/changelogs/hdCLEANER_<version>.txt, 4 langues obligatoires)
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
(cd "$WORK" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
python3 /Volumes/SKYRIM/TOOLS/MAC/_tools/release_notes.py hdCLEANER "$VERSION" --sha "$ZIP.sha256" -o "$WORK/notes.md"
git push origin main
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "hdCLEANER $VERSION" --notes-file "$WORK/notes.md"
rm -rf "$WORK"
echo "OK : release $TAG publiée"
