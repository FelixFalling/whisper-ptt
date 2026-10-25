#!/usr/bin/env python3
"""Tests for whisper-ptt. Nothing here touches a real keyboard, microphone or GPU. One test
types through a virtual keyboard of its own, grabbed first so no key reaches the desktop; it
is skipped when /dev/uinput is not writable.

    ~/.local/share/whisper-ptt/venv/bin/python -m unittest discover -s ~/.local/share/whisper-ptt/tests -v
"""
import importlib.util
import io
import json
import os
import queue
import string
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

import numpy as np

SCRIPT = Path(__file__).resolve().parent.parent / "whisper-ptt.py"
spec = importlib.util.spec_from_file_location("whisper_ptt", SCRIPT)
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)

# Tests never reach the real polish model (or the GPU): polish is off unless a test turns it
# on, and the on/off state file points somewhere that does not exist.
W.POLISH_STATE = Path(tempfile.mkdtemp()) / "polish"
CFG = {**W.DEFAULTS, "min_duration": 0.05, "notify": False, "server_token": "t0ken",
       "server_port": 0, "polish": False, "ollama_url": "http://127.0.0.1:9",
       "transcribe_while_talking": False}
SR = W.SAMPLE_RATE
DECODE = {v: k for k, v in W.KEYMAP.items()}


class FakeRecorder:
    def __init__(self, fail=False):
        self.fail, self.running, self.blocks = fail, False, []

    def start(self):
        if self.fail:
            raise OSError("no microphone")
        self.running = True

    def stop(self):
        self.running = False
        return np.ones(3200, dtype=np.float32)


def seg(text, start=0.0, end=1.0):
    return SimpleNamespace(text=text, start=start, end=end)


class FakeHolder:
    """script(audio) -> segments decides what is heard; by default always self.text."""

    def __init__(self, text="hello", error=None, script=None):
        self.text, self.error, self.script, self.loaded = text, error, script, True
        self.heard = []                     # lengths of the audio it was asked about

    def preload_async(self):
        pass

    def get(self):
        if self.error:
            raise self.error

        def transcribe(audio, **kw):
            self.heard.append(len(audio))
            return (self.script(audio) if self.script else [seg(self.text)]), None
        return SimpleNamespace(transcribe=transcribe)


class FakeKeyboard:
    """Decodes taps back into characters, as a US layout would."""

    def __init__(self, fail_after=None):
        self.chars, self.fail_after, self.closed = [], fail_after, False

    def open(self):
        return self

    def tap(self, key, shift, hold, gap):
        if self.fail_after is not None and len(self.chars) >= self.fail_after:
            raise OSError("uinput went away")
        self.chars.append(DECODE[(key, shift)])

    def close(self):
        self.closed = True

    @property
    def text(self):
        return "".join(self.chars)


class Gate:
    """Stands in for Devices.wait_free."""

    def __init__(self, free=True):
        self.free = threading.Event()
        if free:
            self.free.set()

    def wait_free(self):
        self.free.wait()


def drain(q):
    out = []
    while True:
        try:
            out.append(q.get_nowait())
        except queue.Empty:
            return out


def job(audio=None, session=None):
    return W.Job(np.ones(16000, dtype=np.float32) if audio is None else audio, 1.0, session,
                 time.monotonic())


# BUG: typing ran while Right Ctrl could be held again, so "w" became Ctrl+W.
class TyperTests(unittest.TestCase):
    def test_waits_while_a_modifier_is_held(self):
        gate, kb = Gate(free=False), FakeKeyboard()
        typer = W.Typer({"type_delay_ms": 0}, gate, keyboard=kb)
        text = "this is a sentence long enough to take a while"
        th = threading.Thread(target=typer.type, args=(text,))
        th.start()
        time.sleep(0.2)
        self.assertEqual(kb.text, "", "typed while a modifier was held")
        gate.free.set()
        th.join(2)
        self.assertEqual(kb.text, text)

    def test_every_key_on_the_keyboard_types_itself(self):
        kb = FakeKeyboard()
        text = string.ascii_letters + string.digits + string.punctuation + " \n\t"
        self.assertTrue(W.Typer({"type_delay_ms": 0}, Gate(), keyboard=kb).type(text))
        self.assertEqual(kb.text, text)

    # BUG: ydotool read non-ASCII outside its key table: "don’t" came out "dont", "café" "caf".
    def test_characters_without_a_key_become_their_nearest_lookalike(self):
        kb = FakeKeyboard()
        W.Typer({"type_delay_ms": 0}, Gate(), keyboard=kb).type(
            "don’t, café… “hi” 5€ naïve ½ 9–2")
        self.assertEqual(kb.text, "don't, cafe... \"hi\" 5EUR naive 1/2 9-2")

    def test_what_still_has_no_key_is_left_out(self):
        self.assertEqual(W.typeable("ok ☃ done"), "ok  done")

    def test_a_dead_keyboard_is_reported_and_replaced(self):
        kb = FakeKeyboard(fail_after=3)
        self.assertFalse(W.Typer({"type_delay_ms": 0}, Gate(), keyboard=kb).type("x" * 40))
        self.assertEqual(kb.text, "xxx")
        self.assertTrue(kb.closed, "the broken virtual keyboard was kept")


