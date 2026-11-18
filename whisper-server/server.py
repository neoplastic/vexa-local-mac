"""
OpenAI-compatible transcription server for Apple Silicon, backed by mlx-whisper.

Exposes POST /v1/audio/transcriptions, returning the same `verbose_json` shape
as OpenAI's API (text, language, duration, segments[]). Vexa's WhisperLive
"remote" backend talks to this endpoint.

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
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
from huggingface_hub import snapshot_download

MODEL_REPO = os.getenv("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
API_TOKEN = os.getenv("WHISPER_API_TOKEN", "")
# How long a request may wait for the GPU before we answer 503. WhisperLive
# treats 503 as "busy": it keeps buffering audio and retries with a fresher
# window, which is better for live captions than queueing stale audio.
QUEUE_TIMEOUT_S = float(os.getenv("WHISPER_QUEUE_TIMEOUT_S", "10"))

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("whisper-server")

app = FastAPI(title="vexa-local-mac whisper server")

# MLX is not safe to call from several threads at once, so serialise inference.
_gpu_lock = threading.Lock()
_model_path: Optional[str] = None


def _check_auth(authorization: Optional[str]) -> None:
    if not API_TOKEN:
        return
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid or missing API token")


@app.on_event("startup")
def _load_model() -> None:
    global _model_path
    log.info("Fetching model %s from Hugging Face (cached after first run)", MODEL_REPO)
    _model_path = snapshot_download(MODEL_REPO)
    # Warm up: the first call loads weights onto the GPU.
    import numpy as np

    with _gpu_lock:
        mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=_model_path)
    log.info("Model ready: %s", _model_path)


@app.get("/health")
def health():
    return {"status": "ok" if _model_path else "loading", "model": MODEL_REPO}


@app.get("/v1/models")
def models():
    return {"object": "list", "data": [{"id": MODEL_REPO, "object": "model"}]}


@app.post("/v1/audio/transcriptions")
def transcriptions(
    file: UploadFile = File(...),
    model: str = Form("default"),  # accepted for API compatibility, ignored
    language: Optional[str] = Form(None),
    prompt: Optional[str] = Form(None),
    response_format: str = Form("json"),
    temperature: float = Form(0.0),
    task: str = Form("transcribe"),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)
    if _model_path is None:
        raise HTTPException(status_code=503, detail="Model still loading", headers={"Retry-After": "2"})

    suffix = os.path.splitext(file.filename or "")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix) as tmp:
        tmp.write(file.file.read())
        tmp.flush()

        if not _gpu_lock.acquire(timeout=QUEUE_TIMEOUT_S):
            raise HTTPException(status_code=503, detail="Transcriber busy", headers={"Retry-After": "1"})
        try:
            t0 = time.perf_counter()
            result = mlx_whisper.transcribe(
                tmp.name,
                path_or_hf_repo=_model_path,
                language=language or None,
                initial_prompt=prompt or None,
                temperature=temperature,
                task="translate" if task == "translate" else "transcribe",
                condition_on_previous_text=False,
            )
            elapsed = time.perf_counter() - t0
        finally:
            _gpu_lock.release()

    segments = result.get("segments", [])
    duration = segments[-1]["end"] if segments else 0.0
    log.info("Transcribed %.1fs audio in %.2fs (%d segments)", duration, elapsed, len(segments))

    if response_format == "text":
        return PlainTextResponse(result.get("text", ""))

    body = {"text": result.get("text", "")}
    if response_format == "verbose_json":
        body.update(
            {
                "task": task,
                "language": result.get("language"),
                "duration": duration,
                "segments": [
                    {
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
                    for i, s in enumerate(segments)
                ],
            }
        )
    return JSONResponse(body)
