#!/usr/bin/env bash
# Speak a sentence with macOS `say` and send it to the Whisper server, once
# from the Mac and once from inside a container (the path WhisperLive uses).
. "$(dirname "$0")/lib.sh"
load_env

# Under the project (inside $HOME) so Colima can share it with containers;
# macOS temp folders are not mounted into the Colima VM.
tmp="$(mktemp -d "$RUN_DIR/test-whisper.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
say -o "$tmp/t.aiff" "Hello, this is a test of local meeting transcription."
ffmpeg -loglevel error -y -i "$tmp/t.aiff" -ar 16000 -ac 1 "$tmp/t.wav"

info "From the Mac"
"$WHISPER_DIR/.venv/bin/python" - "$(whisper_url)" "$REMOTE_TRANSCRIBER_API_KEY" "$tmp/t.wav" <<'PY'
import sys, time, json, urllib.request, uuid
url, key, path = sys.argv[1:4]
boundary = uuid.uuid4().hex
audio = open(path, "rb").read()
parts = []
for k, v in {"model": "default", "response_format": "verbose_json", "temperature": "0"}.items():
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + audio + b"\r\n")
parts.append(f"--{boundary}--\r\n".encode())
req = urllib.request.Request(url + "/v1/audio/transcriptions", data=b"".join(parts), headers={
    "Authorization": f"Bearer {key}", "Content-Type": f"multipart/form-data; boundary={boundary}"})
t = time.time()
body = json.loads(urllib.request.urlopen(req, timeout=60).read())
print(f"  {time.time()-t:.2f}s  [{body['language']}] {body['text'].strip()}")
PY

info "From inside a container (via host.docker.internal)"
docker run --rm --add-host host.docker.internal:host-gateway -v "$tmp:/a:ro" curlimages/curl:8.10.1 \
  -sS --max-time 60 -H "Authorization: Bearer $REMOTE_TRANSCRIBER_API_KEY" \
  -F file=@/a/t.wav -F model=default -F response_format=json "$REMOTE_TRANSCRIBER_URL"
echo
