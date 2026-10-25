"""Exercise production formatting without importing GPU, keyboard or audio libraries."""
import ast
from pathlib import Path
import re
import unittest

root=Path(__file__).resolve().parent.parent
tree=ast.parse((root/'whisper-ptt.py').read_text())
functions={'_entry_words','_short_entry','format_dictation'}
module=ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in functions],type_ignores=[])
namespace={'re':re}
exec(compile(module,'entry-formatting','exec'),namespace)
format_dictation=namespace['format_dictation']

class ShortEntries(unittest.TestCase):
    def formatted(self,*texts): return ' '.join(format_dictation(texts))
    def test_form_entry(self):
        self.assertEqual(self.formatted('Portland State University.'),'Portland State University')
    def test_one_and_two_words(self):
        self.assertEqual(self.formatted('Portland.'),'Portland')
        self.assertEqual(self.formatted('New York.'),'New York')
    def test_four_words_unchanged(self):
        self.assertEqual(self.formatted('I live in Portland.'),'I live in Portland.')
    def test_other_punctuation_and_ellipsis_preserved(self):
        for text in ('Why?', 'Great!', 'Well...', '3.14', ''):
            self.assertEqual(self.formatted(text),text)
    def test_closing_quotes_and_space(self):
        self.assertEqual(self.formatted('"Portland State University." '),'"Portland State University" ')
    def test_complete_dictation_not_individual_chunks(self):
        self.assertEqual(self.formatted('Hello.', 'I live here.'),'Hello. I live here.')
        self.assertEqual(self.formatted('Portland', 'State University.'),'Portland State University')
    def test_streaming_resumes_after_four_words(self):
        def chunks():
            yield 'I live in Portland.'
            raise RuntimeError('later transcription failed')
        stream=format_dictation(chunks())
        self.assertEqual(next(stream),'I live in Portland.')
        with self.assertRaises(RuntimeError): next(stream)
    def test_unicode_and_contractions(self):
        self.assertEqual(self.formatted('École de Montréal.'),'École de Montréal')
        self.assertEqual(self.formatted("It's fine."),"It's fine")
    def test_configurable_threshold(self):
        self.assertEqual(' '.join(format_dictation(['Portland State University.'], min_words=3)), 'Portland State University.')
        self.assertEqual(' '.join(format_dictation(['I live in Portland.'], min_words=5)), 'I live in Portland')
    def test_zero_disables_rule(self):
        self.assertEqual(' '.join(format_dictation(['Portland.'], min_words=0)), 'Portland.')
if __name__=='__main__': unittest.main()
