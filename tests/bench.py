#!/usr/bin/env python3
"""Speed and accuracy on the GPU, with no microphone: `whisper-ptt bench`.

Speaks a fixed set of neutral sentences with Kokoro (espeak-ng if Kokoro is missing), once,
into ~/.cache/whisper-ptt/bench, then times what happens after release, for short
dictations and for long ones made of several sentences with a pause between them:

  single pass   the whole recording transcribed at release, as the Mac's requests are
  live          LiveSession: sentences sealed while "he talks", the rest at release

and counts the words each gets wrong. Uses the settings in config.json; --polish adds the
polish model's time. A second model instance is loaded, so the service can keep running.
"""
import importlib.util
import json
import re
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("whisper_ptt", HERE.parent / "whisper-ptt.py")
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)
SR = W.SAMPLE_RATE
CACHE = Path.home() / ".cache" / "whisper-ptt" / "bench"
KOKORO = Path.home() / ".local" / "share" / "kokoro-tts"

SHORT = [
    "Sounds good.",
    "Open the settings page.",
    "Send it to me by Friday.",
    "Can you check the logs again?",
    "The meeting moved to three thirty.",
    "Add a test for the empty case and run the whole suite.",
]
LONG = [
    ["I looked at the build this morning.", "It fails only on the second run, after the cache is warm.",
     "My guess is a stale file in the output folder.", "Can you clear it and try once more?"],
    ["The new laptop arrived yesterday.", "Setting it up took most of the afternoon.",
     "Everything works except the external monitor, which keeps flickering.",
     "I ordered a different cable to rule that out."],
    ["Thanks for the notes from Tuesday.", "I agree with most of them.",
     "The part about the timeline worries me, though, because two of the tasks depend on each other.",
     "Let's talk about it before we commit to a date.", "Does Thursday morning work for you?"],
    ["Here is the plan for the weekend.", "On Saturday we drive up to the lake and set up camp.",
     "Sunday is for the long hike, if the weather holds.", "Bring warm clothes, since the nights get cold.",
     "We should be back home by six."],
]
PAUSES = [0.7, 0.9, 1.2, 0.6, 1.0]


def speak(texts):
    """{text: 16 kHz float32 audio}, synthesised once and cached."""
    CACHE.mkdir(parents=True, exist_ok=True)
    index = CACHE / "index.json"
    known = json.loads(index.read_text()) if index.exists() else {}
    todo = [t for t in texts if t not in known]
    if todo:
        files = {t: str(CACHE / f"s{len(known) + i:03d}.wav") for i, t in enumerate(todo)}
        python = KOKORO / ".venv" / "bin" / "python"
        if python.exists():
            script = (
                "import json,sys,wave,numpy as np\n"
                "from kokoro_onnx import Kokoro\n"
                f"k=Kokoro({str(KOKORO / 'kokoro-v1.0.onnx')!r},{str(KOKORO / 'voices-v1.0.bin')!r})\n"
                "for i,(t,f) in enumerate(json.load(sys.stdin).items()):\n"
                "    s,sr=k.create(t,voice=['am_michael','am_adam','am_eric'][i%3],speed=1.0,lang='en-us')\n"
                "    n=int(len(s)*16000/sr); x=np.interp(np.linspace(0,len(s)-1,n),np.arange(len(s)),s)\n"
                "    w=wave.open(f,'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)\n"
                "    w.writeframes((np.clip(x*0.6,-1,1)*32767).astype('<i2').tobytes()); w.close()\n")
            subprocess.run([str(python), "-c", script], input=json.dumps(files).encode(),
                           check=True, stderr=subprocess.DEVNULL)
        else:
            for t, f in files.items():
                subprocess.run(["espeak-ng", "-v", "en-us", "-s", "165", "-w", f + ".22k", t], check=True)
                subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", f + ".22k", "-ar", "16000",
                                "-ac", "1", f], check=True)
        known.update(files)
        index.write_text(json.dumps(known, indent=1))
    out = {}
    for t in texts:
        with wave.open(known[t]) as w:
            out[t] = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768
    return out


