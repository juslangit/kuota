#!/usr/bin/env bash
# Builds Kuota.app into ./build, signs it with the shared local certificate,
# and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Kuota.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/Kuota" Sources/main.swift
cp Info.plist "$APP/Contents/Info.plist"
"$HOME/Desktop/projects/3d/bengkel/common/sign.sh" "$APP"

mkdir -p "$HOME/Applications"
pkill -x Kuota 2>/dev/null || true
rm -rf "$HOME/Applications/Kuota.app"
cp -R "$APP" "$HOME/Applications/Kuota.app"
echo "→ installed ~/Applications/Kuota.app"
