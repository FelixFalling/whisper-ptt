"""Transcribes on the Mac for Whisper PTT.app when the desktop is away.

The app runs this with the venv that mac/install.sh makes (it has mlx-whisper) and keeps it
running, so the model loads once. One JSON request per line on stdin, one JSON reply per
line on stdout:

    {"wav": "/path/to.wav", "model": "...", "language": "en", "initial_prompt": "",
     "short_entry_min_words": 4}
        -> {"text": "..."} or {"error": "..."}
    {"warm": true, "model": "...", "language": "en"} -> {"ok": true}   loads the model
    {"ping": true} -> {"ok": true}

It decodes the way the desktop does (whisper-ptt.py: transcribe_audio, joined,
_short_entry), so a dictation reads the same wherever it was transcribed.
"""
import json
import re
import sys
import wave

import numpy as np

SAMPLE_RATE = 16000
# At most one retry. mlx-whisper's default retries up to five times whenever Whisper is
# unsure of itself, each a full decode; one still breaks a repetition loop.
TEMPERATURES = (0.0, 0.6)
# A recording that never rises above this (-50 dBFS) holds no speech: a muted microphone,
# or one macOS has not let through. Whisper makes words up for silence ("Thank you."), and
# unlike the desktop this model has no voice detector in front of it.
SILENCE = 0.003

warmed = set()


def entry_words(text):
    """Count Unicode words, keeping apostrophes and hyphens inside a word."""
    return len(re.findall(r"[^\W_]+(?:['’\-][^\W_]+)*", text))


def short_entry(text, min_words=4):
    """Omit the final full stop of an entry shorter than min_words (a form field, a name).
    Ellipses, question marks and exclamation marks stay."""
    if 0 < entry_words(text) < min_words:
        return re.sub(r'(?<!\.)\.(?=["”\')\]]*\s*$)', '', text)
    return text


def tidy(text, min_words=4):
    # Whisper ends a segment with "..." at a pause and starts the next with another.
    text = re.sub(r"\.\.\.(\s*)\.\.\.", r"...\1", text or "").strip()
    return short_entry(text, min_words)


def read_wav(path):
    with wave.open(path) as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, SAMPLE_RATE):
            raise ValueError("expected 16 kHz mono 16-bit WAV")
        pcm = w.readframes(w.getnframes())
    return np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0


def decode(audio, job):
    import mlx_whisper
    return mlx_whisper.transcribe(audio, path_or_hf_repo=job["model"],
                                  language=job.get("language") or None,
                                  initial_prompt=job.get("initial_prompt") or None,
                                  condition_on_previous_text=False,
                                  temperature=TEMPERATURES)


def warm(job):
    """Loads the model (downloading it the first time) and runs it once, so the first
    dictation does not pay for either."""
    if job["model"] not in warmed:
        decode(np.zeros(SAMPLE_RATE, dtype=np.float32), {**job, "initial_prompt": ""})
        warmed.add(job["model"])
    return {"ok": True}


def transcribe(job):
    audio = read_wav(job["wav"])
    if audio.size == 0 or float(np.abs(audio).max()) < SILENCE:
        return {"text": ""}
    out = decode(audio, job)
    warmed.add(job["model"])
    min_words = job.get("short_entry_min_words", 4)
    if type(min_words) is not int or min_words < 0:
        min_words = 4
    return {"text": tidy(out.get("text"), min_words)}


def answer(line):
    try:
        job = json.loads(line)
        if job.get("ping"):
            return {"ok": True}
        return warm(job) if job.get("warm") else transcribe(job)
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {exc}"}


def main():
    replies = sys.stdout
    sys.stdout = sys.stderr     # mlx-whisper and model downloads print progress; keep replies clean
    import mlx_whisper  # noqa: F401  (now, so a missing install shows at start, and ping means it imports)
    for line in sys.stdin:
        if not line.strip():
            continue
        replies.write(json.dumps(answer(line)) + "\n")
        replies.flush()


if __name__ == "__main__":
    main()
