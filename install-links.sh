#!/bin/bash
# Puts this repo's pieces where the system looks for them. Safe to re-run: on a new
# machine, after moving the repo, or if a link went missing. The venv comes first (README).
set -euo pipefail
R="$(cd "$(dirname "$0")" && pwd)"
link() { mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; echo "linked $2"; }
link "$R/bin/whisper-ptt" "$HOME/.local/bin/whisper-ptt"
link "$R/systemd/whisper-ptt.service" "$HOME/.config/systemd/user/whisper-ptt.service"
link "$R/gnome-extension/whisper-polish@felixfalling" \
     "$HOME/.local/share/gnome-shell/extensions/whisper-polish@felixfalling"
if [ ! -f "$HOME/.config/whisper-ptt/config.json" ]; then
  mkdir -p "$HOME/.config/whisper-ptt"
  cp "$R/config.example.json" "$HOME/.config/whisper-ptt/config.json"
  echo "wrote a starter ~/.config/whisper-ptt/config.json: put a server_token in it"
fi
systemctl --user daemon-reload
cat <<MSG
Then, once:
  sudo cp $R/udev/70-whisper-ptt-input.rules /etc/udev/rules.d/ && sudo udevadm control --reload
  systemctl --user enable --now whisper-ptt
  gnome-extensions enable whisper-polish@felixfalling      (after logging out and in)
MSG