@unittest.skipUnless(os.access("/dev/uinput", os.W_OK), "needs a writable /dev/uinput")
class RealKeyboardTests(unittest.TestCase):
    """The real virtual keyboard, end to end through the kernel."""

    def test_the_kernel_sees_exactly_the_text(self):
        from evdev import ecodes
        kb = W.Keyboard()
        kb.NAME = "whisper-ptt test keyboard"
        kb.open()
        dev = kb.ui.device
        dev.grab()                       # from here on nothing reaches the desktop
        events, done = [], threading.Event()

        def read():
            while not done.is_set():
                try:
                    for e in dev.read():
                        events.append(e)
                except BlockingIOError:
                    time.sleep(0.001)
        reader = threading.Thread(target=read)
        reader.start()
        try:
            text = string.ascii_letters + string.digits + string.punctuation + " "
            self.assertTrue(W.Typer({"type_delay_ms": 0.5}, Gate(), keyboard=kb).type(text))
            time.sleep(0.2)
        finally:
            done.set()
            reader.join()
            dev.ungrab()
            kb.close()
        self.assertFalse([e for e in events if e.type == ecodes.EV_SYN and e.code == 3],
                         "the kernel dropped events (SYN_DROPPED)")
        shift, seen = False, []
        for e in events:
            if e.type != ecodes.EV_KEY:
                continue
            if e.code == ecodes.KEY_LEFTSHIFT:
                shift = e.value == 1
            elif e.value == 1:
                seen.append(DECODE[(e.code, shift)])
        self.assertEqual("".join(seen), text)


class DictationTests(unittest.TestCase):
    def make(self, recorder=None, cfg=CFG):
        jobs = queue.Queue()
        d = W.Dictation(cfg, FakeHolder(), recorder or FakeRecorder(), jobs)
        return d, jobs

    def test_a_held_press_becomes_a_job(self):
        d, jobs = self.make()
        d.handle("trigger", 1)
        time.sleep(0.1)
        d.handle("trigger", 0)
        self.assertEqual(len(drain(jobs)), 1)

    # BUG: Right Ctrl+C held a moment recorded him and typed whatever it heard.
    def test_another_key_while_held_cancels(self):
        d, jobs = self.make()
        d.handle("trigger", 1)
        d.handle("other", 46)
        self.assertFalse(d.recorder.running, "cancel must release the microphone immediately")
        self.assertFalse(d.recording)
        time.sleep(0.1)
        d.handle("trigger", 0)
        self.assertEqual(drain(jobs), [])

    def test_a_tap_is_ignored(self):
        d, jobs = self.make()
        d.handle("trigger", 1)
        d.handle("trigger", 0)
        self.assertEqual(drain(jobs), [])

    def test_a_dead_microphone_does_not_crash(self):
        d, jobs = self.make(FakeRecorder(fail=True))
        d.handle("trigger", 1)
        self.assertFalse(d.recording)
        d.handle("trigger", 0)
        self.assertEqual(drain(jobs), [])

    # BUG: a keyboard unplugged mid-press never sent its release, so typing waited forever.
    def test_a_lost_keyboard_ends_the_press(self):
        d, jobs = self.make()
        d.handle("trigger", 1)
        time.sleep(0.1)
        d.handle("lost", None)
        self.assertFalse(d.recording)
        self.assertEqual(drain(jobs), [])

    # BUG: the key loop transcribed and typed, so a second press was not read until then.
    def test_the_key_loop_never_transcribes(self):
        d, jobs = self.make()
        d.holder = FakeHolder(error=AssertionError("the key loop must not transcribe"))
        d.handle("trigger", 1)
        time.sleep(0.1)
        d.handle("trigger", 0)
        self.assertEqual(len(drain(jobs)), 1)

    def test_a_cancelled_dictation_stops_its_live_session(self):
        d, jobs = self.make(cfg={**CFG, "transcribe_while_talking": True})
        d.handle("trigger", 1)
        session = d.session
        self.assertIsNotNone(session)
        d.handle("other", 46)
        time.sleep(0.1)
        d.handle("trigger", 0)
        self.assertEqual(drain(jobs), [])
        session.thread.join(1)
        self.assertFalse(session.thread.is_alive())


