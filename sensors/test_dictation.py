"""Pure unit tests for the JARVIS NEXUS dictation mode.

These tests deliberately avoid audio hardware and pynput:

* The heavy optional dependencies ``mss`` and ``vosk`` are stubbed in
  ``sys.modules`` before ``jarvis_sense`` is imported, because importing the
  module would otherwise fail in an environment without them.
* The tests drive ``_dictation_finalize_and_paste`` directly with an empty
  capture dict, so the real recording step (``_dictation_start_recording``) is
  never called and no microphone is opened.
* ``paste_text`` is monkeypatched so no real clipboard or keystroke injection
  happens.

The pynput-unavailable path of ``run_dictation_mode`` (clear message + exit
code 2) is intentionally NOT exercised here. Reproducing it faithfully requires
simulating a missing ``pynput`` module and observing the process exit code,
which is an environment/CLI concern rather than a unit of the text pipeline.
That branch is a single try/except around ``from pynput import keyboard`` and
returns 2; pynput is never imported at module import time, so the rest of the
module (and these tests) works without it.
"""

import json
import os
import sys
import types
import unittest
from unittest import mock


def _install_stub_modules() -> None:
    """Make jarvis_sense importable without optional heavy dependencies."""
    if "mss" not in sys.modules:
        mss = types.ModuleType("mss")
        # Only referenced as mss.mss() inside VisionWorker, never in these tests.
        mss.mss = object
        sys.modules["mss"] = mss
    if "vosk" not in sys.modules:
        vosk = types.ModuleType("vosk")
        vosk.Model = object
        vosk.KaldiRecognizer = object
        sys.modules["vosk"] = vosk


_install_stub_modules()

# Make jarvis_sense importable whether the file is run directly or via
# ``python -m unittest sensors/test_dictation.py`` from the repo root.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import jarvis_sense as sense  # noqa: E402


class FakeRecognizer:
    """A recognizer that always accepts audio and returns one canned phrase."""

    def __init__(self, text: str) -> None:
        self._text = text
        self.accepted_chunks: list[bytes] = []

    def AcceptWaveform(self, data: bytes) -> bool:
        self.accepted_chunks.append(bytes(data))
        return True

    def FinalResult(self) -> str:
        return json.dumps({"text": self._text}, ensure_ascii=False)


def make_fake_factory(phrases):
    """Return a zero-argument recognizer factory yielding canned phrases."""
    iterator = iter(phrases)

    def factory() -> FakeRecognizer:
        return FakeRecognizer(next(iterator))

    return factory


class DictationTextPipelineTests(unittest.TestCase):
    def test_pastes_exactly_once_per_canned_phrase(self) -> None:
        phrases = ["первая фраза", "вторая фраза", "третья фраза"]
        factory = make_fake_factory(phrases)
        pasted = []
        with mock.patch.object(sense, "paste_text", side_effect=pasted.append):
            for _ in phrases:
                recognizer = factory()
                self.assertTrue(sense._dictation_finalize_and_paste(recognizer, {}))
        self.assertEqual(pasted, phrases)
        self.assertEqual(len(pasted), len(phrases))

    def test_recorded_text_is_trimmed_and_capped(self) -> None:
        long_text = "слово " * 4000  # far beyond DICTATION_MAX_CHARS
        pasted = []
        with mock.patch.object(sense, "paste_text", side_effect=pasted.append):
            sense._dictation_finalize_and_paste(make_fake_factory([long_text])(), {})
        self.assertEqual(len(pasted), 1)
        self.assertEqual(pasted[0], long_text.strip()[:sense.DICTATION_MAX_CHARS])

        pasted = []
        with mock.patch.object(sense, "paste_text", side_effect=pasted.append):
            sense._dictation_finalize_and_paste(make_fake_factory(["   фраза с пробелами   "])(), {})
        self.assertEqual(pasted, ["фраза с пробелами"])

    def test_empty_text_is_skipped(self) -> None:
        pasted = []
        with mock.patch.object(sense, "paste_text", side_effect=pasted.append):
            self.assertFalse(sense._dictation_finalize_and_paste(make_fake_factory([""])(), {}))
            self.assertFalse(sense._dictation_finalize_and_paste(make_fake_factory(["   "])(), {}))
            self.assertTrue(sense._dictation_finalize_and_paste(make_fake_factory(["реальная фраза"])(), {}))
        self.assertEqual(pasted, ["реальная фраза"])

    def test_null_bytes_are_neutralised(self) -> None:
        pasted = []
        with mock.patch.object(sense, "paste_text", side_effect=pasted.append):
            sense._dictation_finalize_and_paste(make_fake_factory(["при\x00вет"])(), {})
        self.assertEqual(pasted, ["при вет"])

    def test_stop_recording_tolerates_bad_final_result(self) -> None:
        class BadRecognizer(FakeRecognizer):
            def FinalResult(self) -> str:
                return "not-json"

        self.assertEqual(sense._dictation_stop_recording({}, BadRecognizer("ignored")), "")

    def test_prepare_dictation_text(self) -> None:
        self.assertEqual(sense._prepare_dictation_text(None), "")
        self.assertEqual(sense._prepare_dictation_text("  hi  "), "hi")
        self.assertEqual(sense._prepare_dictation_text("a" * 5000), "a" * sense.DICTATION_MAX_CHARS)
        self.assertEqual(sense._prepare_dictation_text("x\x00y"), "x y")


if __name__ == "__main__":
    unittest.main()
