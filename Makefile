.PHONY: help setup start stop stop-all restart status logs whisper-logs user test-whisper update app app-test bot-screenshots

help:
	@echo "make setup          One-time: fetch Vexa, write .env, download Whisper model, build images"
	@echo "make start          Start Colima, native Whisper and the Vexa containers"
	@echo "make stop           Stop Vexa and Whisper (Colima keeps running)"
	@echo "make stop-all       Stop Vexa, Whisper and the Colima VM"
	@echo "make status         Show what is running"
	@echo "make logs           Follow Vexa container logs"
	@echo "make whisper-logs   Follow the native Whisper log"
	@echo "make user EMAIL=x   Create a Vexa user and print an API key"
	@echo "make test-whisper   Send a spoken test clip to Whisper"
	@echo "make update         Rebuild Vexa images (after changing VEXA_REF)"
	@echo "make bot-screenshots Copy the meeting bot's join screenshots to logs/"
	@echo "make app            Build the Vexa Local macOS app into app/build/"
	@echo "make app-test       Run the app's unit tests"

setup:
	@scripts/setup.sh

start:
	@scripts/start.sh

stop:
	@scripts/stop.sh

stop-all:
	@scripts/stop.sh --colima

restart: stop start

status:
	@bash -c '. scripts/lib.sh; load_env; \
	  colima status --profile "$$COLIMA_PROFILE" 2>&1 | tail -1; \
	  if whisper_running && http_ok "$$(whisper_url)/health"; then ok "Whisper up at $$(whisper_url)"; else warn "Whisper not running"; fi; \
	  docker info >/dev/null 2>&1 && compose ps --format "table {{.Service}}\t{{.Status}}" || true'

logs:
	@bash -c '. scripts/lib.sh; compose logs -f --tail 100'

whisper-logs:
	@tail -f logs/whisper.log

user:
	@scripts/create-user.sh "$(EMAIL)" "$(NAME)"

test-whisper:
	@scripts/test-whisper.sh

update:
	@scripts/setup.sh

bot-screenshots:
	@mkdir -p logs/bot-screenshots
	@docker run --rm -v vexa-bot-screenshots:/s:ro -v "$(CURDIR)/logs/bot-screenshots:/out" alpine:3.20 sh -c 'cp -a /s/. /out/ && ls -1t /out | head -20'
	@echo "Copied to logs/bot-screenshots/"

app:
	@app/build-app.sh

app-test:
	@cd app && xcrun swift test
