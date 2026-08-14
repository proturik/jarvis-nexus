"""Private local voice-and-vision companion for the native JARVIS desktop pet.

Audio, screenshots, transcription and vision inference stay on this PC.  The
service is deliberately inert until the native pet writes an explicit opt-in
flag to its per-user settings file.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import mss
import numpy as np
import sounddevice as sd
import torch

from PIL import Image
from vosk import KaldiRecognizer, Model


LOCAL_JARVIS = "http://127.0.0.1:3791"
LOCAL_OLLAMA = "http://127.0.0.1:11434"
WAKE_PATTERN = re.compile(r"\b(?:джарвис|джервис|жарвис|jarvis)\b", re.IGNORECASE)
CONFIRM_PATTERN = re.compile(r"\b(?:да|подтверждаю|подтверди|выполняй|делай)\b", re.IGNORECASE)
CANCEL_PATTERN = re.compile(r"\b(?:нет|отмена|отмени|не надо|стоп)\b", re.IGNORECASE)
DEFAULT_VISION_MODEL = "qwen3-vl:4b-instruct"
ACTION_VISION_MODEL = "qwen3-vl:8b-instruct"
LEGACY_THINKING_VISION_MODELS = {"qwen3-vl:4b", "qwen3-vl:4b-thinking"}
NEURAL_TTS_SPEAKER = "xenia"
NEURAL_TTS_SAMPLE_RATE = 48_000
LOCAL_TTS_HOST = "127.0.0.1"
LOCAL_TTS_PORT = 3793
LOCAL_TTS_BODY_LIMIT = 24 * 1024

DEFAULT_SETTINGS: dict[str, Any] = {
    "voiceEnabled": False,
    "visionEnabled": False,
    "microphoneDevice": None,
    "visionIntervalSeconds": 30,
    "visionModel": DEFAULT_VISION_MODEL,
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def clean_text(value: Any, limit: int = 360) -> str:
    text = str(value or "").replace("\x00", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def normalize_microphone_device(value: Any) -> int | None:
    """Return a safe PortAudio index, or None for Windows automatic choice."""
    if value is None or value == "auto" or isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= 0:
        return value
    return None


def default_input_device_id() -> int | None:
    try:
        configured = sd.default.device
        candidate = configured[0] if hasattr(configured, "__getitem__") else configured
        device_id = int(candidate)
    except (IndexError, TypeError, ValueError):
        return None
    return device_id if device_id >= 0 else None


def microphone_catalog() -> tuple[list[dict[str, Any]], int | None]:
    preferred_default = default_input_device_id()
    microphones: list[dict[str, Any]] = []
    for device_id, raw in enumerate(sd.query_devices()):
        if int(raw["max_input_channels"]) <= 0:
            continue
        try:
            host_api = clean_text(sd.query_hostapis(raw["hostapi"])["name"], 80)
        except Exception:
            host_api = "Unknown"
        sample_rate = int(round(float(raw["default_samplerate"])))
        microphones.append(
            {
                "id": device_id,
                "name": clean_text(raw["name"], 160),
                "hostApi": host_api,
                "maxInputChannels": int(raw["max_input_channels"]),
                "defaultSampleRate": sample_rate,
                "isDefault": device_id == preferred_default,
            }
        )
    valid_ids = {entry["id"] for entry in microphones}
    return microphones, preferred_default if preferred_default in valid_ids else None


def microphone_catalog_payload() -> dict[str, Any]:
    microphones, default_id = microphone_catalog()
    return {
        "schemaVersion": 1,
        "defaultDeviceId": default_id,
        "microphones": microphones,
    }


def resolve_microphone(requested_device: Any) -> dict[str, Any]:
    requested = normalize_microphone_device(requested_device)
    microphones, default_id = microphone_catalog()
    by_id = {entry["id"]: entry for entry in microphones}
    if requested is None:
        if default_id is None:
            raise RuntimeError("В Windows не выбран микрофон по умолчанию. Выбери устройство в JARVIS.")
        device_id = default_id
        automatic = True
    else:
        if requested not in by_id:
            raise RuntimeError(f"Выбранный микрофон #{requested} недоступен. Выбери другой в JARVIS.")
        device_id = requested
        automatic = False
    selection = dict(by_id[device_id])
    selection["usesSystemDefault"] = automatic
    return selection


def validate_microphone_capture(selection: dict[str, Any]) -> None:
    sample_rate = int(selection["defaultSampleRate"])
    if sample_rate < 8000:
        raise RuntimeError("Выбранный микрофон сообщает неподдерживаемую частоту.")
    sd.check_input_settings(
        device=int(selection["id"]),
        channels=1,
        dtype="int16",
        samplerate=sample_rate,
    )


def microphone_status_fields(selection: dict[str, Any]) -> dict[str, Any]:
    return {
        "microphone": clean_text(selection["name"], 120),
        "microphoneDevice": int(selection["id"]),
        "microphoneDefault": selection["isDefault"] is True,
        "microphoneAuto": selection["usesSystemDefault"] is True,
        "microphoneSampleRate": int(selection["defaultSampleRate"]),
        "microphoneHostApi": clean_text(selection["hostApi"], 80),
    }


def emit_json(value: dict[str, Any]) -> None:
    try:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        output = sys.stdout
        if output is None:
            return
        binary_output = getattr(output, "buffer", None)
        if binary_output is not None:
            binary_output.write(payload)
            binary_output.flush()
        else:
            output.write(payload.decode("utf-8"))
            output.flush()
    except (AttributeError, OSError, UnicodeError):
        # The production EXE is windowed; a missing console must not fail it.
        pass


def post_json(url: str, payload: dict[str, Any], timeout: int) -> dict[str, Any]:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request = Request(url, data=body, headers={"Content-Type": "application/json; charset=utf-8"}, method="POST")
    try:
        with urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
    except HTTPError as error:
        raw = error.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw)
            message = clean_text(payload.get("error"), 240)
        except (TypeError, ValueError):
            message = ""
        raise RuntimeError(message or f"Локальный сервис вернул HTTP {error.code}.") from error
    except URLError as error:
        raise RuntimeError(f"Локальный сервис недоступен: {error.reason}") from error
    try:
        result = json.loads(raw)
    except ValueError as error:
        raise RuntimeError("Локальный сервис вернул некорректный JSON.") from error
    if not isinstance(result, dict):
        raise RuntimeError("Локальный сервис вернул некорректный ответ.")
    return result


def get_json(url: str, timeout: int) -> dict[str, Any]:
    try:
        with urlopen(url, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
        value = json.loads(raw)
    except (URLError, ValueError) as error:
        raise RuntimeError(f"Локальный сервис недоступен: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeError("Локальный сервис вернул некорректный ответ.")
    return value


class SettingsStore:
    """Reads desired opt-in flags and writes a tiny non-sensitive runtime status."""

    def __init__(self, install_root: Path) -> None:
        app_dir = install_root / "app"
        data_dir = app_dir / "data" if app_dir.is_dir() else install_root / "data"
        self.settings_path = data_dir / "sense-settings.json"
        self.status_path = data_dir / "sense-status.json"
        self._write_lock = threading.Lock()

    def read(self) -> dict[str, Any]:
        result = dict(DEFAULT_SETTINGS)
        try:
            if not self.settings_path.is_file():
                return result
            raw = self.settings_path.read_text(encoding="utf-8-sig")
            value = json.loads(raw)
            if not isinstance(value, dict):
                return result
        except (OSError, ValueError):
            return result

        result["voiceEnabled"] = value.get("voiceEnabled") is True
        result["visionEnabled"] = value.get("visionEnabled") is True
        interval = value.get("visionIntervalSeconds", result["visionIntervalSeconds"])
        if isinstance(interval, (int, float)):
            result["visionIntervalSeconds"] = max(15, min(int(interval), 180))
        model = clean_text(value.get("visionModel"), 80)
        if model:
            result["visionModel"] = (
                DEFAULT_VISION_MODEL if model.lower() in LEGACY_THINKING_VISION_MODELS else model
            )
        result["microphoneDevice"] = normalize_microphone_device(value.get("microphoneDevice"))
        return result

    def update_status(self, **changes: Any) -> None:
        with self._write_lock:
            value: dict[str, Any] = {}
            try:
                if self.status_path.is_file():
                    parsed = json.loads(self.status_path.read_text(encoding="utf-8-sig"))
                    if isinstance(parsed, dict):
                        value.update(parsed)
            except (OSError, ValueError):
                value = {}
            value.update(changes)
            value["updatedAt"] = utc_now()
            try:
                self.status_path.parent.mkdir(parents=True, exist_ok=True)
                temporary = self.status_path.with_name(self.status_path.name + ".tmp")
                temporary.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
                os.replace(temporary, self.status_path)
            except OSError:
                # Status must never break the companion or overwrite settings.
                pass

    def read_status(self) -> dict[str, Any]:
        with self._write_lock:
            try:
                if not self.status_path.is_file():
                    return {}
                value = json.loads(self.status_path.read_text(encoding="utf-8-sig"))
                return value if isinstance(value, dict) else {}
            except (OSError, ValueError):
                return {}


class Speaker:
    """Uses local Silero neural TTS, with Windows SAPI as a safe fallback."""

    def __init__(self, neural_model_path: Path | None = None) -> None:
        self._queue: queue.Queue[tuple[str, threading.Event] | None] = queue.Queue(maxsize=3)
        self._speaking = threading.Event()
        self._closed = threading.Event()
        self._neural_model_path = neural_model_path
        self._neural_model: Any = None
        self._neural_disabled = False
        self._engine = "pending"
        self._thread = threading.Thread(target=self._run, name="JarvisSenseTts", daemon=True)
        self._thread.start()

    @property
    def speaking(self) -> bool:
        return self._speaking.is_set()

    @property
    def engine(self) -> str:
        return self._engine

    def say(self, text: str, low_priority: bool = False) -> threading.Event | None:
        message = clean_text(text, 320)
        if not message or self._closed.is_set():
            return None
        if low_priority and (self.speaking or not self._queue.empty()):
            return None
        completion = threading.Event()
        item = (message, completion)
        try:
            self._queue.put_nowait(item)
            return completion
        except queue.Full:
            if low_priority:
                return None
            try:
                dropped = self._queue.get_nowait()
                if dropped is not None:
                    dropped[1].set()
                self._queue.put_nowait(item)
                return completion
            except queue.Empty:
                return None

    def close(self) -> None:
        self._closed.set()
        try:
            self._queue.put_nowait(None)
        except queue.Full:
            pass

    def _run(self) -> None:
        while not self._closed.is_set():
            item = self._queue.get()
            if item is None:
                return
            message, completion = item
            self._speaking.set()
            try:
                neural_spoken = False
                try:
                    neural_spoken = self._speak_neural(message)
                except Exception:
                    self._neural_disabled = True
                if not neural_spoken:
                    self._engine = "windows-sapi"
                    self._speak_windows(message)
            except (OSError, subprocess.SubprocessError, RuntimeError):
                # Speech is cosmetic: a failed local engine must not kill the
                # recognition worker or leave the microphone active forever.
                pass
            finally:
                self._speaking.clear()
                completion.set()
                time.sleep(0.45)

    def _speak_neural(self, message: str) -> bool:
        if self._neural_disabled or self._neural_model_path is None or not self._neural_model_path.is_file():
            return False
        if self._neural_model is None:
            torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))
            try:
                torch.set_num_interop_threads(1)
            except RuntimeError:
                pass
            self._neural_model = torch.package.PackageImporter(str(self._neural_model_path)).load_pickle(
                "tts_models", "model"
            )
            self._neural_model.to(torch.device("cpu"))
        audio = self._neural_model.apply_tts(
            text=message,
            speaker=NEURAL_TTS_SPEAKER,
            sample_rate=NEURAL_TTS_SAMPLE_RATE,
        )
        samples = audio.detach().cpu().numpy().astype(np.float32, copy=False).reshape(-1)
        if samples.size == 0:
            return False
        peak = float(np.max(np.abs(samples)))
        if peak > 0.0:
            samples = samples * min(0.92 / peak, 1.12)
        sd.play(samples, samplerate=NEURAL_TTS_SAMPLE_RATE, blocking=True)
        self._engine = "silero-xenia"
        return True

    @staticmethod
    def _speak_windows(message: str) -> None:
        encoded_text = base64.b64encode(message.encode("utf-16le")).decode("ascii")
        script = (
            "Add-Type -AssemblyName System.Speech;"
            "$t=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" + encoded_text + "'));"
            "$s=New-Object System.Speech.Synthesis.SpeechSynthesizer;"
            "$voices=@($s.GetInstalledVoices()|Where-Object {$_.Enabled -and $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq 'ru'});"
            "$v=$voices|Where-Object {$_.VoiceInfo.Name -eq 'Microsoft Irina'}|Select-Object -First 1;"
            "if(-not $v){$v=$voices|Where-Object {$_.VoiceInfo.Gender -eq [System.Speech.Synthesis.VoiceGender]::Female}|Select-Object -First 1};"
            "if(-not $v){$v=$voices|Select-Object -First 1};"
            "if($v){$s.SelectVoice($v.VoiceInfo.Name)};"
            "$x=[Security.SecurityElement]::Escape($t);"
            "$ssml='<speak version=\"1.0\" xml:lang=\"ru-RU\"><prosody rate=\"-6%\" pitch=\"+9%\" volume=\"92\">'+$x+'</prosody></speak>';"
            "$s.SpeakSsml($ssml);$s.Dispose();"
        )
        encoded_script = base64.b64encode(script.encode("utf-16le")).decode("ascii")
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-EncodedCommand", encoded_script],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=35,
            creationflags=flags,
        )


class LocalTtsBridge:
    """Queues speech from the native Pet over a loopback-only tiny HTTP bridge."""

    def __init__(self, speaker: Speaker, microphone_level_provider: Any, status_provider: Any, vision_provider: Any) -> None:
        bridge_speaker = speaker
        bridge_microphone_level = microphone_level_provider
        bridge_status = status_provider
        bridge_vision = vision_provider

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                if self.path != "/state":
                    self.send_error(404)
                    return
                status = bridge_status()
                raw_target = status.get("actionTarget")
                action_target = None
                if isinstance(raw_target, dict):
                    target_x = raw_target.get("x")
                    target_y = raw_target.get("y")
                    if isinstance(target_x, int) and isinstance(target_y, int):
                        action_target = {
                            "x": target_x,
                            "y": target_y,
                            "label": clean_text(raw_target.get("label"), 100) or "СЮДА",
                        }
                body = json.dumps(
                    {
                        "speaking": bridge_speaker.speaking,
                        "microphoneLevel": round(float(bridge_microphone_level()), 3),
                        "engine": bridge_speaker.engine,
                        "voice": clean_text(status.get("voice"), 32),
                        "activity": clean_text(status.get("activity"), 40),
                        "lastCommand": clean_text(status.get("lastCommand"), 160),
                        "lastReply": clean_text(status.get("lastReply"), 1200),
                        "actionTarget": action_target,
                        "actionLabel": clean_text(status.get("actionLabel"), 120),
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self) -> None:
                if self.path not in {"/speak", "/vision"}:
                    self.send_error(404)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length < 1 or length > LOCAL_TTS_BODY_LIMIT:
                        raise ValueError("invalid body size")
                    payload = json.loads(self.rfile.read(length).decode("utf-8"))
                    if not isinstance(payload, dict):
                        raise ValueError("invalid payload")
                    if self.path == "/vision":
                        prompt = clean_text(payload.get("prompt"), 12_000)
                        if not prompt:
                            raise ValueError("empty prompt")
                        result = bridge_vision(prompt, payload.get("allowAction") is True)
                        body = json.dumps({"ok": True, **result}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                        self.send_response(200)
                    else:
                        text = clean_text(payload.get("text"), 320)
                        if not text:
                            raise ValueError("empty text")
                        completion = bridge_speaker.say(text)
                        if completion is None or not completion.wait(45.0):
                            self.send_error(503)
                            return
                        body = b'{"ok":true}'
                        self.send_response(202)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
                    self.send_error(400)
                except RuntimeError as error:
                    body = json.dumps({"ok": False, "error": clean_text(error, 180)}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                    self.send_response(503)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            def log_message(self, _format: str, *_args: Any) -> None:
                return

        self._server = ThreadingHTTPServer((LOCAL_TTS_HOST, LOCAL_TTS_PORT), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, name="JarvisSenseTtsBridge", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2.0)


class VoiceWorker:
    def __init__(self, store: SettingsStore, model_path: Path, speaker: Speaker, stop_event: threading.Event) -> None:
        self.store = store
        self.model_path = model_path
        self.speaker = speaker
        self.stop_event = stop_event
        self._audio: queue.Queue[bytes] = queue.Queue(maxsize=18)
        self._model: Model | None = None
        self._recognizer: KaldiRecognizer | None = None
        self._stream: sd.RawInputStream | None = None
        self._enabled = False
        self._busy = False
        self._configured_microphone: int | None = None
        self._active_microphone: dict[str, Any] | None = None
        self._last_audio_at = 0.0
        self._last_callback_error = ""
        self._last_signal_report_at = 0.0
        self._reported_signal = ""
        self._microphone_level = 0.0
        self._microphone_level_at = 0.0
        self._next_auto_device_check = 0.0
        self._awaiting_until = 0.0
        self._pending_action: dict[str, Any] | None = None
        self._pending_until = 0.0
        self._thread = threading.Thread(target=self._run, name="JarvisSenseVoice", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def close(self) -> None:
        self._stop_stream()

    @property
    def microphone_level(self) -> float:
        if time.monotonic() - self._microphone_level_at > 0.35:
            return 0.0
        return self._microphone_level

    def _start_stream(self, requested_device: int | None) -> dict[str, Any]:
        if self._stream is not None:
            return self._active_microphone or resolve_microphone(requested_device)
        if not self.model_path.is_dir():
            raise RuntimeError("Русская модель голоса не установлена.")
        selection = resolve_microphone(requested_device)
        validate_microphone_capture(selection)
        if self._model is None:
            self._model = Model(str(self.model_path))
        sample_rate = int(selection["defaultSampleRate"])
        self._recognizer = KaldiRecognizer(self._model, sample_rate)
        self._recognizer.SetWords(False)
        self._last_audio_at = 0.0
        self._last_callback_error = ""
        self._stream = sd.RawInputStream(
            device=int(selection["id"]),
            samplerate=sample_rate,
            blocksize=8000,
            dtype="int16",
            channels=1,
            callback=self._on_audio,
        )
        self._stream.start()
        self._active_microphone = selection
        return selection

    def _stop_stream(self) -> None:
        stream, self._stream = self._stream, None
        self._recognizer = None
        self._active_microphone = None
        self._last_audio_at = 0.0
        self._reported_signal = ""
        self._microphone_level = 0.0
        self._microphone_level_at = 0.0
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception:
                pass
        while True:
            try:
                self._audio.get_nowait()
            except queue.Empty:
                return

    def _on_audio(self, indata: Any, _frames: int, _time_info: Any, status: Any) -> None:
        # Keep only a timestamp and a tiny status marker; audio itself stays
        # transient in the bounded queue and is never written to disk.
        self._last_audio_at = time.monotonic()
        if status:
            self._last_callback_error = clean_text(str(status), 120)
        if not self._enabled or self.speaker.speaking or self._busy:
            self._microphone_level = 0.0
            self._microphone_level_at = time.monotonic()
            return
        samples = np.frombuffer(indata, dtype=np.int16).astype(np.float32, copy=False)
        rms = float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0
        raw_level = min(1.0, max(0.0, (rms - 180.0) / 3200.0))
        self._microphone_level = (self._microphone_level * 0.62) + (raw_level * 0.38)
        self._microphone_level_at = time.monotonic()
        try:
            self._audio.put_nowait(bytes(indata))
        except queue.Full:
            # It is safer to drop old microphone data than act on delayed speech.
            pass

    def _report_microphone_signal(self) -> None:
        if self._active_microphone is None or self._busy:
            return
        now = time.monotonic()
        signal = "receiving" if now - self._last_audio_at <= 2.0 else "waiting"
        if signal == self._reported_signal and now - self._last_signal_report_at < 5.0:
            return
        self._reported_signal = signal
        self._last_signal_report_at = now
        self.store.update_status(
            voice="listening",
            voiceError="",
            microphoneError="",
            microphoneSignal=signal,
            microphoneStreamError=self._last_callback_error,
            **microphone_status_fields(self._active_microphone),
        )

    def _auto_default_changed(self) -> bool:
        if self._configured_microphone is not None or self._active_microphone is None:
            return False
        now = time.monotonic()
        if now < self._next_auto_device_check:
            return False
        self._next_auto_device_check = now + 5.0
        try:
            return int(resolve_microphone(None)["id"]) != int(self._active_microphone["id"])
        except Exception:
            return True

    def _run(self) -> None:
        while not self.stop_event.is_set():
            settings = self.store.read()
            wants_voice = settings["voiceEnabled"] is True
            requested_device = settings["microphoneDevice"]
            needs_reconfigure = (
                wants_voice != self._enabled
                or (wants_voice and requested_device != self._configured_microphone)
                or (wants_voice and self._auto_default_changed())
            )
            if needs_reconfigure:
                self._stop_stream()
                self._enabled = wants_voice
                self._configured_microphone = requested_device
                self._next_auto_device_check = time.monotonic() + 5.0
                if not wants_voice:
                    self.store.update_status(
                        voice="off",
                        voiceError="",
                        microphoneError="",
                        microphoneSignal="off",
                        microphoneStreamError="",
                    )
                    continue
                try:
                    selection = self._start_stream(requested_device)
                    self.store.update_status(
                        voice="listening",
                        voiceError="",
                        microphoneError="",
                        microphoneSignal="starting",
                        microphoneStreamError="",
                        **microphone_status_fields(selection),
                    )
                    self.speaker.say("Голосовой канал JARVIS включён.")
                except Exception as error:
                    self._enabled = False
                    self._stop_stream()
                    message = clean_text(error, 180)
                    self.store.update_status(
                        voice="error",
                        voiceError=message,
                        microphoneError=message,
                        microphoneSignal="error",
                    )
                    # Retry a temporarily unavailable microphone, but never
                    # spin or flood the local status file when it is absent.
                    self.stop_event.wait(3.0)
                continue

            if not self._enabled or self._recognizer is None:
                self.stop_event.wait(0.3)
                continue
            self._report_microphone_signal()
            try:
                audio = self._audio.get(timeout=0.25)
            except queue.Empty:
                continue
            try:
                if self._recognizer.AcceptWaveform(audio):
                    payload = json.loads(self._recognizer.Result())
                    transcript = clean_text(payload.get("text"), 240)
                    if transcript:
                        self._handle_transcript(transcript)
            except Exception as error:
                message = clean_text(error, 180)
                self.store.update_status(
                    voice="error",
                    voiceError=message,
                    microphoneError=message,
                    microphoneSignal="error",
                )
                self._enabled = False
                self._stop_stream()
                self.stop_event.wait(3.0)

    def _handle_transcript(self, transcript: str) -> None:
        if self.speaker.speaking or self._busy:
            return
        now = time.monotonic()
        if self._pending_action is not None:
            if now >= self._pending_until:
                self._pending_action = None
                self._pending_until = 0.0
                self.store.update_status(actionTarget=None, actionLabel="")
                self.speaker.say("Время подтверждения истекло. Действие отменено.")
            elif CANCEL_PATTERN.search(transcript):
                self._pending_action = None
                self._pending_until = 0.0
                self.store.update_status(actionTarget=None, actionLabel="")
                self.speaker.say("Отменил действие.")
                return
            elif CONFIRM_PATTERN.search(transcript):
                action = self._pending_action
                self._pending_action = None
                self._pending_until = 0.0
                self.store.update_status(actionTarget=None, actionLabel="")
                self._run_async(self._execute_pending, action)
                return

        wake = WAKE_PATTERN.search(transcript)
        if wake:
            remainder = transcript[wake.end():].strip(" ,.!?:;-")
            if remainder:
                self._run_async(self._send_command, remainder)
            else:
                self._awaiting_until = now + 9.0
                # Do not speak an acknowledgement here: while Windows SAPI is
                # talking, _on_audio deliberately drops microphone frames to
                # avoid feedback. A person who pauses after the wake word
                # would otherwise lose their following command.
                self.store.update_status(voice="awaiting-command", voiceError="")
            return

        if now < self._awaiting_until:
            self._awaiting_until = 0.0
            self._run_async(self._send_command, transcript)

    def _run_async(self, callback: Any, *args: Any) -> None:
        if self._busy:
            return
        self._busy = True
        self.store.update_status(voice="processing")

        def work() -> None:
            try:
                callback(*args)
            except Exception as error:
                error_text = clean_text(error, 180)
                self.store.update_status(voice="error", voiceError=error_text, activity="error", lastReply=error_text)
                self.speaker.say("Не смог выполнить запрос локально.")
            finally:
                self._busy = False
                if self.store.read()["voiceEnabled"] is True:
                    self.store.update_status(voice="listening")

        threading.Thread(target=work, name="JarvisSenseVoiceCommand", daemon=True).start()

    def _send_command(self, command: str) -> None:
        display_command = clean_text(command, 160)
        self.store.update_status(activity="processing", lastCommand=display_command, lastReply="")
        response = post_json(LOCAL_JARVIS + "/api/chat", {"message": command}, timeout=75)
        action = response.get("action")
        reply = clean_text(response.get("reply"), 1200)
        if isinstance(action, dict) and clean_text(action.get("token"), 80):
            self._pending_action = action
            self._pending_until = time.monotonic() + 30.0
            label = clean_text(action.get("label"), 110) or "действие"
            raw_target = action.get("target")
            safe_target = None
            if isinstance(raw_target, dict) and isinstance(raw_target.get("x"), int) and isinstance(raw_target.get("y"), int):
                safe_target = {
                    "x": raw_target["x"],
                    "y": raw_target["y"],
                    "label": clean_text(raw_target.get("label"), 100) or "СЮДА",
                }
            prompt = "Есть действие: " + label + ". Скажи подтверждаю или отмена в течение тридцати секунд."
            self.store.update_status(activity="awaiting-confirmation", lastReply=prompt, actionTarget=safe_target, actionLabel=label)
            self.speaker.say(prompt)
            return
        if reply:
            self.store.update_status(activity="responding", lastReply=reply, actionTarget=None, actionLabel="")
            self.speaker.say(reply)

    def _execute_pending(self, action: dict[str, Any]) -> None:
        token = clean_text(action.get("token"), 100)
        if not token:
            raise RuntimeError("Подтверждение действия потеряно.")
        response = post_json(LOCAL_JARVIS + "/api/actions/execute", {"token": token}, timeout=30)
        message = clean_text(response.get("message"), 320)
        if response.get("ok") is not True or not message:
            raise RuntimeError(clean_text(response.get("error"), 180) or "Ядро не подтвердило действие.")
        self.store.update_status(activity="responding", lastReply=message, actionTarget=None, actionLabel="")
        self.speaker.say(message)


class VisionWorker:
    def __init__(self, store: SettingsStore, speaker: Speaker, stop_event: threading.Event) -> None:
        self.store = store
        self.speaker = speaker
        self.stop_event = stop_event
        self._fingerprint: bytes | None = None
        self._inspection_lock = threading.Lock()
        self._thread = threading.Thread(target=self._run, name="JarvisSenseVision", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def inspect(self, instruction: str, allow_action: bool = False) -> dict[str, Any]:
        settings = self.store.read()
        if settings["visionEnabled"] is not True:
            raise RuntimeError("VISION выключен. Включи кнопку VISION // ON и повтори.")
        prompt = clean_text(instruction, 12_000)
        if not prompt:
            raise RuntimeError("Не понял, что нужно посмотреть на экране.")
        display_prompt = clean_text(instruction, 400)
        self.store.update_status(vision="looking", visionError="", activity="vision-looking", lastCommand=display_prompt, lastReply="")
        with self._inspection_lock:
            image, _changed, frame = self._capture_frame()
            action_requested = allow_action is True
            model = ACTION_VISION_MODEL if action_requested else settings["visionModel"]
            try:
                result = self._ask_local_vision_task(image, model, prompt, frame, action_requested)
            except Exception:
                if model == settings["visionModel"]:
                    raise
                model = settings["visionModel"]
                result = self._ask_local_vision_task(image, model, prompt, frame, action_requested)
        answer = clean_text(result.get("answer"), 1200) or "Не смог уверенно понять происходящее на экране."
        self.store.update_status(vision="watching", visionError="", activity="responding", lastReply=answer, visionModel=model)
        return {"answer": answer, "action": result.get("action"), "frame": frame}

    def _run(self) -> None:
        next_capture = 0.0
        last_state = ""
        while not self.stop_event.is_set():
            settings = self.store.read()
            if settings["visionEnabled"] is not True:
                if last_state != "off":
                    self.store.update_status(vision="off", visionError="")
                    last_state = "off"
                self.stop_event.wait(0.75)
                continue

            now = time.monotonic()
            if now < next_capture:
                self.stop_event.wait(min(0.75, next_capture - now))
                continue
            next_capture = now + int(settings["visionIntervalSeconds"])
            try:
                self.store.update_status(vision="looking", visionError="", visionModel=settings["visionModel"])
                with self._inspection_lock:
                    image_bytes, changed, _frame = self._capture_frame()
                    if not changed:
                        self.store.update_status(vision="watching")
                        last_state = "watching"
                        continue
                    comment = self._ask_local_vision(image_bytes, settings["visionModel"])
                if self.store.read()["visionEnabled"] is True and self._is_useful_comment(comment):
                    self.speaker.say(comment, low_priority=True)
                self.store.update_status(vision="watching", visionError="", visionModel=settings["visionModel"])
                last_state = "watching"
            except Exception as error:
                self.store.update_status(vision="error", visionError=clean_text(error, 180), visionModel=settings["visionModel"])
                last_state = "error"

    def _capture_frame(self) -> tuple[bytes, bool, dict[str, int]]:
        with mss.mss() as capture:
            monitor = capture.monitors[0]
            shot = capture.grab(monitor)
            image = Image.frombytes("RGB", shot.size, shot.rgb)
        original_width, original_height = image.size
        image.thumbnail((1280, 720), Image.Resampling.LANCZOS)
        image_width, image_height = image.size
        fingerprint = image.convert("L").resize((64, 36), Image.Resampling.BILINEAR).tobytes()
        changed = self._fingerprint is None
        if self._fingerprint is not None:
            delta = sum(abs(left - right) for left, right in zip(fingerprint, self._fingerprint)) / len(fingerprint)
            changed = delta >= 3.2
        self._fingerprint = fingerprint
        output = io.BytesIO()
        image.save(output, format="JPEG", quality=72, optimize=True)
        frame = {
            "left": int(monitor["left"]),
            "top": int(monitor["top"]),
            "width": int(original_width),
            "height": int(original_height),
            "imageWidth": int(image_width),
            "imageHeight": int(image_height),
        }
        return output.getvalue(), changed, frame

    @staticmethod
    def _ask_local_vision_task(image: bytes, model: str, instruction: str, frame: dict[str, int], allow_action: bool = False) -> dict[str, Any]:
        action_requested = allow_action is True
        forbidden = re.search(r"(?:покуп|купи|удал|отправ|вход|логин|парол|плат[её]ж|оплат|установ|install|purchase|delete|send|password|payment)", instruction, re.IGNORECASE) is not None
        allow_tool = action_requested and not forbidden
        prompt = (
            "Ты локальное зрение JARVIS. Выполни запрос пользователя по одному свежему кадру экрана: " + instruction + "\n"
            "Отвечай честно и кратко по-русски только по видимому. Никогда не утверждай, что уже нажал, открыл, закрыл или запустил. "
            "Не выдумывай невидимое и не раскрывай личные данные. "
            "Если пользователь явно просит безопасно нажать хорошо видимый элемент, вызови инструмент click по центру цели. "
            "Координаты инструмента — целые числа на сетке 1000x1000: левый верх [0,0], правый низ [1000,1000]. "
            "Не вызывай инструмент для покупки, удаления, отправки, входа, пароля, платежа или установки."
        )
        payload: dict[str, Any] = {
            "model": model,
            "messages": [{"role": "user", "content": prompt, "images": [base64.b64encode(image).decode("ascii")]}],
            "stream": False,
            "think": False,
            "keep_alive": 0,
            "options": {"temperature": 0.05, "num_predict": 360},
        }
        if allow_tool:
            payload["tools"] = [{
                "type": "function",
                "function": {
                    "name": "click",
                    "description": "Предложить безопасный клик по центру явно видимого элемента. Координаты на сетке 1000x1000.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "coordinate": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
                            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                            "visibleTarget": {"type": "string", "description": "Короткое название видимой цели."},
                            "reason": {"type": "string", "description": "Почему эта цель соответствует запросу и активному билду."},
                        },
                        "required": ["coordinate", "confidence", "visibleTarget", "reason"],
                    },
                },
            }]
        else:
            payload["format"] = "json"
            payload["messages"][0]["content"] += '\nОтветь строго JSON: {"answer":"краткий ответ","action":null}.'
        response = post_json(LOCAL_OLLAMA + "/api/chat", payload, timeout=120)
        message = response.get("message")
        message = message if isinstance(message, dict) else {}
        content = clean_text(message.get("content"), 1800)
        safe_action = None
        if allow_tool:
            tool_calls = message.get("tool_calls")
            if isinstance(tool_calls, list):
                for call in tool_calls[:1]:
                    function = call.get("function") if isinstance(call, dict) else None
                    if not isinstance(function, dict) or clean_text(function.get("name"), 20).lower() != "click":
                        continue
                    arguments = function.get("arguments")
                    if isinstance(arguments, str):
                        try:
                            arguments = json.loads(arguments)
                        except (TypeError, ValueError, json.JSONDecodeError):
                            arguments = None
                    if not isinstance(arguments, dict):
                        continue
                    try:
                        coordinate = arguments.get("coordinate")
                        confidence = float(arguments.get("confidence", 0.0))
                        if isinstance(coordinate, list) and len(coordinate) == 2:
                            normalized_x, normalized_y = int(coordinate[0]), int(coordinate[1])
                            if 0 <= normalized_x <= 1000 and 0 <= normalized_y <= 1000 and confidence >= 0.88:
                                screen_x = frame["left"] + round(normalized_x * frame["width"] / 1000)
                                screen_y = frame["top"] + round(normalized_y * frame["height"] / 1000)
                                safe_action = {
                                    "type": "click",
                                    "x": screen_x,
                                    "y": screen_y,
                                    "confidence": round(confidence, 3),
                                    "target": clean_text(arguments.get("visibleTarget"), 100) or "СЮДА",
                                    "reason": clean_text(arguments.get("reason"), 320),
                                }
                    except (TypeError, ValueError, OverflowError):
                        safe_action = None
            if content:
                answer = content
            elif safe_action:
                answer = (
                    "🎯 ДЕЛАЙ СЕЙЧАС — выбери «" + safe_action["target"] + "».\n"
                    "💡 ПОЧЕМУ — " + (safe_action["reason"] or "эта цель лучше всего совпадает с запросом и активным билдом.") + "\n"
                    "⚠️ Клик выполню только после твоего подтверждения."
                )
            else:
                answer = "Вижу экран, но не смог уверенно выбрать безопасную цель."
            return {"answer": clean_text(answer, 1200), "action": safe_action}
        try:
            parsed = json.loads(content)
        except (TypeError, ValueError, json.JSONDecodeError):
            return {"answer": content or "Не смог уверенно разобрать экран.", "action": None}
        answer = clean_text(parsed.get("answer"), 1200) if isinstance(parsed, dict) else ""
        return {"answer": answer or "Не смог уверенно понять происходящее на экране.", "action": None}

    @staticmethod
    def _ask_local_vision(image: bytes, model: str) -> str:
        prompt = (
            "Ты JARVIS, добрый умный игровой напарник. Посмотри на один текущий кадр экрана. "
            "Если явно видна игра, дай один короткий полезный тактический совет только по видимому: цель, уклонение, ресурс, позиция или опасность. "
            "Вне игры коротко комментируй только действительно заметное событие. Ответь по-русски одной фразой до 18 слов. "
            "Если кадр непонятный или полезного комментария нет, ответь строго ТИШИНА. "
            "Не придумывай факты, не упоминай, что получил изображение, и не раскрывай личные данные."
        )
        response = post_json(
            LOCAL_OLLAMA + "/api/chat",
            {
                "model": model,
                "messages": [{"role": "user", "content": prompt, "images": [base64.b64encode(image).decode("ascii")] }],
                "stream": False,
                "think": False,
                "keep_alive": 0,
                "options": {"temperature": 0.65, "num_predict": 54},
            },
            timeout=100,
        )
        message = response.get("message")
        if not isinstance(message, dict):
            return "ТИШИНА"
        # Some vision models emit only an internal reasoning field.  Never
        # turn that absence into a made-up spoken comment.
        comment = clean_text(message.get("content"), 220)
        return comment or "ТИШИНА"

    @staticmethod
    def _is_useful_comment(comment: str) -> bool:
        compact = re.sub(r"[\s.!?…]+", "", comment).upper()
        return bool(compact) and compact not in {"ТИШИНА", "НЕТ", "NONE", "SILENCE"}


def resolve_install_root(argument: str | None) -> Path:
    if argument:
        return Path(argument).expanduser().resolve()
    if getattr(sys, "frozen", False):
        # Bundled layout: <install-root>\desktop-shell\sense\JarvisSense.exe.
        return Path(sys.executable).resolve().parent.parent.parent
    return Path(__file__).resolve().parents[1]


def resolve_model_path(argument: str | None) -> Path:
    if argument:
        return Path(argument).expanduser().resolve()
    if getattr(sys, "frozen", False):
        # PyInstaller one-dir keeps bundled data in _internal; _MEIPASS also
        # covers a future one-file build without assuming a filesystem layout.
        runtime_dir = Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent / "_internal"))
        return runtime_dir / "voice-model"
    return Path(__file__).resolve().parent / "models" / "vosk-model-small-ru-0.22"


def resolve_tts_model_path(argument: str | None) -> Path:
    if argument:
        return Path(argument).expanduser().resolve()
    if getattr(sys, "frozen", False):
        runtime_dir = Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent / "_internal"))
        return runtime_dir / "tts-model" / "v5_5_ru.pt"
    return Path(__file__).resolve().parent / "models" / "tts" / "v5_5_ru.pt"


def main() -> int:
    parser = argparse.ArgumentParser(description="Private local JARVIS Sense companion")
    parser.add_argument("--install-root", help="JARVIS installation root")
    parser.add_argument("--model-path", help="Vosk Russian model directory")
    parser.add_argument("--tts-model-path", help="Silero Russian neural TTS model file")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--diagnose", action="store_true", help="validate model and selected microphone, then exit")
    mode.add_argument("--list-microphones", action="store_true", help="print available input devices as JSON, then exit")
    mode.add_argument("--test-tts", metavar="TEXT", help="speak one phrase with local neural TTS, then exit")
    args = parser.parse_args()

    store = SettingsStore(resolve_install_root(args.install_root))
    model_path = resolve_model_path(args.model_path)
    tts_model_path = resolve_tts_model_path(args.tts_model_path)
    if args.list_microphones:
        try:
            emit_json(microphone_catalog_payload())
            return 0
        except Exception as error:
            emit_json(
                {
                    "schemaVersion": 1,
                    "defaultDeviceId": None,
                    "microphones": [],
                    "error": clean_text(error, 180),
                }
            )
            return 1

    if args.test_tts is not None:
        speaker = Speaker(tts_model_path)
        try:
            message = clean_text(args.test_tts, 320)
            ok = bool(message) and speaker._speak_neural(message)
            emit_json({"schemaVersion": 1, "ok": ok, "engine": speaker.engine})
            return 0 if ok else 1
        except Exception as error:
            emit_json({"schemaVersion": 1, "ok": False, "engine": speaker.engine, "error": clean_text(error, 180)})
            return 1
        finally:
            speaker.close()

    if args.diagnose:
        settings = store.read()
        requested_device = settings["microphoneDevice"]
        diagnostic: dict[str, Any] = {
            "schemaVersion": 1,
            "ok": False,
            "modelReady": False,
            "ttsModelReady": tts_model_path.is_file(),
            "microphone": None,
        }
        try:
            if not model_path.is_dir():
                raise RuntimeError("Русская модель голоса не установлена.")
            # Exercise the bundled Vosk DLL and model files without opening an
            # audio stream.  A ready diagnostic proves the package can
            # recognise speech once the user opts in.
            Model(str(model_path))
            diagnostic["modelReady"] = True
            selection = resolve_microphone(requested_device)
            validate_microphone_capture(selection)
            diagnostic["microphone"] = selection
            diagnostic["ok"] = True
            store.update_status(
                voice="ready",
                voiceError="",
                microphoneError="",
                microphoneSignal="validated",
                microphoneStreamError="",
                vision="ready",
                **microphone_status_fields(selection),
            )
            emit_json(diagnostic)
            return 0
        except Exception as error:
            message = clean_text(error, 180)
            diagnostic["error"] = message
            store.update_status(
                voice="error",
                voiceError=message,
                microphoneError=message,
                microphoneSignal="error",
                vision="ready",
            )
            emit_json(diagnostic)
            return 1

    stop_event = threading.Event()
    speaker = Speaker(tts_model_path)
    voice = VoiceWorker(store, model_path, speaker, stop_event)
    vision = VisionWorker(store, speaker, stop_event)
    tts_bridge: LocalTtsBridge | None = None
    try:
        tts_bridge = LocalTtsBridge(speaker, lambda: voice.microphone_level, store.read_status, vision.inspect)
        tts_bridge.start()
    except OSError:
        tts_bridge = None
    store.update_status(
        voice="off",
        voiceError="",
        vision="off",
        microphoneError="",
        microphoneSignal="off",
        microphoneStreamError="",
        privacy="Local microphone, local neural TTS, RAM-only screenshots, localhost-only inference",
    )
    voice.start()
    vision.start()
    try:
        while not stop_event.wait(0.5):
            pass
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        voice.close()
        if tts_bridge is not None:
            tts_bridge.close()
        speaker.close()
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
