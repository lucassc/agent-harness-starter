# Thin wrapper around scripts/ and docker compose. Logic lives in the scripts; read docs/SETUP.md first.
# Defaults are safe: init and wipe are dry runs unless you use their -apply target; nothing here reads secrets/.
# Usage: make help    |    make up AGENT=agent-example
# To add an agent: copy its blocks in compose.yaml, then add its name to AGENTS below.

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules --no-print-directory

AGENTS := agent-example
AGENT ?= agent-example
ifeq ($(filter $(AGENT),$(AGENTS)),)
  $(error AGENT must be one of: $(AGENTS) (got: $(AGENT)))
endif
PROXY := $(AGENT:agent-%=proxy-%)
COMPOSE := docker compose -f compose.yaml

# scan-image fails on any HIGH/CRITICAL finding not in agents/$(AGENT)/trivy-accepted.txt (scripts/check-trivy.sh).
REPORTS := .reports

.PHONY: help lint build scan-image up check stop logs ps init init-apply wipe

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
	@echo "  AGENT=$(AGENT) (one of: $(AGENTS))"

lint: ## Static checks: gitleaks, shellcheck, semgrep, checkov, compose syntax
	@scripts/lint.sh

build: ## Build the agent image (pinned base + checksum-verified gh)
	$(COMPOSE) build $(AGENT)

scan-image: build ## Trivy HIGH/CRITICAL on the agent image; fails on findings not in the accepted list
	@mkdir -p -m 700 $(REPORTS)
	@image="$$($(COMPOSE) config --format json | jq -er '.services["$(AGENT)"].image')"; \
	 out="$(REPORTS)/trivy-$(AGENT).json"; \
	 echo "trivy: $$image (report: $$out)"; \
	 trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --format json -o "$$out" "$$image"; \
	 scripts/check-trivy.sh $(AGENT) "$$out"

up: scan-image ## Build, scan, start proxy then agent, then run both checks
	$(COMPOSE) up -d $(PROXY)
	$(COMPOSE) up -d $(AGENT)
	@$(MAKE) check AGENT=$(AGENT)

check: ## Egress allowlist + managed config checks against the running agent
	scripts/check-egress.sh --run $(AGENT)
	scripts/check-config.sh --run $(AGENT)

stop: ## Stop the agent and its proxy (restart policy is "no")
	$(COMPOSE) stop $(AGENT) $(PROXY)

logs: ## Follow the agent log (Ctrl-C to stop)
	$(COMPOSE) logs -f $(AGENT)

ps: ## Show container status
	$(COMPOSE) ps

init: ## Dry run: show how the data dir would be created
	scripts/init-dirs.sh $(AGENT)

init-apply: ## Create the data dir for UID 10000, mode 700 (asks for sudo)
	scripts/init-dirs.sh --apply $(AGENT)

wipe: ## Dry run only: show what deleting the agent's state would remove
	scripts/wipe-agent.sh $(AGENT)
	@echo "To really delete: stop the agent, then run scripts/wipe-agent.sh --apply --yes $(AGENT) yourself."
