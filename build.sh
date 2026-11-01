#!/bin/bash
# Compile hdCLEANER et produit build/hdCLEANER.app.
# Signature : certificat local stable (sign_app.sh), macOS garde ainsi les autorisations d'un build à l'autre.
# Autre identité : SIGN_IDENTITY="<empreinte SHA-1 ou nom du certificat>" ./build.sh
# Un build normal est déplacé dans ~/Applications/Applications Personnelles (INSTALL_DIR pour un autre dossier).
# Essais réels : SELFTEST=1 ./build.sh ajoute le pilotage sans menu (voir SelfTest.swift).
set -euo pipefail
cd "$(dirname "$0")"

SIGN_TOOL="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
APP="build/hdCLEANER.app"
FLAGS=()
[ "${SELFTEST:-0}" = "1" ] && FLAGS=(-Xswiftc -DHDCLEANER_SELFTEST)

# Socle vit hors de /Volumes/SKYRIM/TOOLS/MAC : sync_apps.sh ne le voit pas, on le reprend ici.
SOCLE_SWIFT="/Volumes/SKYRIM/TOOLS/DESIGN/Socle/swift/Socle.swift"
[ -f "$SOCLE_SWIFT" ] && cp "$SOCLE_SWIFT" Sources/hdCLEANER/Socle.swift

swift build -c release ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)/hdCLEANER"
[ -x "$BIN" ] || { echo "Binaire introuvable : $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/hdCLEANER"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/" # textes fr, en, es, it
cp assets/icon.icns "$APP/Contents/Resources/icon.icns"
cp Resources/LaunchAgent.plist "$APP/Contents/Library/LaunchAgents/com.stephan.hdcleaner.monitor.plist"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
    codesign --verify --strict "$APP"
else
    "$SIGN_TOOL" "$APP"
fi

# Build normal : l'app est déplacée (plus de copie dans build/). Le build d'essai reste dans build/.
if [ "${SELFTEST:-0}" != "1" ]; then
    DEST="${INSTALL_DIR:-$HOME/Applications/Applications Personnelles}"
    mkdir -p "$DEST"
    pgrep -x hdCLEANER >/dev/null && echo "ATTENTION : hdCLEANER tourne, relancez-le pour utiliser la nouvelle version." >&2
    rm -rf "$DEST/hdCLEANER.app"
    mv "$APP" "$DEST/hdCLEANER.app"
    echo "OK : $DEST/hdCLEANER.app"
else
    echo "OK : $(pwd)/$APP (build d'essai)"
fi
