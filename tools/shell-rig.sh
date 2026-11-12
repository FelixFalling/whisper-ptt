#!/usr/bin/env bash
# A throwaway GNOME Shell for trying the Whisper extension without logging out.
#
# It runs headless on a D-Bus of its own, with its own settings and its own extension
# folder (this checkout's extension plus a helper that lets the commands below drive it),
# so nothing in your real session or its settings is touched. The Whisper buttons in it
# are real, though: they switch the real whisper-ptt.service.
#
#   tools/shell-rig.sh start            start it (stops one that is running)
#   tools/shell-rig.sh eval 'JS'        run JavaScript inside it; Main is in scope
#   tools/shell-rig.sh shot NAME        screenshot to $RIG/shots/NAME.png
#   tools/shell-rig.sh errors           what the extension logged, and any JS errors
#   tools/shell-rig.sh stop
#
# For example, the state of the Whisper button:
#   tools/shell-rig.sh eval 'Main.panel.statusArea.quickSettings.menu._grid.get_children()
#       .find(c => c.title === "Whisper").subtitle'
# and a picture of the open menu:
#   tools/shell-rig.sh eval 'Main.overview.hide(); Main.panel.statusArea.quickSettings.menu.open(); 1'
#   tools/shell-rig.sh shot menu
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UUID=whisper-polish@felixfalling
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
RIG="${RIG:-$XDG_RUNTIME_DIR/whisper-ptt-shell-rig}"
DISPLAY_NAME=whisper-ptt-rig

# The shell under test reads its settings and extensions from the rig, not from ~/.config.
rig_env() {
    export XDG_DATA_HOME="$RIG/data" XDG_CONFIG_HOME="$RIG/config" GSETTINGS_BACKEND=keyfile
}

on_bus() {
    [[ -s "$RIG/bus" ]] || { echo 'The rig is not running: tools/shell-rig.sh start' >&2; exit 1; }
    DBUS_SESSION_BUS_ADDRESS="$(cat "$RIG/bus")" "$@"
}

stop() {
    for name in shell bus; do
        [[ -s "$RIG/$name.pid" ]] && kill "$(cat "$RIG/$name.pid")" 2>/dev/null || true
    done
    sleep 0.5
    [[ -s "$RIG/shell.pid" ]] && kill -9 "$(cat "$RIG/shell.pid")" 2>/dev/null || true
    rm -f "$RIG"/*.pid "$RIG/bus" "$XDG_RUNTIME_DIR/$DISPLAY_NAME" "$XDG_RUNTIME_DIR/$DISPLAY_NAME.lock"
}

case "${1:-}" in
  start)
    mkdir -p "$RIG/data/gnome-shell/extensions/rig@whisper-ptt" "$RIG/config/glib-2.0/settings" "$RIG/shots"
    chmod 700 "$RIG"
    stop
    ln -sfn "$ROOT/gnome-extension/$UUID" "$RIG/data/gnome-shell/extensions/$UUID"
    MAJOR="$(gnome-shell --version | grep -oE '[0-9]+' | head -1)"
    cat > "$RIG/data/gnome-shell/extensions/rig@whisper-ptt/metadata.json" <<EOF
{"uuid": "rig@whisper-ptt", "name": "Shell rig", "description": "Lets tools/shell-rig.sh drive this throwaway shell.", "shell-version": ["$MAJOR"]}
EOF
    cat > "$RIG/data/gnome-shell/extensions/rig@whisper-ptt/extension.js" <<'EOF'
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
// Unsafe mode is what allows Eval and screenshots over D-Bus. Only this throwaway shell has it.
export default class Rig extends Extension {
    enable() { global.context.unsafe_mode = true; }
    disable() {}
}
EOF
    cat > "$RIG/config/glib-2.0/settings/keyfile" <<EOF
[org/gnome/shell]
enabled-extensions=['$UUID', 'rig@whisper-ptt']
welcome-dialog-last-shown-version='999.0'

[org/gnome/desktop/interface]
enable-animations=false
EOF
    rig_env
    dbus-daemon --session --print-address=3 --print-pid=4 --fork 3>"$RIG/bus" 4>"$RIG/bus.pid"
    DBUS_SESSION_BUS_ADDRESS="$(cat "$RIG/bus")" setsid nohup gnome-shell --headless --wayland --no-x11 \
        --virtual-monitor 1280x800 --wayland-display "$DISPLAY_NAME" >"$RIG/shell.log" 2>&1 &
    echo $! > "$RIG/shell.pid"
    for _ in $(seq 1 40); do
        if on_bus gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Eval 'true' 2>/dev/null | grep -q '(true'; then
            echo "The rig is up. Its files are in $RIG."
            exit 0
        fi
        sleep 0.5
    done
    echo 'The shell did not come up:' >&2
    tail -20 "$RIG/shell.log" >&2
    exit 1 ;;
  stop)
    stop ;;
  eval)
    on_bus gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
        --method org.gnome.Shell.Eval "${2:?usage: shell-rig.sh eval 'JS'}" ;;
  shot)
    on_bus gdbus call --session --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
        --method org.gnome.Shell.Screenshot.Screenshot false false "$RIG/shots/${2:?usage: shell-rig.sh shot NAME}.png" ;;
  errors)
    grep -i -E -A4 'JS ERROR|whisper-ptt:|whisper-polish' "$RIG/shell.log" || echo 'Nothing logged.' ;;
  *)
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2 ;;
esac
