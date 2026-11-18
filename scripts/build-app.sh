#!/bin/bash
# Compile Lumio et assemble build/Lumio.app (signature locale ad hoc).
# Usage : ./scripts/build-app.sh [--install]   (--install copie l'app dans /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Lumio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Lumio "$APP/Contents/MacOS/Lumio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "OK : $APP"
if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/Lumio.app"
    cp -R "$APP" "/Applications/Lumio.app"
    echo "Installée dans /Applications/Lumio.app"
fi
