"""Tests for mac/app/Resources/fallback.py, the Mac app's local transcriber. mlx-whisper
only exists on Apple Silicon, so a stand-in is used; these check what surrounds the model."""
import importlib.util
import json
import sys
import tempfile
import types
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np

spec = importlib.util.spec_from_file_location(
    "fallback", Path(__file__).resolve().parent.parent / "mac/app/Resources/fallback.py")
F = importlib.util.module_from_spec(spec)
spec.loader.exec_module(F)

W_SPEC = importlib.util.spec_from_file_location(
    "whisper_ptt_for_fallback", Path(__file__).resolve().parent.parent / "whisper-ptt.py")


def wav_file(samples, rate=16000, channels=1):
    f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    with wave.open(f, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((np.asarray(samples) * 32767).astype("<i2").tobytes())
    return f.name


class FallbackTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.text = " Hello there."
        fake = types.ModuleType("mlx_whisper")

        def transcribe(audio, **options):
            self.calls.append((len(audio), options))
            return {"text": self.text}
        fake.transcribe = transcribe
        patcher = patch.dict(sys.modules, {"mlx_whisper": fake})
        patcher.start()
        self.addCleanup(patcher.stop)
        F.warmed.clear()
        self.speech = wav_file(0.3 * np.sin(np.linspace(0, 2000, 16000)))

    def ask(self, **job):
        return F.answer(json.dumps({"model": "m", "language": "en", **job}))

    def test_a_recording_is_transcribed_like_on_the_desktop(self):
        self.text = " The report is due on Friday."
        self.assertEqual(self.ask(wav=self.speech), {"text": "The report is due on Friday."})
        options = self.calls[0][1]
        self.assertEqual(options["temperature"], (0.0, 0.6))
        self.assertFalse(options["condition_on_previous_text"])
        self.assertEqual(options["path_or_hf_repo"], "m")

    # A muted microphone delivers zeros, and Whisper invents "Thank you." for silence.
    def test_silence_is_not_given_to_whisper(self):
        self.assertEqual(self.ask(wav=wav_file(np.zeros(16000))), {"text": ""})
        self.assertEqual(self.ask(wav=wav_file(0.001 * np.ones(16000))), {"text": ""})
        self.assertEqual(self.ask(wav=wav_file([])), {"text": ""})
        self.assertEqual(self.calls, [])

    def test_quiet_speech_still_is(self):
        self.ask(wav=wav_file(0.01 * np.sin(np.linspace(0, 2000, 16000))))
        self.assertEqual(len(self.calls), 1)

    def test_short_entries_lose_their_full_stop_as_on_the_desktop(self):
        self.text = " Hello there."
        self.assertEqual(self.ask(wav=self.speech)["text"], "Hello there")
        self.assertEqual(self.ask(wav=self.speech, short_entry_min_words=0)["text"], "Hello there.")
        self.text = " Really?"
        self.assertEqual(self.ask(wav=self.speech)["text"], "Really?")

    def test_a_pause_is_one_ellipsis(self):
        self.text = " The report... ...can wait until next week."
        self.assertEqual(self.ask(wav=self.speech)["text"], "The report... can wait until next week.")

    def test_warming_loads_each_model_once(self):
        self.assertEqual(self.ask(warm=True), {"ok": True})
        self.assertEqual(self.ask(warm=True), {"ok": True})
        self.assertEqual(len(self.calls), 1)
        self.ask(wav=self.speech)
        self.assertEqual(len(self.calls), 2)

    def test_problems_come_back_as_errors_not_crashes(self):
        self.assertIn("error", F.answer("not json"))
        self.assertIn("error", self.ask(wav="/nonexistent.wav"))
        self.assertIn("16 kHz", self.ask(wav=wav_file(np.zeros(100), rate=44100))["error"])
        self.assertEqual(self.ask(ping=True), {"ok": True})

    # The two copies of the short-entry rule must agree.
    def test_the_rule_matches_the_desktops(self):
        W = importlib.util.module_from_spec(W_SPEC)
        W_SPEC.loader.exec_module(W)
        for text in ("Yes.", "John Smith.", "Okay then...", "He said \"no.\"", "It's done.",
                     "This one is long enough.", "", "Wait!", "état-major.", "3.5."):
            self.assertEqual(F.short_entry(text), W._short_entry(text), text)
            self.assertEqual(F.entry_words(text), W._entry_words(text), text)


if __name__ == "__main__":
    unittest.main()
