#!/usr/bin/env python3
"""Types a known line into whichever window has focus, to find the fastest speed an app
takes without dropping characters: `whisper-ptt type-test [ms]`.

Run it, click into a text field in the app within 3 seconds, keep your hands off the
keyboard, then compare what appears with the line printed here. ms is the time each key is
held and the gap after it (type_delay_ms in config.json); without it, the configured one.
The line has no newline, so nothing gets sent.
"""
import importlib.util
import sys
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "whisper_ptt", Path(__file__).resolve().parent.parent / "whisper-ptt.py")
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)

LINE = ("The quick brown fox jumps over the lazy dog. PACK MY BOX with 5 dozen jugs (liquor?): "
        "it's 100% \"fine\" & [ok] {yes} #1 @home ~/path_x+y=z | a<b>c; done! `tick` ^caret* $9.99,")


class NothingHeld:
    def wait_free(self):
        pass


def main():
    ms = float(sys.argv[1]) if len(sys.argv) > 1 else W.load_config()["type_delay_ms"]
    keyboard = W.Keyboard().open()
    print(f"{ms:g} ms per key ({2 * ms:g} ms a character). Click into the app; typing in",
          end=" ", flush=True)
    for n in (3, 2, 1):
        print(n, end=" ", flush=True)
        time.sleep(1)
    t0 = time.perf_counter()
    W.Typer({"type_delay_ms": ms}, NothingHeld(), keyboard=keyboard).type(LINE)
    took = time.perf_counter() - t0
    keyboard.close()
    print(f"\n\n{len(LINE)} characters in {took:.2f}s. It should read exactly:\n\n{LINE}\n")


if __name__ == "__main__":
    main()