# BUG: a transcription error (a full GPU) killed the whole service.
class WorkerTests(unittest.TestCase):
    def setUp(self):
        W._gpu_failures = 0

    def test_a_failure_is_reported_and_the_next_dictation_still_works(self):
        cfg = {**CFG, "notify": True}
        drain(W._notes)
        kb = FakeKeyboard()
        typer = W.Typer(cfg, Gate(), keyboard=kb)
        jobs = queue.Queue()
        holder = FakeHolder(error=RuntimeError("CUDA failed with error out of memory"))
        threading.Thread(target=W.worker, args=(cfg, holder, jobs, typer), daemon=True).start()
        jobs.put(job())
        time.sleep(0.3)
        notes = drain(W._notes)
        self.assertTrue(any(n[1] == "Dictation failed" and "graphics card is full" in n[2]
                            for n in notes), notes)
        holder.error = None
        jobs.put(job())
        time.sleep(0.3)
        self.assertEqual(kb.text, "hello ")

    def test_silence_types_nothing(self):
        kb = FakeKeyboard()
        W.dictate(CFG, FakeHolder(""), W.Typer(CFG, Gate(), keyboard=kb), job())
        self.assertEqual(kb.text, "")

    # BUG: an unexpected error ended a thread quietly: the service looked fine but was deaf.
    def test_a_loop_that_crashes_is_started_again(self):
        calls, again = [], threading.Event()

        def loop():
            calls.append(1)
            if len(calls) == 1:
                raise RuntimeError("boom")
            again.set()
            threading.Event().wait()
        W.keep_running(loop)
        self.assertTrue(again.wait(3), "the loop was not restarted")


class HolderTests(unittest.TestCase):
    def setUp(self):
        W._gpu_failures = 0
        self.restarts, self.orig_restart = [], W.restart
        W.restart = lambda: self.restarts.append(1)

    def tearDown(self):
        W.restart = self.orig_restart

    def holder(self):
        h = W.ModelHolder({**CFG, "device": "cuda"}, None)
        calls = []
        h._model = SimpleNamespace(model=SimpleNamespace(
            unload_model=lambda to_cpu: calls.append(("park", to_cpu)),
            load_model=lambda: calls.append(("unpark",))))
        return h, calls

    # BUG: the idle timer could park the model right after a dictation it waited on.
    def test_a_recent_use_blocks_the_idle_park(self):
        h, calls = self.holder()
        h.last_used = time.time()
        self.assertIsNone(h.unload(idle_for=300))
        self.assertEqual(calls, [])

    def test_park_and_wake(self):
        h, calls = self.holder()
        h.last_used = time.time() - 400
        self.assertEqual(h.unload(idle_for=300), "parked")
        self.assertFalse(h.loaded)
        h.get()
        self.assertEqual(calls, [("park", True), ("unpark",)])
        self.assertTrue(h.loaded)

    # A CUDA error that is not a full card used to fail every dictation after it.
    def test_a_gpu_error_gets_a_fresh_model_then_a_restart(self):
        h, _ = self.holder()
        broken = RuntimeError("CUDA failed with error unspecified launch failure")
        W.after_failure(h, broken)
        self.assertIsNone(h._model, "the broken model was kept")
        self.assertEqual(self.restarts, [])
        W.after_failure(h, broken)
        self.assertEqual(self.restarts, [1])

    def test_a_full_card_or_a_success_resets_nothing(self):
        h, _ = self.holder()
        W.after_failure(h, RuntimeError("CUDA failed with error out of memory"))
        self.assertIsNotNone(h._model)
        W.after_failure(h, RuntimeError("CUDA failed with error unspecified launch failure"))
        W.after_success()
        W.after_failure(h, RuntimeError("CUDA failed with error unspecified launch failure"))
        self.assertEqual(self.restarts, [], "failures apart were counted as in a row")


