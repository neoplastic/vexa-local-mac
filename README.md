# vexa-local-mac

Run [Vexa](https://github.com/SaharCarmel/vexa), the open-source meeting bot, entirely on an Apple Silicon Mac:

- **Vexa runs in Docker on [Colima](https://github.com/abiosoft/colima).** You don't need Docker Desktop.
- **Whisper runs natively on macOS** with [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper), so it uses the Mac's GPU. Models download from Hugging Face.
- **Vexa Local**, a small macOS app, lets you pick a Whisper model, paste a Google Meet or Teams link, send a bot, and get the transcript saved as Markdown in a folder you choose.

No audio leaves your machine.

```
┌──────────── Colima VM (Docker) ─────────────┐         ┌──────── macOS ────────┐
│ meeting bot ──audio──▶ WhisperLive ──HTTP───┼────────▶│ whisper-server        │
│ (Chromium/Edge)            │                │  host.  │ (mlx-whisper, Metal)  │
│                            ▼                │  docker.│ 127.0.0.1:8083        │
│ api-gateway ◀── transcription-collector     │ internal└───────────────────────┘
│ admin-api · bot-manager · postgres · redis  │
└─────────────────────────────────────────────┘
```

## Requirements

- An Apple Silicon Mac (M1 or later). 16 GB of memory or more is recommended.
- Homebrew packages: `brew install colima docker docker-compose docker-buildx uv ffmpeg`
- Xcode or the Command Line Tools, to build the app.
- About 25 GB of free disk space for images and a model.

## Quick start

```bash
git clone https://github.com/neoplastic/vexa-local-mac
cd vexa-local-mac
make setup     # fetch Vexa, write .env, download the Whisper model, build images (20-40 min the first time)
make start     # start Colima, Whisper and Vexa
make app       # build the macOS app
open "app/build/Vexa Local.app"
```

In the app, paste a meeting link and click **Send bot to meeting**. Someone in the meeting may need to let the bot in from the lobby. The transcript is written to `~/Documents/Vexa Transcripts` (you can change this) and updates every few seconds while the meeting runs.

## The app

| Pane | What it does |
|---|---|
| **Join meeting** | Paste a link, code or invite text. The app detects Google Meet or Teams and fills in the meeting ID and passcode. Set the bot's name, language and output folder. |
| **Transcripts** | Every bot you've sent, with live status (joining, waiting in lobby, active, completed). Open the transcript, show it in Finder, or make the bot leave. |
| **Whisper models** | Recommended models and every MLX Whisper model on Hugging Face, with sizes. Download, delete, or switch the model Whisper uses. |
| **Settings** | Project folder, default transcript folder, API key, and start/stop controls. |

It recognises:

| Input | Detected as |
|---|---|
| `https://meet.google.com/abc-defg-hij`, `abc-defg-hij`, `abcdefghij` | Google Meet |
| `https://teams.live.com/meet/9387167464734?p=…` | Teams (personal) |
| `https://teams.microsoft.com/meet/123456789012?p=…`, `…/v2/?meetingjoin=true#/meet/…` | Teams (work or school) |
| `https://teams.microsoft.com/l/meetup-join/…` | Teams (older link, passed through to the bot) |
| `Meeting ID: 312 004 451 623  Passcode: Ux7Ab2` (pasted invite text), or a bare ID | Teams. You pick work/school or personal. |

The app creates a Vexa API key on first use, using `ADMIN_API_TOKEN` from `.env`. It stores settings, including the API key, in the app's preferences (`io.github.vexa-local-mac`).

## Command line

| Command | |
|---|---|
| `make start` / `make stop` | Start or stop Whisper and Vexa. `make stop-all` also stops Colima. |
| `make status` | Show what's running. |
| `make logs`, `make whisper-logs` | Follow the logs. |
| `make user EMAIL=you@example.com` | Create a Vexa user and print an API key. |
| `make test-whisper` | Speak a test sentence and transcribe it, from the Mac and from inside a container. |
| `make app`, `make app-test` | Build the app or run its unit tests. |

Send a bot without the app:

```bash
curl -X POST http://localhost:8056/bots -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"platform": "google_meet", "native_meeting_id": "abc-defg-hij"}'
curl http://localhost:8056/transcripts/google_meet/abc-defg-hij -H "X-API-Key: $KEY"
```

API docs: http://localhost:8056/docs · Dashboard: http://localhost:3001 (password in `.env`) · MCP server: http://localhost:18888

## Choosing a Whisper model

| Model | Size | Notes |
|---|---|---|
| `whisper-large-v3-turbo` | 1.6 GB | Default. Best balance of speed and accuracy. |
| `whisper-large-v3-turbo-q4` | 0.5 GB | Lighter on memory, slightly less accurate. |
| `whisper-large-v3-mlx` | 3.1 GB | Most accurate, 2-3x slower. |
| `distil-whisper-large-v3` | 1.5 GB | Fast, English only. |
| `whisper-small-mlx` | 0.5 GB | For 8 GB Macs. |

On an M1 Max, Turbo transcribes 5 seconds of speech in under a second. To switch models without the app, set `WHISPER_MODEL` in `.env` and run `scripts/whisper.sh restart`.

Only repos with `weights.npz` or `weights.safetensors` work with mlx-whisper. Repos ending in `-4bit`, `-8bit` or containing `-asr-` are packaged for other libraries, and the app marks them "Not compatible".

## How it fits together

- `scripts/setup.sh` clones Vexa at a pinned commit into `./vexa` and applies the fixes in `patches/`. It also writes `.env` with random secrets and builds the images.
- `compose.mac.yml` is layered on top of Vexa's own compose files.
- `whisper-server/server.py` is an OpenAI-compatible `/v1/audio/transcriptions` endpoint. Vexa's WhisperLive uses it as a "remote" transcriber. It listens on `127.0.0.1` only, and Colima containers reach it through `host.docker.internal`.
- `COMPOSE_PROJECT_NAME=vexa` matters: bot-manager attaches meeting bots to the `vexa_vexa_default` network.

### Fixes applied to upstream Vexa

| Patch | Why |
|---|---|
| `0001-vexa-bot-bookworm-any-arch.patch` | The bot's first build stage used Debian 11 (end of life in 2026, its repo now returns 404s) and was pinned to amd64. It now uses Debian 12 and builds for any architecture. |
| `0002-fix-missing-python-deps.patch` | admin-api was missing `httpx`, calendar-service was missing `email-validator`, and mcp needs `mcp<2` to work with `fastapi-mcp` 0.4. |
| `0003-api-gateway-longer-timeout.patch` | The gateway gave up on internal requests after 5 seconds. Starting a bot can take longer, which showed up as "Service Unavailable (HTTP 503)" even though the bot launched. |
| `0004-bot-shm-and-screenshots.patch` | Gives bot containers 1 GB of shared memory (Chromium can hang with Docker's 64 MB default). Also keeps the bot's join screenshots in the `vexa-bot-screenshots` volume; `make bot-screenshots` copies them out. |

`compose.mac.yml` also turns off MinIO by default, because the `minio/mc` image is no longer on Docker Hub. Recording storage uses local disk (`STORAGE_BACKEND=local`). Recordings are off by default anyway.

## Limits

- **Platforms:** Google Meet and Microsoft Teams. Zoom needs Zoom's proprietary Meeting SDK, which isn't included. FaceTime isn't supported.
- **Guests:** the bot joins as a guest. Organisations that block anonymous guests will block it.
- **Native ARM bot:** upstream builds the bot as `linux/amd64` so it can include Microsoft Edge for Teams. Here it builds natively for ARM, and Teams uses the bundled Chromium (the bot falls back to it automatically). Everything else (Colima, all Vexa services, Postgres, Redis, Whisper) is ARM too, so nothing runs under Rosetta. To get Edge back, set `BOT_PLATFORM=linux/amd64` in `.env` and run `make setup`. That bot runs under Rosetta and is much slower.

## Troubleshooting

- **`docker-credential-desktop: executable file not found`:** remove the `"credsStore": "desktop"` line from `~/.docker/config.json`. Docker Desktop leaves it behind.
- **Whisper won't start:** check `logs/whisper.log`. The first start of a new model includes the download.
- **The bot never joins:** run `make logs` and look at `bot-manager`, then `docker ps -a` for the `vexa-bot` container and its logs.

## License

MIT, see [LICENSE](LICENSE). This applies to the code in this repository. Vexa itself is Apache-2.0. It is downloaded at setup time, and this repo doesn't include it.
