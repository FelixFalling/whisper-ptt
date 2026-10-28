"""Transcribes on the Mac for Whisper PTT.app when the desktop is away.

The app runs this with the venv that mac/install.sh makes (it has mlx-whisper) and keeps it
running, so the model loads once. One JSON request per line on stdin, one JSON reply per
line on stdout:

    {"wav": "/path/to.wav", "model": "...", "language": "en", "initial_prompt": ""}
        -> {"text": "..."} or {"error": "..."}
    {"ping": true} -> {"ok": true}
"""
import json
import sys
import wave

import numpy as np

replies = sys.stdout
sys.stdout = sys.stderr     # mlx-whisper and model downloads print progress; keep replies clean
import mlx_whisper  # noqa: E402


def transcribe(job):
    with wave.open(job["wav"]) as w:
        pcm = w.readframes(w.getnframes())
    audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
    out = mlx_whisper.transcribe(audio, path_or_hf_repo=job["model"],
                                 language=job.get("language") or None,
                                 initial_prompt=job.get("initial_prompt") or None,
                                 condition_on_previous_text=False)
    return {"text": (out.get("text") or "").strip()}


for line in sys.stdin:
    try:
        job = json.loads(line)
        reply = {"ok": True} if job.get("ping") else transcribe(job)
    except Exception as exc:
        reply = {"error": f"{type(exc).__name__}: {exc}"}
    replies.write(json.dumps(reply) + "\n")
    replies.flush()
