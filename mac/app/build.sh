#!/bin/bash
# Builds "Whisper PTT.app" and Whisper-PTT.dmg. Run it on the Mac; it needs the Xcode
# Command Line Tools (xcode-select --install), not Xcode. From the desktop,
# `make mac-app MAC=<ssh host>` copies these sources over and runs it through SSH.
#   ./build.sh             build/Whisper PTT.app and build/Whisper-PTT.dmg
#   ./build.sh --install   also replace /Applications/Whisper PTT.app and open it
set -euo pipefail
cd "$(dirname "$0")"

NAME="Whisper PTT"
BUNDLE_ID="com.felixfalling.whisper-ptt"
APP="build/$NAME.app"
SCRATCH="$HOME/Library/Caches/whisper-ptt-app/swiftpm"   # kept between builds, so rebuilds are quick

swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/WhisperPTT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WhisperPTT"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/fallback.py "$APP/Contents/Resources/"
swift Tools/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# Ad hoc signing needs no Apple account. macOS ties the permissions it grants to this exact
# signature, so a changed app has to be allowed again (the setup window explains how).
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

rm -rf build/dmg build/Whisper-PTT.dmg
mkdir build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "$NAME" -srcfolder build/dmg -format UDZO build/Whisper-PTT.dmg
rm -rf build/dmg
echo "Built $PWD/$APP"
echo "  and $PWD/build/Whisper-PTT.dmg"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x WhisperPTT && sleep 1 || true
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$NAME.app"
  echo "Installed and opened /Applications/$NAME.app"
fi
