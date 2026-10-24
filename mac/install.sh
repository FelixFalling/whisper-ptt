#!/bin/bash
# Installs the Mac side of whisper-ptt. From the folder it came in:   ./install.sh
#   --no-fallback   skip mlx-whisper (no dictation when the desktop is away, ~1 GB less)
#   --autostart     also start it at login (see README.md: macOS permissions get fussier)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/.local/share/whisper-ptt-mac"
CONF="$HOME/.config/whisper-ptt/mac.json"
FALLBACK=1
AUTOSTART=0
for arg in "$@"; do
  case "$arg" in
    --no-fallback) FALLBACK=0 ;;
    --autostart) AUTOSTART=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

if ! command -v python3 >/dev/null; then
  echo "python3 not found. Run:  xcode-select --install   then run this again."
  exit 1
fi
if [[ $FALLBACK == 1 && "$(uname -m)" != "arm64" ]]; then
  echo "The fallback needs Apple Silicon; installing without it."
  FALLBACK=0
fi

mkdir -p "$APP" "$(dirname "$CONF")"
python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install --quiet --upgrade pip
"$APP/venv/bin/pip" install --quiet numpy sounddevice pynput
if [[ $FALLBACK == 1 ]]; then
  echo "Installing mlx-whisper for when the desktop is away (a few minutes)..."
  "$APP/venv/bin/pip" install --quiet mlx-whisper
fi
cp "$HERE/whisper-ptt-mac.py" "$APP/"

if [[ ! -f "$CONF" ]]; then
  cp "$HERE/mac.json" "$CONF"
  chmod 600 "$CONF"
fi
if [[ $FALLBACK == 0 ]]; then
  "$APP/venv/bin/python" - "$CONF" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["fallback"] = False
json.dump(cfg, open(p, "w"), indent=2)
PY
fi

cat > "$APP/run" <<EOF
#!/bin/bash
exec "$APP/venv/bin/python" "$APP/whisper-ptt-mac.py" "\$@"
EOF
chmod +x "$APP/run"

if [[ $AUTOSTART == 1 ]]; then
  PLIST="$HOME/Library/LaunchAgents/com.whisper-ptt.mac.plist"
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.whisper-ptt.mac</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/venv/bin/python</string>
    <string>$APP/whisper-ptt-mac.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/whisper-ptt-mac.log</string>
  <key>StandardErrorPath</key><string>/tmp/whisper-ptt-mac.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Starts at login. Log: /tmp/whisper-ptt-mac.log"
fi

echo
echo "Installed. Start it in Terminal with:"
echo "  $APP/run"
echo "Then hold right Option, speak, and let go."