class DeviceTests(unittest.TestCase):
    def setUp(self):
        self.pipes = []
        self.orig = (W.evdev.list_devices, W.evdev.InputDevice, W.keys_only)
        W.keys_only = lambda dev: True

    def tearDown(self):
        W.evdev.list_devices, W.evdev.InputDevice, W.keys_only = self.orig
        for fd in self.pipes:
            os.close(fd)

    def fake_dev_class(self, opened, names, trigger_paths):
        test = self

        class FakeDev:
            def __init__(self, path):
                opened.append(path)
                self.path, self.name = path, names[path]
                r, w = os.pipe()
                test.pipes += [w]
                self.fd = r

            def capabilities(self):
                if self.path in trigger_paths:
                    return {W.ecodes.EV_KEY: [W.ecodes.KEY_RIGHTCTRL]}
                return {}

            def active_keys(self):
                return []

            def close(self):
                os.close(self.fd)
        return FakeDev

    # BUG: devices were scanned once, so a keyboard replugged after start went deaf.
    def test_rescan_adopts_new_devices_and_skips_non_keyboards_once(self):
        opened, present = [], ["/m"]
        W.evdev.list_devices = lambda: list(present)
        W.evdev.InputDevice = self.fake_dev_class(opened, {"/k": "Keyboard", "/m": "Lid Switch"},
                                                  {"/k"})
        devs = W.Devices(W.ecodes.KEY_RIGHTCTRL, queue.Queue())
        self.assertEqual(devs.scan(), 0)
        devs.scan()
        self.assertEqual(opened, ["/m"], "a non-keyboard was reopened on every scan")
        present.append("/k")                 # a keyboard is plugged in
        self.assertEqual(devs.scan(), 1)
        self.assertIn("/k", devs.watched)

    def test_our_own_virtual_keyboard_is_never_watched(self):
        opened = []
        W.evdev.list_devices = lambda: ["/v"]
        W.evdev.InputDevice = self.fake_dev_class(opened, {"/v": W.Keyboard.NAME}, {"/v"})
        devs = W.Devices(W.ecodes.KEY_RIGHTCTRL, queue.Queue())
        self.assertEqual(devs.scan(), 0)
        self.assertNotIn("/v", devs.watched)

    def test_only_key_events_reach_the_dictation(self):
        events = queue.Queue()
        devs = W.Devices(W.ecodes.KEY_RIGHTCTRL, events)
        ev = lambda t, c, v: SimpleNamespace(type=t, code=c, value=v)
        for e in (ev(W.ecodes.EV_REL, W.ecodes.REL_X, 5),
                  ev(W.ecodes.EV_KEY, W.ecodes.KEY_RIGHTCTRL, 2),
                  ev(W.ecodes.EV_KEY, W.ecodes.KEY_RIGHTCTRL, 1),
                  ev(W.ecodes.EV_KEY, W.ecodes.KEY_C, 1), ev(W.ecodes.EV_KEY, W.ecodes.KEY_C, 0)):
            devs._dispatch("/k", e, has_trigger=True)
        self.assertEqual(drain(events), [("trigger", 1), ("other", W.ecodes.KEY_C)])

    # BUG: Ctrl+wheel (zoom) was invisible, so it recorded and typed whatever it heard.
    def test_the_wheel_cancels_only_while_the_trigger_is_held(self):
        events = queue.Queue()
        devs = W.Devices(W.ecodes.KEY_RIGHTCTRL, events)
        ev = lambda t, c, v: SimpleNamespace(type=t, code=c, value=v)
        wheel = ev(W.ecodes.EV_REL, W.ecodes.REL_WHEEL, -1)
        devs._dispatch("/mouse", wheel, has_trigger=False)
        self.assertEqual(drain(events), [], "a plain scroll woke the dictation")
        devs._dispatch("/k", ev(W.ecodes.EV_KEY, W.ecodes.KEY_RIGHTCTRL, 1), has_trigger=True)
        drain(events)
        devs._dispatch("/mouse", wheel, has_trigger=False)
        self.assertEqual(drain(events), [("other", W.ecodes.REL_WHEEL)])

    # The foot pedal is a held Left Ctrl (keyd): typing under it would be shortcuts.
    def test_typing_waits_for_every_modifier_on_every_device(self):
        devs = W.Devices(W.ecodes.KEY_RIGHTCTRL, queue.Queue())
        ev = lambda c, v: SimpleNamespace(type=W.ecodes.EV_KEY, code=c, value=v)
        devs._dispatch("/pedal", ev(W.ecodes.KEY_LEFTCTRL, 1), has_trigger=False)
        devs._dispatch("/k", ev(W.ecodes.KEY_LEFTSHIFT, 1), has_trigger=False)
        self.assertFalse(devs.free.is_set())
        devs._dispatch("/pedal", ev(W.ecodes.KEY_LEFTCTRL, 0), has_trigger=False)
        self.assertFalse(devs.free.is_set(), "Shift is still down")
        devs._dispatch("/k", ev(W.ecodes.KEY_A, 1), has_trigger=False)
        devs._dispatch("/k", ev(W.ecodes.KEY_LEFTSHIFT, 0), has_trigger=False)
        self.assertTrue(devs.free.is_set())

    def test_an_unplugged_keyboard_leaves_no_modifier_behind(self):
        devs = W.Devices(W.ecodes.KEY_RIGHTCTRL, queue.Queue())
        r, w = os.pipe()
        self.pipes.append(w)
        devs.watched["/k"] = (SimpleNamespace(fd=r, name="kb", close=lambda: os.close(r)), True)
        devs._dispatch("/k", SimpleNamespace(type=W.ecodes.EV_KEY, code=W.ecodes.KEY_RIGHTCTRL,
                                             value=1), has_trigger=True)
        self.assertFalse(devs.free.is_set())
        devs._drop("/k")
        self.assertTrue(devs.free.is_set())

    def test_a_missed_release_is_caught_by_asking_the_kernel(self):
        devs = W.Devices(W.ecodes.KEY_RIGHTCTRL, queue.Queue())
        devs.watched["/k"] = (SimpleNamespace(active_keys=lambda: []), True)
        devs._track("/k", W.ecodes.KEY_LEFTCTRL, True)      # its release never arrives
        th = threading.Thread(target=devs.wait_free)
        th.start()
        th.join(2.5)
        self.assertFalse(th.is_alive(), "typing would have waited forever")


