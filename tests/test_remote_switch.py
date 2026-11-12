"""Tests for bin/whisper-control.py, the remote switch the Mac uses. Standard library only;
whisper-ui.py (systemd, Ollama) is never run."""
import importlib.util
import json
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "control", Path(__file__).resolve().parent.parent / "bin/whisper-control.py")
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)


class Desktop:
    """Stands in for whisper-ui.py: remembers whether Whisper is on."""

    def __init__(self):
        self.active = False
        self.calls = []
        self.stop_error = None      # stopping works, then complains
        self.start_error = None     # starting does not work at all

    def helper(self, *args, timeout=120):
        self.calls.append(args)
        if args == ("status",):
            return json.dumps({"active": self.active, "polish": self.active})
        if args[0] == "all":
            if args[1] == "on" and self.start_error:
                raise RuntimeError(self.start_error)
            self.active = args[1] == "on"
            if not self.active and self.stop_error:
                raise RuntimeError(self.stop_error)
            return ""
        raise AssertionError(args)


class RemoteSwitchTests(unittest.TestCase):
    def setUp(self):
        self.desktop = Desktop()
        patcher = patch.object(C, "helper", self.desktop.helper)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.start()

    def start(self, tailnet_only=False, token="t0ken"):
        self.srv = C.make_server("127.0.0.1", 0, tailnet_only, token=token)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def ask(self, path, body=None, token="t0ken"):
        req = urllib.request.Request(self.url + path, data=body,
                                     headers={"Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json.loads(e.read())

    def test_state_says_whether_whisper_is_on(self):
        code, body = self.ask("/state")
        self.assertEqual((code, body["active"]), (200, False))
        self.assertTrue(body["host"])

    def test_the_mac_switches_whisper_on_and_off(self):
        code, body = self.ask("/power", b'{"on": true}')
        self.assertEqual((code, body["active"]), (200, True))
        code, body = self.ask("/power", b'{"on": false}')
        self.assertEqual((code, body["active"]), (200, False))
        switches = [c for c in self.desktop.calls if c[0] == "all"]
        self.assertEqual(switches, [("all", "on"), ("all", "off")])

    def test_the_token_is_required_for_everything(self):
        self.assertEqual(self.ask("/state", token="wrong")[0], 401)
        self.assertEqual(self.ask("/power", b'{"on": true}', token="wrong")[0], 401)
        self.assertEqual(self.ask("/power", b'{"on": true}', token="")[0], 401)
        self.assertEqual(self.desktop.calls, [])

    # An empty server_token in config.json must not make "Bearer " a valid login.
    def test_an_empty_configured_token_lets_nobody_in(self):
        self.start(token=None)
        with patch.object(C, "load_config", return_value={"server_token": ""}):
            self.assertEqual(self.ask("/state", token="")[0], 401)
        with patch.object(C, "load_config", return_value={"server_token": "fresh"}):
            self.assertEqual(self.ask("/state", token="fresh")[0], 200)

    def test_only_true_and_false_are_switch_positions(self):
        for body in (b'{"on": "yes"}', b'{"on": 1}', b'{}', b'not json', b'["on"]',
                     b'{"on": true, "pad": "' + b"x" * 2000 + b'"}'):
            self.assertEqual(self.ask("/power", body)[0], 400, body[:20])
        self.assertEqual([c for c in self.desktop.calls if c[0] == "all"], [])

    def test_nothing_else_is_served(self):
        self.assertEqual(self.ask("/health")[0], 404)
        self.assertEqual(self.ask("/state", b'{"on": true}')[0], 404)       # a POST to /state
        self.assertEqual(self.desktop.calls, [])

    # Stopping can succeed while unloading the cleanup model fails (Ollama not running).
    def test_a_stop_that_worked_but_complained_is_still_off(self):
        self.desktop.active = True
        self.desktop.stop_error = "cleanup model could not be unloaded"
        code, body = self.ask("/power", b'{"on": false}')
        self.assertEqual((code, body["active"]), (200, False))
        self.assertIn("could not be unloaded", body["note"])

    def test_a_switch_that_did_not_take_is_an_error(self):
        self.desktop.start_error = "Unit not found"
        code, body = self.ask("/power", b'{"on": true}')
        self.assertEqual(code, 500)
        self.assertIn("Unit not found", body["error"])
        self.assertFalse(body["active"])

    # Bound to the Tailscale address, Linux still answers a LAN machine that routes that
    # address its way; only peers with a tailnet address of their own may ask.
    def test_peers_outside_the_tailnet_are_refused(self):
        self.start(tailnet_only=True)
        self.assertEqual(self.ask("/state")[0], 403)
        self.assertEqual(self.desktop.calls, [])

    def test_tailnet_addresses(self):
        for inside in ("100.64.0.1", "100.101.102.103", "100.127.255.254",
                       "fd7a:115c:a1e0::1", "::ffff:100.100.1.1"):
            self.assertTrue(C.from_tailnet(inside), inside)
        for outside in ("192.168.1.20", "127.0.0.1", "100.128.0.1", "100.63.255.255",
                        "8.8.8.8", "::1", "fd00::1", "nonsense"):
            self.assertFalse(C.from_tailnet(outside), outside)

    def test_the_port_is_one_above_the_transcription_server(self):
        self.assertEqual(C.control_port({}), 8766)
        self.assertEqual(C.control_port({"server_port": 9000}), 9001)
        self.assertEqual(C.control_port({"server_port": 9000, "control_port": 9100}), 9100)


if __name__ == "__main__":
    unittest.main()
