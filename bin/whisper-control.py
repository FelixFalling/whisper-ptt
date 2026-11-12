#!/usr/bin/env python3
"""The remote switch: lets the Mac turn Whisper on this desktop on and off.

The transcription server lives inside whisper-ptt.service, so once Whisper is off there is
nothing left for the Mac to ask. This small server stays up instead, as its own unit
(whisper-ptt-control.service), on the same Tailscale address, one port above the
transcription server, with the same token:

    GET  /state                {"ok": true, "host": ..., "active": bool, "polish": bool}
    POST /power  {"on": bool}  flips the switch, then answers like /state

/power does what the Whisper button in GNOME's menu does (whisper-ui.py all on|off): it
starts or stops the service and the cleanup model with it. Nothing else can be asked for;
no part of a request reaches a command line.

It needs only the standard library and the system python3, and holds no model.
"""
import hmac
import ipaddress
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONFIG = Path.home() / ".config" / "whisper-ptt" / "config.json"
HELPER = Path(__file__).resolve().parent / "whisper-ui.py"
# Every Tailscale device has an address in one of these. Tailscale's own firewall rules drop
# packets that claim such an address but arrive on another interface, so a peer inside them
# came through the tailnet.
TAILNET = (ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("fd7a:115c:a1e0::/48"))
MAX_BODY = 1024
SWITCH_LOCK = threading.Lock()          # one start or stop at a time


def log(msg):
    print(f"[whisper-control] {msg}", flush=True)


def load_config():
    try:
        cfg = json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


def control_port(cfg):
    return int(cfg.get("control_port") or int(cfg.get("server_port", 8765)) + 1)


def tailscale_ip():
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True,
                             timeout=5).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out[0] if out else None


def from_tailnet(address):
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    ip = getattr(ip, "ipv4_mapped", None) or ip
    return any(ip in net for net in TAILNET)


def helper(*args, timeout=120):
    """Runs whisper-ui.py, the same helper the GNOME buttons use. Returns its output.

    Its output goes to files, not pipes: switching on leaves a curl behind that warms the
    cleanup model, and a pipe would keep this waiting until that curl ends too.
    """
    with tempfile.TemporaryFile("w+") as out, tempfile.TemporaryFile("w+") as err:
        done = subprocess.run([sys.executable, str(HELPER), *args], stdin=subprocess.DEVNULL,
                              stdout=out, stderr=err, timeout=timeout)
        out.seek(0)
        err.seek(0)
        if done.returncode != 0:
            raise RuntimeError(err.read().strip()[:300] or f"whisper-ui.py {' '.join(args)} failed")
        return out.read()


def state():
    found = json.loads(helper("status", timeout=20))
    return {"ok": True, "host": os.uname().nodename,
            "active": bool(found["active"]), "polish": bool(found["polish"])}


def make_server(host, port, tailnet_only, token=None):
    """token=None reads server_token from the settings on every request, so a changed
    token needs no restart here."""

    class Handler(BaseHTTPRequestHandler):
        timeout = 15                    # a silent connection is dropped, not kept for good

        def log_message(self, fmt, *args):
            pass

        def _reply(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _refused(self):
            """Answers and returns True unless the request may go ahead."""
            if tailnet_only and not from_tailnet(self.client_address[0]):
                self._reply(403, {"error": "not from the tailnet"})
                return True
            wanted = token if token is not None else str(load_config().get("server_token") or "")
            given = self.headers.get("Authorization", "")
            if not wanted or not hmac.compare_digest(given.encode(), f"Bearer {wanted}".encode()):
                self._reply(401, {"error": "unauthorized"})
                return True
            return False

        def do_GET(self):
            if self._refused():
                return
            if self.path != "/state":
                return self._reply(404, {"error": "not found"})
            try:
                self._reply(200, state())
            except Exception as exc:
                log(f"could not read the state: {exc}")
                self._reply(500, {"error": "could not read the state"})

        def do_POST(self):
            if self._refused():
                return
            if self.path != "/power":
                return self._reply(404, {"error": "not found"})
            try:
                size = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                size = -1
            if not 0 < size <= MAX_BODY:
                return self._reply(400, {"error": 'body must be {"on": true} or {"on": false}'})
            try:
                on = json.loads(self.rfile.read(size))["on"]
            except Exception:
                on = None
            if on is not True and on is not False:
                return self._reply(400, {"error": 'body must be {"on": true} or {"on": false}'})
            with SWITCH_LOCK:
                try:
                    helper("all", "on" if on else "off")
                    log(f"Whisper switched {'on' if on else 'off'} from {self.client_address[0]}")
                    note = {}
                except Exception as exc:
                    # Stopping can succeed while unloading the cleanup model fails; the
                    # state below is what counts, and the Mac shows the note.
                    log(f"switching {'on' if on else 'off'} reported: {exc}")
                    note = {"note": str(exc)[:300]}
                try:
                    now = state()
                except Exception as exc:
                    log(f"could not read the state: {exc}")
                    return self._reply(500, {"error": "could not read the state"})
            if now["active"] != on:
                return self._reply(500, {"error": note.get("note") or "the switch did not take",
                                         **{k: now[k] for k in ("host", "active", "polish")}})
            self._reply(200, {**now, **note})

    return ThreadingHTTPServer((host, port), Handler)


def main():
    cfg = load_config()
    if not cfg.get("server") or not cfg.get("server_control", True):
        log("server or server_control is off in config.json; the remote switch stays off")
        return 0
    token = str(cfg.get("server_token") or "")
    if not token:
        log("server_token is empty; the remote switch stays off")
        return 0
    if len(token) < 20:
        log("warning: server_token is short; use a long random one "
            "(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')")
    host = cfg.get("server_host", "tailscale")
    tailnet_only = host == "tailscale"
    while host == "tailscale":           # tailscaled may come up after us at boot
        host = tailscale_ip() or "tailscale"
        if host == "tailscale":
            time.sleep(30)
    port = control_port(cfg)
    try:
        srv = make_server(host, port, tailnet_only)
    except OSError as exc:
        log(f"cannot listen on {host}:{port}: {exc}")
        return 1                         # systemd tries again (the address may not be up yet)
    log(f"remote switch on http://{host}:{port}")
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main() or 0)
