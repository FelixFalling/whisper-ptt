"""Readable logs and CLI options, without microphone or model dependencies."""
import ast
import contextlib
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import unicodedata
import unittest

ROOT = Path(__file__).resolve().parent.parent
tree = ast.parse((ROOT / 'whisper-ptt.py').read_text())
names = {'log', '_text_block', 'log_dictation'}
namespace = dict(re=re, time=time, unicodedata=unicodedata, _log_lock=threading.Lock())
exec(compile(ast.Module(body=[n for n in tree.body
    if isinstance(n, ast.FunctionDef) and n.name in names], type_ignores=[]),
    'log-formatting', 'exec'), namespace)


class LoggingTests(unittest.TestCase):
    def render(self, raw='um hello', output='Hello', notes=()):
        capture = io.StringIO()
        with contextlib.redirect_stdout(capture):
            namespace['log_dictation'](raw, output, 'audio 1.0s', notes=notes)
        return capture.getvalue()

    def test_input_and_cleanup_are_separate_readable_blocks(self):
        out = self.render('um hello\n\nsecond paragraph', 'Hello\n\nSecond paragraph.',
                          [' polished in 0.2s'])
        self.assertIn('Raw input\n```text\num hello\n\nsecond paragraph\n```', out)
        self.assertIn('Cleaned-up output\n```text\nHello\n\nSecond paragraph.\n```', out)
        self.assertIn('\nTiming: audio 1.0s', out)

    def test_cleanup_off_and_fallback_are_never_labelled_cleaned_up(self):
        for notes, expected in [((), 'cleanup off or skipped'),
                                ([' (polish failed)'], 'cleanup failed'),
                                ([' polished in 0.2s', ' (polish failed)'], 'partial cleanup')]:
            with self.subTest(notes=notes):
                out = self.render(notes=notes)
                self.assertIn(expected, out)
                self.assertNotIn('Cleaned-up output', out)

    def test_code_fences_and_terminal_controls_cannot_break_the_block(self):
        block = namespace['_text_block']('say ```hello```\n\x1b[2J')
        self.assertTrue(block.startswith('````text\n'))
        self.assertTrue(block.endswith('\n````'))
        self.assertNotIn('\x1b', block)

    def test_live_logs_and_numeric_history_reach_journalctl(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'journalctl'
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            fake.chmod(0o755)
            env = {**os.environ, 'PATH': directory + ':' + os.environ['PATH']}
            for args in [[], ['-f'], ['20', '--follow'], ['--follow', '20']]:
                with self.subTest(args=args):
                    result = subprocess.run(['bash', str(ROOT / 'bin/whisper-ptt'), 'logs', *args],
                                            env=env, capture_output=True, text=True, check=True)
                    lines = result.stdout.splitlines()
                    self.assertEqual(lines[lines.index('-o') + 1], 'cat')
                    self.assertEqual(lines[lines.index('-n') + 1], '20' if '20' in args else '80')
                    self.assertEqual('--follow' in lines, bool(args))
            invalid = subprocess.run(['bash', str(ROOT / 'bin/whisper-ptt'), 'logs', '--bad'],
                                     env=env, capture_output=True)
            self.assertEqual(invalid.returncode, 2)


if __name__ == '__main__':
    unittest.main()
