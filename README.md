# vexa-local-mac

Run [Vexa](https://github.com/Vexa-ai/vexa) v0.12, the open-source meeting transcriber, entirely on an Apple Silicon Mac:

- **Vexa runs in Docker on [Colima](https://github.com/abiosoft/colima).** You don't need Docker Desktop. Every image is native ARM, so nothing runs under Rosetta.
- **Whisper runs natively on macOS** with [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper), so it uses the Mac's GPU. Models download from Hugging Face.
- **Vexa Local**, a small macOS app, lets you pick a Whisper model, paste a meeting link, and get the transcript saved as Markdown in a folder you choose.

No audio leaves your machine.

## Ways to capture a meeting

| Route | Platforms | How |
|---|---|---|
| **Browser extension** (recommended) | Google Meet, Zoom, Microsoft Teams | You join the meeting yourself in Chrome. Vexa's extension sends the call audio and your microphone to a local "desktop host" that transcribes it. Speakers are named. |
| **Bot** (backup) | Microsoft Teams only | Vexa sends a headless browser into the meeting as a guest. Someone lets it in from the lobby. Speakers aren't named. Google and Zoom refuse bots ([Vexa #2059](https://github.com/Vexa-ai/vexa/issues/2059), [#938](https://github.com/Vexa-ai/vexa/issues/938)). |
| **Record** (no Vexa) | Anything that plays sound on the Mac | The app records your microphone and the Mac's sound output and sends them straight to Whisper. |

All routes use the same native Whisper server and save Markdown files in your transcripts folder.

```
┌──────────── Colima VM (Docker) ────────────┐          ┌──────────── macOS ─────────────┐
│ Teams bot (Chromium) ──audio──▶ meeting-api ├──HTTP──▶│ whisper-server :8083           │
│ gateway :18056 · admin :18057 · mcp         │          │ (mlx-whisper, Metal)           │
│ terminal (web app) :13000 · postgres · redis│          │            ▲                   │
└─────────────────────────────────────────────┘          │ desktop host :8056 / :9099     │
                                                         │            ▲ audio             │
                                                         │ Chrome + Vexa extension        │
                                                         │ (the meeting tab you joined)   │
                                                         └────────────────────────────────┘
```

## Requirements

- An Apple Silicon Mac (M1 or later). 16 GB of memory or more is recommended.
- About 25 GB of free disk space for images and a model.

The app's setup assistant checks and installs the rest:

- Apple's Command Line Tools (for git, and to build the app).
- [Homebrew](https://brew.sh) and these packages: `brew install colima docker docker-compose docker-buildx uv ffmpeg pnpm`
- Node 20 or newer. A Node from nvm, fnm or Volta is fine. Otherwise: `brew install node`
- Google Chrome, for the browser extension (optional).

## Quick start

1. Get the app. Download or clone this repo, then build and install the app:

   ```bash
   git clone https://github.com/neoplastic/vexa-local-mac
   cd vexa-local-mac
   make install   # builds the app and copies it to /Applications
   ```

   Building needs Apple's Command Line Tools. macOS offers to install them the first time you run `git`.

2. Open **Vexa Local** from Applications.
3. Follow the setup assistant. It opens by itself the first time, and whenever something is missing. Press **Set up everything**, or use the button on each row.

The assistant has one row per thing the app needs, in order:

| Row | What it does |
|---|---|
| Command Line Tools | Opens Apple's installer. |
| Homebrew | Shows the install command to paste into Terminal (it needs your password). |
| Homebrew tools | Installs the missing packages with `brew install`. |
| Node 20 or newer | Finds the Node your scripts will use. Installs one only if none is new enough. |
| Docker compose and buildx | Fixes `~/.docker/config.json` if Docker can't find Homebrew's plugins, or still uses Docker Desktop's login helper. It saves a backup first. |
| Project folder | Choose this folder, or download it. |
| App installed in Applications | Copies the app to /Applications and reopens it from there. |
| Vexa set up | Runs `scripts/setup.sh`: about 10-20 GB of downloads, 20-40 minutes the first time. |
| Services running | Starts Colima, Whisper, Vexa and the extension host. |
| Google Chrome (optional) | Installs Chrome with Homebrew, or links to its download page. |
| Browser extension (optional) | The extension steps below. Tick **Done** when it's loaded. |
| Permissions | Microphone and Screen & System Audio, for the Record page. macOS asks the first time you record. |

**Set up everything** runs the automatic steps in order. It stops when it needs you, for example to install Homebrew. Reopen the assistant any time from **Settings**. While something required is missing, the sidebar shows a warning you can click.

Prefer the command line? This does the same without the assistant:

```bash
brew install colima docker docker-compose docker-buildx uv ffmpeg pnpm node
make setup     # fetch Vexa, write .env, download the Whisper model, build the bot, extension and app (20-40 min the first time)
make start     # start Colima, Whisper, Vexa and the desktop host
```

`make setup` also builds the app and copies it to /Applications. It skips the copy if the app is open.

Paste a meeting link in the app. It shows the extension steps:

1. Once: open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose `vexa/clients/extension/dist`.
2. Once: copy your API key from the app (**Copy API key**) and paste it in the extension's settings.
3. Each meeting: join in Chrome, click the Vexa icon on the meeting tab, and press **Start**. Set the language to English (or yours) rather than auto-detect. Auto-detect sometimes invents text in another language during silence.

Start from the meeting tab. If you start from any other tab, the extension records a microphone-only "note". If you're muted in the meeting, your side isn't captured.

For Teams, the app also offers **Or send a Vexa bot instead** as a backup. Let the bot in from the lobby.

Transcripts go to `~/Documents/Vexa Transcripts` (you can change this) and update every few seconds while the meeting runs.

## The app

| Pane | What it does |
|---|---|
| **Join meeting** | Paste a link, code or invite text. The app detects Meet, Teams or Zoom and shows the extension steps, a **Copy API key** button, and whether the desktop host is running. For Teams you can also send a bot instead. |
| **Transcripts** | Every meeting from either route, with its source (bot or extension), live status, and the reason if a bot failed. Open the transcript, show it in Finder, or make a bot leave. |
| **Record** | A fallback that needs only Whisper: no Vexa, Docker, bot or extension. Records your microphone ("You") and the Mac's sound output ("Others"), sends speech to Whisper and writes the transcript as it goes. Because it listens to the Mac itself, it should work with any call app, including FaceTime and the desktop Teams and Zoom apps. |
| **Whisper models** | Downloaded models with their total size, and models known to work with mlx-whisper. Download, delete, or switch the model Whisper uses. More models from Hugging Face are under a disclosure triangle. |
| **Storage** | How much disk Vexa's Docker images, containers, volumes and build cache use, with cleanup buttons. |
| **Connect Claude** | How to give Claude (Desktop or Code) access to your meetings through Vexa's MCP server. |
| **Settings** | Project folder, transcript folder, API key (show, hide, copy), the setup assistant, start/stop controls, and "Stop Vexa when quitting". |

It recognises:

| Input | Detected as |
|---|---|
| `https://meet.google.com/abc-defg-hij`, `abc-defg-hij` | Google Meet |
| `https://teams.live.com/meet/9387167464734?p=…` | Teams personal |
| `https://teams.microsoft.com/meet/123456789012?p=…`, `…/l/meetup-join/…` | Teams work or school |
| `Meeting ID: 312 004 451 623  Passcode: Ux7Ab2` | Teams. For a bot, you pick work/school or personal. |
| `https://us05web.zoom.us/j/81234567890?pwd=…` | Zoom |

The app creates a Vexa API key on first use, using `ADMIN_TOKEN` from `.env`. It stores settings, including the key, in the app's preferences (`io.github.vexa-local-mac`).

### Record (no Vexa needed)

Vexa changes quickly and meeting sites keep fighting bots. The Record page is the safety net. It only needs the Whisper server (`scripts/whisper.sh start`, or the button on the page).

- The first time, macOS asks for **Microphone** and **Screen & System Audio Recording** access. The second one is how a Mac app hears other apps' sound; the app only keeps the sound. After allowing it, quit and reopen the app.
- Use headphones. Without them, your microphone also picks up the other people, and their words appear twice.
- Silence is never sent to Whisper, and common Whisper "hallucinations" (like "Thanks for watching") are dropped.
- "Keep the audio" saves a WAV per lane next to the transcript (about 115 MB per hour each).
- The app is signed ad hoc, so macOS asks for these permissions again after each rebuild. To stop that, create a code-signing certificate named "Vexa Local Dev" in Keychain Access (Certificate Assistant → Create a Certificate → Code Signing), or set `VEXA_SIGN_IDENTITY`, then run `make app`.

When you quit, the app stops the bots, the Vexa containers, the desktop host and Whisper (Colima keeps running). It asks first if a meeting is still being transcribed. You can turn this off in Settings.

## Command line

| Command | |
|---|---|
| `make start` / `make stop` | Start or stop Whisper, Vexa and the desktop host. `make stop-all` also stops Colima. |
| `make status` | Show what's running. |
| `make desktop` | Start only Whisper and the desktop host (enough for Meet and Zoom). |
| `make logs`, `make whisper-logs`, `make desktop-logs` | Follow the logs. |
| `make user EMAIL=you@example.com` | Create a Vexa user and print an API key. |
| `make test-whisper` | Speak a test sentence and transcribe it, from the Mac and from inside a container. |
| `scripts/desktop.sh selftest` | Stream a spoken clip into the desktop host, like the extension does, and print the transcript. |
| `make update` | Re-pull Vexa images and rebuild the bot (after changing `VEXA_REF`). |
| `make cleanup`, `make cleanup-dry-run` | Remove superseded Vexa images, stopped bots and the build cache. |
| `make app`, `make install`, `make app-test` | Build the app, build it and copy it to /Applications, or run its unit tests. |

Send a bot without the app:

```bash
curl -X POST http://localhost:18056/bots -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"platform": "teams", "native_meeting_id": "9387167464734", "passcode": "…"}'
curl http://localhost:18056/transcripts/teams/9387167464734 -H "X-API-Key: $KEY"
```

Extension transcripts: `curl http://localhost:8056/bots` lists them. The desktop host keeps them in memory only, so the app saves them to disk.

Vexa web app: http://localhost:13000 · API gateway: http://localhost:18056 · MCP: http://localhost:18056/mcp

## Choosing a Whisper model

| Model | Size | Notes |
|---|---|---|
| `whisper-large-v3-turbo` | 1.6 GB | Default. Best balance of speed and accuracy. |
| `whisper-large-v3-turbo-q4` | 0.5 GB | Lighter on memory, slightly less accurate. |
| `whisper-large-v3-mlx` | 3.1 GB | Most accurate, 2-3x slower. |
| `distil-whisper-large-v3` | 1.5 GB | Fast, English only. |
| `whisper-small-mlx` | 0.5 GB | For 8 GB Macs. |

On an M1 Max, Turbo transcribes 5 seconds of speech in under a second. To switch models without the app, set `WHISPER_MODEL` in `.env` and run `scripts/whisper.sh restart`.

Only repos with `weights.npz` or `weights.safetensors` work with mlx-whisper. The app hides the rest.

## How it fits together

- `scripts/setup.sh` clones Vexa at a pinned tag (`VEXA_REF` in `scripts/lib.sh`) into `./vexa` and applies the fixes in `patches/`. It writes `.env` with random secrets, pulls Vexa's published ARM images, builds the bot natively, and builds the desktop host and the extension.
- Vexa's own `deploy/compose/docker-compose.yml` runs as the Compose project `vexa-v012`. Its ports are moved up (18056, 18057, 13000) so they don't clash with the desktop host.
- `whisper-server/server.py` is an OpenAI-compatible `/v1/audio/transcriptions` endpoint, with word timestamps and a bearer token. It listens on `127.0.0.1:8083`. Containers reach it through `host.docker.internal`, and the desktop host calls it directly.
- `scripts/desktop.sh` runs Vexa's desktop host (`core/meetings/services/desktop`) with Node. It listens for the extension on `ws://localhost:9099/ingest` and serves transcripts on `http://localhost:8056`.
- `scripts/bot-view.sh` shows a running bot's screen in your browser (noVNC on `localhost:6080`), for debugging joins.

### Fixes applied to upstream Vexa

| Patch | Why |
|---|---|
| `0001-humanized-pointer-too-close.patch` | The Meet bot replays a recorded mouse path towards each button. When the pointer already sat on or near the button, no recorded path fit and the click failed. The bot now moves the pointer away first. (Meet still refuses bots, so this only matters once Google stops doing that.) |
| `0002-extension-teams-capture-audio-element.patch` | On Teams, Chrome's tab capture records pure silence (−91 dB) even while you hear the call, so the extension transcribed nothing. The extension now reads Teams' call audio straight from the page's `<audio>` element and captures your microphone as "You", like it does for Google Meet. Speaker names still come from Teams' speaking indicators. The extension no longer saves a recording file for Teams calls. |

## Limits

- **Extension on Teams** depends on `0002-extension-teams-capture-audio-element.patch`. Upstream, the extension records only silence on Teams. If a Vexa update breaks the patch, use the Teams bot or the Record page.
- **The Teams bot** joins as a guest. Organisations that block anonymous guests will block it. Speakers aren't named in bot transcripts.
- **Google Meet** and **Zoom** refuse bots right now, so they only work through the extension or the Record page. Zoom transcripts show "You" and everyone else as one lane.
- **When Vexa breaks:** the **Record** page doesn't use Vexa at all (see below).
- **FaceTime** and desktop call apps: only through the Record page.

## Troubleshooting

- **`docker-credential-desktop: executable file not found`:** remove the `"credsStore": "desktop"` line from `~/.docker/config.json`. Docker Desktop leaves it behind. The setup assistant's **Fix** button does this for you.
- **`docker: 'compose' is not a docker command`:** Docker can't find Homebrew's plugins. Add `"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]` to `~/.docker/config.json`, or press **Fix** in the setup assistant.
- **`Cannot connect to the Docker daemon`:** another tool may have switched Docker's context. Run `docker context use colima`. The scripts set `DOCKER_HOST` themselves.
- **Whisper won't start:** check `logs/whisper.log`. The first start of a new model includes the download.
- **The extension records nothing:** check the desktop host is up (`make status`), that the API key is pasted in the extension, and that you pressed Start on the meeting tab. Unmute yourself, or your side stays empty. `make desktop-logs` shows `ch999=` (the other people) and `ch1000=` (you) counting up while audio flows. On Teams, the page console also prints a `[teams-audio]` status line every 5 seconds.
- **The bot never joins:** check the reason on the Transcripts page, then `make logs`. `scripts/bot-view.sh` shows what the bot sees.

## License

MIT, see [LICENSE](LICENSE). This applies to the code in this repository. Vexa itself is Apache-2.0. It is downloaded at setup time, and this repo doesn't include it.
