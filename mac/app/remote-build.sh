#!/bin/bash
# Builds the Mac app on the Mac over SSH, from this checkout, and leaves Whisper-PTT.dmg
# in the Mac's Downloads folder. The Makefile's mac-app and mac-install targets run it.
#   bash mac/app/remote-build.sh <ssh host> [--install]
# --install also replaces /Applications/Whisper PTT.app on the Mac and opens it.
set -euo pipefail
HOST="${1:?usage: remote-build.sh <ssh host of the Mac> [--install]}"
shift
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="Library/Caches/whisper-ptt-app/src"

tar -C "$HERE" --exclude=.build --exclude=build -cf - . |
  ssh "$HOST" "rm -rf ~/$SRC && mkdir -p ~/$SRC && tar -xf - -C ~/$SRC"
ssh "$HOST" "cd ~/$SRC && ./build.sh $* && cp build/Whisper-PTT.dmg ~/Downloads/"
echo "Whisper-PTT.dmg is in the Downloads folder on $HOST."
