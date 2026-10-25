.DEFAULT_GOAL := help
SHELL := /bin/bash
ROOT := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
PYTHON ?= python3
VENV_PYTHON ?= $(ROOT)/venv/bin/python
UNIT := whisper-ptt.service

.PHONY: help check test test-full deploy status logs start stop push publish update require-clean
help: ## List available commands
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  make %-12s %s\n", $$1, $$2}' "$(ROOT)/Makefile"

check: ## Check Python, shell, JSON, and GNOME JavaScript syntax
	@cd "$(ROOT)" && $(PYTHON) tools/check.py
	@cd "$(ROOT)" && bash -n bin/whisper-ptt install-links.sh mac/install.sh mac/package.sh tools/deploy.sh
	@cd "$(ROOT)" && node --input-type=module --check < gnome-extension/whisper-polish@felixfalling/extension.js

test: check ## Run fast control tests with mocked systemd and Ollama
	@cd "$(ROOT)" && $(PYTHON) -m unittest discover -s tests -p test_controls.py -v

test-full: test ## Run the complete daemon suite using the virtual environment
	@cd "$(ROOT)" && "$(VENV_PYTHON)" -m unittest discover -s tests -v

deploy: test ## Check and test, refresh links, then restart the local service
	@cd "$(ROOT)" && bash tools/deploy.sh

status: ## Show service state and recent startup output
	@systemctl --user status $(UNIT) --no-pager

logs: ## Show the last 40 service log lines (can contain dictated text)
	@journalctl --user -u $(UNIT) -n 40 --no-pager -o cat

start: ## Enable Whisper and cleanup now, without changing login preferences
	@$(PYTHON) "$(ROOT)/bin/whisper-ui.py" all on

stop: ## Stop Whisper and cleanup and request cleanup-model unloading
	@$(PYTHON) "$(ROOT)/bin/whisper-ui.py" all off

require-clean:
	@cd "$(ROOT)" && test -z "$$(git status --porcelain)" || { echo 'Commit or stash local changes before publishing or updating.' >&2; exit 1; }

push: test ## Check and test, then push existing commits to GitHub
	@$(MAKE) --no-print-directory -C "$(ROOT)" require-clean
	@cd "$(ROOT)" && git push -u origin HEAD

publish: ## Deploy locally, then push existing commits
	@$(MAKE) --no-print-directory -C "$(ROOT)" require-clean
	@$(MAKE) --no-print-directory -C "$(ROOT)" deploy
	@$(MAKE) --no-print-directory -C "$(ROOT)" push

update: ## Pull committed updates from GitHub and deploy locally
	@cd "$(ROOT)" && test -z "$$(git status --porcelain)" || { echo 'Commit or stash local changes before make update.' >&2; exit 1; }
	@cd "$(ROOT)" && git pull --ff-only
	@$(MAKE) --no-print-directory -C "$(ROOT)" deploy
