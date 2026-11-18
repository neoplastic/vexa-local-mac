.PHONY: help setup start stop stop-all restart status logs whisper-logs desktop desktop-logs user test-whisper update cleanup cleanup-dry-run app app-test install

help:
	@echo "make setup          One-time: fetch Vexa, write .env, download Whisper model, build images"
	@echo "make start          Start Colima, native Whisper and the Vexa containers"
	@echo "make stop           Stop Vexa and Whisper (Colima keeps running)"
	@echo "make stop-all       Stop Vexa, Whisper and the Colima VM"
	@echo "make status         Show what is running"
	@echo "make logs           Follow Vexa container logs"
	@echo "make whisper-logs   Follow the native Whisper log"
	@echo "make desktop        Start only the desktop host for the browser extension (Meet, Zoom)"
	@echo "make desktop-logs   Follow the desktop host log"
	@echo "make user EMAIL=x   Create a Vexa user and print an API key"
	@echo "make test-whisper   Send a spoken test clip to Whisper"
	@echo "make update         Re-pull Vexa images and rebuild the bot (after changing VEXA_REF)"
	@echo "make cleanup        Remove superseded Vexa images, stopped bots and the build cache"
	@echo "make cleanup-dry-run  Show what 'make cleanup' would remove and the space it frees"
	@echo "make app            Build the Vexa Local macOS app into app/build/"
	@echo "make install        Build the app and install it in /Applications"
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
	  scripts/desktop.sh status || true; \
	  docker info >/dev/null 2>&1 && compose ps --format "table {{.Service}}\t{{.Status}}" || true'

logs:
	@bash -c '. scripts/lib.sh; compose logs -f --tail 100'

whisper-logs:
	@tail -f logs/whisper.log

desktop:
	@scripts/desktop.sh start

desktop-logs:
	@tail -f logs/desktop.log

user:
	@scripts/create-user.sh "$(EMAIL)" "$(NAME)"

test-whisper:
	@scripts/test-whisper.sh

update:
	@scripts/setup.sh

cleanup:
	@scripts/cleanup.sh

cleanup-dry-run:
	@scripts/cleanup.sh --dry-run

app:
	@app/build-app.sh

# Copy the app into /Applications and remember this project folder, so the
# installed copy (which no longer sits inside the project) still finds it.
install: app
	@if pgrep -x VexaLocal >/dev/null; then echo "Quit Vexa Local first, then run make install again."; exit 1; fi
	@rm -rf "/Applications/Vexa Local.app"
	@ditto "app/build/Vexa Local.app" "/Applications/Vexa Local.app"
	@defaults write io.github.vexa-local-mac vexa.projectPath "$(CURDIR)"
	@echo "Installed /Applications/Vexa Local.app (project folder: $(CURDIR))"

app-test:
	@cd app && xcrun swift test
