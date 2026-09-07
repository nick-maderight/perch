#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["parakeet-mlx", "sounddevice", "numpy"]
# ///
# perch_server.py --- Local Parakeet speech server for Perch
# Copyright (c) 2024 Abhinav Tushar
# Copyright (c) 2026 Nick Wang
# Author: Nick Wang
# Version: 0.1.0
# URL: https://github.com/nick-maderight/perch
# Forked from esi-dictate by Abhinav Tushar <abhinav@lepisma.xyz>
# License:
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
"""Local streaming speech recognition for Perch."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import queue
import signal
import sys
import threading
import time
import wave
from collections import deque
from collections.abc import Iterator
from pathlib import Path

# Keep every Hugging Face download message off the JSON stdout channel.
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
import mlx.core as mx
import numpy as np
import sounddevice as sd
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
FALLBACK_MODEL = "mlx-community/parakeet-tdt-0.6b-v2"
SAMPLE_RATE = 16000
VAD_BLOCK_SAMPLES = SAMPLE_RATE // 10  # 100 ms
MIN_INTERIM_MS = 200
MAX_UTTERANCE_MS = 90_000

_STOP = threading.Event()


def emit(payload: dict) -> None:
    """Write exactly one protocol object to stdout."""
    try:
        sys.stdout.write(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
        )
        sys.stdout.flush()
    except BrokenPipeError:
        _STOP.set()


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def request_stop(_signum: int | None = None, _frame: object | None = None) -> None:
    _STOP.set()


def watch_stdin(stop_on_eof: bool) -> None:
    """Turn a stop line into a stop request; EOF stops live capture."""
    try:
        for line in sys.stdin:
            if line.strip().lower() == "stop":
                _STOP.set()
                return
        # A file invocation commonly inherits /dev/null as stdin.  Its input
        # file, rather than that unrelated descriptor, determines completion.
        if stop_on_eof:
            _STOP.set()
    except (OSError, ValueError):
        if stop_on_eof:
            _STOP.set()


def model_stream(model):
    return model.transcribe_stream(context_size=(256, 256), depth=1)


def warm_model(model) -> None:
    """Exercise the streaming and offline decode paths before announcing readiness."""
    silence = mx.zeros(SAMPLE_RATE, dtype=mx.float32)
    with contextlib.redirect_stdout(sys.stderr):
        with model_stream(model) as transcriber:
            transcriber.add_audio(silence)
            # Force the result path too; this catches stream/decode incompatibilities.
            _ = transcriber.result.text
        _ = model.generate(get_logmel(silence, model.preprocessor_config))[0].text


def load_model(repo: str):
    """Load and warm the requested model, falling back from the v3 default."""
    candidates = [repo]
    if repo == DEFAULT_MODEL:
        candidates.append(FALLBACK_MODEL)
    last_error: Exception | None = None
    for index, candidate in enumerate(candidates):
        if index:
            emit(
                {
                    "event": "status",
                    "message": f"{repo} failed; falling back to {candidate}",
                }
            )
        emit({"event": "status", "message": f"loading model {candidate}"})
        try:
            with contextlib.redirect_stdout(sys.stderr):
                model = from_pretrained(candidate)
            model_rate = int(model.preprocessor_config.sample_rate)
            if model_rate != SAMPLE_RATE:
                raise RuntimeError(
                    f"model {candidate} expects {model_rate} Hz, but Perch requires {SAMPLE_RATE} Hz"
                )
            emit({"event": "status", "message": f"warming model {candidate}"})
            warm_model(model)
            emit({"event": "status", "message": f"model {candidate} loaded and warmed"})
            return model, candidate
        except Exception as error:  # retry v2 only for the v3/default path
            last_error = error
            log(f"model {candidate} failed: {error}")
    raise RuntimeError(f"could not load a usable Parakeet model: {last_error}")


def rms_db(block: np.ndarray) -> float:
    if block.size == 0:
        return -240.0
    value = float(np.sqrt(np.mean(np.square(block, dtype=np.float32))))
    if not np.isfinite(value) or value <= 1.0e-12:
        return -240.0
    return 20.0 * float(np.log10(value))


def block_duration_ms(block: np.ndarray) -> float:
    return len(block) * 1000.0 / SAMPLE_RATE


class Utterance:
    """One Parakeet streaming context plus the raw audio for the final decode.

    Interim text comes from the streaming (local attention) decoder, which is
    fed in blocks of ``stream_samples``; each block costs roughly the same
    encoder pass regardless of size, so the block size sets the interim
    cadence and the real-time factor.  The final text is a full-attention
    offline decode over the whole utterance, which is both faster (RTF ~0.04)
    and more accurate than the streaming draft.
    """

    def __init__(self, model, utterance_id: int, stream_samples: int):
        self.id = utterance_id
        self.model = model
        self.stream_samples = stream_samples
        self._stream = model_stream(model)
        self._transcriber = self._stream.__enter__()
        self._pending: list[np.ndarray] = []
        self._pending_samples = 0
        self._audio: list[np.ndarray] = []
        self.duration_ms = 0.0
        self._closed = False
        self.last_emitted = ""

    def _add(self, samples: np.ndarray) -> None:
        if samples.size == 0:
            return
        # parakeet-mlx requires a one-dimensional MLX float32 array.
        with contextlib.redirect_stdout(sys.stderr):
            self._transcriber.add_audio(mx.array(samples, dtype=mx.float32))

    def feed(self, block: np.ndarray) -> bool:
        """Buffer BLOCK; return True when a stream block was decoded."""
        block = np.asarray(block, dtype=np.float32).reshape(-1)
        if block.size == 0:
            return False
        self._audio.append(block)
        self.duration_ms += block_duration_ms(block)
        self._pending.append(block)
        self._pending_samples += len(block)
        decoded = False
        while self._pending_samples >= self.stream_samples:
            joined = np.concatenate(self._pending)
            self._add(joined[: self.stream_samples])
            remainder = joined[self.stream_samples :]
            self._pending = [remainder] if remainder.size else []
            self._pending_samples = int(remainder.size)
            decoded = True
        return decoded

    def text(self) -> str:
        with contextlib.redirect_stdout(sys.stderr):
            value = self._transcriber.result.text
        return "" if value is None else str(value)

    def maybe_interim(self) -> None:
        text = self.text().strip()
        if not text or text == self.last_emitted:
            return
        emit({"event": "transcript", "id": self.id, "text": text, "final": False})
        self.last_emitted = text

    def finish(self, trailing: list[np.ndarray]) -> str:
        """Close the stream and return the offline decode of the full utterance."""
        self.close()
        audio = np.concatenate(
            self._audio
            + [np.asarray(b, dtype=np.float32).reshape(-1) for b in trailing]
        )
        with contextlib.redirect_stdout(sys.stderr):
            mel = get_logmel(mx.array(audio), self.model.preprocessor_config)
            result = self.model.generate(mel)[0]
        return ("" if result.text is None else str(result.text)).strip()

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            with contextlib.redirect_stdout(sys.stderr):
                self._stream.__exit__(None, None, None)


def validate_wave(path: Path) -> None:
    if not path.is_file():
        raise ValueError(f"input file does not exist: {path}")
    try:
        with wave.open(str(path), "rb") as source:
            details = (
                source.getnchannels(),
                source.getsampwidth(),
                source.getframerate(),
                source.getcomptype(),
            )
    except (OSError, wave.Error) as error:
        raise ValueError(f"could not read WAV input {path}: {error}") from error
    expected = (1, 2, SAMPLE_RATE, "NONE")
    if details != expected:
        raise ValueError(
            f"input WAV must be 16 kHz mono 16-bit PCM; got "
            f"channels={details[0]}, sample_width={details[1]}, "
            f"sample_rate={details[2]}, compression={details[3]}"
        )


def file_blocks(path: Path, realtime: bool, trailing_ms: int) -> Iterator[np.ndarray]:
    """Yield fixed 100 ms WAV blocks, then enough silence to close the final utterance."""
    block_index = 0
    start_time = time.monotonic()
    with wave.open(str(path), "rb") as source:
        while True:
            raw = source.readframes(VAD_BLOCK_SAMPLES)
            if not raw:
                break
            block = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
            if len(block) < VAD_BLOCK_SAMPLES:
                block = np.pad(block, (0, VAD_BLOCK_SAMPLES - len(block)))
            if realtime:
                deadline = start_time + block_index * (VAD_BLOCK_SAMPLES / SAMPLE_RATE)
                delay = deadline - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
            block_index += 1
            yield block
    silence_blocks = max(1, int(np.ceil((trailing_ms + 500) / 100.0)))
    for _ in range(silence_blocks):
        if realtime:
            deadline = start_time + block_index * (VAD_BLOCK_SAMPLES / SAMPLE_RATE)
            delay = deadline - time.monotonic()
            if delay > 0:
                time.sleep(delay)
        block_index += 1
        yield np.zeros(VAD_BLOCK_SAMPLES, dtype=np.float32)


def parse_device(value: str | None):
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return value


def input_device_name(device) -> str:
    info = (
        sd.query_devices(device, "input")
        if device is not None
        else sd.query_devices(kind="input")
    )
    if info is None or int(info.get("max_input_channels", 0)) < 1:
        raise RuntimeError("selected sounddevice has no input channel")
    return str(info["name"])


def start_microphone(device, audio_queue: queue.Queue[np.ndarray]):
    def callback(indata, _frames, _time_info, status) -> None:
        if status:
            log(f"sounddevice: {status}")
        block = np.asarray(indata, dtype=np.float32)
        if block.ndim > 1:
            block = block[:, 0]
        block = block.reshape(-1).copy()
        try:
            audio_queue.put_nowait(block)
        except queue.Full:
            log("sounddevice input queue is full; dropping an audio block")

    stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        blocksize=VAD_BLOCK_SAMPLES,
        device=device,
        callback=callback,
    )
    stream.start()
    return stream


def run_audio(model, args, source: Iterator[np.ndarray]) -> None:
    """Consume file or microphone blocks through the same VAD path."""
    pre_roll: deque[np.ndarray] = deque(maxlen=3)
    active: Utterance | None = None
    held_silence: list[np.ndarray] = []
    silence_ms = 0.0
    next_id = 1
    stream_samples = max(MIN_INTERIM_MS, args.interim_ms) * SAMPLE_RATE // 1000

    def finalize() -> None:
        nonlocal active, silence_ms
        if active is None:
            return
        text = active.finish(held_silence)
        if text:
            emit({"event": "transcript", "id": active.id, "text": text, "final": True})
        active = None
        held_silence.clear()
        silence_ms = 0.0
        pre_roll.clear()

    for block in source:
        if _STOP.is_set():
            break
        block = np.asarray(block, dtype=np.float32).reshape(-1)
        if block.size == 0:
            continue
        speaking = rms_db(block) >= args.threshold_db
        if speaking:
            if active is None:
                active = Utterance(model, next_id, stream_samples)
                next_id += 1
                for old_block in pre_roll:
                    active.feed(old_block)
                pre_roll.clear()
            else:
                # Short pauses inside one utterance are real audio; feed them
                # once speech resumes so the stream sees contiguous input.
                for quiet_block in held_silence:
                    active.feed(quiet_block)
                held_silence.clear()
            if active.feed(block):
                active.maybe_interim()
            silence_ms = 0.0
            if active.duration_ms >= MAX_UTTERANCE_MS:
                finalize()
        elif active is None:
            pre_roll.append(block)
        else:
            held_silence.append(block)
            silence_ms += block_duration_ms(block)
            if silence_ms >= max(0, args.utterance_end_ms):
                finalize()

    finalize()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Local Parakeet speech server for Perch"
    )
    parser.add_argument(
        "--model", default=DEFAULT_MODEL, help="Hugging Face model repository"
    )
    parser.add_argument("--device", help="sounddevice input name or numeric index")
    parser.add_argument(
        "--input", type=Path, help="strict 16 kHz mono 16-bit PCM WAV file"
    )
    parser.add_argument(
        "--realtime", action="store_true", help="pace --input at wall-clock speed"
    )
    parser.add_argument("--utterance-end-ms", type=int, default=800)
    parser.add_argument("--threshold-db", type=float, default=-45.0)
    parser.add_argument(
        "--interim-ms",
        type=int,
        default=1000,
        help=f"interim transcript cadence; also the streaming block size (min {MIN_INTERIM_MS})",
    )
    parser.add_argument("--list-devices", action="store_true")
    args = parser.parse_args(argv)
    if args.utterance_end_ms < 0 or args.interim_ms < 0:
        parser.error("--utterance-end-ms and --interim-ms must be non-negative")
    if args.realtime and args.input is None:
        parser.error("--realtime requires --input")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.list_devices:
        try:
            print(sd.query_devices(), flush=True)
            return 0
        except Exception as error:
            print(f"could not list sound devices: {error}", file=sys.stderr, flush=True)
            return 1
    if args.input is not None:
        try:
            validate_wave(args.input)
        except ValueError as error:
            emit({"event": "error", "message": str(error)})
            emit({"event": "done"})
            return 1
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    threading.Thread(
        target=watch_stdin,
        args=(args.input is None,),
        name="perch-stdin",
        daemon=True,
    ).start()

    model = None
    microphone = None
    try:
        model, model_name = load_model(args.model)
        if args.input is not None:
            source: Iterator[np.ndarray] = file_blocks(
                args.input, args.realtime, args.utterance_end_ms
            )
            input_name = str(args.input)
        else:
            audio_queue: queue.Queue[np.ndarray] = queue.Queue(maxsize=128)
            device = parse_device(args.device)
            input_name = input_device_name(device)
            microphone = start_microphone(device, audio_queue)

            def microphone_blocks() -> Iterator[np.ndarray]:
                while not _STOP.is_set():
                    try:
                        yield audio_queue.get(timeout=0.1)
                    except queue.Empty:
                        continue

            source = microphone_blocks()
        emit({"event": "ready", "model": model_name, "input": input_name})
        run_audio(model, args, source)
        return 0
    except KeyboardInterrupt:
        request_stop()
        return 0
    except Exception as error:
        log(f"server error: {error}")
        emit({"event": "error", "message": str(error)})
        return 1
    finally:
        if microphone is not None:
            try:
                microphone.stop()
                microphone.close()
            except Exception as error:
                log(f"sounddevice close error: {error}")
        emit({"event": "done"})


if __name__ == "__main__":
    raise SystemExit(main())
