#!/bin/bash
# Builds ../whisper-ptt-mac.zip for the MacBook, with mac.json filled in from this
# machine's config. The token lives only in ~/.config/whisper-ptt/config.json and in the
# zip; it is never committed (mac/mac.json and *.zip are gitignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$HERE" <<'PY'
import json, pathlib, sys
here = pathlib.Path(sys.argv[1])
desk = json.loads((pathlib.Path.home() / ".config/whisper-ptt/config.json").read_text())
mac = json.loads((here / "mac.example.json").read_text())
mac["token"] = desk["server_token"]
import subprocess
host = desk.get("server_host", "tailscale")
if host == "tailscale":
    host = subprocess.check_output(["tailscale", "ip", "-4"], text=True).strip().splitlines()[0]
mac["server"] = f"http://{host}:{desk.get('server_port', 8765)}"
out = here / "mac.json"
out.write_text(json.dumps(mac, indent=2) + "\n")
out.chmod(0o600)
PY
cd "$HERE/.."
rm -f whisper-ptt-mac.zip
zip -q -r whisper-ptt-mac.zip mac -x 'mac/__pycache__/*' 'mac/mac.example.json' 'mac/package.sh' 'mac/app/*'
echo "built $(pwd)/whisper-ptt-mac.zip; send it to the Mac with:"
echo "  sudo tailscale file cp $(pwd)/whisper-ptt-mac.zip <your-mac-tailscale-name>:"