def wav(seconds=1.0):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(np.zeros(int(16000 * seconds), dtype="<i2").tobytes())
    return buf.getvalue()


class ServerTests(unittest.TestCase):
    def setUp(self):
        W._gpu_failures = 0
        self.holder = FakeHolder("from the mac")
        self.srv = W.make_server(self.holder, CFG, "127.0.0.1")
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def post(self, path, data=b"", token="t0ken", headers=None):
        req = urllib.request.Request(self.url + path, data=data, method="POST",
                                     headers={"Authorization": f"Bearer {token}",
                                              **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_the_token_is_required(self):
        self.assertEqual(self.post("/transcribe", wav(), token="wrong")[0], 401)

    def test_a_wav_is_transcribed(self):
        self.assertEqual(self.post("/transcribe", wav()), (200, {"text": "from the mac"}))

    # BUG: a malformed Content-Length crashed the request handler with a traceback.
    def test_a_bad_length_is_a_clean_400(self):
        req = urllib.request.Request(self.url + "/transcribe", data=b"x", method="POST",
                                     headers={"Authorization": "Bearer t0ken"})
        req.add_unredirected_header("Content-Length", "abc")
        try:
            urllib.request.urlopen(req, timeout=5)
            code = 200
        except urllib.error.HTTPError as e:
            code = e.code
        self.assertEqual(code, 400)

    def test_a_full_gpu_is_a_503_the_mac_falls_back_on(self):
        self.holder.error = RuntimeError("CUDA failed with error out of memory")
        code, body = self.post("/transcribe", wav())
        self.assertEqual(code, 503)
        self.assertIn("graphics card is full", body["error"])


class PolishTests(unittest.TestCase):
    def setUp(self):
        self.reply, self.last = {"message": {"content": ""}}, None
        test = self

        class FakeOllama(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                test.last = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                reply = test.reply                  # None: hand back the text unchanged
                if reply is None:
                    reply = {"message": {"content": test.last["messages"][-1]["content"]}}
                body = json.dumps(reply).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.cfg = {**CFG, "polish": True,
                    "ollama_url": f"http://127.0.0.1:{self.srv.server_address[1]}"}
        self.state = Path(tempfile.mkdtemp()) / "polish"
        self.orig_state, W.POLISH_STATE = W.POLISH_STATE, self.state

    def tearDown(self):
        W.POLISH_STATE = self.orig_state
        self.srv.shutdown()
        self.srv.server_close()

    # "proper grammar all the time" (2026-10-01): on unless switched off.
    def test_on_by_default_and_switchable_without_a_restart(self):
        self.assertTrue(W.polish_on(self.cfg))
        self.state.write_text("off\n")
        self.assertFalse(W.polish_on(self.cfg))
        self.state.write_text("on\n")
        self.assertTrue(W.polish_on(self.cfg))

    def test_quotes_and_dashes_are_cleaned_up(self):
        self.reply = {"message": {"content": '"I tested it — and it worked."'}}
        self.assertEqual(W.polish(self.cfg, "so um I tested it and like it worked"),
                         "I tested it, and it worked.")
        self.assertIs(self.last["think"], False)
        self.assertEqual(self.last["messages"][1]["content"],
                         "so um I tested it and like it worked")

    # A model that answers the dictation instead of editing it must not be typed.
    def test_an_answer_instead_of_an_edit_types_the_words_as_spoken(self):
        self.reply = {"message": {"content": "Sure! " + "Here is a long answer. " * 20}}
        text, note = W.maybe_polish(self.cfg, "what time is it over there right now")
        self.assertEqual(text, "what time is it over there right now")
        self.assertIn("failed", note)

    # The reply is capped near the text's length, so a runaway stops early, not at the timeout.
    def test_a_reply_that_runs_on_is_cut_off_and_typed_as_spoken(self):
        said = "so I think we should ship the fix today guys"
        self.reply = {"message": {"content": "Sure, here is"}, "done_reason": "length"}
        self.assertEqual(W.maybe_polish(self.cfg, said), (said, " (polish failed)"))
        self.assertEqual(self.last["options"]["num_predict"], len(said) // 2 + 64)

    def test_a_same_length_rewrite_is_rejected(self):
        self.reply = {"message": {"content": "Completely different words of equal size here."}}
        text, note = W.maybe_polish(self.cfg, "so I think we should ship the fix today guys")
        self.assertEqual(text, "so I think we should ship the fix today guys")
        self.assertIn("failed", note)

    def test_short_dictations_are_not_sent_to_the_model(self):
        self.reply = {"message": {"content": "SHOULD NOT BE USED"}}
        self.assertEqual(W.maybe_polish(self.cfg, "yeah do it"), ("yeah do it", ""))
        self.assertIsNone(self.last)

    def test_a_small_edit_of_a_short_text_is_not_a_length_failure(self):
        self.reply = {"message": {"content": "Yes, send it over to them now."}}
        self.assertEqual(W.polish(self.cfg, "yes send it over to them now"),
                         "Yes, send it over to them now.")

    def test_off_leaves_the_words_alone(self):
        self.state.write_text("off")
        self.assertEqual(W.maybe_polish(self.cfg, "um hello"), ("um hello", ""))

    def test_no_model_server_types_the_words_as_spoken(self):
        cfg = {**self.cfg, "ollama_url": "http://127.0.0.1:9"}
        said = "um hello there how are you doing today"
        self.assertEqual(W.maybe_polish(cfg, said)[0], said)

    def test_earlier_sentences_go_in_as_earlier_turns_of_the_chat(self):
        self.reply = None
        said = "on saturday we drive up to the lake"
        W.polish(self.cfg, said, history=[("here is the plan for the weekend",
                                           "Here is the plan for the weekend.")])
        self.assertEqual([(m["role"], m["content"]) for m in self.last["messages"][1:]],
                         [("user", "here is the plan for the weekend"),
                          ("assistant", "Here is the plan for the weekend."), ("user", said)])

    # BUG: polished alone, "On Saturday we drive up to the lake" came back "we drove".
    def test_a_live_dictation_polishes_each_sentence_after_the_ones_before_it(self):
        self.reply = None
        orig, W.speech_chunks = W.speech_chunks, lambda a: [(0, 3 * SR), (int(3.6 * SR), 7 * SR)]
        try:
            holder = FakeHolder(script=lambda a: [seg(" Here is the plan for the weekend.", 0, 3.05),
                                                  seg(" On Saturday we", 3.6, 7.0)])
            s = W.LiveSession(self.cfg, holder, [], True, run=False)
            self.assertTrue(s.step(np.zeros(7 * SR, np.float32)))
            holder.script = lambda a: [seg(" On Saturday we drive up to the lake.", 0, 4.0)]
            self.assertEqual(list(s.texts(np.zeros(8 * SR, np.float32))),
                             ["Here is the plan for the weekend.",
                              "On Saturday we drive up to the lake."])
        finally:
            W.speech_chunks = orig
        self.assertEqual([m["role"] for m in self.last["messages"]],
                         ["system", "user", "assistant", "user"])
        self.assertEqual(self.last["messages"][1]["content"], "Here is the plan for the weekend.")

    def test_the_worker_types_the_polished_text(self):
        self.reply = {"message": {"content": "Hello there, how are you doing today?"}}
        kb = FakeKeyboard()
        typer = W.Typer(self.cfg, Gate(), keyboard=kb)
        jobs = queue.Queue()
        threading.Thread(target=W.worker, args=(self.cfg,
                                                FakeHolder("um hello there how are you doing today"), jobs,
                                                typer), daemon=True).start()
        jobs.put(job())
        time.sleep(0.4)
        self.assertEqual(kb.text, "Hello there, how are you doing today? ")


class LiveSessionTests(unittest.TestCase):
    """Long dictations sealed sentence by sentence while he is still talking."""

    def setUp(self):
        self.orig_chunks = W.speech_chunks
        self.speech = []
        W.speech_chunks = lambda audio: [(int(a * SR), int(b * SR)) for a, b in self.speech]

    def tearDown(self):
        W.speech_chunks = self.orig_chunks

    def session(self, holder, polishing=False):
        return W.LiveSession(CFG, holder, [], polishing, run=False)

    def test_a_sentence_that_ends_at_a_pause_is_sealed(self):
        self.speech = [(0, 3.0), (3.6, 7.0)]
        s = self.session(FakeHolder(script=lambda a: [seg(" I went home.", 0, 3.05),
                                                      seg(" Then I", 3.6, 7.0)]))
        self.assertTrue(s.step(np.zeros(7 * SR, np.float32)))
        self.assertEqual(s.sealed_at, int(3.2 * SR), "cut 0.2 s into the pause")
        self.assertEqual(s.pieces[0].result(1), "I went home.")

    def test_the_latest_sentence_break_wins(self):
        self.speech = [(0, 2.0), (2.6, 5.0), (5.7, 8.0)]
        s = self.session(FakeHolder(script=lambda a: [seg(" One.", 0, 2.0), seg(" Two?", 2.6, 5.0),
                                                      seg(" Three and", 5.7, 8.0)]))
        self.assertTrue(s.step(np.zeros(8 * SR, np.float32)))
        self.assertEqual(s.sealed_at, int(5.2 * SR))
        self.assertEqual(s.pieces[0].result(1), "One. Two?")

    def test_a_pause_in_the_middle_of_a_sentence_is_not_sealed(self):
        self.speech = [(0, 3.0), (3.6, 7.0)]
        s = self.session(FakeHolder(script=lambda a: [seg(" I went to the", 0, 3.0),
                                                      seg(" store and then", 3.6, 7.0)]))
        self.assertFalse(s.step(np.zeros(7 * SR, np.float32)))
        self.assertEqual((s.sealed_at, s.pieces), (0, []))

    # BUG: "..." (Whisper's mark for a pause in thought) was taken for a full stop, so the
    # rest came out "about... ...is whether".
    def test_an_ellipsis_is_a_pause_in_thought_not_a_sentence_end(self):
        self.speech = [(0, 3.0), (4.0, 7.0)]
        s = self.session(FakeHolder(script=lambda a: [seg(" So what I wanted to ask about...", 0, 3.0),
                                                      seg(" is whether the report", 4.0, 7.0)]))
        self.assertFalse(s.step(np.zeros(7 * SR, np.float32)))

    def test_doubled_ellipses_are_merged(self):
        holder = FakeHolder(script=lambda a: [seg(" the report..."), seg(" ...can wait.")])
        self.assertEqual(W.transcribe_audio(holder, CFG, np.zeros(SR, np.float32)),
                         "the report... can wait.")

    def test_a_full_stop_without_a_real_pause_is_not_sealed(self):
        self.speech = [(0, 7.0)]                        # he never stopped
        holder = FakeHolder(script=lambda a: [seg(" One.", 0, 3.0), seg(" Two", 3.0, 7.0)])
        s = self.session(holder)
        self.assertFalse(s.step(np.zeros(7 * SR, np.float32)))
        self.assertEqual(holder.heard, [], "transcribed with no pause to seal at")

    def test_each_pause_is_tried_once_and_only_with_words_after_it(self):
        holder = FakeHolder(script=lambda a: [seg(" I went to the", 0, 3.0), seg(" store", 3.6, 5.0)])
        s = self.session(holder)
        self.speech = [(0, 3.0), (3.6, 4.2)]            # he has only just started again
        self.assertFalse(s.step(np.zeros(int(4.2 * SR), np.float32)))
        self.assertEqual(holder.heard, [], "tried before Whisper could tell what the pause ends")
        self.speech = [(0, 3.0), (3.6, 5.0)]
        self.assertFalse(s.step(np.zeros(5 * SR, np.float32)))
        self.assertEqual(len(holder.heard), 1)
        self.speech = [(0, 3.0), (3.6, 6.0)]            # no new pause since
        self.assertFalse(s.step(np.zeros(6 * SR, np.float32)))
        self.assertEqual(len(holder.heard), 1, "transcribed again with nothing new to seal")

    def test_release_types_the_sealed_sentences_then_the_rest(self):
        self.speech = [(0, 3.0), (3.6, 7.0)]
        holder = FakeHolder(script=lambda a: [seg(" I went home.", 0, 3.05), seg(" Then I", 3.6, 7.0)])
        s = self.session(holder)
        s.step(np.zeros(7 * SR, np.float32))
        holder.script = lambda a: [seg(" Then I left.", 0, 4.0)]
        self.assertEqual(list(s.texts(np.zeros(8 * SR, np.float32))),
                         ["I went home.", "Then I left."])
        self.assertEqual(holder.heard[-1], 8 * SR - int(3.2 * SR), "re-heard sealed audio")

    def test_a_short_dictation_is_transcribed_once_at_release(self):
        holder = FakeHolder("short one")
        s = self.session(holder)
        self.assertEqual(list(s.texts(np.zeros(2 * SR, np.float32))), ["short one"])
        self.assertEqual(holder.heard, [2 * SR])

    def test_the_worker_types_a_live_dictation_with_spaces_between(self):
        self.speech = [(0, 3.0), (3.6, 7.0)]
        holder = FakeHolder(script=lambda a: [seg(" I went home.", 0, 3.05), seg(" Then I", 3.6, 7.0)])
        s = self.session(holder)
        s.step(np.zeros(7 * SR, np.float32))
        holder.script = lambda a: [seg(" Then I left.", 0, 4.0)]
        kb = FakeKeyboard()
        W.dictate(CFG, holder, W.Typer(CFG, Gate(), keyboard=kb), job(np.zeros(8 * SR, np.float32), s))
        self.assertEqual(kb.text, "I went home. Then I left. ")

    def test_it_runs_by_itself_while_he_talks(self):
        self.speech = [(0, 3.0), (3.6, 6.5)]
        blocks = []
        holder = FakeHolder(script=lambda a: [seg(" I went home.", 0, 3.05), seg(" Then I", 3.6, 6.5)])
        s = W.LiveSession(CFG, holder, blocks, False)
        try:
            for _ in range(int(6.5 * SR / W.Recorder.BLOCK)):     # 6.5 s of audio arrives
                blocks.append(np.zeros((W.Recorder.BLOCK, 1), np.float32))
            deadline = time.time() + 3
            while not s.pieces and time.time() < deadline:
                time.sleep(0.05)
            self.assertEqual(len(s.pieces), 1, "nothing was sealed while he talked")
        finally:
            s.discard()


if __name__ == "__main__":
    unittest.main()
