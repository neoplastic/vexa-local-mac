"""
OpenAI-compatible transcription server for Apple Silicon, backed by mlx-whisper.

Exposes POST /v1/audio/transcriptions with the same request and `verbose_json`
response shape as OpenAI's API (text, language, duration, segments[], words[]).
Vexa's meeting bot sends its audio here.

Runs natively on macOS so Whisper gets the Metal GPU, which Docker/Colima
containers cannot reach.
"""

import logging
import os
import tempfile
import threading
import time
from typing import Optional

import mlx_whisper
import numpy as np
from fastapi import FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, PlainTextResponse
from huggingface_hub import snapshot_download

MODEL_REPO = os.getenv("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
API_TOKEN = os.getenv("WHISPER_API_TOKEN", "")
# How long a request may wait for the GPU before we answer 503. Vexa's client
# treats 503 as "busy, retry", which beats queueing stale audio for live captions.
QUEUE_TIMEOUT_S = float(os.getenv("WHISPER_QUEUE_TIMEOUT_S", "10"))

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper(), format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("whisper-server")

app = FastAPI(title="vexa-local-mac whisper server")

# MLX is not safe to call from several threads at once, so serialise inference.
_gpu_lock = threading.Lock()
_model_path: Optional[str] = None


@app.on_event("startup")
def _load_model() -> None:
    global _model_path
    log.info("Fetching model %s from Hugging Face (cached after first run)", MODEL_REPO)
    _model_path = snapshot_download(MODEL_REPO)
    with _gpu_lock:  # warm up: the first call loads weights onto the GPU
        mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=_model_path)
    log.info("Model ready: %s", _model_path)


@app.get("/health")
def health():
    return {"status": "ok" if _model_path else "loading", "model": MODEL_REPO}


@app.get("/v1/models")
def models():
    return {"object": "list", "data": [{"id": MODEL_REPO, "object": "model"}]}


def _transcribe(path: str, language: Optional[str], prompt: Optional[str], temperature: float,
                task: str, words: bool) -> tuple:
    if not _gpu_lock.acquire(timeout=QUEUE_TIMEOUT_S):
        raise HTTPException(status_code=503, detail="Transcriber busy", headers={"Retry-After": "1"})
    try:
        t0 = time.perf_counter()
        result = mlx_whisper.transcribe(
            path,
            path_or_hf_repo=_model_path,
            language=language or None,
            initial_prompt=prompt or None,
            temperature=temperature,
            task="translate" if task == "translate" else "transcribe",
            condition_on_previous_text=False,
            word_timestamps=words,
        )
        return result, time.perf_counter() - t0
    finally:
        _gpu_lock.release()


@app.post("/v1/audio/transcriptions")
async def transcriptions(request: Request):
    if API_TOKEN and request.headers.get("authorization") != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid or missing API token")
    if _model_path is None:
        raise HTTPException(status_code=503, detail="Model still loading", headers={"Retry-After": "2"})

    form = await request.form()
    upload = form.get("file")
    if upload is None or not hasattr(upload, "read"):
        raise HTTPException(status_code=400, detail="Missing 'file' upload")

    def field(name: str, default: str = "") -> str:
        value = form.get(name)
        return value if isinstance(value, str) else default

    response_format = field("response_format", "json")
    task = field("task", "transcribe")
    try:
        temperature = float(field("temperature", "0") or 0)
    except ValueError:
        temperature = 0.0
    granularities = form.getlist("timestamp_granularities") + form.getlist("timestamp_granularities[]")
    want_words = response_format == "verbose_json" and any("word" in str(g) for g in granularities)

    suffix = os.path.splitext(getattr(upload, "filename", "") or "")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix) as tmp:
        tmp.write(await upload.read())
        tmp.flush()
        result, elapsed = await run_in_threadpool(
            _transcribe, tmp.name, field("language") or None, field("prompt") or None,
            temperature, task, want_words)

    segments = result.get("segments", [])
    duration = segments[-1]["end"] if segments else 0.0
    log.info("Transcribed %.1fs audio in %.2fs (%d segments)", duration, elapsed, len(segments))

    if response_format == "text":
        return PlainTextResponse(result.get("text", ""))

    body = {"text": result.get("text", "")}
    if response_format == "verbose_json":
        out_segments = []
        all_words = []
        for i, s in enumerate(segments):
            seg = {
                "id": s.get("id", i),
                "seek": s.get("seek", 0),
                "start": s.get("start", 0.0),
                "end": s.get("end", 0.0),
                "text": s.get("text", ""),
                "tokens": s.get("tokens", []),
                "temperature": s.get("temperature", temperature),
                "avg_logprob": s.get("avg_logprob", 0.0),
                "compression_ratio": s.get("compression_ratio", 1.0),
                "no_speech_prob": s.get("no_speech_prob", 0.0),
            }
            if want_words:
                seg["words"] = [
                    {"word": w.get("word", ""), "start": w.get("start", 0.0), "end": w.get("end", 0.0),
                     "probability": w.get("probability", 0.0)}
                    for w in s.get("words", [])
                ]
                all_words.extend(seg["words"])
            out_segments.append(seg)
        body.update({"task": task, "language": result.get("language"), "duration": duration,
                     "segments": out_segments})
        if want_words:
            body["words"] = all_words
    return JSONResponse(body)
