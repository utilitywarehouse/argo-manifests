# vars.mk — shared variables and tool bootstrap.
#
# Included by conventions.mk (per package) and by the root Makefile (which defines
# its own fan-out targets, so it must not include conventions.mk).

SHELL := /bin/bash

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
POLICY := $(ROOT)/policy
BUILD_DIR ?= bin

KUSTOMIZE ?= kustomize
ARGO ?= argo
CONFTEST ?= conftest
# Pinned by mise, not fetched by npx: a floating prettier can reformat and turn CI
# red with no change to the repo. --ignore-path is explicit because make runs it
# from a package directory, where it would not find the repo-root .prettierignore.
PRETTIER ?= prettier --ignore-path $(ROOT)/../.prettierignore

TOOLS := $(KUSTOMIZE) $(ARGO) $(CONFTEST) $(firstword $(PRETTIER))

MISE_TOML := $(ROOT)/../mise.toml

# The version the cluster runs (drives system/Makefile's get-upstream), stripped of
# its leading v to compare against the mise pin.
ARGO_VERSION := $(patsubst v%,%,$(shell awk -F= '/^VERSION=/{print $$2}' $(ROOT)/system/Makefile))

.PHONY: tools argo-version

# Fails early with what to install rather than a confusing error mid-run, and
# catches the one pin that can silently drift.
tools:
	@missing=""; \
	for t in $(TOOLS); do \
		command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "❌ missing tools:$$missing"; \
		echo "   mise install"; \
		exit 1; \
	fi; \
	pinned=$$(awk -F'"' '/^argo /{print $$2}' $(MISE_TOML)); \
	if [ "$$pinned" != "$(ARGO_VERSION)" ]; then \
		echo "❌ argo $$pinned in mise.toml but $(ARGO_VERSION) in system/Makefile"; \
		echo "   lint would run a different version than the cluster"; \
		exit 1; \
	fi; \
	echo "✅ tools (argo $$pinned)"

argo-version:
	@echo $(ARGO_VERSION)
