#!/usr/bin/env bash
# Compile NotchRAM.app (aucune dépendance, juste swiftc) et l'installe dans ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/NotchRAM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# binaire universel : Apple Silicon + Intel (sans encoche, il retombe sur une pastille sous la barre des menus)
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 main.swift -o "build/NotchRAM-$arch"
done
lipo -create build/NotchRAM-arm64 build/NotchRAM-x86_64 -output "$APP/Contents/MacOS/NotchRAM"
rm build/NotchRAM-arm64 build/NotchRAM-x86_64
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/NotchRAM" --selftest
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/NotchRAM.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installé : $HOME/Applications/NotchRAM.app"
