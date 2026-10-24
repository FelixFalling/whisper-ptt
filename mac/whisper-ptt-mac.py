#!/usr/bin/env python3
"""Push-to-talk dictation on the Mac, transcribed on the desktop's GPU.

Hold right Option, speak, release: the audio goes to whisper-ptt on the desktop
 over Tailscale, and the text is pasted at the cursor. If the desktop does
not answer, it transcribes on this Mac with mlx-whisper instead (that model downloads the
first time it is needed). Pressing any other key while Option is held cancels, so Option
still works as a modifier for typing accents and symbols.

Settings: ~/.config/whisper-ptt/mac.json. Start: ~/.local/share/whisper-ptt-mac/run
"""
import io
import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.request
import wave
from pathlib import Path

import numpy as np

CONFIG_PATH = Path.home() / ".config" / "whisper-ptt" / "mac.json"
DEFAULTS = {
    "server": "http://YOUR-DESKTOP-TAILSCALE-IP:8765",   # the desktop's Tailscale address
    "token": "",
    "key": "alt_r",                 # a pynput Key name; alt_r is right Option
    "min_duration": 0.35,           # shorter presses are ignored
    "language": "en",
    "initial_prompt": "",
    "trailing_space": True,
    "fallback": True,               # transcribe on this Mac when the desktop is away
    "fallback_model": "mlx-community/whisper-large-v3-turbo",
    "connect_timeout": 1.5,         # how long to wait for the desktop before falling back
    "transcribe_timeout": 30,       # a cold desktop needs about 5 s to load its model
    "sounds": True,
    "restore_clipboard": True,      # put back the text that was on the clipboard
}
SAMPLE_RATE = 16000
UTF8 = {**os.environ, "LANG": "en_US.UTF-8"}   # pbcopy mangles accents without a locale


def log(msg):
    print(f"[whisper-ptt-mac] {msg}", flush=True)


def load_config():
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text()))
        except Exception as exc:
            log(f"config unreadable, using defaults: {exc}")
    return cfg


