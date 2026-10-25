#!/usr/bin/env bash
set -euo pipefail
DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CANONICAL_ROOT="$(python3 -c 'from pathlib import Path; print((Path.home()/".local/share/whisper-ptt").resolve())')"
if [[ "$DEPLOY_ROOT" != "$CANONICAL_ROOT" ]]; then
    echo 'Deploy from ~/.local/share/whisper-ptt (or its symlink), not an experimental checkout.' >&2
    exit 1
fi
if [[ ! -x "$DEPLOY_ROOT/venv/bin/python" ]]; then
    echo 'Missing venv/bin/python. Follow the README installation instructions first.' >&2
    exit 1
fi
python3 - <<'PY'
import json
from pathlib import Path
path=Path.home()/'.config/whisper-ptt/config.json'
json.loads(path.read_text())
print('Local configuration parses successfully.')
PY
cd "$DEPLOY_ROOT"
bash install-links.sh
systemctl --user restart whisper-ptt.service
if ! systemctl --user is-active --quiet whisper-ptt.service; then
    systemctl --user status whisper-ptt.service --no-pager || true
    exit 1
fi
echo "Deployed commit $(git rev-parse --short HEAD) to the local service."
if [[ -n "$(git status --porcelain)" ]]; then
    echo 'Working tree has uncommitted changes; the service is running those files too.'
fi
echo 'The process is active; model loading may still be in progress. Run make logs to check startup.'
echo 'For GNOME extension changes: save your work, then log out and back in.'