def dictation(clips, pauses):
    """Sentences with pauses between them, a little silence around, and a mic's noise floor."""
    gap = lambda s: np.zeros(int(s * SR), np.float32)
    parts = [gap(0.3)]
    for i, clip in enumerate(clips):
        parts += [clip, gap(pauses[i % len(pauses)] if i < len(clips) - 1 else 0.25)]
    audio = np.concatenate(parts)
    return audio + np.random.default_rng(len(audio)).normal(0, 0.003, len(audio)).astype(np.float32)


def words(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def wrong(ref, hyp):
    """Words wrong (substituted, missing or extra) by edit distance."""
    r, h = words(ref), words(hyp)
    row = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, row[0] = row[0], i
        for j in range(1, len(h) + 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
    return row[len(h)]


def live(holder, cfg, audio, polishing):
    """Feeds the audio to a LiveSession as fast as the GPU allows, a second of speech at a time
    the way its thread does, then times release. Returns (text, seconds to first text, to all)."""
    s = W.LiveSession(cfg, holder, [], polishing, run=False)
    tried = 0
    for end in range(SR, audio.size + 1, SR // 4):
        if end - s.sealed_at >= s.START * SR and end - tried >= s.EVERY * SR:
            tried = end
            s.step(audio[:end])
    for piece in s.pieces:
        piece.result()                    # by release these are long done in real life
    t0 = time.perf_counter()
    first, texts = None, []
    for text in s.texts(audio):
        first = first or time.perf_counter() - t0
        texts.append(text)
    return " ".join(t for t in texts if t), first, time.perf_counter() - t0, len(s.pieces)


def main():
    polishing = "--polish" in sys.argv
    cfg = W.load_config()
    print(f"model {cfg['model']} ({cfg['compute_type']}), beam {cfg['beam_size']}, "
          f"polish {'on' if polishing else 'off'}")
    audio = speak(SHORT + [s for group in LONG for s in group])
    W._preload_cuda_libs()
    from faster_whisper import WhisperModel
    holder = W.ModelHolder(cfg, WhisperModel)
    t0 = time.perf_counter()
    holder.load()
    print(f"load {time.perf_counter() - t0:.1f}s (compiled GPU code cached in "
          f"{W.os.environ['CUDA_CACHE_PATH']})\n")

    def single(a, ref):
        t = time.perf_counter()
        text, _ = W.maybe_polish(cfg, W.transcribe_audio(holder, cfg, a), quiet=True,
                                 polishing=polishing)
        return text, time.perf_counter() - t

    print(f"{'':44}{'seconds':>8}{'release->text':>15}{'words wrong':>13}")
    errs = total = 0
    for ref in SHORT:
        a = dictation([audio[ref]], PAUSES)
        single(a, ref)                                # warm
        text, took = single(a, ref)
        errs, total = errs + wrong(ref, text), total + len(words(ref))
        print(f"  short  {ref[:36]:36}{a.size / SR:7.1f}s{took * 1000:13.0f}ms{wrong(ref, text):>10}")
    print(f"  short dictations: {errs}/{total} words wrong\n")
    rows = []
    for group in LONG:
        ref = " ".join(group)
        a = dictation([audio[s] for s in group], PAUSES)
        text1, took1 = single(a, ref)
        text2, first, took2, early = live(holder, cfg, a, polishing)
        rows.append((wrong(ref, text1), wrong(ref, text2), len(words(ref))))
        print(f"  long   {group[0][:36]:36}{a.size / SR:7.1f}s\n"
              f"           single pass{'':22}{took1 * 1000:13.0f}ms{rows[-1][0]:>10}\n"
              f"           live, {early} sentence(s) early{'':10}{took2 * 1000:13.0f}ms{rows[-1][1]:>10}"
              f"   (first text {first * 1000:.0f}ms)")
    n = sum(r[2] for r in rows)
    print(f"\n  long dictations: single pass {sum(r[0] for r in rows)}/{n} words wrong, "
          f"live {sum(r[1] for r in rows)}/{n}")


if __name__ == "__main__":
    main()
