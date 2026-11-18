#!/usr/bin/env bash
# Control the native Whisper server: whisper.sh start|stop|restart|status
. "$(dirname "$0")/lib.sh"
load_env

start_whisper() {
  if whisper_running; then
    ok "Whisper already running (pid $(cat "$RUN_DIR/whisper.pid"))"
  else
    [ -x "$WHISPER_DIR/.venv/bin/uvicorn" ] || die "Whisper is not installed. Run 'make setup' first."
    info "Starting Whisper on $(whisper_url) with $WHISPER_MODEL"
    (
      cd "$WHISPER_DIR"
      WHISPER_API_TOKEN="$REMOTE_TRANSCRIBER_API_KEY" WHISPER_MODEL="$WHISPER_MODEL" \
        nohup .venv/bin/uvicorn server:app --host "${WHISPER_HOST:-127.0.0.1}" --port "${WHISPER_PORT:-8083}" \
        >> "$LOG_DIR/whisper.log" 2>&1 < /dev/null &
      echo $! > "$RUN_DIR/whisper.pid"
    )
  fi
  # First start of a new model includes the Hugging Face download.
  for _ in $(seq 1 600); do
    http_ok "$(whisper_url)/health" && break
    whisper_running || die "Whisper exited. See logs/whisper.log"
    sleep 1
  done
  http_ok "$(whisper_url)/health" || die "Whisper did not become ready. See logs/whisper.log"
  ok "Whisper ready"
}

stop_whisper() {
  if whisper_running; then
    info "Stopping Whisper"
    pid="$(cat "$RUN_DIR/whisper.pid")"
    kill "$pid"
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$RUN_DIR/whisper.pid"
}

case "${1:-status}" in
  start)   start_whisper ;;
  stop)    stop_whisper; ok "Whisper stopped" ;;
  restart) stop_whisper; start_whisper ;;
  status)  if whisper_running && http_ok "$(whisper_url)/health"; then ok "Whisper up at $(whisper_url)"; else warn "Whisper not running"; exit 1; fi ;;
  *)       die "Usage: whisper.sh start|stop|restart|status" ;;
esac