def sound(cfg, name):
    if cfg["sounds"]:
        subprocess.Popen(["afplay", f"/System/Library/Sounds/{name}.aiff"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def resample(audio, src, dst=SAMPLE_RATE):
    """Mac microphones record at 44.1 or 48 kHz; Whisper wants 16 kHz."""
    if src == dst or audio.size == 0:
        return audio.astype(np.float32)
    if src % dst == 0:              # 48 kHz: average each group of 3, a cheap low-pass
        k = src // dst
        n = audio.size // k * k
        return audio[:n].reshape(-1, k).mean(axis=1).astype(np.float32)
    n = int(round(audio.size * dst / src))
    x = np.linspace(0, audio.size - 1, n)
    return np.interp(x, np.arange(audio.size), audio).astype(np.float32)


def to_wav(audio):
    """16 kHz mono 16-bit WAV, the one format the desktop accepts."""
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


def call(cfg, path, data=b"", timeout=5.0):
    req = urllib.request.Request(
        cfg["server"].rstrip("/") + path, data=data, method="POST",
        headers={"Authorization": f"Bearer {cfg['token']}", "Content-Type": "audio/wav"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"{}")


class Recorder:
    """Records at the microphone's own rate and hands back 16 kHz mono float32."""

    def __init__(self):
        self.blocks, self.stream, self.rate = [], None, SAMPLE_RATE

    def _callback(self, indata, frames, time_info, status):
        self.blocks.append(indata.copy())

    def start(self):
        import sounddevice as sd
        self.blocks = []
        self.rate = int(sd.query_devices(kind="input")["default_samplerate"])
        self.stream = sd.InputStream(samplerate=self.rate, channels=1, dtype="float32",
                                     callback=self._callback)
        self.stream.start()

    def stop(self):
        stream, self.stream = self.stream, None
        if stream is None:
            return np.zeros(0, dtype=np.float32)
        try:
            stream.stop()
            stream.close()
        except Exception as exc:        # an error here would kill the key listener
            log(f"microphone stopped badly: {exc}")
        if not self.blocks:
            return np.zeros(0, dtype=np.float32)
        return resample(np.concatenate(self.blocks).reshape(-1), self.rate)


class Warm(threading.Thread):
    """POST /warm on key press: the desktop starts loading its model while he is still
    talking, and the answer says whether the desktop is reachable at all."""

    def __init__(self, cfg):
        super().__init__(daemon=True)
        self.cfg, self.ok = cfg, False

    def run(self):
        try:
            call(self.cfg, "/warm", timeout=self.cfg["connect_timeout"])
            self.ok = True
        except Exception as exc:
            log(f"desktop not reachable: {exc}")


def transcribe_here(cfg, audio):
    import mlx_whisper              # only loaded when the desktop is away
    out = mlx_whisper.transcribe(audio, path_or_hf_repo=cfg["fallback_model"],
                                 language=cfg["language"] or None,
                                 initial_prompt=cfg["initial_prompt"] or None,
                                 condition_on_previous_text=False)
    return (out.get("text") or "").strip()


def paste(cfg, text, kb, Key):
    old = None
    if cfg["restore_clipboard"]:
        old = subprocess.run(["pbpaste"], capture_output=True, env=UTF8).stdout
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), env=UTF8, check=False)
    with kb.pressed(Key.cmd):
        kb.press("v")
        kb.release("v")
    if old:                         # only text can be restored; pbpaste cannot see images
        time.sleep(0.5)
        subprocess.run(["pbcopy"], input=old, env=UTF8, check=False)


def worker(cfg, kb, Key, jobs, trigger_up, state):
    """Transcribes and pastes each recording in order. It never pastes while Option is
    held: Cmd+V with Option down is Cmd+Option+V, which some apps treat as a different
    command (Finder moves files with it)."""
    while True:
        audio, warm = jobs.get()
        warm.join(cfg["connect_timeout"])
        text, where, t0 = None, "", time.time()
        if warm.ok:
            try:
                text = call(cfg, "/transcribe", to_wav(audio),
                            timeout=cfg["transcribe_timeout"]).get("text", "")
                where = "desktop"
            except Exception as exc:
                log(f"desktop failed: {exc}")
        if text is None and cfg["fallback"]:
            try:
                text, where = transcribe_here(cfg, audio), "this Mac"
            except Exception as exc:
                log(f"fallback on this Mac failed: {exc}")
        secs = audio.size / SAMPLE_RATE
        if text is None:
            log(f"{secs:.1f}s audio: no transcription")
            sound(cfg, "Basso")
            continue
        if not text:
            log(f"{secs:.1f}s audio: nothing heard ({where})")
            continue
        if cfg["trailing_space"]:
            text += " "
        log(f"{secs:.1f}s audio -> {time.time() - t0:.2f}s on {where}, {len(text)} chars")
        trigger_up.wait()
        state["pasting"] = True          # our own Cmd+V must not cancel a new dictation
        try:
            paste(cfg, text, kb, Key)
        finally:
            state["pasting"] = False
        sound(cfg, "Pop")


def main():
    cfg = load_config()
    if not cfg["token"]:
        log(f"no token in {CONFIG_PATH}; copy it from the desktop's config")
        return 1
    from pynput import keyboard
    trigger = getattr(keyboard.Key, cfg["key"], None)
    if trigger is None:
        log(f"unknown key {cfg['key']!r}; use a pynput Key name such as alt_r or cmd_r")
        return 1
    kb, recorder, jobs = keyboard.Controller(), Recorder(), queue.Queue()
    state = {"recording": False, "started": 0.0, "cancelled": False, "warm": None,
             "pasting": False, "press": 0}
    trigger_up = threading.Event()
    trigger_up.set()

    def tick(press):
        if state["recording"] and not state["cancelled"] and press == state["press"]:
            sound(cfg, "Tink")

    def on_press(key):
        if key == trigger:
            trigger_up.clear()
            if state["recording"]:
                return
            state.update(recording=True, started=time.time(), cancelled=False)
            state["warm"] = Warm(cfg)
            state["warm"].start()
            try:
                recorder.start()
            except Exception as exc:
                log(f"could not open the microphone: {exc}")
                state["recording"] = False
                sound(cfg, "Basso")
                return
            # The tick waits out min_duration, so Option used for an accent stays silent.
            state["press"] += 1
            threading.Timer(cfg["min_duration"], tick, args=(state["press"],)).start()
        elif state["recording"] and not state["pasting"]:
            state["cancelled"] = True       # Option used as a modifier, not dictation

    def on_release(key):
        if key == trigger:
            trigger_up.set()
        if key != trigger or not state["recording"]:
            return
        state["recording"] = False
        audio = recorder.stop()
        held = time.time() - state["started"]
        if state["cancelled"] or held < cfg["min_duration"] or audio.size == 0:
            return
        jobs.put((audio, state["warm"]))

    threading.Thread(target=worker, args=(cfg, kb, keyboard.Key, jobs, trigger_up, state),
                     daemon=True).start()
    log(f"hold {cfg['key']} to dictate (desktop: {cfg['server']}, "
        f"fallback on this Mac: {'on' if cfg['fallback'] else 'off'})")
    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


if __name__ == "__main__":
    sys.exit(main() or 0)
